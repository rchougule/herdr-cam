// Pure logic for the herdr-cam window: argument parsing, key mapping, the tray of
// captured photos, the result file, and the image pipeline. No AppKit or
// AVFoundation here, so tests/core can compile it headless with plain swiftc.

import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Options

struct Options: Equatable {
    /// Base path for this run. Photos go to "<out>-1.jpg", "<out>-2.jpg", …
    /// and the outcome to "<out>.result".
    var out: String
    var maxEdge: Int = 2048
    var quality: Double = 0.85
    var timerSeconds: Int = 3
    var maxShots: Int = 10
    /// Close (discarding photos) after this long without a key press, so a forgotten
    /// window never leaves the camera running.
    var idleSeconds: Int = 180
    // Test hooks. Parsed only in test builds (-D HERDR_CAM_TESTING), so a release
    // bundle cannot be driven to take a photo without someone pressing a key.
    var fakeImages: [String] = []
    var autoCapture: Int?
    var autoShots: Int = 1
}

enum OptionsError: Error, Equatable, CustomStringConvertible {
    case missingOut
    case missingValue(String)
    case badValue(String, String)
    case unknown(String)

    var description: String {
        switch self {
        case .missingOut: return "missing --out"
        case .missingValue(let f): return "\(f) needs a value"
        case .badValue(let f, let v): return "invalid value '\(v)' for \(f)"
        case .unknown(let f): return "unknown option \(f)"
        }
    }
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
    func int(_ flag: String, _ range: ClosedRange<Int>) throws -> Int {
        let v = try value(flag)
        guard let n = Int(v), range.contains(n) else { throw OptionsError.badValue(flag, v) }
        return n
    }
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--out":
            out = try value(arg)
        case "--max-edge":
            opts.maxEdge = try int(arg, 64...8192)
        case "--quality":
            let v = try value(arg)
            guard let q = Double(v), q > 0, q <= 1 else { throw OptionsError.badValue(arg, v) }
            opts.quality = q
        case "--timer":
            opts.timerSeconds = try int(arg, 1...30)
        case "--max-shots":
            opts.maxShots = try int(arg, 1...20)
        case "--idle-timeout":
            opts.idleSeconds = try int(arg, 10...3600)
        #if HERDR_CAM_TESTING
        case "--fake-image":
            opts.fakeImages.append(try value(arg))
        case "--auto-capture":
            opts.autoCapture = try int(arg, 1...30)
        case "--auto-shots":
            opts.autoShots = try int(arg, 1...20)
        #endif
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

/// The --out value even when other options are invalid, so a bad option can still be
/// reported through the result file instead of vanishing with the app's stderr.
func outArgument(_ args: [String]) -> String? {
    guard let i = args.firstIndex(of: "--out"), i + 1 < args.count, !args[i + 1].isEmpty else { return nil }
    return args[i + 1]
}

// MARK: - Keys

enum CamCommand: Equatable {
    case capture, send, undo, timedCapture, cancel, nextCamera, toggleMirror
}

/// Maps a key press to a command. keyCode covers keys whose characters vary by
/// layout; letters go by character and only without ⌘/⌃/⌥, so ⌘C and friends do
/// nothing instead of switching cameras.
func camCommand(characters: String, keyCode: UInt16, modified: Bool = false) -> CamCommand? {
    if modified {
        // ⌘W / ⌘Q close the window the usual way.
        return ["w", "q"].contains(characters.lowercased()) ? .cancel : nil
    }
    switch keyCode {
    case 49: return .capture  // space
    case 36, 76: return .send  // return, keypad enter
    case 51, 117: return .undo  // delete, forward delete
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

func hudText(camera: String, mirrored: Bool, countdown: Int?, shots: Int = 0) -> String {
    if let n = countdown { return "Capturing in \(n)…   Esc cancel" }
    let status = "[\(camera)\(mirrored ? "  ·  mirrored" : "")]"
    if shots == 0 {
        return "Space capture  ·  Enter send  ·  T timer  ·  C camera  ·  M mirror  ·  Esc cancel    \(status)"
    }
    let photos = shots == 1 ? "1 photo" : "\(shots) photos"
    return "Space add  ·  Enter send \(photos)  ·  ⌫ undo  ·  T timer  ·  Esc discard    \(status)"
}

// MARK: - Tray

/// The photos taken so far in this window, in order.
struct Tray: Equatable {
    let base: String
    let limit: Int
    private(set) var shots: [String] = []
    private var taken = 0

    init(base: String, limit: Int) {
        self.base = base
        self.limit = limit
    }

    var isFull: Bool { shots.count >= limit }

    /// Path for the next photo. Numbers are never reused, even after an undo.
    mutating func nextPath() -> String {
        taken += 1
        return "\(base)-\(taken).jpg"
    }

    @discardableResult
    mutating func add(_ path: String) -> Bool {
        guard !isFull else { return false }
        shots.append(path)
        return true
    }

    mutating func undo() -> String? { shots.popLast() }
}

// MARK: - Result file

/// How a run ended, written to "<out>.result" for bin/herdr-cam:
///   ok\n<path>\n<path>…   cancel   error\n<message>
/// A missing file means the app crashed or never started.
enum RunResult: Equatable {
    case ok([String])
    case cancel
    case error(String)

    var encoded: String {
        switch self {
        case .ok(let paths): return (["ok"] + paths).joined(separator: "\n") + "\n"
        case .cancel: return "cancel\n"
        case .error(let msg): return "error\n\(msg.replacingOccurrences(of: "\n", with: " "))\n"
        }
    }

    static func decode(_ text: String) -> RunResult? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        switch lines.first {
        case "ok": return .ok(lines.dropFirst().filter { !$0.isEmpty })
        case "cancel": return .cancel
        case "error": return .error(lines.count > 1 ? lines[1] : "")
        default: return nil
        }
    }
}

func writeResult(_ result: RunResult, base: String) {
    try? writeAtomically(Data(result.encoded.utf8), to: base + ".result")
}

// MARK: - Image pipeline

enum PipelineError: Error, Equatable {
    case unreadable
    case encodeFailed
}

/// Decodes any ImageIO-readable image, applies its EXIF orientation, scales the
/// long edge down to maxEdge (never up), and re-encodes as JPEG with no metadata.
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
/// Photos and results are private to the user: 0700 directories, 0600 files.
func writeAtomically(_ data: Data, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
}
