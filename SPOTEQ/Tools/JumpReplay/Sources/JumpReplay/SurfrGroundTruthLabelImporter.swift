//
//  SurfrGroundTruthLabelImporter.swift
//  JumpReplay
//
//  Loads Surfr/WOO jump labels (the "ground truth" a real session was scored
//  against) from a JSON file, so the evaluation harness can measure v10/v11
//  against them by timestamp rather than by raw count.
//
//  JSON shape:
//    {
//      "log": "...", "sensorOnly": true,
//      "jumps": [ { "id": 1, "elapsedSec": 1078, "height": 1.26,
//                   "airtime": 2.11, "distance": 13 }, ... ]
//    }
//

import Foundation

struct SurfrLabel {
    let id: Int
    let elapsedSec: Double      // take-off time, seconds into the session
    let height: Double?         // metres
    let airtime: Double?        // seconds
    let distance: Double?       // metres (0 / nil when no GPS route)
}

struct SurfrGroundTruthLabels {
    let log: String?
    let sensorOnly: Bool
    let jumps: [SurfrLabel]
}

enum SurfrGroundTruthLabelImporter {

    /// Decoder-friendly mirror of the on-disk JSON.
    private struct File: Decodable {
        struct Jump: Decodable {
            let id: Int?
            let elapsedSec: Double?
            let time: Double?          // accepted alias for elapsedSec
            let height: Double?
            let airtime: Double?
            let distance: Double?
        }
        let log: String?
        let sensorOnly: Bool?
        let jumps: [Jump]
    }

    static func load(_ url: URL, timeOffsetSec: Double = 0) throws -> SurfrGroundTruthLabels {
        let data = try Data(contentsOf: url)
        let file = try JSONDecoder().decode(File.self, from: data)
        let jumps = file.jumps.enumerated().map { (i, j) -> SurfrLabel in
            SurfrLabel(
                id: j.id ?? (i + 1),
                elapsedSec: (j.elapsedSec ?? j.time ?? 0) + timeOffsetSec,
                height: j.height,
                airtime: j.airtime,
                distance: j.distance
            )
        }.sorted { $0.elapsedSec < $1.elapsedSec }
        return SurfrGroundTruthLabels(log: file.log, sensorOnly: file.sensorOnly ?? true, jumps: jumps)
    }
}
