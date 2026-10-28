//
//  VideoPerson+Summary.swift
//  CensorKit
//
//  Created by David Sherlock on 2026.
//

public extension VideoPerson {

    /// The line under their face on the people sheet — `#2  0:04–1:23  48s`
    /// — for a report to print the same words.
    var summary: String { SheetLabels.person(self) }
}
