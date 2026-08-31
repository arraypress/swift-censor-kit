//
//  FaceGeometry.swift
//  CensorKit
//
//  Created by David Sherlock on 2026.
//
//  Vision's face rectangle is a FEATURE box — eyes, nose, mouth — and by
//  design excludes the forehead, hair and chin. A cover sized to it
//  leaves the person identifiable (the first real handheld clip proved
//  it: one eye, the glasses and all the hair were outside the box).
//  This is the correction, pure and pinned: grow wide for ears and hair,
//  grow tall with the extra height biased ABOVE the detection, where the
//  forehead and hair actually are. Privacy-first: err on over-covering.
//

public enum FaceGeometry {

    /// Width multiplier over the detected feature box.
    public static let widthGrowth = 1.6
    /// Height multiplier over the detected feature box.
    public static let heightGrowth = 2.2
    /// The share of the added height that goes ABOVE the detection.
    public static let upwardBias = 0.65

    /// The cover box for a detected face box (normalized, top-left origin),
    /// clamped to the frame.
    public static func coverBox(
        x: Double, y: Double, width: Double, height: Double
    ) -> (x: Double, y: Double, width: Double, height: Double) {
        let grownW = width * widthGrowth
        let grownH = height * heightGrowth
        let rawX = x - (grownW - width) / 2
        let rawY = y - (grownH - height) * upwardBias
        let x0 = max(0, rawX)
        let y0 = max(0, rawY)
        let x1 = min(1, rawX + grownW)
        let y1 = min(1, rawY + grownH)
        return (x0, y0, max(0, x1 - x0), max(0, y1 - y0))
    }
}
