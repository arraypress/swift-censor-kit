//
//  HeadExtent.swift
//  CensorKit
//
//  Created by David Sherlock on 2026.
//
//  Adaptive cover sizing: measure the head instead of guessing it. No
//  single multiplier of the face box is right — 2.2× tall leaves big
//  curly hair outside on one clip and reads comically oversized on a
//  close-up — so the default cover is the extent of the person-mask
//  component around the detected face, cut off below the chin so the
//  torso never joins the head. The mask work is Vision's; this file is
//  the pure part a test can pin: the component walk over a bit grid and
//  the margins the caller applies.
//

import Foundation

public enum HeadExtent {

    /// Margin multiplier for stills — a whisker of safety, nothing more.
    public static let stillMargin = 1.06
    /// Margin multiplier for video: covers must LEAD a moving head, not
    /// trail it — detection samples run every stride, and the subject
    /// keeps moving between them.
    public static let videoMotionMargin = 1.18
    /// Below this face width (pixels), segmentation on the crop is noise
    /// — tiny tiled-pass faces fall back to the multiplier cover.
    public static let minimumAdaptiveFacePixels = 48.0
    /// The mask component is only followed this many face-heights below
    /// the face box before the cut — the chin line that keeps torsos out.
    /// 1.0 swallowed visible chest on close-ups; 0.6 keeps chin and neck.
    public static let belowFaceAllowance = 0.6

    /// The extent of the mask component overlapping `face`, bounded below
    /// the chin cut. Everything is in the GRID's normalized coordinates
    /// (top-left origin). Returns nil when no mask cell overlaps the face.
    public static func headBox(
        mask: [Bool], width: Int, height: Int,
        face: (x: Double, y: Double, width: Double, height: Double)
    ) -> (x: Double, y: Double, width: Double, height: Double)? {
        guard width > 0, height > 0, mask.count == width * height else { return nil }

        func cell(_ x: Int, _ y: Int) -> Bool { mask[y * width + x] }
        let fx0 = max(0, Int(face.x * Double(width)))
        let fy0 = max(0, Int(face.y * Double(height)))
        let fx1 = min(width - 1, Int((face.x + face.width) * Double(width)))
        let fy1 = min(height - 1, Int((face.y + face.height) * Double(height)))
        guard fx0 <= fx1, fy0 <= fy1 else { return nil }

        // The chin cut: rows below this take no part in the component.
        let cutRow = min(height - 1,
                         fy1 + Int(face.height * belowFaceAllowance * Double(height)))

        var seeds: [(Int, Int)] = []
        for y in fy0...fy1 {
            for x in fx0...fx1 where cell(x, y) { seeds.append((x, y)) }
        }
        guard !seeds.isEmpty else { return nil }

        var visited = [Bool](repeating: false, count: mask.count)
        var queue = seeds
        for (x, y) in seeds { visited[y * width + x] = true }
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        var index = 0
        while index < queue.count {
            let (x, y) = queue[index]
            index += 1
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                guard nx >= 0, nx < width, ny >= 0, ny <= cutRow,
                      !visited[ny * width + nx], cell(nx, ny) else { continue }
                visited[ny * width + nx] = true
                queue.append((nx, ny))
            }
        }

        return (Double(minX) / Double(width),
                Double(minY) / Double(height),
                Double(maxX - minX + 1) / Double(width),
                Double(maxY - minY + 1) / Double(height))
    }

    /// A box grown by `margin` around its center, clamped to the frame.
    public static func withMargin(
        _ box: (x: Double, y: Double, width: Double, height: Double), margin: Double
    ) -> (x: Double, y: Double, width: Double, height: Double) {
        let w = box.width * margin
        let h = box.height * margin
        let rawX = box.x - (w - box.width) / 2
        let rawY = box.y - (h - box.height) / 2
        let x0 = max(0, rawX)
        let y0 = max(0, rawY)
        return (x0, y0, min(1, rawX + w) - x0, min(1, rawY + h) - y0)
    }
}
