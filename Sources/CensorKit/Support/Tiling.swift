//
//  Tiling.swift
//  CensorKit
//
//  Created by David Sherlock on 2026.
//
//  The small-face fix, pure. Vision's face detector has an effective
//  minimum face size relative to the image: on a 6000px wedding group
//  shot it found the six foreground faces and missed four background
//  ones — still perfectly identifiable. Cropping the frame into
//  overlapping tiles and detecting per tile raises every face's
//  relative size; these functions cut the tiles, carry tile-space boxes
//  back to frame space, and merge the passes so a face seen twice
//  (full-frame + tile, or two overlapping tiles) is counted once.
//

import Foundation

public enum Tiling {

    /// One tile, normalized to the frame (top-left origin).
    public struct Tile: Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    /// An `n`×`n` grid of tiles with `overlap` (fraction of a tile) shared
    /// between neighbours, so a face on a seam is whole in at least one.
    public static func grid(_ n: Int, overlap: Double = 0.2) -> [Tile] {
        guard n > 1 else { return [Tile(x: 0, y: 0, width: 1, height: 1)] }
        let clamped = min(max(overlap, 0), 0.5)
        let side = 1.0 / (Double(n) - clamped * (Double(n) - 1))
        let step = side * (1 - clamped)
        var tiles: [Tile] = []
        for row in 0..<n {
            for column in 0..<n {
                tiles.append(Tile(
                    x: min(Double(column) * step, 1 - side),
                    y: min(Double(row) * step, 1 - side),
                    width: side, height: side))
            }
        }
        return tiles
    }

    /// A box normalized to `tile` → the same box normalized to the frame.
    public static func toFrame(
        x: Double, y: Double, width: Double, height: Double, tile: Tile
    ) -> (x: Double, y: Double, width: Double, height: Double) {
        (tile.x + x * tile.width,
         tile.y + y * tile.height,
         width * tile.width,
         height * tile.height)
    }

    /// Intersection over union of two frame-space boxes.
    public static func iou(
        _ a: (x: Double, y: Double, width: Double, height: Double),
        _ b: (x: Double, y: Double, width: Double, height: Double)
    ) -> Double {
        let ix = max(a.x, b.x)
        let iy = max(a.y, b.y)
        let ix1 = min(a.x + a.width, b.x + b.width)
        let iy1 = min(a.y + a.height, b.y + b.height)
        let iw = max(0, ix1 - ix)
        let ih = max(0, iy1 - iy)
        let inter = iw * ih
        let union = a.width * a.height + b.width * b.height - inter
        return union > 0 ? inter / union : 0
    }

    /// Detections from all passes with duplicates merged: two boxes above
    /// `iouThreshold` are one face, and the LARGER box wins — the pass
    /// that saw more of the face saw it better.
    public static func merge(
        _ detections: [TrackMath.Detection], iouThreshold: Double = 0.35
    ) -> [TrackMath.Detection] {
        let bySize = detections.sorted {
            $0.width * $0.height > $1.width * $1.height
        }
        var kept: [TrackMath.Detection] = []
        for candidate in bySize {
            let duplicate = kept.contains {
                iou((x: $0.x, y: $0.y, width: $0.width, height: $0.height),
                    (x: candidate.x, y: candidate.y,
                     width: candidate.width, height: candidate.height)) >= iouThreshold
            }
            if !duplicate { kept.append(candidate) }
        }
        return kept
    }
}
