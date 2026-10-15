//
//  VideoCensor.swift
//  CensorKit
//
//  Created by David Sherlock on 2026.
//
//  A video censored in two passes: analysis decodes once and lets
//  TrackMath turn sampled detections into steady tracks; the render pass
//  decodes again, covers each frame, and writes.
//
//  Two hard-won rules shape the writing side, and both now live in
//  swift-video-forge, which `vid` shares. QUALITY PARITY: the writer is
//  configured FROM the source (codec, bitrate, 10-bit depth, color tags,
//  frame rate — VideoForge's `WriterSettings`), because default settings
//  turned iPhone HDR into starved 8-bit SDR. INTERLEAVED FEEDING: every
//  input is fed only when the writer asks (VideoForge's `WriterPump`);
//  the writer THROTTLES an input that runs ahead of the others, so
//  draining audio to the end before the first video frame deadlocks on
//  long clips — the 4K bug was nine minutes of spinning on an audio input
//  the writer had politely paused. Audio and timed-metadata tracks pass through
//  untouched (re-encoding rejects float32 LPCM; iPhone clips carry mebx
//  metadata worth keeping) — all but timed tracks that identify, which
//  are dropped, and every output is re-read by MetadataCheck.
//

import AVFoundation
import CoreImage
import Foundation
import ImageIO
import VideoForge

public enum VideoCensor {

    public struct Options: Sendable {
        /// Seconds between detection samples.
        public var detectStride: TimeInterval
        /// Seconds a cover outlives its last detection.
        public var hold: TimeInterval
        /// Smoothing weight of each NEW sample (1 = none).
        public var smoothing: Double
        /// Adds the tiled detection pass to every sample — small
        /// background faces at a real cost; measured in the README.
        public var thorough: Bool

        public init(detectStride: TimeInterval = 0.25, hold: TimeInterval = 0.75,
                    smoothing: Double = 0.5, thorough: Bool = false) {
            self.detectStride = detectStride
            self.hold = hold
            self.smoothing = smoothing
            self.thorough = thorough
        }
    }

    /// Censors one video to `output` (or reports, when `dryRun`).
    public static func censor(
        videoAt url: URL, target: CensorTargetSpec, style: CoverStyle,
        to output: URL, dryRun: Bool, options: Options = Options(),
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> FileOutcome {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw CensorError.io("\(url.lastPathComponent) has no video track")
        }
        let (naturalSize, transform, duration) = try await (
            videoTrack.load(.naturalSize), videoTrack.load(.preferredTransform),
            asset.load(.duration))
        let extent = CGRect(origin: .zero, size: naturalSize)
        let turns = OrientationMap.quarterTurns(of: transform)
        let context = CIContext()

        // Analysis (faces and text; regions need none, person is per-frame).
        var tracks: [Track] = []
        var analysisDetail: String?
        switch target {
        case .faces(let selection):
            if selection.usesNumbers {
                throw CensorError.usage(
                    "numbered face selection works on images — on video, select with reference photos")
            }
            let wantIdentity = selection.wantsIdentity
            let samples = try await sampleDetections(
                asset: asset, track: videoTrack, stride: options.detectStride, context: context
            ) { image in
                let found = options.thorough
                    ? try Detector.facesThorough(in: image, withEmbeddings: wantIdentity,
                                                 quarterTurns: turns, force: true)
                    : try Detector.faces(in: image, withEmbeddings: wantIdentity,
                                         quarterTurns: turns)
                // Size the cover at sample time and TRACK the head boxes:
                // the render pass then draws tracks verbatim, and the
                // video margin leads a moving head instead of trailing it.
                return found.map { detection in
                    var head = detection
                    let sized = Detector.adaptiveHeadBox(
                        in: image, face: detection, quarterTurns: turns,
                        margin: HeadExtent.videoMotionMargin)
                        ?? FaceGeometry.coverBox(
                            x: detection.x, y: detection.y,
                            width: detection.width, height: detection.height)
                    head.x = sized.x
                    head.y = sized.y
                    head.width = sized.width
                    head.height = sized.height
                    return head
                }
            }
            var all = TrackMath.associate(samples)
            if wantIdentity {
                let before = all.count
                all = all.filter {
                    FaceMatching.shouldCover($0.embedding,
                                             except: selection.except, only: selection.only)
                }
                analysisDetail = "\(before) face tracks, \(before - all.count) left uncovered by reference match"
            }
            tracks = all.map {
                Track(id: $0.id,
                      keyframes: TrackMath.extend(
                        TrackMath.smooth($0.keyframes, alpha: options.smoothing),
                        hold: options.hold),
                      embedding: $0.embedding)
            }

        case .text, .matching:
            let matcher = target.textMatcher!
            let samples = try await sampleDetections(
                asset: asset, track: videoTrack, stride: options.detectStride, context: context
            ) { image in
                try Detector.textBoxes(in: image, matcher: matcher, quarterTurns: turns)
            }
            // Text is held a stride BEFORE it was first read as well as
            // after: OCR that misreads a line on one sample leaves the
            // frames before the next sample uncovered, and a card number
            // showed at 0.1 s of a clip it was covered in from 0.25 s on.
            tracks = TrackMath.associate(samples).map {
                Track(id: $0.id,
                      keyframes: TrackMath.leadIn(TrackMath.extend($0.keyframes, hold: options.hold + options.detectStride),
                                                  by: options.detectStride))
            }

        case .regions, .person:
            break
        }

        let reviewGaps = TrackMath.gaps(in: tracks, duration: duration.seconds)
        let gapsOrNil = reviewGaps.isEmpty ? nil : reviewGaps

        if dryRun {
            let covers: Int
            var detail = analysisDetail
            switch target {
            case .faces, .text, .matching:
                covers = tracks.count
            case .regions(let regions):
                covers = regions.count
            case .person:
                let seen = try await samplePersonPresence(
                    asset: asset, track: videoTrack, duration: duration.seconds, context: context)
                covers = seen
                detail = "people present in \(seen) of 5 sampled frames"
            }
            return FileOutcome(input: url.path, status: .wouldCover, covers: covers,
                               detail: detail, gaps: gapsOrNil)
        }

        let isPerson: Bool
        var personOnly: Int?
        switch target {
        case .person(let only):
            isPerson = true
            personOnly = only
        default:
            isPerson = false
        }
        if case .faces = target, tracks.isEmpty {
            return FileOutcome(input: url.path, status: .skipped, covers: 0,
                               detail: analysisDetail ?? "no faces detected")
        }
        if target.textMatcher != nil, tracks.isEmpty {
            return FileOutcome(input: url.path, status: .skipped, covers: 0,
                               detail: "no matching text detected")
        }
        if personOnly != nil {
            throw CensorError.usage("--only is available on images; video person mode covers everyone")
        }

        // Derive the writer's story from the source's (quality parity).
        let settings = derivedSettings(from: try await VideoSourceFormat.load(from: videoTrack))

        // Reader: video in the pipeline format, everything else passthrough.
        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: settings.pixelFormat])
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)

        var passthroughPairs: [(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)] = []
        let writer = try makeWriter(at: output)

        // Encoders refuse odd dimensions (fleet trap): the settings are even.
        let videoSettings = settings.videoOutputSettings
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw CensorError.processing("the writer refused the derived video settings")
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.transform = transform
        guard writer.canAdd(videoInput) else {
            throw CensorError.processing("the writer refused the derived video settings")
        }
        writer.add(videoInput)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput, sourcePixelBufferAttributes: settings.pixelBufferAttributes)

        // Audio and timed metadata: passthrough, format hints from the source
        // — except a timed track that says where the camera was or where the
        // faces were. Those passed straight through until 2026-10-10: the
        // container's location was dropped, a timed location track was not.
        writer.metadata = []
        for track in try await asset.load(.tracks) where track.mediaType != .video {
            guard track.mediaType == .audio || track.mediaType == .metadata else { continue }
            let descriptions = try await track.load(.formatDescriptions)
            if track.mediaType == .metadata, MetadataCheck.isIdentifying(descriptions) { continue }
            let hint = descriptions.first
            let input = AVAssetWriterInput(mediaType: track.mediaType,
                                           outputSettings: nil, sourceFormatHint: hint)
            guard writer.canAdd(input) else { continue }
            let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            guard reader.canAdd(trackOutput) else { continue }
            writer.add(input)
            reader.add(trackOutput)
            passthroughPairs.append((trackOutput, input))
        }

        // Interleaved pumping: every input is fed only when the writer asks.
        // The emoji must be upright in DISPLAY space: pre-rotate it by the
        // inverse of the display rotation.
        let emoji = style.mode == .emoji
            ? CoverRenderer.renderEmoji(style.emoji).map {
                turns == 0 ? $0 : $0.oriented(Self.emojiOrientation(quarterTurns: turns))
            }
            : nil
        let counters = Counters()
        let total = duration.seconds
        let plan = FramePlan(target: target, tracks: tracks, isPerson: isPerson,
                             extent: extent, style: style, emojiImage: emoji)

        var feeds: [WriterFeed] = [WriterFeed(input: videoInput) {
            guard let sample = videoOutput.copyNextSampleBuffer() else { return false }
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return true }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let t = pts.seconds
            var image = CIImage(cvPixelBuffer: buffer)

            let covers = try plan.covers(at: t, buffer: buffer)
            if !covers.isEmpty {
                image = CoverRenderer.apply(covers, to: image, style: plan.style,
                                            emojiImage: plan.emojiImage)
                counters.covered += 1
            }

            var rendered: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool else {
                throw CensorError.processing("the writer offered no pixel buffer pool")
            }
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &rendered)
            guard let rendered else {
                throw CensorError.processing("could not allocate an output frame")
            }
            plan.context.render(image, to: rendered)
            adaptor.append(rendered, withPresentationTime: pts)

            counters.frames += 1
            if total > 0, counters.frames % 30 == 0 { progress?(min(1, t / total)) }
            return true
        }]
        for (trackOutput, input) in passthroughPairs {
            feeds.append(.copying(from: trackOutput, to: input))
        }
        do {
            try await WriterPump.run(WriterJob(reader: reader, writer: writer, feeds: feeds))
        } catch let error as VideoForgeError {
            throw CensorError.io("writing \(output.lastPathComponent) failed: \(error.localizedDescription)")
        }
        // Checked, not assumed: a censored clip for sharing that still says
        // where it was shot is removed and refused.
        let leaks = await MetadataCheck.videoLeaks(in: output)
        guard leaks.isEmpty else {
            try? FileManager.default.removeItem(at: output)
            throw CensorError.processing("\(output.lastPathComponent) still carried \(leaks.joined(separator: ", ")) metadata; nothing was written")
        }

        let coverCount = isPerson ? counters.covered : tracks.count
        let regionCount: Int
        if case .regions(let regions) = target { regionCount = regions.count } else { regionCount = 0 }
        return FileOutcome(
            input: url.path, output: output.path, status: .covered,
            covers: max(coverCount, regionCount),
            detail: analysisDetail ?? "\(counters.covered) of \(counters.frames) frames covered",
            gaps: gapsOrNil)
    }

    private final class Counters: @unchecked Sendable {
        var frames = 0
        var covered = 0
    }

    /// Everything the per-frame cover decision needs, queue-confined.
    private final class FramePlan: @unchecked Sendable {
        let target: CensorTargetSpec
        let tracks: [Track]
        let isPerson: Bool
        let extent: CGRect
        let style: CoverStyle
        let emojiImage: CIImage?
        let context = CIContext()

        init(target: CensorTargetSpec, tracks: [Track], isPerson: Bool,
             extent: CGRect, style: CoverStyle, emojiImage: CIImage?) {
            self.target = target
            self.tracks = tracks
            self.isPerson = isPerson
            self.extent = extent
            self.style = style
            self.emojiImage = emojiImage
        }

        func covers(at t: TimeInterval, buffer: CVPixelBuffer) throws -> [CoverRenderer.Cover] {
            if isPerson {
                guard let mask = try Detector.personSegmentationMask(in: buffer, extent: extent)
                else { return [] }
                return [.init(shape: .mask(mask), rect: extent)]
            }
            switch target {
            case .regions(let regions):
                return regions.filter { $0.covers(at: t) }.map {
                    .init(shape: .rectangle, rect: CoverRenderer.coverRect(
                        x: $0.x, y: $0.y, width: $0.width, height: $0.height, in: extent))
                }
            case .text, .matching:
                return tracks.compactMap { track in
                    track.box(at: t).map {
                        .init(shape: .rectangle, rect: CoverRenderer.coverRect(
                            x: $0.x, y: $0.y, width: $0.width, height: $0.height, in: extent))
                    }
                }
            default:
                // Tracks already carry sized head boxes (adaptive or
                // fallback, applied at sample time) — draw them as they
                // are. The outline diagnostic on video shows that one box.
                return tracks.compactMap { track in
                    track.box(at: t).map { box in
                        .init(shape: .oval,
                              rect: CoverRenderer.coverRect(
                                x: box.x, y: box.y,
                                width: box.width, height: box.height, in: extent))
                    }
                }
            }
        }
    }

    /// The pre-rotation that makes an emoji upright after the display
    /// transform is applied — the INVERSE of the display rotation.
    private static func emojiOrientation(quarterTurns: Int) -> CGImagePropertyOrientation {
        switch quarterTurns {
        case 1: return .left
        case 2: return .down
        case 3: return .right
        default: return .up
        }
    }

    // MARK: - Derivation glue

    private static func makeWriter(at output: URL) throws -> AVAssetWriter {
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: output)
        return try AVAssetWriter(outputURL: output, fileType: .mov)
    }

    /// The source's format story → the writer's settings.
    ///
    /// The codec rule is censor-kit's own: HEVC in → HEVC out; anything
    /// else re-encodes as H.264 — except a 10-bit source, which is ALWAYS
    /// HEVC Main 10 (H.264 hardware paths are 8-bit; writing one would
    /// truncate the source's depth). Frames are worked on in RGB, for
    /// Vision and the cover drawing: BGRA, or 10-bit ARGB when deep.
    static func derivedSettings(from source: VideoSourceFormat) -> WriterSettings {
        let deep = (source.bitsPerComponent ?? 8) >= 10
        let hevcIn = source.codec == "hvc1" || source.codec == "hev1"
        return WriterSettings.derive(from: source, codec: hevcIn || deep ? .hevc : .h264,
                                     processesInRGB: true)
    }

    /// Decodes once, running `detect` on frames sampled every `stride`
    /// seconds; each detection is stamped with its sample time.
    private static func sampleDetections(
        asset: AVURLAsset, track: AVAssetTrack, stride: TimeInterval, context: CIContext,
        detect: (CGImage) throws -> [TrackMath.Detection]
    ) async throws -> [[TrackMath.Detection]] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw CensorError.processing("could not read the video for analysis")
        }

        var samples: [[TrackMath.Detection]] = []
        var nextSample = 0.0
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard t >= nextSample else { continue }
            nextSample = t + stride
            let image = CIImage(cvPixelBuffer: buffer)
            guard let cgImage = context.createCGImage(image, from: image.extent) else { continue }
            let stamped = try detect(cgImage).map { detection in
                var d = detection
                d.time = t
                return d
            }
            samples.append(stamped)
        }
        reader.cancelReading()
        return samples
    }

    /// How many of five evenly spaced frames contain people (dry run).
    private static func samplePersonPresence(
        asset: AVURLAsset, track: AVAssetTrack, duration: TimeInterval, context: CIContext
    ) async throws -> Int {
        let stride = max(duration / 5, 0.1)
        let samples = try await sampleDetections(
            asset: asset, track: track, stride: stride, context: context
        ) { image in
            let request = try Detector.personMask(in: image, only: nil)
            return request == nil ? [] : [TrackMath.Detection(time: 0, x: 0, y: 0, width: 1, height: 1)]
        }
        return samples.filter { !$0.isEmpty }.count
    }
}
