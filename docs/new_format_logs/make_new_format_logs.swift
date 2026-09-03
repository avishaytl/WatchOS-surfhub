// make_new_format_logs.swift
//
// Generates one real BINARY example of every log the watch sends to the server,
// using the production codec (BinaryLogEnvelope.swift). For each log it writes:
//   <name>.klog          — the exact binary bytes sent over the wire (KLOG)
//   <name>.decoded.json  — the same payload decoded back, to prove the schema/fields
//   <name>.hex           — hex dump of the binary
//
// Logs covered:
//   1. diagnostic_session_log      → CloudSyncService.uploadLog  (wraps raw .kslog)
//   2. watch_ingest_start          → WatchSessionUploader.start
//   3. watch_ingest_ping           → WatchSessionUploader.ping
//   4. watch_ingest_record         → WatchSessionUploader.record
//   5. watch_ingest_end            → WatchSessionUploader.end
//
// Build & run:
//   swiftc "SPOTEQ/SPOTEQ Watch App/Services/BinaryLogEnvelope.swift" \
//          new_format_logs/make_new_format_logs.swift -o /tmp/gen && /tmp/gen

import Foundation

@main
struct Generator {
    static func main() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

        // Reuse the realistic .kslog produced earlier as the diagnostic payload.
        // Fall back to a tiny synthetic kslog if it isn't present.
        let kslogPath = root.deletingLastPathComponent()
            .appendingPathComponent("examples/generated/spoteq_session.kslog")
        let kslogData = (try? Data(contentsOf: kslogPath))
            ?? Data([0x4B, 0x53, 0x4C, 0x47, 0x01, 0x00] + [UInt8](repeating: 0xAB, count: 32))

        let iso = "2026-06-15T14:35:10Z"

        // ── 1. Diagnostic session-log upload (CloudSyncService.uploadLog) ──
        let diagnostic = BinaryLogEnvelope(fields: [
            .string("type", "session_log"),
            .string("filename", "log_20260615_143052_F4A2C0D1.kslog"),
            .string("contentType", "application/x-spoteq-session-log"),
            .string("contentEncoding", "binary"),
            .string("appVersion", "1.0"),
            .string("build", "42"),
            .string("uploadedAt", iso),
            .blob("content", kslogData)
        ]).encoded()

        // ── 2. start (WatchSessionUploader.start) ──
        let start = BinaryLogEnvelope.encode(object: [
            "type": "start",
            "lat": 32.835421,
            "lng": 34.967118,
            "startedAt": "2026-06-15T14:30:52Z"
        ])

        // ── 3. ping (WatchSessionUploader.ping) ──
        let ping = BinaryLogEnvelope.encode(object: [
            "type": "ping",
            "sessId": 8842,
            "lat": 32.836902,
            "lng": 34.965331,
            "jmax": 1.30,
            "jcnt": 1
        ])

        // ── 4. record (WatchSessionUploader.record) ──
        let record = BinaryLogEnvelope.encode(object: [
            "type": "record",
            "sessId": 8842,
            "jumpM": 3.50,
            "airS": 1.90,
            "speedKmh": 38.4,
            "distKm": 12.4
        ])

        // ── 5. end (WatchSessionUploader.end) ── (with nested track + jData)
        let end = BinaryLogEnvelope.encode(object: [
            "type": "end",
            "sessId": 8842,
            "durMin": 47,
            "jmax": 3.50,
            "jcnt": 2,
            "airS": 1.90,
            "spdKmh": 38,
            "distKm": 12.4,
            "stars": 4,
            "windKts": 18,
            "dir": "NW",
            "avgKmh": 24.6,
            // track = [[lat·1e4, lng·1e4], …] — same schema/units as the JSON contract.
            "track": [[328354, 349671], [328369, 349653], [328380, 349640]],
            // jData = one entry per jump: t sec, h cm, a tenths-sec, s km/h, d dm, y/x lat/lng·1e4.
            "jData": [
                ["t": 8, "h": 130, "a": 14, "s": 34, "d": 12, "y": 328354, "x": 349671],
                ["t": 16, "h": 350, "a": 19, "s": 41, "d": 18, "y": 328369, "x": 349653]
            ]
        ])

        let items: [(String, Data)] = [
            ("1_diagnostic_session_log", diagnostic),
            ("2_watch_ingest_start", start),
            ("3_watch_ingest_ping", ping),
            ("4_watch_ingest_record", record),
            ("5_watch_ingest_end", end),
        ]

        var readme = """
        # new_format_logs — binary (KLOG) examples

        Every log the watch sends to the server, encoded in the production binary
        format (`BinaryLogEnvelope`, magic `KLOG`). Same schema/fields as before —
        only the serialization is binary (no JSON, no CSV, no base64).

        | file | source | content-type on wire |
        |------|--------|----------------------|
        | `1_diagnostic_session_log.klog` | `CloudSyncService.uploadLog` | `application/octet-stream` |
        | `2_watch_ingest_start.klog`     | `WatchSessionUploader.start`  | `application/octet-stream` |
        | `3_watch_ingest_ping.klog`      | `WatchSessionUploader.ping`   | `application/octet-stream` |
        | `4_watch_ingest_record.klog`    | `WatchSessionUploader.record` | `application/octet-stream` |
        | `5_watch_ingest_end.klog`       | `WatchSessionUploader.end`    | `application/octet-stream` |

        For each `*.klog` there is a `*.decoded.json` (the bytes decoded back, proving
        the schema round-trips) and a `*.hex` dump.

        Regenerate:
        ```
        swiftc "SPOTEQ/SPOTEQ Watch App/Services/BinaryLogEnvelope.swift" \\
               new_format_logs/make_new_format_logs.swift -o /tmp/gen && /tmp/gen
        ```

        ## Sizes

        """

        for (name, data) in items {
            // binary
            try data.write(to: root.appendingPathComponent("\(name).klog"), options: .atomic)
            // decoded view
            let decoded = BinaryLogEnvelope.decodeToObject(data) ?? [:]
            let viewable = jsonViewable(decoded)
            let json = try JSONSerialization.data(withJSONObject: viewable,
                                                  options: [.prettyPrinted, .sortedKeys])
            try json.write(to: root.appendingPathComponent("\(name).decoded.json"), options: .atomic)
            // hex
            try hexDump(data.prefix(400), totalBytes: data.count)
                .write(to: root.appendingPathComponent("\(name).hex"),
                       atomically: true, encoding: .utf8)

            readme += "- `\(name).klog` — \(data.count) bytes\n"
            print("✅ \(name).klog  (\(data.count) bytes)")
        }

        try readme.write(to: root.appendingPathComponent("README.md"),
                         atomically: true, encoding: .utf8)
        print("📁 Wrote \(items.count) logs + decoded views + hex to new_format_logs/")
    }

    /// Replace raw `Data` blobs with a JSON-friendly descriptor for the decoded view.
    static func jsonViewable(_ value: Any) -> Any {
        switch value {
        case let d as Data:
            return [
                "_blob": true,
                "bytes": d.count,
                "head_hex": d.prefix(8).map { String(format: "%02x", $0) }.joined(),
                "note": "raw file embedded as-is on the wire (not base64)"
            ]
        case let dict as [String: Any]:
            return dict.mapValues { jsonViewable($0) }
        case let arr as [Any]:
            return arr.map { jsonViewable($0) }
        default:
            return value
        }
    }

    static func hexDump(_ data: Data, totalBytes: Int) -> String {
        let bytes = [UInt8](data)
        var lines: [String] = []
        var off = 0
        while off < bytes.count {
            let chunk = bytes[off..<min(off + 16, bytes.count)]
            let hex = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
                .padding(toLength: 16 * 3 - 1, withPad: " ", startingAt: 0)
            let ascii = chunk.map { (32...126).contains($0) ? String(UnicodeScalar($0)) : "." }.joined()
            lines.append(String(format: "%08x  %@  |%@|", off, hex, ascii))
            off += 16
        }
        var out = lines.joined(separator: "\n") + "\n"
        if totalBytes > bytes.count { out += "... (\(totalBytes - bytes.count) more bytes)\n" }
        return out
    }
}
