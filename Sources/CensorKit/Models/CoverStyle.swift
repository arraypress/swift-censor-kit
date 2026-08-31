//
//  CoverStyle.swift
//  CensorKit
//
//  Created by David Sherlock on 2026.
//
//  How a cover looks. The three modes and their feel are ported from
//  caption-kit's FaceCensorFilter — deliberate duplication between
//  independent packages, per the fleet convention, rather than dragging
//  the whole captioning system in as a dependency.
//

/// The look of a censoring cover.
public struct CoverStyle: Sendable, Equatable {

    /// How the covered pixels are hidden.
    public enum Mode: String, Sendable, CaseIterable {
        case blur, pixelate, emoji
    }

    /// The hiding strategy.
    public var mode: Mode
    /// Strength, `0…1`: blur radius or pixel size at the top end.
    public var intensity: Double
    /// The emoji drawn in `.emoji` mode.
    public var emoji: String
    /// Extra margin around each detected box, as a fraction of its size.
    public var padding: Double

    public init(mode: Mode = .blur, intensity: Double = 0.7,
                emoji: String = "🙂", padding: Double = 0.25) {
        self.mode = mode
        self.intensity = intensity
        self.emoji = emoji
        self.padding = padding
    }
}
