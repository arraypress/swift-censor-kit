//
//  PeopleTests.swift
//  CensorKitTests
//
//  Created by David Sherlock on 2026.
//
//  Video people and previews: tracks that stop at cuts, the grouping and
//  numbering rules pinned pure, and — where the real-portrait fixtures
//  exist — a three-shot video (one person, another, the first again from a
//  different shoot) listed, numbered and covered by number.
//

import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Vision
import XCTest
@testable import CensorKit

final class PeopleTests: XCTestCase {

    private func detection(_ t: Double, x: Double = 0.4) -> TrackMath.Detection {
        TrackMath.Detection(time: t, x: x, y: 0.3, width: 0.2, height: 0.2)
    }

    private func track(_ id: Int, from: Double, to: Double, x: Double = 0.4) -> Track {
        Track(id: id, keyframes: stride(from: from, through: to, by: 0.25).map {
            TrackedBox(time: $0, x: x, y: 0.3, width: 0.2, height: 0.2)
        })
    }

    // MARK: - Cuts

    func testATrackStopsAtACut() {
        let samples = (0..<8).map { [detection(Double($0) * 0.25)] }
        XCTAssertEqual(TrackMath.associate(samples).count, 1, "one shot, one track")
        let split = TrackMath.associate(samples, cuts: [1.0])
        XCTAssertEqual(split.count, 2, "the face after the cut is a new track")
        XCTAssertEqual(split[0].keyframes.last?.time, 0.75)
        XCTAssertEqual(split[1].keyframes.first?.time, 1.0)
    }

    func testLeadAndHoldStayInsideTheShot() {
        let keyframes = [TrackedBox(time: 1.1, x: 0.4, y: 0.3, width: 0.2, height: 0.2),
                         TrackedBox(time: 1.35, x: 0.4, y: 0.3, width: 0.2, height: 0.2)]
        XCTAssertEqual(TrackMath.leadIn(keyframes, by: 0.25).first?.time ?? 0, 0.85, accuracy: 1e-9)
        XCTAssertEqual(TrackMath.leadIn(keyframes, by: 0.25, cuts: [1.0]).first?.time, 1.0,
                       "a lead never reaches into the shot before")
        XCTAssertEqual(TrackMath.extend(keyframes, hold: 0.75).last?.time ?? 0, 2.1, accuracy: 1e-9)
        let held = TrackMath.extend(keyframes, hold: 0.75, cuts: [1.5])
        XCTAssertLessThan(held.last!.time, 1.5, "a hold ends before the next shot")
        XCTAssertEqual(TrackMath.extend(keyframes, hold: 0.75, cuts: [1.35 + 0.001]).count, 2,
                       "no room before the cut, no hold")
    }

    // MARK: - Grouping and numbering

    func testSideBySideFacesKeepTheirTracks() {
        // Two faces 0.1 apart; next sample Vision lists the right-hand one
        // first, drifted left. Taking tracks in that order swapped them.
        func face(_ t: Double, _ cx: Double) -> TrackMath.Detection {
            TrackMath.Detection(time: t, x: cx - 0.05, y: 0.3, width: 0.1, height: 0.1)
        }
        let tracks = TrackMath.associate([[face(0, 0.40), face(0, 0.50)], [face(0.25, 0.47), face(0.25, 0.52)]])
        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(tracks[0].keyframes.map { $0.x + 0.05 }.map { ($0 * 100).rounded() }, [40, 47])
        XCTAssertEqual(tracks[1].keyframes.map { $0.x + 0.05 }.map { ($0 * 100).rounded() }, [50, 52])
        // Listed right first, each drifted toward the other: taking the
        // first track in reach (not the closest pair) swaps them too.
        let crossed = TrackMath.associate([[face(0, 0.40), face(0, 0.50)], [face(0.25, 0.53), face(0.25, 0.45)]])
        XCTAssertEqual(crossed[0].keyframes.map { $0.x + 0.05 }.map { ($0 * 100).rounded() }, [40, 45])
        XCTAssertEqual(crossed[1].keyframes.map { $0.x + 0.05 }.map { ($0 * 100).rounded() }, [50, 53])
    }

    func testATrackIsSplitWhereItsFaceChanges() {
        // Two people crossing: track 0 is Anna, then Ben; track 1 the reverse.
        let tracks = [track(0, from: 0, to: 4), track(1, from: 0, to: 4, x: 0.6), track(2, from: 5, to: 6)]
        let votes: [PeopleGrouping.Vote] = [
            .init(track: 0, time: 0, group: "anna"), .init(track: 0, time: 1, group: "anna"),
            .init(track: 0, time: 2, group: nil), .init(track: 0, time: 3, group: "ben"),
            .init(track: 1, time: 0, group: "ben"), .init(track: 1, time: 3, group: "anna"),
            .init(track: 2, time: 5, group: nil),
        ]
        let (pieces, groups) = PeopleGrouping.split(tracks, votes: votes)
        XCTAssertEqual(pieces.map(\.id), [0, 3, 1, 4, 2], "new pieces take ids above every track, in order")
        XCTAssertEqual(pieces[0].keyframes.last?.time, 1.75, "the piece ends halfway between the crops")
        XCTAssertEqual(pieces[1].keyframes.first?.time, 2)
        XCTAssertEqual(pieces[0].keyframes.count + pieces[1].keyframes.count, tracks[0].keyframes.count,
                       "no sample lost or doubled")
        XCTAssertEqual(groups[0], "anna")
        XCTAssertEqual(groups[3], "ben")
        XCTAssertEqual(groups[1], "ben")
        XCTAssertEqual(groups[4], "anna")
        XCTAssertNil(groups[2], "no face seen, no group")
        let people = PeopleGrouping.people(pieces, groups: groups)
        XCTAssertEqual(people.map(\.tracks), [[0, 4], [1, 3], [2]],
                       "each person gets their own halves back")
    }

    func testACropAloneInItsGroupSplitsNothing() {
        let tracks = [track(0, from: 0, to: 3), track(1, from: 4, to: 5)]
        let votes: [PeopleGrouping.Vote] = [
            .init(track: 0, time: 0, group: "anna"), .init(track: 0, time: 1, group: "anna"),
            .init(track: 0, time: 3, group: "blur"), .init(track: 1, time: 4, group: "solo"),
        ]
        let (pieces, groups) = PeopleGrouping.split(tracks, votes: votes)
        XCTAssertEqual(pieces.map(\.id), [0, 1], "one odd crop is not a second person")
        XCTAssertEqual(groups[0], "anna")
        XCTAssertNil(groups[1], "a person seen once is a person alone")
    }

    func testCropsAreSpacedAlongATrack() {
        let times = PeopleGrouping.cropTimes(track(0, from: 0, to: 2.5).keyframes, spacing: 1).map(\.time)
        XCTAssertEqual(times, [0, 1, 2, 2.5], "about one a second, and the last")
        XCTAssertEqual(PeopleGrouping.cropTimes(track(0, from: 3, to: 3).keyframes, spacing: 1).count, 1)
    }

    func testPeopleAreNumberedByFirstAppearance() {
        let tracks = [track(0, from: 2, to: 3), track(1, from: 0, to: 1, x: 0.7), track(2, from: 0, to: 0.5, x: 0.1),
                      track(3, from: 5, to: 6, x: 0.7), track(4, from: 4, to: 4)]
        let people = PeopleGrouping.people(tracks, groups: [1: "anna", 3: "anna", 0: "ben"])
        XCTAssertEqual(people.map(\.tracks), [[2], [1, 3], [0], [4]],
                       "first seen first; at the same moment, left first; a track with no group alone")
        XCTAssertEqual(people.map(\.number), [1, 2, 3, 4])
        XCTAssertEqual(people[1].appearances, 2)
        XCTAssertEqual(people[1].from, 0)
        XCTAssertEqual(people[1].to, 6)
        XCTAssertEqual(people[1].seconds, 2, accuracy: 1e-9)
        XCTAssertEqual(PeopleGrouping.people(tracks.reversed(), groups: [1: "anna", 3: "anna", 0: "ben"]), people,
                       "the order tracks arrive in changes nothing")
    }

    func testANumberedSelectionCoversThosePeopleOnly() throws {
        let tracks = [track(0, from: 0, to: 1), track(1, from: 1, to: 2), track(2, from: 3, to: 4)]
        let people = PeopleGrouping.people(tracks, groups: [0: "a", 2: "a", 1: "b"])
        let only = try PeopleGrouping.covered(tracks, people: people, selection: FaceSelection(onlyNumbers: [1]))
        XCTAssertEqual(only.map(\.id), [0, 2], "every appearance of person 1")
        let skip = try PeopleGrouping.covered(tracks, people: people, selection: FaceSelection(skipNumbers: [1]))
        XCTAssertEqual(skip.map(\.id), [1])
        XCTAssertThrowsError(try PeopleGrouping.covered(tracks, people: people,
                                                        selection: FaceSelection(skipNumbers: [3])),
                             "a number the video has no person for is refused")
    }

    // MARK: - Labels and names

    func testSheetLabels() {
        XCTAssertEqual(SheetLabels.clock(0), "0:00")
        XCTAssertEqual(SheetLabels.clock(83.9), "1:23")
        XCTAssertEqual(SheetLabels.clock(3725), "1:02:05")
        let person = VideoPerson(number: 2, from: 4, to: 83.25, seconds: 48.25, appearances: 3, tracks: [])
        XCTAssertEqual(SheetLabels.person(person), "#2  0:04–1:23  48s")
        XCTAssertEqual(SheetLabels.frame(at: 12, covers: 0), "0:12  nothing covered")
        XCTAssertEqual(SheetLabels.frame(at: 12, covers: 1), "0:12  1 cover")
        XCTAssertEqual(SheetLabels.frame(at: 12, covers: 3), "0:12  3 covers")
    }

    func testSheetsLandBesideTheCopy() {
        let clip = URL(fileURLWithPath: "/a/sub/clip.MP4")
        XCTAssertEqual(OutputNaming.sheet("people", for: clip, outDir: nil, root: nil).path, "/a/sub/clip-people.jpg")
        XCTAssertEqual(OutputNaming.sheet("preview", for: clip, outDir: URL(fileURLWithPath: "/out"),
                                          root: URL(fileURLWithPath: "/a")).path, "/out/sub/clip-preview.jpg")
    }

    func testTheLedgerCountsSheets() {
        var ledger = Ledger()
        ledger.record(FileOutcome(input: "a.mov", status: .previewed))
        ledger.record(FileOutcome(input: "b.mov", status: .outlined))
        ledger.record(FileOutcome(input: "c.mov", status: .outlined))
        XCTAssertEqual(ledger.summary, "1 previewed · 2 outlined")
        XCTAssertTrue(ledger.succeeded)
    }

    func testPeopleJSONLeavesOutTheTrackBookkeeping() throws {
        let person = VideoPerson(number: 1, from: 0, to: 2, seconds: 2, appearances: 1, tracks: [7])
        let json = String(data: try JSONEncoder().encode(person), encoding: .utf8)!
        XCTAssertFalse(json.contains("tracks"))
        XCTAssertEqual(try JSONDecoder().decode(VideoPerson.self, from: Data(json.utf8)).number, 1)
    }

    // MARK: - Real faces

    private var fixtures: URL? {
        let path = ProcessInfo.processInfo.environment["CENSOR_FACE_FIXTURES"]
            ?? NSString(string: "~/Developer/Swift/Libraries/.face-fixtures").expandingTildeInPath
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    func testAFaceOnlyTheNewerDetectorSeesIsFound() async throws {
        guard #available(macOS 27.0, *) else { throw XCTSkip("revision 4 is macOS 27") }
        // A frame of Tears of Steel (Blender Foundation, CC BY 3.0): a face
        // half behind a rifle scope, which revision 3 does not find.
        guard let url = fixtures?.appendingPathComponent("tears-of-steel-scope.jpg"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw XCTSkip("fixture tears-of-steel-scope.jpg missing")
        }
        let older = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: image).perform([older])
        XCTAssertEqual(older.results?.count, 0, "the fixture is one revision 3 misses")
        let found = try await Detector.faces(in: image, withEmbeddings: false)
        XCTAssertEqual(found.count, 1, "both detectors run, merged")
    }

    /// Three shots of 1.5 s each, every photo fitted on a grey 640×480 frame.
    private func threeShots(_ photos: [URL], at url: URL) throws {
        let (width, height, fps) = (640, 480, Int32(24))
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let context = CIContext()
        let grey = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        var frame = 0
        for photo in photos {
            let image = CIImage(contentsOf: photo, options: [.applyOrientationProperty: true])!
            let scale = min(Double(width) / image.extent.width, Double(height) / image.extent.height)
            let fitted = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let placed = fitted.transformed(by: CGAffineTransform(
                translationX: (Double(width) - fitted.extent.width) / 2,
                y: (Double(height) - fitted.extent.height) / 2)).composited(over: grey)
            for _ in 0..<36 {
                while !input.isReadyForMoreMediaData { usleep(2000) }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
                context.render(placed, to: buffer!)
                adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
                frame += 1
            }
        }
        input.markAsFinished()
        let done = XCTestExpectation(description: "written")
        writer.finishWriting { done.fulfill() }
        wait(for: [done], timeout: 30)
        XCTAssertEqual(writer.status, .completed)
    }

    func testAThreeShotVideoIsListedNumberedAndCoveredByNumber() async throws {
        guard #available(macOS 27.0, *) else { throw XCTSkip("face grouping is macOS 27") }
        guard let fixtures else { throw XCTSkip("no face fixtures on this machine") }
        let photos = ["businesswoman-isolated.jpg", "self-portrait.jpg", "businesswoman-walking.jpg"]
            .map { fixtures.appendingPathComponent($0) }
        for photo in photos where !FileManager.default.fileExists(atPath: photo.path) {
            throw XCTSkip("fixture \(photo.lastPathComponent) missing")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("people-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let clip = dir.appendingPathComponent("shots.mov")
        try threeShots(photos, at: clip)

        // The list: the model twice (two shoots, two shots), the painter once.
        let sheet = dir.appendingPathComponent("shots-people.jpg")
        let listed = try await VideoCensor.people(videoAt: clip, to: sheet)
        XCTAssertEqual(listed.status, .outlined)
        let people = try XCTUnwrap(listed.people)
        let analysis = try await VideoAnalysis.run(try await VideoAnalysis.Source.load(clip), target: .faces(FaceSelection()), options: VideoCensor.Options(), listPeople: true)
        XCTAssertEqual(people.count, 2, "\(people)")
        XCTAssertEqual(people[0].from, 0, accuracy: 0.3)
        XCTAssertGreaterThan(people[0].to, 4, "the first person comes back in the third shot")
        XCTAssertEqual(people[1].from, 1.5, accuracy: 0.3)
        XCTAssertNotNil(CGImageSourceCreateWithURL(sheet as CFURL, nil), "the sheet is a picture")

        // Covering person 2 alone changes the middle shot and only it.
        let output = dir.appendingPathComponent("shots-censored.mov")
        let covered = try await VideoCensor.censor(
            videoAt: clip, target: .faces(FaceSelection(onlyNumbers: [2])),
            style: CoverStyle(mode: .pixelate, intensity: 1), to: output, dryRun: false)
        XCTAssertEqual(covered.status, .covered)
        // Measured inside each shot's face: re-encoding alone moves its
        // pixels a little, a cover moves them a lot.
        var differences: [Double] = []
        for time in [0.75, 2.25, 3.75] {
            let before = try await frame(of: clip, at: time), after = try await frame(of: output, at: time)
            let found = try await Detector.faces(in: before, withEmbeddings: false)
            let face = try XCTUnwrap(found.first)
            differences.append(meanDifference(before, after, in: CGRect(x: face.x, y: face.y,
                                                                        width: face.width, height: face.height)))
        }
        XCTAssertGreaterThan(differences[1], 25, "person 2's face is covered: \(differences)")
        XCTAssertLessThan(max(differences[0], differences[2]), 12, "person 1's face is not: \(differences)")

        // The preview: stills carrying the covers, as the render drew them.
        let preview = dir.appendingPathComponent("shots-preview.jpg")
        let previewed = try await VideoCensor.preview(
            videoAt: clip, target: .faces(FaceSelection()), style: CoverStyle(),
            to: preview, options: VideoCensor.Options(previewFrames: 6))
        XCTAssertEqual(previewed.status, .previewed)
        XCTAssertEqual(previewed.covers, 6, "every still holds a face, so every still carries a cover")
    }

    private func frame(of url: URL, at seconds: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    /// The mean absolute difference per channel, 0–255, inside `area`
    /// (normalized, top-left origin).
    private func meanDifference(_ a: CGImage, _ b: CGImage, in area: CGRect) -> Double {
        let width = a.width, height = a.height
        func pixels(_ image: CGImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: width * height * 4)
            let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return data
        }
        let (pa, pb) = (pixels(a), pixels(b))
        var total = 0, count = 0
        for y in Int(area.minY * Double(height))..<Int(area.maxY * Double(height)) {
            for x in Int(area.minX * Double(width))..<Int(area.maxX * Double(width)) {
                for c in 0..<3 {
                    let i = (y * width + x) * 4 + c
                    total += abs(Int(pa[i]) - Int(pb[i]))
                    count += 1
                }
            }
        }
        return Double(total) / Double(max(1, count))
    }
}
