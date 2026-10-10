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
import CoreText
import Foundation
import Vision
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
        // The tail is MOVING (0.55 → 0.475 over 0.5 s = 0.15/s), so the
        // hold continues the motion: 0.475 − 0.15 × 0.75.
        XCTAssertEqual(held.last?.x ?? 0, 0.3625, accuracy: 1e-9,
                       "a moving hold follows the exit velocity")

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
            style: CoverStyle(mode: .blur, intensity: 1, padding: 1),
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

    /// A JPEG carrying everything a shared photo should not: where it was
    /// taken, the camera and its serial number, and who took it.
    private func makeTaggedJPEG(at url: URL) throws {
        let png = url.deletingPathExtension().appendingPathExtension("png")
        try makeQuadrantImage(at: png)
        let source = CGImageSourceCreateWithURL(png as CFURL, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        let properties: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 51.5007, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 0.1246, kCGImagePropertyGPSLongitudeRef: "W"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 17 Pro",
                                             kCGImagePropertyTIFFArtist: "Someone"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifBodySerialNumber: "C39XK2ABCDEF",
                                             kCGImagePropertyExifDateTimeOriginal: "2026:10:10 09:00:00"],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCByline: ["Someone"]],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try FileManager.default.removeItem(at: png)
    }

    func testACoveredPhotoKeepsNoLocationCameraOrAuthor() throws {
        // Found 2026-10-10: CIImage(contentsOf:) carries the source's
        // properties through every filter and writeJPEGRepresentation wrote
        // them back — GPS, make, model and serial number all survived a
        // "redacted" copy.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("censor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("photo.jpg")
        try makeTaggedJPEG(at: input)
        XCTAssertFalse(MetadataCheck.leaks(in: input).isEmpty, "the fixture must carry what the test looks for")

        for ext in ["jpg", "heic", "png"] {
            let output = dir.appendingPathComponent("photo-censored.\(ext)")
            _ = try ImageCensor.censor(imageAt: input, target: .regions([Region(x: 0.3, y: 0.3, width: 0.4, height: 0.4)]),
                                       style: CoverStyle(mode: .blur, intensity: 1, padding: 1),
                                       to: output, dryRun: false)
            XCTAssertEqual(MetadataCheck.leaks(in: output), [], "\(ext) kept metadata")
        }
    }

    func testTheMetadataCheckNamesWhatItFinds() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("censor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("photo.jpg")
        try makeTaggedJPEG(at: input)
        let found = Set(MetadataCheck.leaks(in: input))
        XCTAssertTrue(found.isSuperset(of: ["GPS", "camera", "serial number", "author", "IPTC"]), "\(found)")
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

    /// A clip carrying what an iPhone video carries about its maker: where it
    /// was shot and on what, in the container AND as a timed metadata track.
    private func makeTaggedVideo(at url: URL) throws {
        let plain = url.deletingLastPathComponent().appendingPathComponent("plain-\(UUID().uuidString).mov")
        try makeVideo(at: plain)
        defer { try? FileManager.default.removeItem(at: plain) }

        func item(_ identifier: String, _ value: String) -> AVMutableMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = AVMetadataIdentifier(identifier)
            item.value = value as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            return item
        }
        let location = "mdta/com.apple.quicktime.location.ISO6709"

        let source = AVURLAsset(url: plain)
        let reader = try AVAssetReader(asset: source)
        let videoTrack = source.tracks(withMediaType: .video)[0]
        let readerOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        reader.add(readerOutput)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.metadata = [item(location, "+51.5007-000.1246/"), item("mdta/com.apple.quicktime.make", "Apple"),
                           item("mdta/com.apple.quicktime.model", "iPhone 17 Pro")]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                            sourceFormatHint: videoTrack.formatDescriptions.first as! CMFormatDescription)
        writer.add(videoInput)
        // A timed track that says where, every moment of the clip.
        let spec = [kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier: location,
                    kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType: kCMMetadataBaseDataType_UTF8] as NSDictionary
        var description: CMFormatDescription?
        CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: nil, metadataType: kCMMetadataFormatType_Boxed,
                                                                   metadataSpecifications: [spec] as CFArray, formatDescriptionOut: &description)
        let metadataInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: description)
        let adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)
        writer.add(metadataInput)

        reader.startReading()
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        adaptor.append(AVTimedMetadataGroup(items: [item(location, "+51.5007-000.1246/")],
                                            timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1))))
        metadataInput.markAsFinished()
        while let sample = readerOutput.copyNextSampleBuffer() {
            while !videoInput.isReadyForMoreMediaData { usleep(2000) }
            videoInput.append(sample)
        }
        videoInput.markAsFinished()
        let done = XCTestExpectation(description: "written")
        writer.finishWriting { done.fulfill() }
        wait(for: [done], timeout: 30)
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
    }

    func testACoveredVideoKeepsNoLocationOrCamera() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("censor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("clip.mov")
        try makeTaggedVideo(at: input)
        let before = await MetadataCheck.videoLeaks(in: input)
        XCTAssertTrue(Set(before).isSuperset(of: ["location", "camera", "timed location"]), "the fixture carries \(before)")

        let output = dir.appendingPathComponent("clip-censored.mov")
        _ = try await VideoCensor.censor(videoAt: input, target: .regions([Region(x: 0.3, y: 0.3, width: 0.4, height: 0.4)]),
                                         style: CoverStyle(mode: .blur, intensity: 1, padding: 1), to: output, dryRun: false)
        let after = await MetadataCheck.videoLeaks(in: output)
        XCTAssertEqual(after, [], "the censored clip still carries \(after)")
    }

    /// A one-second clip of a card held up to the camera: two lines of text
    /// on every frame, one of them a card number.
    private func makeTextVideo(at url: URL, lines: [String]) throws {
        let width = 640, height = 360
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<24 {
            while !input.isReadyForMoreMediaData { usleep(2000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            CVPixelBufferLockBaseAddress(buffer!, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer!), width: width, height: height,
                                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer!),
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            for (index, line) in lines.enumerated() {
                context.textPosition = CGPoint(x: 40, y: CGFloat(height - 120 - index * 70))
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Menlo" as CFString, 34, nil)])), context)
            }
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 24))
        }
        input.markAsFinished()
        let done = XCTestExpectation(description: "written")
        writer.finishWriting { done.fulfill() }
        wait(for: [done], timeout: 30)
    }

    private func ocrFrame(of url: URL, at seconds: Double) async throws -> String {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    func testACallersRuleCoversTextInVideoSolidly() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("censor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("card.mov")
        try makeTextVideo(at: input, lines: ["Membership ACME", "4111 1111 1111 1111"])
        let before = try await ocrFrame(of: input, at: 0.5)
        XCTAssertTrue(before.contains("4111"), "the fixture shows the number: \(before)")

        // A rule only the caller knows: sixteen digits, here.
        let rule = TextMatcher(summary: "card") { $0.filter(\.isNumber).count == 16 }
        let output = dir.appendingPathComponent("card-covered.mov")
        let outcome = try await VideoCensor.censor(videoAt: input, target: .matching(rule),
                                                   style: CoverStyle(mode: .solid, intensity: 1, padding: 1.1),
                                                   to: output, dryRun: false)
        XCTAssertEqual(outcome.status, .covered)
        for t in [0.1, 0.5, 0.9] {
            let after = try await ocrFrame(of: output, at: t)
            XCTAssertFalse(after.contains("4111"), "at \(t)s the number still reads: \(after)")
            XCTAssertTrue(after.contains("ACME"), "the rest of the frame stays legible")
        }
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
            style: CoverStyle(mode: .blur, intensity: 1, padding: 1),
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

    // MARK: - Coverage, orientation and exit rules

    func testFaceGeometryGrowsUpAndOut() {
        let head = FaceGeometry.coverBox(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        XCTAssertEqual(head.width, 0.32, accuracy: 1e-9, "1.6× wide")
        XCTAssertEqual(head.height, 0.44, accuracy: 1e-9, "2.2× tall")
        XCTAssertEqual(head.x, 0.34, accuracy: 1e-9, "widened symmetrically")
        // 0.24 of added height, 65% of it above: y = 0.4 − 0.156.
        XCTAssertEqual(head.y, 0.244, accuracy: 1e-9, "the growth is biased above — hair lives there")

        let clamped = FaceGeometry.coverBox(x: 0.9, y: 0.02, width: 0.15, height: 0.1)
        XCTAssertLessThanOrEqual(clamped.x + clamped.width, 1.0)
        XCTAssertGreaterThanOrEqual(clamped.y, 0.0)
    }

    func testOrientationMapping() {
        let portrait = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 2160, ty: 0)
        XCTAssertEqual(OrientationMap.quarterTurns(of: portrait), 1)
        XCTAssertEqual(OrientationMap.quarterTurns(of: .identity), 0)
        XCTAssertEqual(OrientationMap.quarterTurns(of: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 0, ty: 0)), 2)
        XCTAssertEqual(OrientationMap.visionOrientation(quarterTurns: 1), .right)

        // Display top-center → storage right-center, for a 90° CW display
        // rotation (derived by hand: xs = yd, ys = 1 − xd − wd).
        let s1 = OrientationMap.toStorage(x: 0.45, y: 0.05, width: 0.1, height: 0.08, quarterTurns: 1)
        XCTAssertEqual(s1.x, 0.05, accuracy: 1e-9)
        XCTAssertEqual(s1.y, 0.45, accuracy: 1e-9)
        XCTAssertEqual(s1.width, 0.08, accuracy: 1e-9)
        XCTAssertEqual(s1.height, 0.1, accuracy: 1e-9)

        // Round trips: mapping by turns then by the inverse turns is identity.
        for (turns, inverse) in [(1, 3), (2, 2), (3, 1)] {
            let once = OrientationMap.toStorage(x: 0.2, y: 0.3, width: 0.25, height: 0.15, quarterTurns: turns)
            let back = OrientationMap.toStorage(x: once.x, y: once.y, width: once.width,
                                                height: once.height, quarterTurns: inverse)
            XCTAssertEqual(back.x, 0.2, accuracy: 1e-9, "turns \(turns)")
            XCTAssertEqual(back.y, 0.3, accuracy: 1e-9)
            XCTAssertEqual(back.width, 0.25, accuracy: 1e-9)
            XCTAssertEqual(back.height, 0.15, accuracy: 1e-9)
        }
    }

    func testExitAwareHold() {
        // Stationary: frozen in place, the conservative occlusion case.
        let still = [TrackedBox(time: 0, x: 0.4, y: 0.4, width: 0.1, height: 0.1),
                     TrackedBox(time: 0.5, x: 0.401, y: 0.4, width: 0.1, height: 0.1)]
        let frozen = TrackMath.extend(still, hold: 0.75)
        XCTAssertEqual(frozen.last?.x ?? 0, 0.401, accuracy: 1e-9)
        XCTAssertEqual(frozen.last?.time ?? 0, 1.25, accuracy: 1e-9)

        // Walking off the right edge: the hold slides with the exit and is
        // cut once the box would be fully outside.
        let leaving = [TrackedBox(time: 0, x: 0.6, y: 0.4, width: 0.2, height: 0.2),
                       TrackedBox(time: 0.25, x: 0.8, y: 0.4, width: 0.2, height: 0.2)]
        let slid = TrackMath.extend(leaving, hold: 0.75)
        // Velocity 0.8/s rightward; fully out when x reaches 1.0 → 0.25 s.
        XCTAssertEqual(slid.last?.time ?? 0, 0.5, accuracy: 1e-9, "the hold decays at the edge")
        XCTAssertEqual(slid.last?.x ?? 0, 1.0, accuracy: 1e-9, "…having slid to it, not frozen mid-air")
    }

    func testRotatedVideoCoversTrackTheDisplayPath() async throws {
        guard let fixtures else { throw XCTSkip("no face fixtures on this machine") }
        let portraitURL = fixtures.appendingPathComponent("businesswoman-isolated.jpg")
        guard FileManager.default.fileExists(atPath: portraitURL.path) else {
            throw XCTSkip("fixture businesswoman-isolated.jpg missing")
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("censor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Storage 640×360 shown as 360×640 portrait via a 90° CW transform.
        // The portrait glides down the DISPLAY: x_d fixed, y_d 0.05 → 0.25.
        let W = 640, H = 360, fps: Int32 = 12, frames = 24
        let source = CIImage(contentsOf: portraitURL)!
        // Upright in display = rotated 90° CCW in storage.
        let rotated = source.oriented(.left)
        // Person height ≈ 0.9 of display height = 0.9 × W in storage x-extent.
        let scale = 0.9 * CGFloat(W) / rotated.extent.width
        let sprite = rotated.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let input = dir.appendingPathComponent("rotated.mov")
        let writer = try AVAssetWriter(outputURL: input, fileType: .mov)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: W, AVVideoHeightKey: H,
        ])
        videoInput.transform = CGAffineTransform(rotationAngle: .pi / 2)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H,
            ])
        writer.add(videoInput)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let context = CIContext()
        let ground = CIImage(color: CIColor(red: 0.2, green: 0.25, blue: 0.2))
            .cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
        var displayTops: [Double] = []
        for i in 0..<frames {
            let f = Double(i) / Double(frames - 1)
            let yd = 0.05 + f * 0.20                      // display top of the sprite
            displayTops.append(yd)
            // Display (xd fixed ≈ centered) → storage: the sprite's display
            // top-left maps to storage with x_s = y_d (hand-derived).
            let sx = CGFloat(yd) * CGFloat(W)
            let sy = (CGFloat(H) - sprite.extent.height) / 2
            let frame = sprite
                .transformed(by: CGAffineTransform(translationX: sx - sprite.extent.origin.x,
                                                   y: sy - sprite.extent.origin.y))
                .composited(over: ground)
            while !videoInput.isReadyForMoreMediaData { usleep(2000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            context.render(frame, to: buffer!)
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        videoInput.markAsFinished()
        let done = XCTestExpectation(description: "written")
        writer.finishWriting { done.fulfill() }
        await fulfillment(of: [done], timeout: 30)
        XCTAssertEqual(writer.status, .completed)

        let output = dir.appendingPathComponent("rotated-censored.mov")
        let outcome = try await VideoCensor.censor(
            videoAt: input, target: .faces(FaceSelection()),
            style: CoverStyle(mode: .pixelate, intensity: 1),
            to: output, dryRun: false,
            options: VideoCensor.Options(detectStride: 0.15, hold: 0.3))
        XCTAssertEqual(outcome.status, .covered, outcome.detail ?? "")

        // Compare source and censored frames midway: the changed pixels
        // must sit where the face is — in STORAGE space, x near the
        // sprite's display-y position (plus the in-sprite face offset),
        // y in the band the face occupies.
        func frameAt(_ url: URL, index: Int) async throws -> CVPixelBuffer {
            let asset = AVURLAsset(url: url)
            let track = try await asset.loadTracks(withMediaType: .video).first!
            let reader = try AVAssetReader(asset: asset)
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(out)
            XCTAssertTrue(reader.startReading())
            var n = 0
            while let sample = out.copyNextSampleBuffer() {
                if n == index, let buffer = CMSampleBufferGetImageBuffer(sample) {
                    reader.cancelReading()
                    return buffer
                }
                n += 1
            }
            fatalError("frame \(index) missing")
        }
        let midIndex = frames / 2
        let a = try await frameAt(input, index: midIndex)
        let b = try await frameAt(output, index: midIndex)
        CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let baseA = CVPixelBufferGetBaseAddress(a)!.assumingMemoryBound(to: UInt8.self)
        let baseB = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
        let rowA = CVPixelBufferGetBytesPerRow(a), rowB = CVPixelBufferGetBytesPerRow(b)
        var sumX = 0.0, sumY = 0.0, count = 0.0
        for y in 0..<H {
            for x in 0..<W {
                let pa = y * rowA + x * 4, pb = y * rowB + x * 4
                let d = abs(Int(baseA[pa]) - Int(baseB[pb])) + abs(Int(baseA[pa + 1]) - Int(baseB[pb + 1]))
                    + abs(Int(baseA[pa + 2]) - Int(baseB[pb + 2]))
                if d > 90 { sumX += Double(x); sumY += Double(y); count += 1 }
            }
        }
        XCTAssertGreaterThan(count, 300, "the cover must have changed a real region")
        let cx = sumX / count / Double(W)
        let cy = sumY / count / Double(H)
        // Expected face center in storage: display top yd(mid) plus the
        // face's in-sprite offset. Face in the portrait sits at display
        // fractions (x 0.41–0.56, y 0.10–0.20 of the image) → in storage
        // x runs with display y. Sprite occupies 0.9 of display height.
        let yd = displayTops[midIndex]
        let expectedCX = yd + (0.10 + 0.05) * 0.9      // display-y of face center × sprite span
        // Storage y = 1 − xd − w: the sprite is x-centered in display, the
        // face at 0.41–0.56 of its width; sprite width in display ≈
        // sprite.extent.height/H of the display width.
        let spriteDisplayW = Double(sprite.extent.height) / Double(H)
        let faceDX = 0.5 - spriteDisplayW / 2 + (0.41 + 0.075) * spriteDisplayW
        let expectedCY = 1 - faceDX
        XCTAssertEqual(cx, expectedCX, accuracy: 0.12,
                       "cover tracks the display-space path (storage x)")
        XCTAssertEqual(cy, expectedCY, accuracy: 0.15,
                       "cover sits on the face, not offset (storage y)")
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

    // MARK: - Tiling, ordering, selection, head extent, gaps

    func testTilingGridAndMapping() {
        let tiles = Tiling.grid(3, overlap: 0.2)
        XCTAssertEqual(tiles.count, 9)
        for tile in tiles {
            XCTAssertGreaterThanOrEqual(tile.x, 0)
            XCTAssertLessThanOrEqual(tile.x + tile.width, 1.0 + 1e-9)
            XCTAssertLessThanOrEqual(tile.y + tile.height, 1.0 + 1e-9)
        }
        let side = tiles[0].width
        let step = tiles[1].x - tiles[0].x
        XCTAssertEqual(side - step, side * 0.2, accuracy: 1e-9, "neighbours share the overlap")
        XCTAssertEqual(Tiling.grid(1), [Tiling.Tile(x: 0, y: 0, width: 1, height: 1)])

        let tile = Tiling.Tile(x: 0.5, y: 0.25, width: 0.4, height: 0.4)
        let framed = Tiling.toFrame(x: 0.25, y: 0.5, width: 0.5, height: 0.25, tile: tile)
        XCTAssertEqual(framed.x, 0.6, accuracy: 1e-9)
        XCTAssertEqual(framed.y, 0.45, accuracy: 1e-9)
        XCTAssertEqual(framed.width, 0.2, accuracy: 1e-9)
        XCTAssertEqual(framed.height, 0.1, accuracy: 1e-9)
    }

    func testTilingMergeDropsDuplicatesKeepsDistinct() {
        let big = TrackMath.Detection(time: 0, x: 0.10, y: 0.10, width: 0.20, height: 0.20)
        let dupe = TrackMath.Detection(time: 0, x: 0.11, y: 0.11, width: 0.18, height: 0.18)
        let other = TrackMath.Detection(time: 0, x: 0.70, y: 0.70, width: 0.10, height: 0.10)
        let merged = Tiling.merge([dupe, big, other])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].width, 0.20, accuracy: 1e-9, "the larger of a duplicate pair wins")
    }

    func testFaceOrderingReadsLeftToRight() {
        let a = TrackMath.Detection(time: 0, x: 0.6, y: 0.2, width: 0.1, height: 0.1)
        let b = TrackMath.Detection(time: 0, x: 0.1, y: 0.5, width: 0.1, height: 0.1)
        let c = TrackMath.Detection(time: 0, x: 0.605, y: 0.6, width: 0.1, height: 0.1)
        let ordered = FaceOrdering.ordered([a, c, b])
        XCTAssertEqual(ordered[0].x, 0.1, "leftmost is number 1")
        XCTAssertEqual(ordered[1].y, 0.2, "a near-tied column falls back to top-to-bottom")
        XCTAssertEqual(ordered[2].y, 0.6)
    }

    func testFaceSelectionComposes() {
        let ref: [Float] = [1, 0, 0, 0]
        let matching: [Float] = [1, 0.5, 0, 0]
        let stranger: [Float] = [3, 3, 3, 3]

        let numbersOnly = FaceSelection(onlyNumbers: [2, 4])
        XCTAssertTrue(numbersOnly.usesNumbers)
        XCTAssertFalse(numbersOnly.wantsIdentity)
        XCTAssertTrue(numbersOnly.shouldCover(number: 2, embedding: []))
        XCTAssertFalse(numbersOnly.shouldCover(number: 3, embedding: []))

        let skip = FaceSelection(skipNumbers: [1])
        XCTAssertFalse(skip.shouldCover(number: 1, embedding: []))
        XCTAssertTrue(skip.shouldCover(number: 2, embedding: []))

        let both = FaceSelection(except: [ref], onlyNumbers: [1, 2])
        XCTAssertFalse(both.shouldCover(number: 1, embedding: matching), "matches --except")
        XCTAssertTrue(both.shouldCover(number: 1, embedding: stranger))
        XCTAssertFalse(both.shouldCover(number: 3, embedding: stranger), "outside --only numbers")

        XCTAssertFalse(FaceSelection().isSelective)
    }

    func testHeadExtentMeasuresTheComponentAndCutsTheTorso() throws {
        // A 10×12 grid: a 2-wide head column with hair above the face,
        // a neck running down into a 6-wide shoulder slab.
        let width = 10, height = 12
        var mask = [Bool](repeating: false, count: width * height)
        func fill(_ xs: ClosedRange<Int>, _ ys: ClosedRange<Int>) {
            for y in ys { for x in xs { mask[y * width + x] = true } }
        }
        fill(4...5, 1...4)
        fill(4...5, 5...11)
        fill(2...7, 8...11)
        let face = (x: 0.4, y: 0.2, width: 0.2, height: 0.2)
        let head = try XCTUnwrap(HeadExtent.headBox(
            mask: mask, width: width, height: height, face: face))
        XCTAssertEqual(head.y, 1.0 / 12, accuracy: 1e-9, "the hair above the face is covered")
        XCTAssertEqual(head.width, 0.2, accuracy: 1e-9, "the head stays head-wide")
        XCTAssertLessThan(head.y + head.height, 0.8, "the shoulder slab is cut away")

        XCTAssertNil(HeadExtent.headBox(
            mask: [Bool](repeating: false, count: width * height),
            width: width, height: height, face: face),
            "no mask under the face means no measured head")

        let margined = HeadExtent.withMargin((x: 0.45, y: 0.1, width: 0.2, height: 0.4), margin: 1.1)
        XCTAssertEqual(margined.width, 0.22, accuracy: 1e-9)
        XCTAssertEqual(margined.height, 0.44, accuracy: 1e-9)
    }

    func testCoverageGaps() {
        let duration = 10.0
        let exiting = Track(id: 0, keyframes: [
            TrackedBox(time: 0, x: 0.7, y: 0.4, width: 0.2, height: 0.2),
            TrackedBox(time: 1, x: 0.85, y: 0.4, width: 0.2, height: 0.2)])
        let lost = Track(id: 1, keyframes: [
            TrackedBox(time: 2, x: 0.4, y: 0.4, width: 0.1, height: 0.1),
            TrackedBox(time: 3, x: 0.41, y: 0.4, width: 0.1, height: 0.1)])
        let reacquired = Track(id: 2, keyframes: [
            TrackedBox(time: 4.2, x: 0.43, y: 0.41, width: 0.1, height: 0.1),
            TrackedBox(time: 9.95, x: 0.43, y: 0.41, width: 0.1, height: 0.1)])
        let vanished = Track(id: 3, keyframes: [
            TrackedBox(time: 5, x: 0.1, y: 0.7, width: 0.15, height: 0.15),
            TrackedBox(time: 6, x: 0.12, y: 0.7, width: 0.15, height: 0.15)])
        let gaps = TrackMath.gaps(in: [exiting, lost, reacquired, vanished], duration: duration)
        XCTAssertEqual(gaps.count, 2)
        XCTAssertEqual(gaps[0].track, 1)
        XCTAssertEqual(gaps[0].start, 3, accuracy: 1e-9)
        XCTAssertEqual(gaps[0].end, 4.2, accuracy: 1e-9, "review ends at the re-acquisition")
        XCTAssertEqual(gaps[1].track, 3)
        XCTAssertEqual(gaps[1].end, duration, accuracy: 1e-9, "never re-acquired: review to the end")
    }

    func testTiledPassFindsAFaceTheFullFrameMayMiss() throws {
        guard let fixtures else { throw XCTSkip("no face fixtures on this machine") }
        let url = fixtures.appendingPathComponent("businesswoman-isolated.jpg")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("fixture businesswoman-isolated.jpg missing")
        }
        let portrait = CGImageSourceCreateImageAtIndex(
            CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!
        let side = 3200
        let sprite = 600.0
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.35, green: 0.4, blue: 0.35, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let scale = sprite / Double(portrait.height)
        context.draw(portrait, in: CGRect(x: 400, y: 2400,
                                          width: Double(portrait.width) * scale, height: sprite))
        let canvas = context.makeImage()!

        let thorough = try Detector.facesThorough(in: canvas, withEmbeddings: false)
        XCTAssertGreaterThanOrEqual(thorough.count, 1, "the tiled pass finds the small face")
        let plain = try Detector.faces(in: canvas, withEmbeddings: false)
        XCTAssertGreaterThanOrEqual(thorough.count, plain.count,
                                    "tiling never loses what the full frame saw")
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
            imageAt: canvasURL, target: .faces(FaceSelection(except: [embedding])),
            style: CoverStyle(mode: .pixelate, intensity: 1, padding: 1.1),
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
