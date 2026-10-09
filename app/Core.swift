// Pure logic for the herdr-cam window: argument parsing, key mapping, and the
// image pipeline. No AppKit or AVFoundation here, so tests/core can compile it
// headless with plain swiftc.

import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Options

struct Options: Equatable {
    var out: String
    var maxEdge: Int = 2048
    var quality: Double = 0.85
    var timerSeconds: Int = 3
    /// Skip the camera and run this file through the pipeline. Used by tests.
    var fakeImage: String?
    /// Start a countdown of this many seconds as soon as the camera is live.
    /// Used by the live camera e2e test, which has no hands to press Space.
    var autoCapture: Int?
}

enum OptionsError: Error, Equatable {
    case missingOut
    case missingValue(String)
    case badValue(String, String)
    case unknown(String)
}

func parseOptions(_ args: [String]) throws -> Options {
    var out: String?
    var opts = Options(out: "")
    var i = 0
    func value(_ flag: String) throws -> String {
        guard i + 1 < args.count else { throw OptionsError.missingValue(flag) }
        i += 1
        return args[i]
    }
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--out":
            out = try value(arg)
        case "--max-edge":
            let v = try value(arg)
            guard let n = Int(v), n >= 64 else { throw OptionsError.badValue(arg, v) }
            opts.maxEdge = n
        case "--quality":
            let v = try value(arg)
            guard let q = Double(v), q > 0, q <= 1 else { throw OptionsError.badValue(arg, v) }
            opts.quality = q
        case "--timer":
            let v = try value(arg)
            guard let n = Int(v), (1...30).contains(n) else { throw OptionsError.badValue(arg, v) }
            opts.timerSeconds = n
        case "--auto-capture":
            let v = try value(arg)
            guard let n = Int(v), (1...30).contains(n) else { throw OptionsError.badValue(arg, v) }
            opts.autoCapture = n
        case "--fake-image":
            opts.fakeImage = try value(arg)
        default:
            // LaunchServices may append its own single-dash args (-psn_..., -NS...).
            if arg.hasPrefix("--") { throw OptionsError.unknown(arg) }
        }
        i += 1
    }
    guard let o = out, !o.isEmpty else { throw OptionsError.missingOut }
    opts.out = o
    return opts
}

// MARK: - Keys

enum CamCommand: Equatable {
    case capture, timedCapture, cancel, nextCamera, toggleMirror
}

/// Maps a key press to a command. keyCode covers keys whose characters vary
/// by layout (Space, Return, Escape); letters go by character.
func camCommand(characters: String, keyCode: UInt16) -> CamCommand? {
    switch keyCode {
    case 49, 36, 76: return .capture  // space, return, keypad enter
    case 53: return .cancel  // escape
    default: break
    }
    switch characters.lowercased() {
    case "q": return .cancel
    case "c": return .nextCamera
    case "m": return .toggleMirror
    case "t": return .timedCapture
    default: return nil
    }
}

func hudText(camera: String, mirrored: Bool, countdown: Int?) -> String {
    if let n = countdown { return "Capturing in \(n)…   Esc cancel" }
    let mirror = mirrored ? "  ·  mirrored" : ""
    return "Space capture  ·  T timer  ·  C camera  ·  M mirror  ·  Esc cancel      [\(camera)\(mirror)]"
}

// MARK: - Image pipeline

enum PipelineError: Error, Equatable {
    case unreadable
    case encodeFailed
}

/// Decodes any ImageIO-readable image, applies its EXIF orientation, scales the
/// long edge down to maxEdge (never up), and re-encodes as JPEG.
func processImage(_ data: Data, maxEdge: Int, quality: Double) throws -> Data {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
        CGImageSourceGetCount(src) > 0
    else { throw PipelineError.unreadable }

    let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
    let w = props[kCGImagePropertyPixelWidth] as? Int ?? maxEdge
    let h = props[kCGImagePropertyPixelHeight] as? Int ?? maxEdge
    let target = min(maxEdge, max(w, h))

    let thumbOpts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: target,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary)
    else { throw PipelineError.unreadable }

    let out = NSMutableData()
    guard
        let dest = CGImageDestinationCreateWithData(
            out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
    else { throw PipelineError.encodeFailed }
    let destOpts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
    CGImageDestinationAddImage(dest, image, destOpts as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw PipelineError.encodeFailed }
    return out as Data
}

/// Writes next to the target then renames, so a reader never sees a partial file.
func writeAtomically(_ data: Data, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}

/// Failure reasons go to "<out>.err" so the launcher can surface them.
func writeError(_ message: String, out: String) {
    try? writeAtomically(Data((message + "\n").utf8), to: out + ".err")
}
