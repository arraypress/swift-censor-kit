//
//  VideoCensor.swift
//  CensorKit
//
//  Created by David Sherlock on 2026.
//
//  A video censored in two passes. The analysis pass decodes once,
//  detecting at a stride and letting TrackMath turn samples into steady
//  tracks; the render pass decodes again, covers each frame, and writes.
//  Audio is passed through untouched (fleet trap: re-encoding rejects
//  float32 LPCM — passthrough carries anything), and the source's
//  transform rides onto the writer so rotated phone footage stays
//  rotated. Detection cost scales with the stride, not the frame rate.
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

        // Analysis: sampled detections → tracks (faces and text only; regions
        // need none and person masks are computed per frame).
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

        // Render.
        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)

        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack {
            let out = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            reader.add(out)
            audioOutput = out
        }

        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)

        // Encoders refuse odd dimensions (fleet trap) — floor to even.
        let width = Int(naturalSize.width / 2) * 2
        let height = Int(naturalSize.height / 2) * 2
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = transform
        writer.add(videoInput)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])

        var audioInput: AVAssetWriterInput?
        if let audioTrack {
            let descriptions = try await audioTrack.load(.formatDescriptions)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil,
                                           sourceFormatHint: descriptions.first)
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }

        guard reader.startReading() else {
            throw CensorError.processing("could not read \(url.lastPathComponent): \(reader.error?.localizedDescription ?? "unknown")")
        }
        guard writer.startWriting() else {
            throw CensorError.io("could not write \(output.lastPathComponent): \(writer.error?.localizedDescription ?? "unknown")")
        }
        writer.startSession(atSourceTime: .zero)

        // Audio first, in full — compressed audio is small next to video and
        // the writer interleaves on disk regardless.
        if let audioOutput, let audioInput {
            while let sample = audioOutput.copyNextSampleBuffer() {
                while !audioInput.isReadyForMoreMediaData { usleep(2000) }
                audioInput.append(sample)
            }
            audioInput.markAsFinished()
        }

        let emoji = style.mode == .emoji ? CoverRenderer.renderEmoji(style.emoji) : nil
        var frames = 0
        var coveredFrames = 0
        let total = duration.seconds

        while let sample = videoOutput.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let t = pts.seconds
            var image = CIImage(cvPixelBuffer: buffer)

            var covers: [CoverRenderer.Cover] = []
            if isPerson {
                if let mask = try Detector.personSegmentationMask(in: buffer, extent: extent) {
                    covers.append(.init(shape: .mask(mask), rect: extent))
                }
            } else {
                switch target {
                case .regions(let regions):
                    for region in regions where region.covers(at: t) {
                        covers.append(.init(shape: .rectangle, rect: CoverRenderer.coverRect(
                            x: region.x, y: region.y,
                            width: region.width, height: region.height, in: extent)))
                    }
                case .text:
                    for track in tracks {
                        if let box = track.box(at: t) {
                            covers.append(.init(shape: .rectangle, rect: CoverRenderer.coverRect(
                                x: box.x, y: box.y, width: box.width, height: box.height, in: extent)))
                        }
                    }
                default:
                    for track in tracks {
                        if let box = track.box(at: t) {
                            covers.append(.init(shape: .oval, rect: CoverRenderer.coverRect(
                                x: box.x, y: box.y, width: box.width, height: box.height, in: extent)))
                        }
                    }
                }
            }

            if !covers.isEmpty {
                image = CoverRenderer.apply(covers, to: image, style: style, emojiImage: emoji)
                coveredFrames += 1
            }

            var rendered: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool else {
                throw CensorError.processing("the writer offered no pixel buffer pool")
            }
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &rendered)
            guard let rendered else {
                throw CensorError.processing("could not allocate an output frame")
            }
            context.render(image, to: rendered)
            while !videoInput.isReadyForMoreMediaData { usleep(2000) }
            adaptor.append(rendered, withPresentationTime: pts)

            frames += 1
            if total > 0, frames % 30 == 0 { progress?(min(1, t / total)) }
        }
        videoInput.markAsFinished()

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw CensorError.io("finishing \(output.lastPathComponent) failed: \(writer.error?.localizedDescription ?? "unknown")")
        }

        let coverCount = isPerson ? coveredFrames : tracks.count
        let regionCount: Int
        if case .regions(let regions) = target { regionCount = regions.count } else { regionCount = 0 }
        return FileOutcome(
            input: url.path, output: output.path, status: .covered,
            covers: max(coverCount, regionCount),
            detail: analysisDetail ?? "\(coveredFrames) of \(frames) frames covered")
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
