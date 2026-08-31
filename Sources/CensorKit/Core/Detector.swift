//
//  Detector.swift
//  CensorKit
//
//  Created by David Sherlock on 2026.
//
//  The Vision passes, each a function from a bitmap to plain values, in
//  the fleet's reporting convention (normalized, top-left origin). The
//  face-crop identity approach — a feature print of the crop with a 30%
//  margin, because Apple ships no public recognition API — follows
//  swift-photo-index, whose calibration the matcher's threshold cites.
//

import CoreGraphics
import CoreImage
import Foundation
import Vision

enum Detector {

    /// Detected faces; embeddings only when identity is needed.
    static func faces(in image: CGImage, withEmbeddings: Bool) throws -> [TrackMath.Detection] {
        let request = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        var out: [TrackMath.Detection] = []
        for observation in request.results ?? [] {
            let box = observation.boundingBox
            var embedding: [Float] = []
            if withEmbeddings, let crop = faceCrop(from: image, boundingBox: box) {
                embedding = (try? featurePrint(of: crop)) ?? []
            }
            // Vision's origin is bottom-left; the fleet reports top-left.
            out.append(TrackMath.Detection(
                time: 0,
                x: box.origin.x,
                y: 1 - box.origin.y - box.height,
                width: box.width,
                height: box.height,
                embedding: embedding))
        }
        return out
    }

    /// Boxes of recognized lines whose text contains the pattern.
    static func textBoxes(in image: CGImage, pattern: String) throws -> [TrackMath.Detection] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        var out: [TrackMath.Detection] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first,
                  TextMatch.matches(candidate.string, pattern: pattern) else { continue }
            let box = observation.boundingBox
            out.append(TrackMath.Detection(
                time: 0,
                x: box.origin.x,
                y: 1 - box.origin.y - box.height,
                width: box.width,
                height: box.height))
        }
        return out
    }

    /// The whole-image (or crop) feature print, as raw floats.
    static func featurePrint(of image: CGImage) throws -> [Float] {
        let request = VNGenerateImageFeaturePrintRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        guard let observation = request.results?.first else {
            throw CensorError.processing("no feature print produced")
        }
        return Vectors.floats(from: observation.data)
    }

    /// The largest face's embedding in a reference photo.
    static func referenceEmbedding(in image: CGImage) throws -> [Float] {
        let detections = try faces(in: image, withEmbeddings: true)
        guard let best = detections.max(by: { $0.width * $0.height < $1.width * $1.height }),
              !best.embedding.isEmpty else {
            throw CensorError.usage("no face found in the reference photo")
        }
        return best.embedding
    }

    /// A person mask for a still: instance masks when `only` selects one
    /// person (1-based, by mask area, largest first), else everyone.
    /// Returned in the image's pixel space, white where covered.
    static func personMask(in image: CGImage, only: Int?) throws -> (mask: CIImage, people: Int)? {
        let request = VNGeneratePersonInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        guard let observation = request.results?.first,
              !observation.allInstances.isEmpty else { return nil }
        let all = observation.allInstances

        var chosen = all
        if let only {
            // Rank instances by mask area so `--only 1` is the biggest person.
            var areas: [(instance: Int, area: Int)] = []
            for instance in all {
                let buffer = try observation.generateScaledMaskForImage(
                    forInstances: IndexSet(integer: instance), from: handler)
                areas.append((instance, Self.maskArea(buffer)))
            }
            let ranked = areas.sorted { $0.area > $1.area }
            guard only >= 1, only <= ranked.count else {
                throw CensorError.usage("--only \(only): the frame has \(ranked.count) people")
            }
            chosen = IndexSet(integer: ranked[only - 1].instance)
        }

        let buffer = try observation.generateScaledMaskForImage(forInstances: chosen, from: handler)
        return (CIImage(cvPixelBuffer: buffer), all.count)
    }

    /// A fast all-person mask for a video frame, scaled to `extent`.
    static func personSegmentationMask(in buffer: CVPixelBuffer, extent: CGRect) throws -> CIImage? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try VNImageRequestHandler(cvPixelBuffer: buffer).perform([request])
        guard let observation = request.results?.first else { return nil }
        let mask = CIImage(cvPixelBuffer: observation.pixelBuffer)
        let sx = extent.width / mask.extent.width
        let sy = extent.height / mask.extent.height
        return mask.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
    }

    /// The face's pixels with a 30% margin, clamped to the image — hair
    /// and jaw carry most of what makes the print distinctive.
    static func faceCrop(from image: CGImage, boundingBox box: CGRect) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let w = box.width * width
        let h = box.height * height
        let margin = 0.3 * max(w, h)
        let rect = CGRect(
            x: box.origin.x * width - margin,
            y: (1 - box.origin.y - box.height) * height - margin,
            width: w + 2 * margin,
            height: h + 2 * margin
        ).intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !rect.isEmpty else { return nil }
        return image.cropping(to: rect.integral)
    }

    /// White pixels in a one-component mask — the cheapest area measure.
    private static func maskArea(_ buffer: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let height = CVPixelBufferGetHeight(buffer)
        let width = CVPixelBufferGetWidth(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var area = 0
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            for column in 0..<width where bytes[row * rowBytes + column] > 127 {
                area += 1
            }
        }
        return area
    }
}
