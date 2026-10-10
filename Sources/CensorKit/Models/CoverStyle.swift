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
        /// Opaque black: nothing of the covered pixels survives — what a
        /// redaction needs, where blur and pixelation only obscure.
        case solid
    }

    /// The hiding strategy.
    public var mode: Mode
    /// Strength, `0…1`: blur radius or pixel size at the top end.
    public var intensity: Double
    /// The emoji drawn in `.emoji` mode.
    public var emoji: String
    /// User multiplier on the finished cover box: 1 leaves the measured
    /// cover exactly as sized, larger grows it. Applied ONCE, in the
    /// renderer — sizing itself (adaptive head extent, or the multiplier
    /// fallback) happens upstream, so nothing stacks.
    public var padding: Double
    /// Diagnostic mode: draw the raw detection and the final cover as
    /// frames instead of covering — registration made visible.
    public var outline: Bool

    public init(mode: Mode = .blur, intensity: Double = 0.7,
                emoji: String = "🙂", padding: Double = 1.0,
                outline: Bool = false) {
        self.mode = mode
        self.intensity = intensity
        self.emoji = emoji
        self.padding = padding
        self.outline = outline
    }
}
