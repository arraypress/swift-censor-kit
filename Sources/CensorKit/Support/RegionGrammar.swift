//
//  RegionGrammar.swift
//  CensorKit
//
//  Created by David Sherlock on 2026.
//
//  `x,y,w,h[@t0-t1]` → Region, as a pure function the tests pin to the
//  character. Fractions of the frame, not pixels, so one flag means the
//  same thing at every resolution.
//

import Foundation

public enum RegionGrammar {

    /// Parses `x,y,w,h` or `x,y,w,h@t0-t1` (fractions; seconds).
    public static func parse(_ raw: String) throws -> Region {
        let parts = raw.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count <= 2, let boxPart = parts.first else {
            throw CensorError.usage("Region is x,y,w,h or x,y,w,h@t0-t1 — got \"\(raw)\"")
        }

        let numbers = boxPart.split(separator: ",", omittingEmptySubsequences: false)
            .map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count == 4, !numbers.contains(nil) else {
            throw CensorError.usage("Region needs four numbers x,y,w,h — got \"\(boxPart)\"")
        }
        let values = numbers.compactMap { $0 }
        guard values.allSatisfy({ $0 >= 0 && $0 <= 1 }), values[2] > 0, values[3] > 0 else {
            throw CensorError.usage("Region values are fractions of the frame, 0…1, with positive size — got \"\(boxPart)\"")
        }
        guard values[0] + values[2] <= 1.000001, values[1] + values[3] <= 1.000001 else {
            throw CensorError.usage("Region reaches outside the frame — got \"\(boxPart)\"")
        }

        var start: TimeInterval?
        var end: TimeInterval?
        if parts.count == 2 {
            let window = parts[1].split(separator: "-", omittingEmptySubsequences: false)
            guard window.count == 2,
                  let t0 = TimeInterval(window[0].trimmingCharacters(in: .whitespaces)),
                  let t1 = TimeInterval(window[1].trimmingCharacters(in: .whitespaces)),
                  t0 >= 0, t1 > t0 else {
                throw CensorError.usage("Region time window is @t0-t1 in seconds, t1 after t0 — got \"@\(parts[1])\"")
            }
            start = t0
            end = t1
        }

        return Region(x: values[0], y: values[1], width: values[2], height: values[3],
                      start: start, end: end)
    }
}
