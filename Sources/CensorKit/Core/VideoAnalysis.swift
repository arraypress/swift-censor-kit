//
//  VideoAnalysis.swift
//  CensorKit
//
//  Created by David Sherlock on 2026.
//
//  The decode-once pass every video run shares — censoring, previewing and
//  listing people: sample frames, find what the target names, turn the
//  detections into steady tracks, and, for faces, decide who is covered.
//  Running the same pass for `--outline` and for the run that covers by its
//  numbers is what keeps the numbers the same.
//

import AVFoundation
import CoreImage
import Foundation
import VideoForge

/// A video's analysis: the tracks a render draws, and what it found.
struct VideoAnalysis {

    /// The video, opened.
    struct Source {
        let url: URL
        let asset: AVURLAsset
        let track: AVAssetTrack
        let transform: CGAffineTransform
        let duration: CMTime
        /// The stored frame, in pixels.
        let extent: CGRect
        /// The display rotation, in quarter turns.
        let turns: Int

        static func load(_ url: URL) async throws -> Source {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw CensorError.io("\(url.lastPathComponent) has no video track")
            }
            let (size, transform, duration) = try await (
                track.load(.naturalSize), track.load(.preferredTransform), asset.load(.duration))
            return Source(url: url, asset: asset, track: track, transform: transform, duration: duration,
                          extent: CGRect(origin: .zero, size: size),
                          turns: OrientationMap.quarterTurns(of: transform))
        }
    }

    /// Where a face sample came from, to find its crop again.
    struct SampleKey: Hashable {
        let time: TimeInterval
        let x: Double
        let y: Double
    }

    /// What sampling measured for each face, beyond its box: the cover
    /// sized to the head, and — when people are numbered — a crop.
    final class Measures: @unchecked Sendable {
        var head: [SampleKey: TrackedBox] = [:]
        var jpeg: [SampleKey: Data] = [:]
        /// The detected face's area, a fraction of the frame — the biggest
        /// is the clearest picture of a person.
        var area: [SampleKey: Double] = [:]
    }

    /// The covers to draw, ready: smoothed, led in and held.
    var tracks: [Track] = []
    /// A line about the selection, when one was made.
    var detail: String?
    /// The seconds a human should review.
    var gaps: [CoverageGap]?
    /// The people found, when faces were numbered.
    var people: [VideoPerson]?
    /// Every person's face tracks, before selection (for the people sheet).
    var allTracks: [Track] = []
    /// What sampling measured, when people were found — their crops.
    var measures: Measures?

    /// Seconds between the crops of one track the face grouping sees.
    static let cropSpacing = 1.0

    /// Analyzes `source` for `target`. `listPeople` numbers the faces even
    /// when the selection names none (the people sheet).
    static func run(_ source: Source, target: CensorTargetSpec, options: VideoCensor.Options,
                    listPeople: Bool = false) async throws -> VideoAnalysis {
        var analysis = VideoAnalysis()
        let context = CIContext()
        switch target {
        case .faces(let selection):
            try await analysis.faces(source, selection: selection, options: options,
                                     listPeople: listPeople, context: context)
        case .text, .matching:
            let matcher = target.textMatcher!
            let turns = source.turns
            let samples = try await VideoCensor.sampleDetections(
                asset: source.asset, track: source.track, stride: options.detectStride, context: context
            ) { image, _ in
                try Detector.textBoxes(in: image, matcher: matcher, quarterTurns: turns)
            }
            // Text is held a stride BEFORE it was first read as well as
            // after: OCR that misreads a line on one sample leaves the
            // frames before the next sample uncovered, and a card number
            // showed at 0.1 s of a clip it was covered in from 0.25 s on.
            analysis.tracks = TrackMath.associate(samples).map {
                Track(id: $0.id,
                      keyframes: TrackMath.leadIn(TrackMath.extend($0.keyframes, hold: options.hold + options.detectStride),
                                                  by: options.detectStride))
            }
        case .regions, .person:
            break
        }
        let gaps = TrackMath.gaps(in: analysis.tracks, duration: source.duration.seconds)
        analysis.gaps = gaps.isEmpty ? nil : gaps
        return analysis
    }

    private mutating func faces(_ source: Source, selection: FaceSelection, options: VideoCensor.Options,
                                listPeople: Bool, context: CIContext) async throws {
        let numbering = listPeople || selection.usesNumbers
        if numbering {
            guard #available(macOS 27.0, *) else {
                throw CensorError.unavailable(
                    "numbering the people in a video needs macOS 27 (Apple's face grouping)")
            }
        }
        // Where the shots change — no track runs across one — read
        // alongside the sampling; it decodes the video on its own.
        let url = source.url
        async let shots = Scenes.detect(url)
        let wantIdentity = selection.wantsIdentity
        let turns = source.turns
        let measured = Measures()
        let samples = try await VideoCensor.sampleDetections(
            asset: source.asset, track: source.track, stride: options.detectStride, context: context
        ) { image, time in
            let found = options.thorough
                ? try await Detector.facesThorough(in: image, withEmbeddings: wantIdentity,
                                                   quarterTurns: turns, force: true)
                : try await Detector.faces(in: image, withEmbeddings: wantIdentity, quarterTurns: turns)
            // Size the cover at sample time but TRACK the face: heads of
            // people shoulder to shoulder overlap (their person masks join),
            // so head boxes swapped between them; faces do not overlap. The
            // video margin leads a moving head instead of trailing it.
            for detection in found {
                let sized = Detector.adaptiveHeadBox(
                    in: image, face: detection, quarterTurns: turns,
                    margin: HeadExtent.videoMotionMargin)
                    ?? FaceGeometry.coverBox(
                        x: detection.x, y: detection.y,
                        width: detection.width, height: detection.height)
                let key = SampleKey(time: time, x: detection.x, y: detection.y)
                measured.head[key] = TrackedBox(time: time, x: sized.x, y: sized.y,
                                                width: sized.width, height: sized.height)
                if numbering, #available(macOS 27.0, *),
                   let jpeg = FaceGroups.crop(of: image, face: detection, quarterTurns: turns) {
                    measured.jpeg[key] = jpeg
                    measured.area[key] = detection.width * detection.height
                }
            }
            return found
        }
        let cuts: [TimeInterval]
        do {
            cuts = try await shots.changes.map(\.time)
        } catch {
            throw CensorError.io("reading \(url.lastPathComponent) for its shots failed: \(error.localizedDescription)")
        }
        var all = TrackMath.associate(samples, cuts: cuts)

        var chosen = all
        if numbering, #available(macOS 27.0, *) {
            var picked: [FaceGroups.Crop] = []
            for track in all {
                for box in PeopleGrouping.cropTimes(track.keyframes, spacing: Self.cropSpacing) {
                    if let jpeg = measured.jpeg[SampleKey(time: box.time, x: box.x, y: box.y)] {
                        picked.append(FaceGroups.Crop(track: track.id, time: box.time, jpeg: jpeg))
                    }
                }
            }
            let votes = try await FaceGroups.votes(picked)
            let (pieces, groups) = PeopleGrouping.split(all, votes: votes)
            all = pieces
            let people = PeopleGrouping.people(all, groups: groups)
            self.people = people
            self.measures = measured
            self.allTracks = all
            chosen = try PeopleGrouping.covered(all, people: people, selection: selection)
            if selection.isSelective {
                detail = "\(people.count) people, \(all.count - chosen.count) of \(all.count) face tracks left uncovered by selection"
            }
        } else if wantIdentity {
            chosen = all.filter {
                FaceMatching.shouldCover($0.embedding, except: selection.except, only: selection.only)
            }
            detail = "\(all.count) face tracks, \(all.count - chosen.count) left uncovered by reference match"
        }

        // A face is covered from a stride before it was first seen — it
        // was on screen since the sample before — never across a cut.
        tracks = chosen.map { track in
            let heads = track.keyframes.map { measured.head[SampleKey(time: $0.time, x: $0.x, y: $0.y)] ?? $0 }
            return Track(id: track.id,
                  keyframes: TrackMath.extend(
                    TrackMath.leadIn(TrackMath.smooth(heads, alpha: options.smoothing),
                                     by: options.detectStride, cuts: cuts),
                    hold: options.hold, cuts: cuts),
                  embedding: track.embedding)
        }
    }
}
