//
//  PeopleGrouping.swift
//  CensorKit
//
//  Created by David Sherlock on 2026.
//
//  Face tracks → people, as pure functions. Apple's face grouping
//  (FaceGroups) sees a crop of each track about once a second and puts
//  each crop's face in a group. Where a track's crops change group, the
//  track is split: two people crossing swap tracks — measured on a film
//  scene, the grouping was right about every crop while one track held
//  three crops of one man and then the other — and a track that is two
//  people would otherwise make one of them a number that covers both.
//  The tracks of one group are one person. The numbers must come out
//  the same on every run over the same video — `--outline` prints them,
//  a later run covers by them — so every tie is broken by a fixed rule.
//

import Foundation

enum PeopleGrouping {

    /// What the face grouping said about one crop of one track.
    struct Vote: Equatable {
        /// The track the crop came from.
        let track: Int
        /// The sample the crop is of.
        let time: TimeInterval
        /// The group its face went to; nil when no face was found in it.
        let group: String?
    }

    /// The keyframes worth a crop: the first, then one at least `spacing`
    /// seconds after the last chosen, and the last.
    static func cropTimes(_ keyframes: [TrackedBox], spacing: TimeInterval) -> [TrackedBox] {
        var chosen: [TrackedBox] = []
        for box in keyframes where chosen.last.map({ box.time - $0.time >= spacing }) ?? true {
            chosen.append(box)
        }
        if let last = keyframes.last, chosen.last != last { chosen.append(last) }
        return chosen
    }

    /// Tracks split where their crops change group, and each piece's group.
    ///
    /// A piece ends halfway between the last crop of one group and the
    /// first of the next. Crops with no face found join whichever piece
    /// they fall in, and so does a crop alone in its group across the whole
    /// video: it says nothing about who anyone is. On a film scene, one
    /// such crop — a face half behind a shoulder — split a track of the
    /// same woman into two people. A track none of whose crops held a face has no group —
    /// it is a person alone. New pieces take ids above every existing one,
    /// in track order, so the same video always splits the same way.
    static func split(_ tracks: [Track], votes: [Vote]) -> (tracks: [Track], groups: [Int: String]) {
        var sizes: [String: Int] = [:]
        for vote in votes { if let group = vote.group { sizes[group, default: 0] += 1 } }
        var byTrack: [Int: [Vote]] = [:]
        for vote in votes where (vote.group.flatMap { sizes[$0] } ?? 0) > 1 {
            byTrack[vote.track, default: []].append(vote)
        }
        var nextID = (tracks.map(\.id).max() ?? -1) + 1
        var out: [Track] = []
        var groups: [Int: String] = [:]
        for track in tracks.sorted(by: { $0.id < $1.id }) {
            let seen = (byTrack[track.id] ?? []).sorted { $0.time < $1.time }
            // Runs of one group, and where each next run begins.
            var runs: [(group: String, start: TimeInterval)] = []
            var previous: Vote?
            for vote in seen {
                if let last = previous, last.group != vote.group {
                    runs.append((vote.group!, (last.time + vote.time) / 2))
                } else if previous == nil {
                    runs.append((vote.group!, -.infinity))
                }
                previous = vote
            }
            guard runs.count > 1 else {
                out.append(track)
                if let only = runs.first { groups[track.id] = only.group }
                continue
            }
            for (index, run) in runs.enumerated() {
                let end = index + 1 < runs.count ? runs[index + 1].start : .infinity
                let keyframes = track.keyframes.filter { $0.time >= run.start && $0.time < end }
                guard !keyframes.isEmpty else { continue }
                let id = index == 0 ? track.id : nextID
                if index > 0 { nextID += 1 }
                out.append(Track(id: id, keyframes: keyframes, embedding: track.embedding))
                groups[id] = run.group
            }
        }
        return (out, groups)
    }

    /// The people: tracks sharing a group are one person; a track without
    /// a group is one alone. Numbered by first appearance, then by where
    /// they first stood, left to right — then by track, which is fixed.
    static func people(_ tracks: [Track], groups: [Int: String]) -> [VideoPerson] {
        var members: [String: [Track]] = [:]
        for track in tracks where !track.keyframes.isEmpty {
            members[groups[track.id] ?? "track-\(track.id)", default: []].append(track)
        }
        let people = members.values.map { group -> (start: TrackedBox, tracks: [Track]) in
            let sorted = group.sorted { first($0) < first($1) }
            return (sorted[0].keyframes[0], sorted)
        }
        .sorted { a, b in
            if a.start.time != b.start.time { return a.start.time < b.start.time }
            if a.start.x != b.start.x { return a.start.x < b.start.x }
            return a.tracks[0].id < b.tracks[0].id
        }
        return people.enumerated().map { index, person in
            VideoPerson(
                number: index + 1,
                from: person.start.time,
                to: person.tracks.map { $0.keyframes.last!.time }.max()!,
                seconds: person.tracks.reduce(0) { $0 + $1.keyframes.last!.time - $1.keyframes[0].time },
                appearances: person.tracks.count,
                tracks: person.tracks.map(\.id).sorted())
        }
    }

    /// When a track starts: its first sample's time, then its id.
    private static func first(_ track: Track) -> (TimeInterval, Int) {
        (track.keyframes[0].time, track.id)
    }

    /// The tracks a selection covers, by person number and reference match.
    ///
    /// - Throws: ``CensorError/usage(_:)`` for a number the video has no
    ///   person for — a typo would otherwise cover, or spare, nobody.
    static func covered(_ tracks: [Track], people: [VideoPerson], selection: FaceSelection) throws -> [Track] {
        let named = selection.onlyNumbers.union(selection.skipNumbers)
        if let missing = named.sorted().first(where: { $0 > people.count }) {
            throw CensorError.usage(
                "person \(missing): the video has \(people.count) — see the numbers --outline draws")
        }
        var numberOf: [Int: Int] = [:]
        for person in people { for track in person.tracks { numberOf[track] = person.number } }
        return tracks.filter { track in
            guard let number = numberOf[track.id] else { return true }
            return selection.shouldCover(number: number, embedding: track.embedding)
        }
    }
}
