//
//  CensorKitTests.swift
//  CensorKitTests
//
//  Created by David Sherlock on 2026.
//
//  The rules pinned pure (grammar, tracks, matching, naming, ledger),
//  the render path proven on synthesized stills and video with no
//  Vision in sight, and — where the real-portrait fixtures exist — the
//  detector and the except-rule proven on actual faces, pixel-checked.
//

import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import CensorKit

final class CensorKitTests: XCTestCase {

    // MARK: - Pure rules

    func testRegionGrammar() throws {
        let plain = try RegionGrammar.parse("0.1,0.2,0.3,0.4")
        XCTAssertEqual(plain, Region(x: 0.1, y: 0.2, width: 0.3, height: 0.4))

        let timed = try RegionGrammar.parse("0,0,1,1@2-5.5")
        XCTAssertEqual(timed.start, 2)
        XCTAssertEqual(timed.end, 5.5)
        XCTAssertTrue(timed.covers(at: 3))
        XCTAssertFalse(timed.covers(at: 6))

        XCTAssertThrowsError(try RegionGrammar.parse("0.1,0.2,0.3"))
        XCTAssertThrowsError(try RegionGrammar.parse("0.1,0.2,0.3,1.4"))
        XCTAssertThrowsError(try RegionGrammar.parse("0.5,0.5,0.6,0.1"), "reaches outside")
        XCTAssertThrowsError(try RegionGrammar.parse("0,0,0,0.5"), "zero size")
        XCTAssertThrowsError(try RegionGrammar.parse("0,0,1,1@5-2"), "backwards window")
    }

    func testTrackAssociationKeepsIdentityAndStartsNewTracks() {
        // Two subjects far apart, drifting slowly right; a third appears late.
        var samples: [[TrackMath.Detection]] = []
        for i in 0..<5 {
            let t = Double(i) * 0.25
            var sample = [
                TrackMath.Detection(time: t, x: 0.1 + Double(i) * 0.02, y: 0.1, width: 0.1, height: 0.1),
                TrackMath.Detection(time: t, x: 0.7 - Double(i) * 0.02, y: 0.7, width: 0.1, height: 0.1),
            ]
            if i >= 3 {
                sample.append(TrackMath.Detection(time: t, x: 0.4, y: 0.4, width: 0.1, height: 0.1))
            }
            samples.append(sample)
        }
        let tracks = TrackMath.associate(samples)
        XCTAssertEqual(tracks.count, 3)
        XCTAssertEqual(tracks[0].keyframes.count, 5)
        XCTAssertEqual(tracks[1].keyframes.count, 5)
        XCTAssertEqual(tracks[2].keyframes.count, 2, "the latecomer keeps its own track")
        // Identity held: track 0's boxes all near the top-left path.
        XCTAssertTrue(tracks[0].keyframes.allSatisfy { $0.y == 0.1 })
    }

    func testSmoothingHoldAndInterpolation() {
        let jittery = [
            TrackedBox(time: 0.0, x: 0.50, y: 0.5, width: 0.1, height: 0.1),
            TrackedBox(time: 0.5, x: 0.60, y: 0.5, width: 0.1, height: 0.1),
            TrackedBox(time: 1.0, x: 0.40, y: 0.5, width: 0.1, height: 0.1),
        ]
        let smoothed = TrackMath.smooth(jittery, alpha: 0.5)
        XCTAssertEqual(smoothed[1].x, 0.55, accuracy: 1e-9, "half-weight toward the new sample")
        XCTAssertEqual(smoothed[2].x, 0.475, accuracy: 1e-9)

        let held = TrackMath.extend(smoothed, hold: 0.75)
        XCTAssertEqual(held.last?.time ?? 0, 1.75, accuracy: 1e-9)
        XCTAssertEqual(held.last?.x ?? 0, 0.475, accuracy: 1e-9, "the hold freezes the last box")

        XCTAssertNil(TrackMath.box(at: -0.1, in: held))
        XCTAssertNil(TrackMath.box(at: 1.76, in: held))
        let mid = TrackMath.box(at: 0.25, in: held)
        XCTAssertEqual(mid?.x ?? 0, 0.525, accuracy: 1e-9, "linear between keyframes")
    }

    func testFaceMatchingThresholdAndSelection() {
        let reference: [Float] = [1, 0, 0, 0]
        let near: [Float] = [1, 0.79, 0, 0]   // distance 0.79
        let far: [Float] = [1, 0.81, 0, 0]    // distance 0.81
        XCTAssertTrue(FaceMatching.matches(near, anyOf: [reference]))
        XCTAssertFalse(FaceMatching.matches(far, anyOf: [reference]))

        XCTAssertFalse(FaceMatching.shouldCover(near, except: [reference], only: []),
                       "a face matching --except is left alone")
        XCTAssertTrue(FaceMatching.shouldCover(far, except: [reference], only: []))
        XCTAssertTrue(FaceMatching.shouldCover(near, except: [], only: [reference]))
        XCTAssertFalse(FaceMatching.shouldCover(far, except: [], only: [reference]))
        XCTAssertTrue(FaceMatching.shouldCover(far, except: [], only: []), "no selection covers everyone")
    }

    func testOutputNamingAndSkipRule() {
        let input = URL(fileURLWithPath: "/a/sub/pic.JPG")
        XCTAssertEqual(
            OutputNaming.output(for: input, outDir: nil, root: nil, isVideo: false).path,
            "/a/sub/pic-censored.jpg")
        XCTAssertEqual(
            OutputNaming.output(for: URL(fileURLWithPath: "/a/clip.mp4"),
                                outDir: nil, root: nil, isVideo: true).path,
            "/a/clip-censored.mov", "video always lands in .mov")
        XCTAssertEqual(
            OutputNaming.output(for: input, outDir: URL(fileURLWithPath: "/out"),
                                root: URL(fileURLWithPath: "/a"), isVideo: false).path,
            "/out/sub/pic-censored.jpg", "out-dir mirrors the structure")

        let old = Date(timeIntervalSince1970: 100)
        let new = Date(timeIntervalSince1970: 200)
        XCTAssertTrue(OutputNaming.shouldSkip(inputModified: old, outputModified: new, force: false))
        XCTAssertFalse(OutputNaming.shouldSkip(inputModified: new, outputModified: old, force: false))
        XCTAssertFalse(OutputNaming.shouldSkip(inputModified: old, outputModified: new, force: true))
        XCTAssertFalse(OutputNaming.shouldSkip(inputModified: old, outputModified: nil, force: false))
    }

    func testLedger() {
        var ledger = Ledger()
        ledger.record(FileOutcome(input: "a", status: .covered, covers: 2))
        ledger.record(FileOutcome(input: "b", status: .skipped))
        ledger.record(FileOutcome(input: "c", status: .failed, detail: "boom"))
        XCTAssertEqual(ledger.covered, 1)
        XCTAssertEqual(ledger.skipped, 1)
        XCTAssertEqual(ledger.failed, 1)
        XCTAssertFalse(ledger.succeeded)
        XCTAssertEqual(ledger.summary, "1 covered · 1 skipped · 1 FAILED")
        XCTAssertEqual(Ledger().summary, "nothing to do")
    }

    func testTextMatch() {
        XCTAssertTrue(TextMatch.matches("Call 555-0199 today", pattern: "555-01"))
        XCTAssertTrue(TextMatch.matches("REGISTRATION XYZ", pattern: "xyz"))
        XCTAssertFalse(TextMatch.matches("nothing here", pattern: "555"))
        XCTAssertFalse(TextMatch.matches("anything", pattern: ""))
    }

    // MARK: - Render path (no Vision)

    /// A four-quadrant PNG: enough structure that any cover changes pixels.
    private func makeQuadrantImage(at url: URL, side: Int = 200) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let half = CGFloat(side) / 2
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: half, height: half))
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: half, y: 0, width: half, height: half))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: half, width: half, height: half))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: half, y: half, width: half, height: half))
        let image = context.makeImage()!
        let ci = CIImage(cgImage: image)
        try CIContext().writePNGRepresentation(of: ci, to: url, format: .RGBA8, colorSpace: space)
    }

    private func pixel(_ url: URL, x: Int, y: Int) throws -> (r: UInt8, g: UInt8, b: UInt8) {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        var data = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8,
                                bytesPerRow: 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -CGFloat(x), y: -CGFloat(image.height - 1 - y),
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        return (data[0], data[1], data[2])
    }

    func testStillRegionCoverChangesInsideLeavesOutside() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("censor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("board.png")
        try makeQuadrantImage(at: input)
        let output = dir.appendingPathComponent("board-censored.png")

        let region = Region(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        let outcome = try ImageCensor.censor(
            imageAt: input, target: .regions([region]),
            style: CoverStyle(mode: .blur, intensity: 1, padding: 0),
            to: output, dryRun: false)
        XCTAssertEqual(outcome.status, .covered)
        XCTAssertEqual(outcome.covers, 1)

        // The quadrant boundary runs through the region's middle: a heavy
        // blur mixes the colors there. The far corners sit outside.
        let before = try pixel(input, x: 100, y: 100)
        let after = try pixel(output, x: 100, y: 100)
        XCTAssertNotEqual([before.r, before.g, before.b], [after.r, after.g, after.b],
                          "the covered center must change")
        let cornerBefore = try pixel(input, x: 5, y: 5)
        let cornerAfter = try pixel(output, x: 5, y: 5)
        XCTAssertEqual([cornerBefore.r, cornerBefore.g, cornerBefore.b],
                       [cornerAfter.r, cornerAfter.g, cornerAfter.b],
                       "outside the cover stays byte-identical")
    }

    func testDryRunRendersNothing() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("censor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("board.png")
        try makeQuadrantImage(at: input)
        let output = dir.appendingPathComponent("board-censored.png")

        let outcome = try ImageCensor.censor(
            imageAt: input, target: .regions([Region(x: 0.25, y: 0.25, width: 0.5, height: 0.5)]),
            style: CoverStyle(), to: output, dryRun: true)
        XCTAssertEqual(outcome.status, .wouldCover)
        XCTAssertEqual(outcome.covers, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    /// A short synthesized H.264 video of the quadrant board.
    private func makeVideo(at url: URL, seconds: Double = 1, fps: Int32 = 24, side: Int = 160) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: side, AVVideoHeightKey: side,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: side, kCVPixelBufferHeightKey as String: side,
            ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("frame-\(UUID().uuidString).png")
        try makeQuadrantImage(at: tmp, side: side)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let frame = CIImage(contentsOf: tmp)!
        let context = CIContext()

        let frames = Int(seconds * Double(fps))
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { usleep(2000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            context.render(frame, to: buffer!)
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()
        let done = XCTestExpectation(description: "written")
        writer.finishWriting { done.fulfill() }
        wait(for: [done], timeout: 30)
        XCTAssertEqual(writer.status, .completed)
    }

    func testVideoRegionCoverAndContainerContract() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("censor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("clip.mov")
        try makeVideo(at: input)
        let output = dir.appendingPathComponent("clip-censored.mov")

        let outcome = try await VideoCensor.censor(
            videoAt: input,
            target: .regions([Region(x: 0.3, y: 0.3, width: 0.4, height: 0.4)]),
            style: CoverStyle(mode: .blur, intensity: 1, padding: 0),
            to: output, dryRun: false)
        XCTAssertEqual(outcome.status, .covered)

        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 1.0, accuracy: 0.15)

        // Read the middle frame: center mixed by the blur, corner still its
        // quadrant color (H.264 is lossy — compare with tolerance).
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(readerOutput)
        XCTAssertTrue(reader.startReading())
        var middle: CVPixelBuffer?
        while let sample = readerOutput.copyNextSampleBuffer() {
            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if t >= 0.5, middle == nil { middle = CMSampleBufferGetImageBuffer(sample) }
        }
        let buffer = try XCTUnwrap(middle)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        func bgra(_ x: Int, _ y: Int) -> (b: Int, g: Int, r: Int) {
            let p = y * rowBytes + x * 4
            return (Int(base[p]), Int(base[p + 1]), Int(base[p + 2]))
        }
        // Top-left corner of the board is blue (video y=0 is top).
        let corner = bgra(5, 5)
        XCTAssertGreaterThan(corner.b, 180, "corner keeps its quadrant color")
        XCTAssertLessThan(corner.r, 80)
        // The center under a full blur mixes all four quadrants: no channel
        // stays saturated.
        let center = bgra(80, 80)
        XCTAssertLessThan(center.b, 220)
        XCTAssertGreaterThan(center.b + center.g + center.r, 120, "blurred, not blacked out")
    }

    // MARK: - Quality parity

    func testWriterSettingsDerivation() {
        // The real iPhone HDR story: HEVC 10-bit HLG at 31 Mb/s.
        let hdr = WriterSettings.derive(
            codecSubtype: "hvc1", width: 3840, height: 2160,
            estimatedDataRate: 31_000_000, nominalFrameRate: 24,
            bitsPerComponent: 10, colorPrimaries: "ITU_R_2020",
            transferFunction: "ITU_R_2100_HLG", yCbCrMatrix: "ITU_R_2020")
        XCTAssertEqual(hdr.codec, "hvc1")
        XCTAssertEqual(hdr.profileLevel, "HEVC_Main10_AutoLevel")
        XCTAssertEqual(hdr.averageBitRate, 31_000_000, "never below the source's rate")
        XCTAssertEqual(hdr.expectedFrameRate, 24)
        XCTAssertEqual(hdr.transferFunction, "ITU_R_2100_HLG")
        XCTAssertEqual(hdr.pixelFormat, kCVPixelFormatType_ARGB2101010LEPacked)

        // Plain 8-bit H.264 with no rate estimate: the resolution floor.
        let sdr = WriterSettings.derive(
            codecSubtype: "avc1", width: 1920, height: 1080,
            estimatedDataRate: 0, nominalFrameRate: 30,
            bitsPerComponent: 8, colorPrimaries: nil,
            transferFunction: nil, yCbCrMatrix: nil)
        XCTAssertEqual(sdr.codec, "avc1")
        XCTAssertNil(sdr.profileLevel)
        XCTAssertEqual(sdr.averageBitRate, Int(1920.0 * 1080 * 30 * 0.05))
        XCTAssertFalse(sdr.hasColorProperties)
        XCTAssertEqual(sdr.pixelFormat, kCVPixelFormatType_32BGRA)

        // A partial color set is dropped whole — the writer rejects partial
        // dictionaries, and guessing the missing member invents color.
        let partial = WriterSettings.derive(
            codecSubtype: "hvc1", width: 100, height: 100,
            estimatedDataRate: 5_000_000, nominalFrameRate: 30,
            bitsPerComponent: 8, colorPrimaries: "ITU_R_709_2",
            transferFunction: nil, yCbCrMatrix: "ITU_R_709_2")
        XCTAssertFalse(partial.hasColorProperties)
        XCTAssertNil(partial.colorPrimaries)

        // Any 10-bit source is HEVC Main10, whatever it arrived as: the
        // H.264 path is 8-bit and would truncate.
        let prores = WriterSettings.derive(
            codecSubtype: "ap4h", width: 1920, height: 1080,
            estimatedDataRate: 80_000_000, nominalFrameRate: 25,
            bitsPerComponent: 10, colorPrimaries: nil,
            transferFunction: nil, yCbCrMatrix: nil)
        XCTAssertEqual(prores.codec, "hvc1")
        XCTAssertEqual(prores.profileLevel, "HEVC_Main10_AutoLevel")
    }

    /// A small Main10 HLG clip for the end-to-end depth/color probe.
    private func makeTenBitHLGVideo(at url: URL, side: Int = 320, seconds: Double = 1) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: side, AVVideoHeightKey: side,
            AVVideoCompressionPropertiesKey: [
                AVVideoProfileLevelKey: "HEVC_Main10_AutoLevel",
                AVVideoAverageBitRateKey: 4_000_000,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_ARGB2101010LEPacked,
                kCVPixelBufferWidthKey as String: side, kCVPixelBufferHeightKey as String: side,
            ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("frame10-\(UUID().uuidString).png")
        try makeQuadrantImage(at: tmp, side: side)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let frame = CIImage(contentsOf: tmp)!
        let context = CIContext()
        let fps: Int32 = 24
        for i in 0..<Int(seconds * Double(fps)) {
            while !input.isReadyForMoreMediaData { usleep(2000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            context.render(frame, to: buffer!)
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()
        let done = XCTestExpectation(description: "written")
        writer.finishWriting { done.fulfill() }
        wait(for: [done], timeout: 30)
        XCTAssertEqual(writer.status, .completed)
    }

    private func videoStory(of url: URL) async throws -> (subtype: String, bits: Int?,
                                                          primaries: String?, transfer: String?) {
        let asset = AVURLAsset(url: url)
        // XCTUnwrap's autoclosure cannot await — hoist the loads first.
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let descriptions = try await track.load(.formatDescriptions)
        let desc = try XCTUnwrap(descriptions.first)
        let sub = CMFormatDescriptionGetMediaSubType(desc)
        let subtype = String(format: "%c%c%c%c", (sub >> 24) & 255, (sub >> 16) & 255,
                             (sub >> 8) & 255, sub & 255)
        let ext = CMFormatDescriptionGetExtensions(desc) as? [String: Any]
        return (subtype, ext?["BitsPerComponent"] as? Int,
                ext?["CVImageBufferColorPrimaries"] as? String,
                ext?["CVImageBufferTransferFunction"] as? String)
    }

    func testTenBitHEVCSurvivesTheRoundTrip() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("censor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("hdr.mov")
        try makeTenBitHLGVideo(at: input)

        let source = try await videoStory(of: input)
        XCTAssertEqual(source.subtype, "hvc1")
        XCTAssertEqual(source.bits, 10, "the fixture itself must be 10-bit")
        XCTAssertEqual(source.transfer, "ITU_R_2100_HLG")

        let output = dir.appendingPathComponent("hdr-censored.mov")
        let outcome = try await VideoCensor.censor(
            videoAt: input,
            target: .regions([Region(x: 0.3, y: 0.3, width: 0.4, height: 0.4)]),
            style: CoverStyle(mode: .pixelate, intensity: 1),
            to: output, dryRun: false)
        XCTAssertEqual(outcome.status, .covered)

        let written = try await videoStory(of: output)
        XCTAssertEqual(written.subtype, "hvc1", "HEVC in, HEVC out")
        XCTAssertEqual(written.bits, 10, "10-bit survives the cover pass")
        XCTAssertEqual(written.primaries, "ITU_R_2020")
        XCTAssertEqual(written.transfer, "ITU_R_2100_HLG", "HLG is not flattened to SDR")
    }

    // MARK: - Real faces (gated on the local fixtures folder)

    private var fixtures: URL? {
        let path = ProcessInfo.processInfo.environment["CENSOR_FACE_FIXTURES"]
            ?? NSString(string: "~/Developer/Swift/Libraries/.face-fixtures").expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    func testDetectsARealFace() throws {
        guard let fixtures else { throw XCTSkip("no face fixtures on this machine") }
        let url = fixtures.appendingPathComponent("businesswoman-isolated.jpg")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("fixture businesswoman-isolated.jpg missing")
        }
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        let faces = try Detector.faces(in: image, withEmbeddings: true)
        let face = try XCTUnwrap(faces.first, "the stock photo holds one detectable face")
        XCTAssertTrue(face.x >= 0 && face.x + face.width <= 1)
        XCTAssertTrue(face.y >= 0 && face.y + face.height <= 1)
        XCTAssertFalse(face.embedding.isEmpty, "identity mode carries a crop embedding")
    }

    func testExceptLeavesTheReferencedPersonAlone() throws {
        guard let fixtures else { throw XCTSkip("no face fixtures on this machine") }
        // Left: a different person (illustration). Right: the stock model.
        // Reference: the SAME model from a DIFFERENT shoot — the hardest
        // honest form of the match.
        let left = fixtures.appendingPathComponent("self-portrait.jpg")
        let right = fixtures.appendingPathComponent("businesswoman-isolated.jpg")
        let reference = fixtures.appendingPathComponent("businesswoman-walking.jpg")
        for url in [left, right, reference]
        where !FileManager.default.fileExists(atPath: url.path) {
            throw XCTSkip("fixture \(url.lastPathComponent) missing")
        }

        // Two different people side by side on one canvas.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("censor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let canvasURL = dir.appendingPathComponent("pair.png")

        let leftImage = CGImageSourceCreateImageAtIndex(
            CGImageSourceCreateWithURL(left as CFURL, nil)!, 0, nil)!
        let rightImage = CGImageSourceCreateImageAtIndex(
            CGImageSourceCreateWithURL(right as CFURL, nil)!, 0, nil)!
        let height = 480
        func scaled(_ image: CGImage) -> CGSize {
            let s = CGFloat(height) / CGFloat(image.height)
            return CGSize(width: CGFloat(image.width) * s, height: CGFloat(height))
        }
        let leftSize = scaled(leftImage)
        let rightSize = scaled(rightImage)
        let width = Int(leftSize.width + rightSize.width)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(leftImage, in: CGRect(origin: .zero, size: leftSize))
        context.draw(rightImage, in: CGRect(origin: CGPoint(x: leftSize.width, y: 0), size: rightSize))
        try CIContext().writePNGRepresentation(
            of: CIImage(cgImage: context.makeImage()!), to: canvasURL,
            format: .RGBA8, colorSpace: space)

        // Reference is the SAME person as the right half, from a different file.
        let embedding = try References.embedding(fromImageAt: reference)
        let output = dir.appendingPathComponent("pair-censored.png")
        let outcome = try ImageCensor.censor(
            imageAt: canvasURL, target: .faces(except: [embedding], only: []),
            style: CoverStyle(mode: .pixelate, intensity: 1, padding: 0.1),
            to: output, dryRun: false)

        XCTAssertEqual(outcome.status, .covered)
        XCTAssertEqual(outcome.covers, 1, "one face covered, the referenced one spared: \(outcome.detail ?? "")")

        // Pixel proof: the left half changed, the right half did not.
        let beforeSource = CGImageSourceCreateWithURL(canvasURL as CFURL, nil)!
        let afterSource = CGImageSourceCreateWithURL(output as CFURL, nil)!
        let before = CGImageSourceCreateImageAtIndex(beforeSource, 0, nil)!
        let after = CGImageSourceCreateImageAtIndex(afterSource, 0, nil)!
        func rgba(_ image: CGImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let ctx = CGContext(data: &data, width: image.width, height: image.height,
                                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return data
        }
        let a = rgba(before)
        let b = rgba(after)
        let split = Int(leftSize.width)
        var changedLeft = 0
        var changedRight = 0
        for y in 0..<height {
            for x in 0..<width {
                let p = (y * width + x) * 4
                if a[p] != b[p] || a[p + 1] != b[p + 1] || a[p + 2] != b[p + 2] {
                    if x < split { changedLeft += 1 } else { changedRight += 1 }
                }
            }
        }
        XCTAssertGreaterThan(changedLeft, 500, "the unreferenced face was covered")
        XCTAssertEqual(changedRight, 0, "the referenced person is untouched, to the pixel")
    }
}
