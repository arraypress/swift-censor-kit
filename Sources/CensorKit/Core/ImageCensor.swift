//
//  ImageCensor.swift
//  CensorKit
//
//  Created by David Sherlock on 2026.
//
//  One still, censored: detect, decide, render, write — never in place.
//  Orientation is baked in on load so a rotated phone photo's covers land
//  where the faces are, and the source's color space rides through.
//

import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageCensor {

    /// Censors one image to `output` (or just reports, when `dryRun`).
    public static func censor(
        imageAt url: URL, target: CensorTargetSpec, style: CoverStyle,
        to output: URL, dryRun: Bool
    ) async throws -> FileOutcome {
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw CensorError.io("could not read \(url.lastPathComponent) as an image")
        }
        let context = CIContext()
        guard let cgImage = context.createCGImage(image, from: image.extent) else {
            throw CensorError.processing("could not rasterize \(url.lastPathComponent)")
        }

        var covers: [CoverRenderer.Cover] = []
        var detail: String?

        switch target {
        case .faces(let selection):
            // Full-frame plus tiles (big stills), in reading order so the
            // numbers --outline draws are the numbers --only takes.
            let detections = FaceOrdering.ordered(
                try await Detector.facesThorough(in: cgImage, withEmbeddings: selection.wantsIdentity))
            var kept = 0
            for (index, detection) in detections.enumerated() {
                let number = index + 1
                guard selection.shouldCover(number: number, embedding: detection.embedding)
                else { kept += 1; continue }
                // The cover is the MEASURED head where segmentation sees
                // one, the multiplier guess where it does not.
                let head = Detector.adaptiveHeadBox(
                    in: cgImage, face: detection, quarterTurns: 0,
                    margin: HeadExtent.stillMargin)
                    ?? FaceGeometry.coverBox(
                        x: detection.x, y: detection.y,
                        width: detection.width, height: detection.height)
                covers.append(.init(
                    shape: .oval,
                    rect: CoverRenderer.coverRect(
                        x: head.x, y: head.y,
                        width: head.width, height: head.height, in: image.extent),
                    raw: CoverRenderer.coverRect(
                        x: detection.x, y: detection.y,
                        width: detection.width, height: detection.height, in: image.extent),
                    label: number))
            }
            if selection.isSelective {
                detail = "\(detections.count) faces, \(kept) left uncovered by selection"
            }

        case .person(let only):
            if let (mask, people) = try Detector.personMask(in: cgImage, only: only) {
                covers.append(.init(shape: .mask(mask), rect: image.extent))
                detail = only.map { "person \($0) of \(people)" } ?? "\(people) people, one mask"
            }

        case .text, .matching:
            for detection in try Detector.textBoxes(in: cgImage, matcher: target.textMatcher!) {
                covers.append(.init(shape: .rectangle, rect: CoverRenderer.coverRect(
                    x: detection.x, y: detection.y,
                    width: detection.width, height: detection.height, in: image.extent)))
            }

        case .regions(let regions):
            for region in regions where region.covers(at: 0) {
                covers.append(.init(shape: .rectangle, rect: CoverRenderer.coverRect(
                    x: region.x, y: region.y,
                    width: region.width, height: region.height, in: image.extent)))
            }
        }

        // A cover count for .person means people found, not boxes.
        let coverCount = covers.contains { if case .mask = $0.shape { true } else { false } }
            ? max(covers.count, 1)
            : covers.count

        if dryRun {
            return FileOutcome(input: url.path, status: .wouldCover,
                               covers: coverCount, detail: detail)
        }
        guard !covers.isEmpty else {
            return FileOutcome(input: url.path, status: .skipped,
                               covers: 0, detail: detail ?? "nothing detected to cover")
        }

        let emoji = style.mode == .emoji ? CoverRenderer.renderEmoji(style.emoji) : nil
        let rendered = CoverRenderer.apply(covers, to: image, style: style, emojiImage: emoji)
        try write(rendered, from: image, to: output, context: context)
        return FileOutcome(input: url.path, output: output.path, status: .covered,
                           covers: coverCount, detail: detail)
    }

    private static func write(_ image: CIImage, from source: CIImage, to output: URL,
                              context: CIContext) throws {
        let space = source.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        // The source's properties ride through every filter and Core Image
        // writes them back: GPS, camera, serial number and author survived a
        // blur until this. Orientation is already in the pixels (the read
        // applied it), so nothing worth keeping goes with them.
        let image = image.settingProperties([:])
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        switch output.pathExtension.lowercased() {
        case "jpg", "jpeg":
            try context.writeJPEGRepresentation(
                of: image, to: output, colorSpace: space,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.92])
        case "heic":
            try context.writeHEIFRepresentation(
                of: image, to: output, format: .RGBA8, colorSpace: space,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.92])
        default:
            try context.writePNGRepresentation(of: image, to: output, format: .RGBA8, colorSpace: space)
        }
        // Checked, not assumed: a copy for sharing that still says where it
        // was taken is removed and refused.
        let leaks = MetadataCheck.leaks(in: output)
        guard leaks.isEmpty else {
            try? FileManager.default.removeItem(at: output)
            throw CensorError.processing("\(output.lastPathComponent) still carried \(leaks.joined(separator: ", ")) metadata; nothing was written")
        }
    }
}
