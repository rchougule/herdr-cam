// Headless tests for app/Core.swift. Built and run by scripts/test.sh:
//   swiftc app/Core.swift tests/core/main.swift -o build/core-tests
// XCTest is not shipped with the Command Line Tools, so this is a tiny runner.

import Foundation
import ImageIO

var failures = 0
var passed = 0

func check(_ cond: @autoclosure () -> Bool, _ name: String, line: Int = #line) {
    if cond() {
        passed += 1
    } else {
        failures += 1
        print("FAIL line \(line): \(name)")
    }
}

func expectThrows<E: Error & Equatable>(_ expected: E, _ name: String, _ body: () throws -> Void) {
    do {
        try body()
        check(false, "\(name): expected \(expected), nothing thrown")
    } catch let e as E {
        check(e == expected, "\(name): expected \(expected), got \(e)")
    } catch {
        check(false, "\(name): unexpected error \(error)")
    }
}

func pixelSize(_ data: Data) -> (Int, Int, String) {
    let src = CGImageSourceCreateWithData(data as CFData, nil)!
    let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
    let type = CGImageSourceGetType(src) as String? ?? ""
    return (p[kCGImagePropertyPixelWidth] as! Int, p[kCGImagePropertyPixelHeight] as! Int, type)
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let fixture = try! Data(contentsOf: root.appendingPathComponent("tests/fixtures/test.png"))

// parseOptions
do {
    let o = try! parseOptions(["--out", "/tmp/a.jpg"])
    check(o == Options(out: "/tmp/a.jpg"), "defaults apply")

    let full = try! parseOptions([
        "--out", "/x.jpg", "--max-edge", "1024", "--quality", "0.5", "--timer", "5",
        "--fake-image", "/f.png",
    ])
    check(full.maxEdge == 1024 && full.quality == 0.5 && full.timerSeconds == 5, "values parsed")
    check(full.fakeImage == "/f.png", "fake image parsed")
    check(full.autoCapture == nil, "auto capture off by default")

    let auto = try! parseOptions(["--out", "/x.jpg", "--auto-capture", "4"])
    check(auto.autoCapture == 4, "auto capture parsed")
    expectThrows(OptionsError.badValue("--auto-capture", "0"), "auto capture range") {
        _ = try parseOptions(["--out", "/x", "--auto-capture", "0"])
    }

    let psn = try! parseOptions(["-psn_0_12345", "--out", "/x.jpg", "-NSDocumentRevisionsDebugMode", "YES"])
    check(psn.out == "/x.jpg", "LaunchServices single-dash args are ignored")

    expectThrows(OptionsError.missingOut, "out required") { _ = try parseOptions([]) }
    expectThrows(OptionsError.missingValue("--out"), "dangling flag") { _ = try parseOptions(["--out"]) }
    expectThrows(OptionsError.badValue("--quality", "2"), "quality range") {
        _ = try parseOptions(["--out", "/x", "--quality", "2"])
    }
    expectThrows(OptionsError.badValue("--max-edge", "10"), "max-edge floor") {
        _ = try parseOptions(["--out", "/x", "--max-edge", "10"])
    }
    expectThrows(OptionsError.unknown("--nope"), "unknown long flag") {
        _ = try parseOptions(["--out", "/x", "--nope"])
    }
}

// camCommand
check(camCommand(characters: " ", keyCode: 49) == .capture, "space captures")
check(camCommand(characters: "\r", keyCode: 36) == .capture, "return captures")
check(camCommand(characters: "\u{1b}", keyCode: 53) == .cancel, "escape cancels")
check(camCommand(characters: "Q", keyCode: 12) == .cancel, "q cancels, any case")
check(camCommand(characters: "c", keyCode: 8) == .nextCamera, "c cycles camera")
check(camCommand(characters: "m", keyCode: 46) == .toggleMirror, "m toggles mirror")
check(camCommand(characters: "t", keyCode: 17) == .timedCapture, "t starts timer")
check(camCommand(characters: "x", keyCode: 7) == nil, "other keys ignored")

// hudText
check(hudText(camera: "FaceTime HD", mirrored: false, countdown: nil).contains("[FaceTime HD]"), "hud names camera")
check(hudText(camera: "X", mirrored: true, countdown: nil).contains("mirrored"), "hud shows mirror")
check(hudText(camera: "X", mirrored: false, countdown: 2).hasPrefix("Capturing in 2"), "hud countdown")

// processImage
do {
    let (fw, fh, _) = pixelSize(fixture)
    let small = try! processImage(fixture, maxEdge: 100, quality: 0.8)
    let (w, h, type) = pixelSize(small)
    check(type == "public.jpeg", "output is JPEG, got \(type)")
    check(max(w, h) == 100, "long edge scaled to maxEdge, got \(w)x\(h)")
    check(abs(Double(w) / Double(h) - Double(fw) / Double(fh)) < 0.02, "aspect ratio kept")

    let big = try! processImage(fixture, maxEdge: 4096, quality: 0.8)
    let (bw, bh, _) = pixelSize(big)
    check(bw == fw && bh == fh, "never upscales, got \(bw)x\(bh)")

    // Privacy: camera and location metadata must not survive the pipeline.
    let tagged = NSMutableData()
    let src = CGImageSourceCreateWithData(fixture as CFData, nil)!
    let dest = CGImageDestinationCreateWithData(tagged as CFMutableData, "public.jpeg" as CFString, 1, nil)!
    let meta: [CFString: Any] = [
        kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 12.97, kCGImagePropertyGPSLongitude: 77.59],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "MacBook"],
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:09 11:00:00"],
    ]
    CGImageDestinationAddImageFromSource(dest, src, 0, meta as CFDictionary)
    CGImageDestinationFinalize(dest)
    let taggedProps = CGImageSourceCopyPropertiesAtIndex(
        CGImageSourceCreateWithData(tagged as CFData, nil)!, 0, nil) as! [CFString: Any]
    check(taggedProps[kCGImagePropertyGPSDictionary] != nil, "fixture really carries GPS before processing")

    let cleaned = try! processImage(tagged as Data, maxEdge: 200, quality: 0.8)
    let props = CGImageSourceCopyPropertiesAtIndex(
        CGImageSourceCreateWithData(cleaned as CFData, nil)!, 0, nil) as! [CFString: Any]
    check(props[kCGImagePropertyGPSDictionary] == nil, "GPS stripped")
    let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
    check(tiff[kCGImagePropertyTIFFMake] == nil && tiff[kCGImagePropertyTIFFModel] == nil, "camera make/model stripped")
    let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
    check(exif[kCGImagePropertyExifDateTimeOriginal] == nil, "capture timestamp stripped")

    expectThrows(PipelineError.unreadable, "garbage input") {
        _ = try processImage(Data("not an image".utf8), maxEdge: 100, quality: 0.8)
    }
}

// writeAtomically / writeError
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("herdr-cam-\(UUID())")
    let path = dir.appendingPathComponent("nested/out.jpg").path
    try! writeAtomically(Data([1, 2, 3]), to: path)
    check(FileManager.default.contents(atPath: path) == Data([1, 2, 3]), "creates parents and writes")
    writeError("camera denied", out: path)
    let err = String(data: FileManager.default.contents(atPath: path + ".err") ?? Data(), encoding: .utf8)
    check(err == "camera denied\n", "error sidecar written")
    try? FileManager.default.removeItem(at: dir)
}

print("core: \(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
