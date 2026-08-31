//
//  CensorError.swift
//  CensorKit
//
//  Created by David Sherlock on 2026.
//

import Foundation

/// What can go wrong, in the caller's terms.
public enum CensorError: Error, LocalizedError, Equatable {
    /// The caller asked for something malformed; the message says what.
    case usage(String)
    /// A file could not be read or written.
    case io(String)
    /// A Vision or CoreImage pass failed.
    case processing(String)
    /// The capability exists but is not available here (e.g. the sensitive-
    /// content analyzer without its entitlement).
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .usage(let s), .io(let s), .processing(let s), .unavailable(let s):
            return s
        }
    }
}
