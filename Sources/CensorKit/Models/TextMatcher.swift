//
//  TextMatcher.swift
//  CensorKit
//
//  Created by David Sherlock on 2026.
//
//  Which recognised lines earn a cover, decided by the caller. A plain
//  substring is enough to cover a name; a card number needs its Luhn check
//  and an IBAN its mod-97, and those rules live in RedactKit, which this
//  kit does not depend on — so the rule is handed in, not reimplemented.
//

import Foundation

/// A rule for which recognised text lines to cover.
public struct TextMatcher: Sendable {
    /// What it matches, for a report: `"4111"`, `"card, iban, email"`.
    public let summary: String
    /// Whether a recognised line should be covered.
    public let matches: @Sendable (String) -> Bool

    /// - Parameters:
    ///   - summary: What it matches, for a report.
    ///   - matches: The rule.
    public init(summary: String, matches: @escaping @Sendable (String) -> Bool) {
        self.summary = summary
        self.matches = matches
    }

    /// Lines containing a phrase, case-insensitively — what `.text(pattern:)` means.
    public static func containing(_ pattern: String) -> TextMatcher {
        TextMatcher(summary: pattern) { TextMatch.matches($0, pattern: pattern) }
    }
}
