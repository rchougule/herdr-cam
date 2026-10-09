// Headless tests for app/Core.swift. scripts/test.sh builds and runs them twice, as a
// test build and as a release build, so the hook-gating is checked both ways:
//   swiftc -D HERDR_CAM_TESTING app/Core.swift tests/core/main.swift -o build/core-tests
//   swiftc app/Core.swift tests/core/main.swift -o build/core-tests-release
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
    let o = try! parseOptions(["--out", "/tmp/a"])
    check(o == Options(out: "/tmp/a"), "defaults apply")

    let full = try! parseOptions([
        "--out", "/x", "--max-edge", "1024", "--quality", "0.5", "--timer", "5", "--max-shots", "4",
    ])
    check(full.maxEdge == 1024 && full.quality == 0.5 && full.timerSeconds == 5, "values parsed")
    check(full.maxShots == 4, "max shots parsed")
    check(o.idleSeconds == 180, "idle timeout defaults to 3 minutes")
    check(try! parseOptions(["--out", "/x", "--idle-timeout", "60"]).idleSeconds == 60, "idle timeout parsed")

    let psn = try! parseOptions(["-psn_0_12345", "--out", "/x", "-NSDocumentRevisionsDebugMode", "YES"])
    check(psn.out == "/x", "LaunchServices single-dash args are ignored")

    expectThrows(OptionsError.missingOut, "out required") { _ = try parseOptions([]) }
    expectThrows(OptionsError.missingOut, "empty out rejected") { _ = try parseOptions(["--out", ""]) }
    expectThrows(OptionsError.missingValue("--out"), "dangling flag") { _ = try parseOptions(["--out"]) }
    for (flag, bad) in [("--quality", "2"), ("--quality", "0"), ("--max-edge", "10"), ("--max-edge", "9000"),
                        ("--timer", "0"), ("--timer", "31"), ("--max-shots", "0"),
                        ("--idle-timeout", "5"), ("--idle-timeout", "4000")] {
        expectThrows(OptionsError.badValue(flag, bad), "\(flag) rejects \(bad)") {
            _ = try parseOptions(["--out", "/x", flag, bad])
        }
    }
    expectThrows(OptionsError.unknown("--nope"), "unknown long flag") {
        _ = try parseOptions(["--out", "/x", "--nope"])
    }
    check(OptionsError.badValue("--quality", "2").description == "invalid value '2' for --quality", "readable error")

    check(outArgument(["--quality", "9", "--out", "/b"]) == "/b", "out found despite bad options")
    check(outArgument(["--out"]) == nil && outArgument(["--out", ""]) == nil, "no out, no result path")

    #if HERDR_CAM_TESTING
    let hooks = try! parseOptions(["--out", "/x", "--fake-image", "/a.png", "--fake-image", "/b.png",
                                   "--auto-capture", "4", "--auto-shots", "2"])
    check(hooks.fakeImages == ["/a.png", "/b.png"], "fake images repeat")
    check(hooks.autoCapture == 4 && hooks.autoShots == 2, "auto capture parsed")
    expectThrows(OptionsError.badValue("--auto-capture", "0"), "auto capture range") {
        _ = try parseOptions(["--out", "/x", "--auto-capture", "0"])
    }
    #else
    // Release builds must not be drivable without a key press.
    for hook in ["--fake-image", "--auto-capture", "--auto-shots"] {
        expectThrows(OptionsError.unknown(hook), "release build rejects \(hook)") {
            _ = try parseOptions(["--out", "/x", hook, "1"])
        }
    }
    #endif
}

// camCommand
check(camCommand(characters: " ", keyCode: 49) == .capture, "space captures")
check(camCommand(characters: "\r", keyCode: 36) == .send, "return sends")
check(camCommand(characters: "\u{3}", keyCode: 76) == .send, "keypad enter sends")
check(camCommand(characters: "\u{7f}", keyCode: 51) == .undo, "delete undoes")
check(camCommand(characters: "\u{1b}", keyCode: 53) == .cancel, "escape cancels")
check(camCommand(characters: "Q", keyCode: 12) == .cancel, "q cancels, any case")
check(camCommand(characters: "c", keyCode: 8) == .nextCamera, "c cycles camera")
check(camCommand(characters: "m", keyCode: 46) == .toggleMirror, "m toggles mirror")
check(camCommand(characters: "t", keyCode: 17) == .timedCapture, "t starts timer")
check(camCommand(characters: "x", keyCode: 7) == nil, "other keys ignored")
check(camCommand(characters: "c", keyCode: 8, modified: true) == nil, "cmd-c does not switch camera")
check(camCommand(characters: "w", keyCode: 13, modified: true) == .cancel, "cmd-w closes")
check(camCommand(characters: " ", keyCode: 49, modified: true) == nil, "modified space ignored")

// Tray
do {
    var tray = Tray(base: "/c/note", limit: 2)
    let a = tray.nextPath(), b = tray.nextPath()
    check(a == "/c/note-1.jpg" && b == "/c/note-2.jpg", "numbered paths")
    check(tray.add(a) && tray.add(b), "adds up to the limit")
    check(tray.isFull && !tray.add("/c/note-3.jpg"), "refuses past the limit")
    check(tray.undo() == b && tray.shots == [a], "undo drops the last photo")
    check(tray.nextPath() == "/c/note-3.jpg", "numbers are not reused after undo")
    _ = tray.undo()
    check(tray.undo() == nil, "undo on empty tray is a no-op")
}

// RunResult
do {
    let ok = RunResult.ok(["/a-1.jpg", "/a-2.jpg"])
    check(ok.encoded == "ok\n/a-1.jpg\n/a-2.jpg\n", "ok encodes paths one per line")
    check(RunResult.decode(ok.encoded) == ok, "ok round-trips")
    check(RunResult.decode(RunResult.cancel.encoded) == .cancel, "cancel round-trips")
    let err = RunResult.error("two\nlines")
    check(err.encoded == "error\ntwo lines\n", "error message kept on one line")
    check(RunResult.decode(err.encoded) == .error("two lines"), "error round-trips")
    check(RunResult.decode("garbage") == nil && RunResult.decode("") == nil, "unknown result rejected")
}

// hudText
check(hudText(camera: "FaceTime HD", mirrored: false, countdown: nil).contains("[FaceTime HD]"), "hud names camera")
check(hudText(camera: "X", mirrored: true, countdown: nil).contains("mirrored"), "hud shows mirror")
check(hudText(camera: "X", mirrored: false, countdown: 2).hasPrefix("Capturing in 2"), "hud countdown")
check(hudText(camera: "X", mirrored: false, countdown: nil).hasPrefix("Space capture"), "hud empty tray")
check(hudText(camera: "X", mirrored: false, countdown: nil, shots: 2).contains("Enter send 2 photos"), "hud counts photos")
check(hudText(camera: "X", mirrored: false, countdown: nil, shots: 1).contains("send 1 photo "), "hud singular")

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

    // EXIF orientation 6 (rotated 90°): the output must come out upright, so the
    // width and height swap and no orientation tag is left behind.
    let rotated = NSMutableData()
    let rdest = CGImageDestinationCreateWithData(rotated as CFMutableData, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImageFromSource(rdest, src, 0, [kCGImagePropertyOrientation: 6] as CFDictionary)
    CGImageDestinationFinalize(rdest)
    let upright = try! processImage(rotated as Data, maxEdge: 4096, quality: 0.8)
    let (uw, uh, _) = pixelSize(upright)
    check(uw == fh && uh == fw, "orientation applied, got \(uw)x\(uh)")
    let uprops = CGImageSourceCopyPropertiesAtIndex(
        CGImageSourceCreateWithData(upright as CFData, nil)!, 0, nil) as! [CFString: Any]
    check((uprops[kCGImagePropertyOrientation] as? Int ?? 1) == 1, "no orientation tag left")

    let low = try! processImage(fixture, maxEdge: 320, quality: 0.2)
    let high = try! processImage(fixture, maxEdge: 320, quality: 0.95)
    check(low.count < high.count, "quality is applied (\(low.count) < \(high.count) bytes)")

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
    let perms = (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int
    check(perms == 0o600, "photo is private to the user, got \(String(perms ?? 0, radix: 8))")
    let dperms = (try? FileManager.default.attributesOfItem(atPath: (path as NSString).deletingLastPathComponent))?[.posixPermissions] as? Int
    check(dperms == 0o700, "new directories are private, got \(String(dperms ?? 0, radix: 8))")
    writeResult(.cancel, base: dir.appendingPathComponent("run").path)
    let res = String(data: FileManager.default.contents(atPath: dir.appendingPathComponent("run.result").path) ?? Data(), encoding: .utf8)
    check(res == "cancel\n", "result file written")
    try? FileManager.default.removeItem(at: dir)
}

print("core: \(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
