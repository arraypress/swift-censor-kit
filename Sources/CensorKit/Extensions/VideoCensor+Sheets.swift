//
//  VideoCensor+Sheets.swift
//  CensorKit
//
//  Created by David Sherlock on 2026.
//
//  Two looks at a video before the long render, each one picture: the
//  people a scan found, numbered for `--only`/`--skip`, and covered stills
//  from across the clip. Both run the same analysis a render runs, so what
//  they show is what the render does.
//

import AVFoundation
import CoreImage
import Foundation
import ImageForge

public extension VideoCensor {

    /// Writes a sheet of covered stills from across the video instead of
    /// the video — the covers exactly as the render would draw them.
    ///
    /// - Parameters:
    ///   - url: The video.
    ///   - target: What to cover.
    ///   - style: How covers look.
    ///   - sheet: The JPEG to write.
    ///   - options: Sampling, and how many stills (`previewFrames`).
    /// - Returns: The outcome; `covers` counts the stills that carry one.
    static func preview(videoAt url: URL, target: CensorTargetSpec, style: CoverStyle,
                        to sheet: URL, options: Options = Options()) async throws -> FileOutcome {
        let source = try await VideoAnalysis.Source.load(url)
        let analysis = try await VideoAnalysis.run(source, target: target, options: options)
        let isPerson: Bool
        if case .person = target { isPerson = true } else { isPerson = false }

        let generator = AVAssetImageGenerator(asset: source.asset)
        // Stored, unrotated frames: covers are placed in storage space, and
        // the still is turned upright after.
        generator.appliesPreferredTrackTransform = false
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: Self.previewSide, height: Self.previewSide)

        let duration = source.duration.seconds
        let count = max(1, options.previewFrames)
        let context = CIContext()
        let emoji = style.mode == .emoji
            ? CoverRenderer.renderEmoji(style.emoji).map {
                source.turns == 0 ? $0 : $0.oriented(emojiOrientation(quarterTurns: source.turns))
            }
            : nil
        var tiles: [SheetTile] = []
        var covered = 0
        for index in 0..<count {
            let wanted = duration * (Double(index) + 0.5) / Double(count)
            let (frame, actual) = try await generator.image(at: CMTime(seconds: wanted, preferredTimescale: 600))
            let still = CIImage(cgImage: frame)
            let plan = FramePlan(target: target, tracks: analysis.tracks, isPerson: isPerson,
                                 extent: still.extent, style: style, emojiImage: emoji)
            let time = actual.seconds
            let covers = try plan.covers(at: time) {
                try Detector.personSegmentationMask(in: frame, extent: still.extent)
            }
            if !covers.isEmpty { covered += 1 }
            let drawn = CoverRenderer.apply(covers, to: still, style: style, emojiImage: emoji)
                .oriented(OrientationMap.uprightingOrientation(quarterTurns: source.turns))
            let upright = drawn.transformed(by: CGAffineTransform(
                translationX: -drawn.extent.minX, y: -drawn.extent.minY))
            guard let image = context.createCGImage(upright, from: upright.extent) else {
                throw CensorError.processing("could not draw the still at \(SheetLabels.clock(time))")
            }
            tiles.append(SheetTile(image: image, label: SheetLabels.frame(at: time, covers: covers.count)))
        }
        try write(try ImageForge.contactSheet(tiles, spec: SheetSpec(columns: 4, cellWidth: 400)), to: sheet)
        return FileOutcome(input: url.path, output: sheet.path, status: .previewed, covers: covered,
                           detail: analysis.detail ?? "\(covered) of \(count) stills carry a cover",
                           gaps: analysis.gaps, people: analysis.people)
    }

    /// Writes a sheet of the people in a video — each person's clearest
    /// face, numbered by first appearance — for `--only` and `--skip`.
    ///
    /// The numbers hold for a later run over the same video with the same
    /// sampling options; they come from the same analysis.
    ///
    /// - Parameters:
    ///   - url: The video.
    ///   - sheet: The JPEG to write.
    ///   - options: Sampling.
    /// - Returns: The outcome, with `people` filled.
    /// - Throws: ``CensorError/unavailable(_:)`` before macOS 27.
    static func people(videoAt url: URL, to sheet: URL,
                       options: Options = Options()) async throws -> FileOutcome {
        let source = try await VideoAnalysis.Source.load(url)
        let analysis = try await VideoAnalysis.run(source, target: .faces(FaceSelection()),
                                                   options: options, listPeople: true)
        let people = analysis.people ?? []
        guard !people.isEmpty, let measures = analysis.measures else {
            return FileOutcome(input: url.path, status: .skipped, detail: "no faces detected", people: [])
        }
        let byID = Dictionary(uniqueKeysWithValues: analysis.allTracks.map { ($0.id, $0) })
        var tiles: [SheetTile] = []
        for person in people {
            // The clearest picture: the biggest face of any appearance.
            let keys = person.tracks.compactMap { byID[$0] }.flatMap(\.keyframes)
                .map { VideoAnalysis.SampleKey(time: $0.time, x: $0.x, y: $0.y) }
            guard let best = keys.max(by: { (measures.area[$0] ?? 0) < (measures.area[$1] ?? 0) }),
                  let jpeg = measures.jpeg[best],
                  let decoded = CGImageSourceCreateWithData(jpeg as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(decoded, 0, nil) else { continue }
            tiles.append(SheetTile(image: image, label: SheetLabels.person(person)))
        }
        try write(try ImageForge.contactSheet(
            tiles, spec: SheetSpec(columns: 6, cellWidth: 220, cellAspect: 1)), to: sheet)
        return FileOutcome(input: url.path, output: sheet.path, status: .outlined, covers: people.count,
                           detail: "\(people.count) people — cover or spare them by number with --only/--skip",
                           people: people)
    }

    /// The longest side of a preview still, in pixels.
    internal static let previewSide = 960

    private static func write(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try ImageEncoder.encode(image, format: .jpeg, spec: EncodeSpec(quality: 0.85))
        _ = try ImageEncoder.write(data, to: url, overwrites: true)
    }
}
