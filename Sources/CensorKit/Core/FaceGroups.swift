//
//  FaceGroups.swift
//  CensorKit
//
//  Created by David Sherlock on 2026.
//
//  Which face tracks are the same person, by Apple's face grouping
//  (MediaIntelligence's FaceGroupAnalyzer, macOS 27) — the people grouping
//  Photos does, over a few crops of each track written to a scratch folder.
//
//  MEASURED on 734 frames of a feature film (one a second): 460 faces into
//  37 groups, every group one actor, never two actors in one group; an
//  actor in dark scenes can come out as two or three groups — the safe
//  way round, since picking two numbers is better than sparing a stranger.
//  Two runs gave the same groups. The framework prints its progress to
//  standard output, where a command-line tool writes JSON, and CoreData's
//  debug lines to standard error, where it reports progress — so it runs
//  with both silenced.
//

import CoreGraphics
import Foundation
import ImageIO
import MediaIntelligence
import StdoutSilencer
import UniformTypeIdentifiers

@available(macOS 27.0, *)
enum FaceGroups {

    /// One crop to group: a face from one track, with room around it.
    struct Crop {
        let track: Int
        /// The sample it is of.
        let time: TimeInterval
        /// JPEG bytes.
        let jpeg: Data
    }

    /// Each crop's group, as votes for PeopleGrouping.
    static func votes(_ crops: [Crop]) async throws -> [PeopleGrouping.Vote] {
        guard !crops.isEmpty else { return [] }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("censor-faces-\(UUID().uuidString)")
        let images = folder.appendingPathComponent("crops")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var assets: [MediaIntelligenceImageAsset] = []
        for (index, crop) in crops.enumerated() {
            let url = images.appendingPathComponent("\(index).jpg")
            try crop.jpeg.write(to: url)
            let id = MediaIntelligenceImageAsset.ID("\(index)")
            assets.append(MediaIntelligenceImageAsset(id: id, kind: .url(url)))
        }

        let faces: [FaceGroupAnalyzer.Face] = try await StandardError.silenced { try await StandardOutput.silenced {
            let analyzer = try FaceGroupAnalyzer(workingDirectory: folder.appendingPathComponent("groups"))
            for try await _ in try await analyzer.insertOrUpdateAssets(assets) {}
            try await analyzer.update()
            var all: [FaceGroupAnalyzer.Face] = []
            for try await face in analyzer.allFaces { all.append(face) }
            return all
        } }

        // A crop can hold a second face at its edge; the crop is about the
        // one nearest its centre.
        var nearest: [MediaIntelligenceImageAsset.ID: (distance: Double, group: String?)] = [:]
        for face in faces {
            let dx = face.bounds.midX - 0.5, dy = face.bounds.midY - 0.5
            let distance = dx * dx + dy * dy
            if let held = nearest[face.assetID], held.distance <= distance { continue }
            nearest[face.assetID] = (distance, face.entityID?.rawValue)
        }
        return zip(assets, crops).map { asset, crop in
            PeopleGrouping.Vote(track: crop.track, time: crop.time, group: nearest[asset.id]?.group)
        }
    }

    /// A face crop for grouping and for the people sheet: the face with
    /// half its size again on every side, upright, at most `side` pixels.
    static func crop(of image: CGImage, face: TrackMath.Detection, quarterTurns: Int,
                     side: Int = 256) -> Data? {
        let width = Double(image.width), height = Double(image.height)
        let margin = 0.5 * max(face.width * width, face.height * height)
        let rect = CGRect(x: face.x * width - margin, y: face.y * height - margin,
                          width: face.width * width + 2 * margin, height: face.height * height + 2 * margin)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
        guard rect.width >= 8, rect.height >= 8, let cropped = image.cropping(to: rect) else { return nil }
        let upright = Detector.upright(cropped, quarterTurns: quarterTurns)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        let options: [CFString: Any] = [kCGImageDestinationImageMaxPixelSize: side,
                                        kCGImageDestinationLossyCompressionQuality: 0.85]
        CGImageDestinationAddImage(destination, upright, options as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
