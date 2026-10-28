//
//  SheetLabels.swift
//  CensorKit
//
//  Created by David Sherlock on 2026.
//
//  The lines under a contact sheet's tiles, as pure functions.
//

import Foundation

enum SheetLabels {

    /// Seconds as m:ss — or h:mm:ss from an hour on.
    static func clock(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        let (h, m, s) = (whole / 3600, whole / 60 % 60, whole % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// A person's tile: their number, when they are on screen, for how long.
    static func person(_ person: VideoPerson) -> String {
        let span = person.from == person.to
            ? clock(person.from) : "\(clock(person.from))–\(clock(person.to))"
        return "#\(person.number)  \(span)  \(max(1, Int(person.seconds.rounded())))s"
    }

    /// A preview frame's tile: when it is, and how many covers it carries.
    static func frame(at time: TimeInterval, covers: Int) -> String {
        "\(clock(time))  " + (covers == 0 ? "nothing covered" : covers == 1 ? "1 cover" : "\(covers) covers")
    }
}
