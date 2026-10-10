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
    ///
    /// `quarterTurns` is the source's display rotation: detection runs in
    /// DISPLAY orientation (Vision wants faces upright — a portrait
    /// phone clip stores them sideways), and the boxes are carried back
    /// to storage space, where covers are drawn. Crops are uprighted
    /// before feature-printing so they match upright reference photos.
    static func faces(in image: CGImage, withEmbeddings: Bool,
                      quarterTurns: Int = 0) throws -> [TrackMath.Detection] {
        let request = VNDetectFaceRectanglesRequest()
        let orientation = OrientationMap.visionOrientation(quarterTurns: quarterTurns)
        try VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
            .perform([request])
        var out: [TrackMath.Detection] = []
        for observation in request.results ?? [] {
            let box = observation.boundingBox
            // Vision's origin is bottom-left in the ORIENTED image; flip
            // to top-left there, then carry to storage space.
            let storage = OrientationMap.toStorage(
                x: box.origin.x, y: 1 - box.origin.y - box.height,
                width: box.width, height: box.height, quarterTurns: quarterTurns)
            var embedding: [Float] = []
            if withEmbeddings {
                let visionBox = CGRect(x: storage.x, y: 1 - storage.y - storage.height,
                                       width: storage.width, height: storage.height)
                if let crop = faceCrop(from: image, boundingBox: visionBox) {
                    let uprighted = upright(crop, quarterTurns: quarterTurns)
                    embedding = (try? featurePrint(of: uprighted)) ?? []
                }
            }
            out.append(TrackMath.Detection(
                time: 0,
                x: storage.x, y: storage.y,
                width: storage.width, height: storage.height,
                embedding: embedding))
        }
        return out
    }

    /// A storage-space crop rotated upright, for feature prints that can
    /// match upright references.
    static func upright(_ crop: CGImage, quarterTurns: Int) -> CGImage {
        guard quarterTurns != 0 else { return crop }
        let oriented = CIImage(cgImage: crop)
            .oriented(OrientationMap.uprightingOrientation(quarterTurns: quarterTurns))
        let moved = oriented.transformed(by: CGAffineTransform(
            translationX: -oriented.extent.origin.x, y: -oriented.extent.origin.y))
        return uprightContext.createCGImage(moved, from: moved.extent) ?? crop
    }

    private static let uprightContext = CIContext()

    /// Boxes of recognized lines whose text contains the pattern.
    static func textBoxes(in image: CGImage, pattern: String,
                          quarterTurns: Int = 0) throws -> [TrackMath.Detection] {
        try textBoxes(in: image, matcher: .containing(pattern), quarterTurns: quarterTurns)
    }

    /// Boxes of recognized lines a matcher picks.
    static func textBoxes(in image: CGImage, matcher: TextMatcher,
                          quarterTurns: Int = 0) throws -> [TrackMath.Detection] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let orientation = OrientationMap.visionOrientation(quarterTurns: quarterTurns)
        try VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
            .perform([request])
        var out: [TrackMath.Detection] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first,
                  matcher.matches(candidate.string) else { continue }
            let box = observation.boundingBox
            let storage = OrientationMap.toStorage(
                x: box.origin.x, y: 1 - box.origin.y - box.height,
                width: box.width, height: box.height, quarterTurns: quarterTurns)
            out.append(TrackMath.Detection(
                time: 0,
                x: storage.x, y: storage.y,
                width: storage.width, height: storage.height))
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

// MARK: - Small faces and measured heads

extension Detector {

    /// Stills at or above this many pixels on their longer side get the
    /// tiled second pass by default — below it, faces Vision can find at
    /// all are already large relative to the frame.
    static let tilingMinimumDimension = 1600

    /// The full-frame pass plus a 3×3 overlapping tiled pass, merged.
    ///
    /// Vision's detector has an effective minimum face size relative to
    /// its input: a 6000px group photo's background faces simply do not
    /// exist to the full-frame pass. Tiles raise every face's relative
    /// size. `force` runs the tiles regardless of size (video --thorough).
    static func facesThorough(
        in image: CGImage, withEmbeddings: Bool, quarterTurns: Int = 0,
        force: Bool = false
    ) throws -> [TrackMath.Detection] {
        var all = try faces(in: image, withEmbeddings: withEmbeddings,
                            quarterTurns: quarterTurns)
        let longSide = max(image.width, image.height)
        guard force || longSide >= tilingMinimumDimension else { return all }

        let width = Double(image.width)
        let height = Double(image.height)
        // Tiles aim near 1500px so a face's relative size rises the same
        // on a 3000px frame and a 6000px one; capped to keep cost sane.
        let n = min(4, max(2, longSide / 1500))
        for tile in Tiling.grid(n) {
            let rect = CGRect(x: tile.x * width, y: tile.y * height,
                              width: tile.width * width, height: tile.height * height)
            guard let crop = image.cropping(to: rect.integral) else { continue }
            let found = try faces(in: crop, withEmbeddings: withEmbeddings,
                                  quarterTurns: quarterTurns)
            for detection in found {
                let framed = Tiling.toFrame(
                    x: detection.x, y: detection.y,
                    width: detection.width, height: detection.height, tile: tile)
                var carried = detection
                carried.x = framed.x
                carried.y = framed.y
                carried.width = framed.width
                carried.height = framed.height
                all.append(carried)
            }
        }
        return Tiling.merge(all)
    }

    /// The measured head cover for a detected face: person-mask extent
    /// around the face, chin-cut, with the caller's margin — or nil when
    /// the face is too small for segmentation to mean anything, or the
    /// mask finds nothing (the multiplier fallback takes over).
    static func adaptiveHeadBox(
        in image: CGImage, face: TrackMath.Detection, quarterTurns: Int,
        margin: Double
    ) -> (x: Double, y: Double, width: Double, height: Double)? {
        let width = Double(image.width)
        let height = Double(image.height)
        let facePixels = max(face.width * width, face.height * height)
        guard facePixels >= HeadExtent.minimumAdaptiveFacePixels else { return nil }

        // A square search region, three face-sides around the center.
        let side = 3 * facePixels
        let cx = (face.x + face.width / 2) * width
        let cy = (face.y + face.height / 2) * height
        let region = CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
        guard region.width > 8, region.height > 8,
              let crop = image.cropping(to: region) else { return nil }

        // Work upright: "below the chin" means display-down, not storage-down.
        let uprighted = upright(crop, quarterTurns: quarterTurns)
        let inverse = (4 - quarterTurns) % 4

        // The face box in region coordinates (storage), then in display.
        let rFace = (x: (face.x * width - region.minX) / region.width,
                     y: (face.y * height - region.minY) / region.height,
                     width: face.width * width / region.width,
                     height: face.height * height / region.height)
        let dFace = OrientationMap.toStorage(
            x: rFace.x, y: rFace.y, width: rFace.width, height: rFace.height,
            quarterTurns: inverse)

        guard let grid = personMaskGrid(in: uprighted) else { return nil }
        guard let extent = HeadExtent.headBox(
            mask: grid.mask, width: grid.width, height: grid.height,
            face: dFace) else { return nil }

        // Display-region → storage-region → frame, then the margin.
        let back = OrientationMap.toStorage(
            x: extent.x, y: extent.y, width: extent.width, height: extent.height,
            quarterTurns: quarterTurns)
        let framed = (x: (region.minX + back.x * region.width) / width,
                      y: (region.minY + back.y * region.height) / height,
                      width: back.width * region.width / width,
                      height: back.height * region.height / height)
        return HeadExtent.withMargin(framed, margin: margin)
    }

    /// All person instances in one downsampled bit grid, or nil when the
    /// request fails or finds nobody.
    private static func personMaskGrid(
        in image: CGImage
    ) -> (mask: [Bool], width: Int, height: Int)? {
        let request = VNGeneratePersonInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first,
              !observation.allInstances.isEmpty,
              let buffer = try? observation.generateScaledMaskForImage(
                forInstances: observation.allInstances, from: handler)
        else { return nil }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bufferWidth = CVPixelBufferGetWidth(buffer)
        let bufferHeight = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)

        let gridWidth = min(bufferWidth, 160)
        let gridHeight = max(1, bufferHeight * gridWidth / max(1, bufferWidth))
        var mask = [Bool](repeating: false, count: gridWidth * gridHeight)

        if format == kCVPixelFormatType_OneComponent32Float {
            let floats = base.assumingMemoryBound(to: Float.self)
            let floatsPerRow = rowBytes / MemoryLayout<Float>.stride
            for gy in 0..<gridHeight {
                let sy = gy * bufferHeight / gridHeight
                for gx in 0..<gridWidth {
                    let sx = gx * bufferWidth / gridWidth
                    mask[gy * gridWidth + gx] = floats[sy * floatsPerRow + sx] > 0.5
                }
            }
        } else {
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for gy in 0..<gridHeight {
                let sy = gy * bufferHeight / gridHeight
                for gx in 0..<gridWidth {
                    let sx = gx * bufferWidth / gridWidth
                    mask[gy * gridWidth + gx] = bytes[sy * rowBytes + sx] > 127
                }
            }
        }
        return (mask, gridWidth, gridHeight)
    }
}
