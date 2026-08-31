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
    ) throws -> FileOutcome {
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
        case .faces(let except, let only):
            let wantIdentity = !except.isEmpty || !only.isEmpty
            let detections = try Detector.faces(in: cgImage, withEmbeddings: wantIdentity)
            var kept = 0
            for detection in detections {
                let cover = wantIdentity
                    ? FaceMatching.shouldCover(detection.embedding, except: except, only: only)
                    : true
                guard cover else { kept += 1; continue }
                covers.append(.init(shape: .oval, rect: CoverRenderer.coverRect(
                    x: detection.x, y: detection.y,
                    width: detection.width, height: detection.height, in: image.extent)))
            }
            if wantIdentity {
                detail = "\(detections.count) faces, \(kept) left uncovered by reference match"
            }

        case .person(let only):
            if let (mask, people) = try Detector.personMask(in: cgImage, only: only) {
                covers.append(.init(shape: .mask(mask), rect: image.extent))
                detail = only.map { "person \($0) of \(people)" } ?? "\(people) people, one mask"
            }

        case .text(let pattern):
            for detection in try Detector.textBoxes(in: cgImage, pattern: pattern) {
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
    }
}
