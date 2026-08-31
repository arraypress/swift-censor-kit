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
//  Two hard-won rules shape the writing side. QUALITY PARITY: the writer
//  is configured FROM the source (codec, bitrate, 10-bit depth, color
//  tags, frame rate — see WriterSettings), because default settings
//  turned iPhone HDR into starved 8-bit SDR. INTERLEAVED FEEDING: every
//  input is pumped via requestMediaDataWhenReady; the writer THROTTLES
//  an input that runs ahead of the others, so draining audio to the end
//  before the first video frame deadlocks on long clips — the 4K bug
//  was nine minutes of spinning on an audio input the writer had
//  politely paused. Audio and timed-metadata tracks pass through
//  untouched (re-encoding rejects float32 LPCM; iPhone clips carry mebx
//  metadata worth keeping).
//

import AVFoundation
import CoreImage
import Foundation

public enum VideoCensor {

    public struct Options: Sendable {
        /// Seconds between detection samples.
        public var detectStride: TimeInterval
        /// Seconds a cover outlives its last detection.
        public var hold: TimeInterval
        /// Smoothing weight of each NEW sample (1 = none).
        public var smoothing: Double

        public init(detectStride: TimeInterval = 0.25, hold: TimeInterval = 0.75,
                    smoothing: Double = 0.5) {
            self.detectStride = detectStride
            self.hold = hold
            self.smoothing = smoothing
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
        let context = CIContext()

        // Analysis (faces and text; regions need none, person is per-frame).
        var tracks: [Track] = []
        var analysisDetail: String?
        switch target {
        case .faces(let except, let only):
            let wantIdentity = !except.isEmpty || !only.isEmpty
            let samples = try await sampleDetections(
                asset: asset, track: videoTrack, stride: options.detectStride, context: context
            ) { image in
                try Detector.faces(in: image, withEmbeddings: wantIdentity)
            }
            var all = TrackMath.associate(samples)
            if wantIdentity {
                let before = all.count
                all = all.filter {
                    FaceMatching.shouldCover($0.embedding, except: except, only: only)
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

        case .text(let pattern):
            let samples = try await sampleDetections(
                asset: asset, track: videoTrack, stride: options.detectStride, context: context
            ) { image in
                try Detector.textBoxes(in: image, pattern: pattern)
            }
            tracks = TrackMath.associate(samples).map {
                Track(id: $0.id,
                      keyframes: TrackMath.extend($0.keyframes, hold: options.hold + options.detectStride))
            }

        case .regions, .person:
            break
        }

        if dryRun {
            let covers: Int
            var detail = analysisDetail
            switch target {
            case .faces, .text:
                covers = tracks.count
            case .regions(let regions):
                covers = regions.count
            case .person:
                let seen = try await samplePersonPresence(
                    asset: asset, track: videoTrack, duration: duration.seconds, context: context)
                covers = seen
                detail = "people present in \(seen) of 5 sampled frames"
            }
            return FileOutcome(input: url.path, status: .wouldCover, covers: covers, detail: detail)
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
        if case .text = target, tracks.isEmpty {
            return FileOutcome(input: url.path, status: .skipped, covers: 0,
                               detail: "no matching text detected")
        }
        if personOnly != nil {
            throw CensorError.usage("--only is available on images; video person mode covers everyone")
        }

        // Derive the writer's story from the source's (quality parity).
        let descriptions = try await videoTrack.load(.formatDescriptions)
        let fps = try await videoTrack.load(.nominalFrameRate)
        let dataRate = try await videoTrack.load(.estimatedDataRate)
        let settings = derivedSettings(
            from: descriptions.first, size: naturalSize,
            fps: Double(fps), dataRate: Double(dataRate))

        // Reader: video in the pipeline format, everything else passthrough.
        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: settings.pixelFormat])
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)

        var passthroughPairs: [(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)] = []
        let writer = try makeWriter(at: output)

        // Encoders refuse odd dimensions (fleet trap) — floor to even.
        let width = Int(naturalSize.width / 2) * 2
        let height = Int(naturalSize.height / 2) * 2
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: settings.codec == "hvc1" ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        var compression: [String: Any] = [AVVideoAverageBitRateKey: settings.averageBitRate]
        if let profile = settings.profileLevel {
            compression[AVVideoProfileLevelKey] = profile
        }
        if let expected = settings.expectedFrameRate {
            compression[AVVideoExpectedSourceFrameRateKey] = expected
        }
        videoSettings[AVVideoCompressionPropertiesKey] = compression
        if settings.hasColorProperties {
            videoSettings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: settings.colorPrimaries!,
                AVVideoTransferFunctionKey: settings.transferFunction!,
                AVVideoYCbCrMatrixKey: settings.yCbCrMatrix!,
            ]
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.transform = transform
        guard writer.canAdd(videoInput) else {
            throw CensorError.processing("the writer refused the derived video settings")
        }
        writer.add(videoInput)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: settings.pixelFormat,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])

        // Audio and timed metadata: passthrough, format hints from the source.
        for track in try await asset.load(.tracks) where track.mediaType != .video {
            guard track.mediaType == .audio || track.mediaType == .metadata else { continue }
            let hint = try await track.load(.formatDescriptions).first
            let input = AVAssetWriterInput(mediaType: track.mediaType,
                                           outputSettings: nil, sourceFormatHint: hint)
            guard writer.canAdd(input) else { continue }
            let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            guard reader.canAdd(trackOutput) else { continue }
            writer.add(input)
            reader.add(trackOutput)
            passthroughPairs.append((trackOutput, input))
        }

        guard reader.startReading() else {
            throw CensorError.processing("could not read \(url.lastPathComponent): \(reader.error?.localizedDescription ?? "unknown")")
        }
        guard writer.startWriting() else {
            throw CensorError.io("could not write \(output.lastPathComponent): \(writer.error?.localizedDescription ?? "unknown")")
        }
        writer.startSession(atSourceTime: .zero)

        // Interleaved pumping: every input is fed only when the writer asks.
        let emoji = style.mode == .emoji ? CoverRenderer.renderEmoji(style.emoji) : nil
        let counters = Counters()
        let total = duration.seconds
        let plan = FramePlan(target: target, tracks: tracks, isPerson: isPerson,
                             extent: extent, style: style, emojiImage: emoji)

        var feeds: [Feed] = [Feed(input: videoInput, label: "video") {
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
            feeds.append(Feed(input: input, label: "passthrough") {
                guard let sample = trackOutput.copyNextSampleBuffer() else { return false }
                input.append(sample)
                return true
            })
        }
        try await pump(feeds)
        reader.cancelReading()

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw CensorError.io("finishing \(output.lastPathComponent) failed: \(writer.error?.localizedDescription ?? "unknown")")
        }

        let coverCount = isPerson ? counters.covered : tracks.count
        let regionCount: Int
        if case .regions(let regions) = target { regionCount = regions.count } else { regionCount = 0 }
        return FileOutcome(
            input: url.path, output: output.path, status: .covered,
            covers: max(coverCount, regionCount),
            detail: analysisDetail ?? "\(counters.covered) of \(counters.frames) frames covered")
    }

    // MARK: - The feeding machinery

    /// One writer input and the step that feeds it its next sample.
    /// State is confined to the input's own serial queue.
    private final class Feed: @unchecked Sendable {
        let input: AVAssetWriterInput
        let queue: DispatchQueue
        let step: () throws -> Bool
        var finished = false

        init(input: AVAssetWriterInput, label: String, step: @escaping () throws -> Bool) {
            self.input = input
            self.queue = DispatchQueue(label: "censorkit.feed.\(label)")
            self.step = step
        }
    }

    private final class Counters: @unchecked Sendable {
        var frames = 0
        var covered = 0
    }

    private final class ErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var error: Error?
        func set(_ e: Error) { lock.lock(); if error == nil { error = e }; lock.unlock() }
        func get() -> Error? { lock.lock(); defer { lock.unlock() }; return error }
    }

    /// Runs every feed under `requestMediaDataWhenReady` until all sources
    /// drain, surfacing the first error. The writer throttles inputs that
    /// run ahead; feeding on demand is what keeps long clips deadlock-free.
    private static func pump(_ feeds: [Feed]) async throws {
        let errors = ErrorBox()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            for feed in feeds {
                group.enter()
                feed.input.requestMediaDataWhenReady(on: feed.queue) {
                    guard !feed.finished else { return }
                    do {
                        while feed.input.isReadyForMoreMediaData {
                            if try !feed.step() {
                                feed.finished = true
                                feed.input.markAsFinished()
                                group.leave()
                                return
                            }
                        }
                    } catch {
                        errors.set(error)
                        feed.finished = true
                        feed.input.markAsFinished()
                        group.leave()
                    }
                }
            }
            group.notify(queue: DispatchQueue.global()) { continuation.resume() }
        }
        if let error = errors.get() { throw error }
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
            case .text:
                return tracks.compactMap { track in
                    track.box(at: t).map {
                        .init(shape: .rectangle, rect: CoverRenderer.coverRect(
                            x: $0.x, y: $0.y, width: $0.width, height: $0.height, in: extent))
                    }
                }
            default:
                return tracks.compactMap { track in
                    track.box(at: t).map {
                        .init(shape: .oval, rect: CoverRenderer.coverRect(
                            x: $0.x, y: $0.y, width: $0.width, height: $0.height, in: extent))
                    }
                }
            }
        }
    }

    // MARK: - Derivation glue

    private static func makeWriter(at output: URL) throws -> AVAssetWriter {
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: output)
        return try AVAssetWriter(outputURL: output, fileType: .mov)
    }

    /// The source's format story as plain values → WriterSettings.
    static func derivedSettings(
        from description: CMFormatDescription?, size: CGSize,
        fps: Double, dataRate: Double
    ) -> WriterSettings {
        var subtype = "avc1"
        var bits: Int?
        var primaries: String?
        var transfer: String?
        var matrix: String?
        if let description {
            let sub = CMFormatDescriptionGetMediaSubType(description)
            subtype = String(format: "%c%c%c%c", (sub >> 24) & 255, (sub >> 16) & 255,
                             (sub >> 8) & 255, sub & 255)
            if let ext = CMFormatDescriptionGetExtensions(description) as? [String: Any] {
                bits = ext["BitsPerComponent"] as? Int
                primaries = ext["CVImageBufferColorPrimaries"] as? String
                transfer = ext["CVImageBufferTransferFunction"] as? String
                matrix = ext["CVImageBufferYCbCrMatrix"] as? String
            }
        }
        return WriterSettings.derive(
            codecSubtype: subtype, width: Int(size.width), height: Int(size.height),
            estimatedDataRate: dataRate, nominalFrameRate: fps,
            bitsPerComponent: bits, colorPrimaries: primaries,
            transferFunction: transfer, yCbCrMatrix: matrix)
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
