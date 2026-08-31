//
//  SCAGate.swift
//  CensorKit
//
//  Created by David Sherlock on 2026.
//
//  Apple's sensitive-content analyzer, behind one honest gate. The
//  framework judges whole files only — it locates nothing — and it only
//  runs where its policy allows (the user's Sensitive Content Warning
//  setting, or a client entitlement). Everything here reports which.
//

import Foundation
import SensitiveContentAnalysis

public enum SCAGate {

    /// Whether the analyzer will answer at all in this process.
    public static var isAvailable: Bool {
        SCSensitivityAnalyzer().analysisPolicy != .disabled
    }

    /// The message shown when it will not.
    public static let unavailableReason = """
        the sensitive-content analyzer is disabled for this process — it \
        requires either Sensitive Content Warning (System Settings → \
        Privacy & Security) or an entitlement this binary does not hold
        """

    /// Whether Apple's analyzer flags the image.
    public static func isSensitive(imageAt url: URL) async throws -> Bool {
        guard isAvailable else { throw CensorError.unavailable(unavailableReason) }
        return try await SCSensitivityAnalyzer().analyzeImage(at: url).isSensitive
    }

    /// Whether Apple's analyzer flags the video.
    public static func isSensitive(videoAt url: URL) async throws -> Bool {
        guard isAvailable else { throw CensorError.unavailable(unavailableReason) }
        let handler = SCSensitivityAnalyzer().videoAnalysis(forFileAt: url)
        return try await handler.hasSensitiveContent().isSensitive
    }
}
