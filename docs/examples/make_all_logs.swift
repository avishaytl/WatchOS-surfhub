// make_all_logs.swift
//
// Generates ONE real example of every artifact the Kiters app produces / sends,
// using the EXACT field layout from the production code, with realistic mock data.
//
//   1. kiters_session.kslog            — binary session log (.kslog, the file itself)
//   2. kiters_session.preview.txt      — decoded CSV preview (what "Share" emits)
//   3. kiters_session.kslog.hex        — hex dump of the binary header + first records
//   4. kiters_cloud_upload.json        — exact CloudLogPayload POST body (kslog as base64)
//   5. kiters_cloud_upload.http        — the full HTTP request (URL + headers + body ref)
//   6. kiters_jumpreplay_report.json   — JumpReplay analysis report (ReplayReport)
//
// Run:  swift docs/examples/make_all_logs.swift
//
// All binary encoding mirrors SessionLogger.swift (little-endian, scaled integers).

import Foundation

// ──────────────────────────────────────────────────────────────────────────
// MARK: Output location
// ──────────────────────────────────────────────────────────────────────────

let outDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("generated", isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let kslogURL    = outDir.appendingPathComponent("kiters_session.kslog")
let previewURL  = outDir.appendingPathComponent("kiters_session.preview.txt")
let hexURL      = outDir.appendingPathComponent("kiters_session.kslog.hex")
let cloudURL    = outDir.appendingPathComponent("kiters_cloud_upload.json")
let httpURL     = outDir.appendingPathComponent("kiters_cloud_upload.http")
let replayURL   = outDir.appendingPathComponent("kiters_jumpreplay_report.json")

// ──────────────────────────────────────────────────────────────────────────
// MARK: Session identity (mock but realistically shaped)
// ──────────────────────────────────────────────────────────────────────────

let sessionId   = "F4A2C0D1-3B7E-4A9C-9E21-5C8D0E6F1A22"   // UUID, as SessionManager produces
let dateStr     = "20260615_143052"                         // yyyyMMdd_HHmmss
let filename    = "log_\(dateStr)_\(sessionId.prefix(8)).kslog"  // = log_20260615_F4A2C0D1.kslog
let appVersion  = "1.0"
let build       = "42"
let deviceId    = "watch"

// Standard-mode parameters (production defaults from JumpDetectionConfig)
let pMinSpeed   = 15.0 / 3.6   // 4.1667 m/s
let pTakeoffG   = 1.5
let pLandingG   = 2.0
let pMinAirtime = 0.5
let pMaxAirtime = 8.0
let pCooldown   = 1.5

let columns = "idx,t,ax,ay,az,aM,gx,gy,gz,gM,gvX,gvY,gvZ,baro,baseBaro,spd,lowG,state,evt"

// ──────────────────────────────────────────────────────────────────────────
// MARK: Binary encoders (mirror SessionLogger.swift exactly)
// ──────────────────────────────────────────────────────────────────────────

enum St: UInt8 { case idle = 0, riding = 1, airborne = 2, cooldown = 3 }

func scaledInt16(_ v: Double?, _ scale: Double) -> Int16 {
    guard let v, v.isFinite else { return Int16.min }
    return Int16(clamping: Int((v * scale).rounded()))
}
func scaledInt32(_ v: Double?, _ scale: Double) -> Int32 {
    guard let v, v.isFinite else { return Int32.min }
    return Int32(clamping: Int((v * scale).rounded()))
}
func scaledUInt16(_ v: Double, _ scale: Double) -> UInt16 {
    guard v.isFinite else { return 0 }
    return UInt16(clamping: max(0, Int((v * scale).rounded())))
}

extension Data {
    mutating func u16(_ v: UInt16) { var le = v.littleEndian; Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { var le = v.littleEndian; Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) } }
    mutating func i16(_ v: Int16)  { var le = v.littleEndian; Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) } }
    mutating func i32(_ v: Int32)  { var le = v.littleEndian; Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) } }
}

struct Header: Codable {
    let app: String; let format: String; let version: Int
    let session: String; let date: String; let mode: String
    let devMode: Bool; let sampleRateHz: Int
    let parameters: Params; let columns: [String]
    struct Params: Codable {
        let minSpeed, takeoffG, landingG, minAirtime, maxAirtime, cooldown: Double
    }
}

func makeHeader() -> Data {
    let h = Header(
        app: "Kiters", format: "kslog", version: 1,
        session: sessionId, date: dateStr, mode: "Standard",
        devMode: false, sampleRateHz: 50,
        parameters: .init(minSpeed: pMinSpeed, takeoffG: pTakeoffG, landingG: pLandingG,
                          minAirtime: pMinAirtime, maxAirtime: pMaxAirtime, cooldown: pCooldown),
        columns: columns.components(separatedBy: ",")
    )
    let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
    let json = (try? enc.encode(h)) ?? Data()
    var d = Data()
    d.append(contentsOf: "KSLG".utf8)   // magic
    d.append(1)                          // version
    d.append(0)                          // reserved
    d.u16(UInt16(clamping: json.count))  // header length
    d.append(json.prefix(Int(UInt16.max)))
    return d
}

func sampleRecord(idx: UInt32, tMs: UInt32,
                  ax: Double, ay: Double, az: Double, aM: Double,
                  gx: Double, gy: Double, gz: Double, gM: Double,
                  gvX: Double, gvY: Double, gvZ: Double,
                  baro: Double?, baseBaro: Double?,
                  speed: Double, lowG: UInt16, state: St, event: String = "") -> Data {
    let ev = Data(event.utf8.prefix(Int(UInt16.max)))
    var d = Data()
    d.append(1)                              // RecordType.sample
    d.u32(idx); d.u32(tMs)
    d.i16(scaledInt16(ax, 1000)); d.i16(scaledInt16(ay, 1000))
    d.i16(scaledInt16(az, 1000)); d.i16(scaledInt16(aM, 1000))
    d.i16(scaledInt16(gx, 1000)); d.i16(scaledInt16(gy, 1000))
    d.i16(scaledInt16(gz, 1000)); d.i16(scaledInt16(gM, 1000))
    d.i16(scaledInt16(gvX, 1000)); d.i16(scaledInt16(gvY, 1000)); d.i16(scaledInt16(gvZ, 1000))
    d.i32(scaledInt32(baro, 100)); d.i32(scaledInt32(baseBaro, 100))
    d.u16(scaledUInt16(speed, 100)); d.u16(lowG)
    d.append(state.rawValue)
    d.u16(UInt16(ev.count)); d.append(ev)
    return d
}

func eventRecord(idx: UInt32, tMs: UInt32, speed: Double, state: St, event: String) -> Data {
    let ev = Data(event.utf8.prefix(Int(UInt16.max)))
    var d = Data()
    d.append(2)                              // RecordType.event
    d.u32(idx); d.u32(tMs)
    d.u16(scaledUInt16(speed, 100))
    d.append(state.rawValue)
    d.u16(UInt16(ev.count)); d.append(ev)
    return d
}

// ──────────────────────────────────────────────────────────────────────────
// MARK: Procedural realistic session @ 50 Hz
//   IDLE → RIDING → JUMP#1 (1.4s, ~1.3m) → cooldown → RIDING
//        → JUMP#2 (1.9s, ~3.5m) → cooldown → RIDING → IDLE (stop)
// ──────────────────────────────────────────────────────────────────────────

let dt = 0.02                  // 50 Hz
let baseBaro = 1013.25         // sea-level-ish baseline (hPa)
let baroPerMeter = 0.1186      // hPa drop per metre of altitude
var rng = SystemRandomNumberGenerator()
func noise(_ a: Double) -> Double { Double.random(in: -a...a, using: &rng) }

var log = makeHeader()
var idx: UInt32 = 0
var csv: [String] = []         // for the decoded preview

func emitSample(t: Double, ax: Double, ay: Double, az: Double,
                gx: Double, gy: Double, gz: Double,
                baroAbs: Double, speed: Double, lowG: UInt16, state: St, event: String = "") {
    idx += 1
    let aM = (ax*ax + ay*ay + az*az).squareRoot()
    let gM = (gx*gx + gy*gy + gz*gz).squareRoot()
    // gravity vector — roughly board-down with slight lean
    let gvX = 0.02 + noise(0.01), gvY = -0.03 + noise(0.01)
    let gvZ = -(1.0 - gvX*gvX - gvY*gvY).squareRoot()
    let tMs = UInt32((t * 1000).rounded())
    log.append(sampleRecord(idx: idx, tMs: tMs, ax: ax, ay: ay, az: az, aM: aM,
                            gx: gx, gy: gy, gz: gz, gM: gM,
                            gvX: gvX, gvY: gvY, gvZ: gvZ,
                            baro: baroAbs, baseBaro: baseBaro,
                            speed: speed, lowG: lowG, state: state, event: event))
    csv.append([
        "\(idx)", String(format: "%.3f", t),
        f(ax), f(ay), f(az), f(aM), f(gx), f(gy), f(gz), f(gM),
        f(gvX), f(gvY), f(gvZ),
        String(format: "%.2f", baroAbs), String(format: "%.2f", baseBaro),
        String(format: "%.2f", speed), "\(lowG)", stateName(state), san(event)
    ].joined(separator: ","))
}

func emitEvent(t: Double, speed: Double, state: St, event: String) {
    idx += 1
    let tMs = UInt32((t * 1000).rounded())
    log.append(eventRecord(idx: idx, tMs: tMs, speed: speed, state: state, event: event))
    csv.append("\(idx),\(String(format: "%.3f", t)),,,,,,,,,,,,,,\(String(format: "%.2f", speed)),,\(stateName(state)),\(san(event))")
}

func f(_ v: Double) -> String { String(format: "%.3f", v) }
func san(_ s: String) -> String { s.replacingOccurrences(of: ",", with: ";") }
func stateName(_ s: St) -> String {
    switch s { case .idle: return "idle"; case .riding: return "riding"
               case .airborne: return "airborne"; case .cooldown: return "cooldown" }
}

var t = 0.0

// Reset event (matches JumpDetector v7 Log.event on start)
emitEvent(t: t, speed: 0, state: .idle,
          event: "JumpDetector(v7) reset — Standard minSpd=15km/h tkoff=1.5g land=2.0g air=0.5-8.0s cd=1.5s")

// Phase 1: IDLE, speed ramps 0 → 4.5 m/s (3.0 s)
while t < 3.0 {
    let spd = (t / 3.0) * 4.5
    emitSample(t: t, ax: noise(0.05), ay: noise(0.05), az: 1.0 + noise(0.05),
               gx: noise(0.2), gy: noise(0.2), gz: noise(0.1),
               baroAbs: baseBaro + noise(0.02), speed: spd, lowG: 0, state: .idle)
    t += dt
}
emitEvent(t: t, speed: 4.6, state: .riding, event: "IDLE→RIDING (spd=16.6km/h)")

// Phase 2: RIDING cruise ~8.5 m/s (5.0 s of chop)
while t < 8.0 {
    let spd = 8.5 + noise(0.4)
    emitSample(t: t, ax: noise(0.4), ay: noise(0.3), az: 1.0 + noise(0.5),
               gx: noise(1.2), gy: noise(0.9), gz: noise(0.6),
               baroAbs: baseBaro + noise(0.04), speed: spd, lowG: 0, state: .riding)
    t += dt
}

// ── JUMP #1 : takeoff @ 8.00s, airtime 1.40s, height ~1.30m ──
func jumpArc(start: Double, airtime: Double, height: Double, peakLandG: Double,
             rotation: Double, jumpIdx: Int, distance: Double, confidence: Double) {
    // Takeoff spike (2 samples ≥ takeoffG), lowG ramps
    emitSample(t: t, ax: 0.6, ay: 0.3, az: 2.0, gx: 2.4, gy: 1.1, gz: 0.6,
               baroAbs: baseBaro, speed: 8.6, lowG: 1, state: .riding, event: "takeoff spike aM=2.18g")
    t += dt
    emitSample(t: t, ax: 0.4, ay: 0.2, az: 1.9, gx: 2.6, gy: 1.2, gz: 0.7,
               baroAbs: baseBaro - 0.02, speed: 8.6, lowG: 2, state: .riding)
    t += dt
    emitEvent(t: t, speed: 8.6, state: .airborne, event: "RIDING→AIRBORNE (lowG×3)")

    let end = start + airtime
    while t < end {
        let phase = (t - start) / airtime          // 0..1
        let alt = 4 * height * phase * (1 - phase)  // parabolic arc, apex at mid
        let lowG = UInt16(2 + Int(6 * (1 - abs(0.5 - phase) * 2)))   // lowest-g near apex
        emitSample(t: t,
                   ax: noise(0.15), ay: noise(0.15), az: 0.25 + noise(0.1),
                   gx: rotation * 6 + noise(0.5), gy: noise(0.6), gz: noise(0.4),
                   baroAbs: baseBaro - alt * baroPerMeter, speed: 8.4 + noise(0.2),
                   lowG: lowG, state: .airborne)
        t += dt
    }
    // Landing impact ≥ landingG
    emitSample(t: t, ax: 0.9, ay: 0.5, az: peakLandG, gx: 1.2, gy: 0.4, gz: 0.2,
               baroAbs: baseBaro - 0.02, speed: 8.0, lowG: 0, state: .airborne, event: "landing impact")
    t += dt
    emitEvent(t: t, speed: 8.0, state: .cooldown,
              event: "JUMP #\(jumpIdx) ACCEPTED air=\(String(format:"%.2f",airtime))s h=\(String(format:"%.2f",height))m rot=\(Int(rotation)) dist=\(String(format:"%.1f",distance))m conf=\(String(format:"%.1f",confidence)) src=kinematic")
    // Cooldown window (1.5 s)
    let cdEnd = t + pCooldown
    while t < cdEnd {
        emitSample(t: t, ax: noise(0.3), ay: noise(0.3), az: 1.0 + noise(0.3),
                   gx: noise(0.8), gy: noise(0.6), gz: noise(0.4),
                   baroAbs: baseBaro + noise(0.03), speed: 7.8 + noise(0.3),
                   lowG: 0, state: .cooldown)
        t += dt
    }
    emitEvent(t: t, speed: 8.2, state: .riding, event: "COOLDOWN→RIDING")
}

jumpArc(start: 8.0 + 3*dt, airtime: 1.40, height: 1.30, peakLandG: 2.6,
        rotation: 0, jumpIdx: 1, distance: 9.4, confidence: 74.0)

// Phase 3: RIDING between jumps (~4 s)
let mid = t + 4.0
while t < mid {
    let spd = 9.0 + noise(0.5)
    emitSample(t: t, ax: noise(0.4), ay: noise(0.3), az: 1.0 + noise(0.5),
               gx: noise(1.3), gy: noise(1.0), gz: noise(0.6),
               baroAbs: baseBaro + noise(0.04), speed: spd, lowG: 0, state: .riding)
    t += dt
}

// ── JUMP #2 : bigger, airtime 1.90s, height ~3.50m, half rotation ──
jumpArc(start: t + 3*dt, airtime: 1.90, height: 3.50, peakLandG: 2.9,
        rotation: 1, jumpIdx: 2, distance: 18.7, confidence: 88.0)

// Phase 4: RIDING wind-down then stop (~3 s)
let endRide = t + 3.0
while t < endRide {
    let spd = max(0, 7.0 - (t - (endRide - 3.0)) * 2.3) + noise(0.3)
    emitSample(t: t, ax: noise(0.3), ay: noise(0.3), az: 1.0 + noise(0.3),
               gx: noise(0.9), gy: noise(0.7), gz: noise(0.4),
               baroAbs: baseBaro + noise(0.03), speed: spd, lowG: 0,
               state: spd >= pMinSpeed ? .riding : .idle)
    t += dt
}
emitEvent(t: t, speed: 1.2, state: .idle, event: "RIDING→IDLE (spd<minSpeed)")
emitEvent(t: t, speed: 0, state: .idle, event: "session stopped (2 jumps, \(idx) records)")

// ──────────────────────────────────────────────────────────────────────────
// MARK: Write artifact 1 — the .kslog binary
// ──────────────────────────────────────────────────────────────────────────

try log.write(to: kslogURL, options: .atomic)
let sizeBytes = log.count

// ──────────────────────────────────────────────────────────────────────────
// MARK: Write artifact 2 — decoded CSV preview (what "Share" emits)
// ──────────────────────────────────────────────────────────────────────────

var preview = """
Kiters Session Log
File: \(filename)
Size: \(byteString(sizeBytes))
Format: binary kslog v1
session: \(sessionId)
date: \(dateStr)
mode: Standard
devMode: false
sampleRate: 50 Hz
minSpeed(m/s): \(String(format: "%.2f", pMinSpeed))
takeoffG(g): \(String(format: "%.2f", pTakeoffG))
landingG(g): \(String(format: "%.2f", pLandingG))
minAirtime(s): \(String(format: "%.2f", pMinAirtime))
maxAirtime(s): \(String(format: "%.2f", pMaxAirtime))
cooldown(s): \(String(format: "%.2f", pCooldown))

CSV preview decoded from binary:
\(columns)

"""
// Show first 40 + an ellipsis + the event-bearing rows so it stays readable.
let head = csv.prefix(40)
preview += head.joined(separator: "\n")
preview += "\n... (\(csv.count - head.count) more rows — full data in the .kslog file)\n\nEvent rows in this session:\n"
preview += csv.filter { line in
    let parts = line.split(separator: ",", omittingEmptySubsequences: false)
    return parts.count >= 19 && !parts[18].isEmpty
}.joined(separator: "\n")
preview += "\n"
try preview.write(to: previewURL, atomically: true, encoding: .utf8)

// ──────────────────────────────────────────────────────────────────────────
// MARK: Write artifact 3 — hex dump (header + first ~7 records)
// ──────────────────────────────────────────────────────────────────────────

let hexBytes = [UInt8](log.prefix(512))
var hexLines: [String] = []
var off = 0
while off < hexBytes.count {
    let chunk = hexBytes[off..<min(off + 16, hexBytes.count)]
    let hex = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
        .padding(toLength: 16 * 3 - 1, withPad: " ", startingAt: 0)
    let ascii = chunk.map { (32...126).contains($0) ? String(UnicodeScalar($0)) : "." }.joined()
    hexLines.append(String(format: "%08x  %@  |%@|", off, hex, ascii))
    off += 16
}
try (hexLines.joined(separator: "\n") + "\n... (\(sizeBytes - 512) more bytes)\n")
    .write(to: hexURL, atomically: true, encoding: .utf8)

// ──────────────────────────────────────────────────────────────────────────
// MARK: Write artifact 4 — Cloud upload payload (CloudLogPayload, the POST body)
// ──────────────────────────────────────────────────────────────────────────

struct CloudLogPayload: Encodable {
    let type, filename, contentType: String
    let contentEncoding: String?
    let appVersion, build: String?
    let uploadedAt: String
    let content: String
}
let base64 = log.base64EncodedString()
let payload = CloudLogPayload(
    type: "session_log",
    filename: filename,
    contentType: "application/x-kiters-session-log",
    contentEncoding: "base64",
    appVersion: appVersion,
    build: build,
    uploadedAt: "2026-06-15T14:35:10Z",
    content: base64
)
let penc = JSONEncoder(); penc.outputFormatting = [.prettyPrinted, .sortedKeys]
try penc.encode(payload).write(to: cloudURL, options: .atomic)

// ──────────────────────────────────────────────────────────────────────────
// MARK: Write artifact 5 — full HTTP request (URL + headers)
// ──────────────────────────────────────────────────────────────────────────

let http = """
POST /functions/v1/calib-log?device=\(deviceId)&session=\(filename.replacingOccurrences(of: ".kslog", with: "")) HTTP/1.1
Host: vvowvcdylztsqpzifdqc.supabase.co
Content-Type: application/json
Accept: */*
X-Calib-Token: ywxC26KVA7WD-_HftsCiCBb6W5bxkFzGT-Xe1Z4FvC4

<body = kiters_cloud_upload.json — the CloudLogPayload above>

# Expected 2xx response shape (CloudLogUploadResponse):
# { "id": "9f3...", "status": "uploaded", "ok": true, "path": "logs/watch/\(filename)" }
"""
try http.write(to: httpURL, atomically: true, encoding: .utf8)

// ──────────────────────────────────────────────────────────────────────────
// MARK: Write artifact 6 — JumpReplay analysis report (ReplayReport)
// ──────────────────────────────────────────────────────────────────────────

struct ReplayJump: Codable {
    let index: Int; let takeoffOffsetSec, airtime: Double
    let physicalAirtime: Double?; let height: Double; let heightSource: String
    let apexTime: Double?; let confidence: Double; let rotations: Int
    let jumpDistance: Double; let accepted: Bool
}
struct ReplayReport: Codable {
    let file, format: String; let detectedRateHz: Double
    let sampleCount: Int; let durationSec, mockSpeedMps: Double
    let detectionMode: String; let jumps: [ReplayJump]
}
let report = ReplayReport(
    file: filename, format: "kslog",
    detectedRateHz: 49.999999996820875,
    sampleCount: Int(idx),
    durationSec: t,
    mockSpeedMps: 8.5,
    detectionMode: "standard",
    jumps: [
        ReplayJump(index: 0, takeoffOffsetSec: 8.04, airtime: 1.40, physicalAirtime: 1.46,
                   height: 1.30, heightSource: "kin", apexTime: 0.70, confidence: 74.0,
                   rotations: 0, jumpDistance: 9.4, accepted: true),
        ReplayJump(index: 1, takeoffOffsetSec: 16.34, airtime: 1.90, physicalAirtime: 1.98,
                   height: 3.50, heightSource: "baro", apexTime: 0.95, confidence: 88.0,
                   rotations: 1, jumpDistance: 18.7, accepted: true),
    ]
)
let renc = JSONEncoder(); renc.outputFormatting = [.prettyPrinted, .sortedKeys]
try renc.encode(report).write(to: replayURL, options: .atomic)

// ──────────────────────────────────────────────────────────────────────────

func byteString(_ n: Int) -> String {
    if n < 1024 { return "\(n) B" }
    return String(format: "%.1f KB", Double(n) / 1024)
}

print("✅ Generated \(idx) records, \(byteString(sizeBytes)) binary")
print("   1. \(kslogURL.lastPathComponent)        (\(byteString(sizeBytes)))")
print("   2. \(previewURL.lastPathComponent)")
print("   3. \(hexURL.lastPathComponent)")
print("   4. \(cloudURL.lastPathComponent)   (base64 payload)")
print("   5. \(httpURL.lastPathComponent)")
print("   6. \(replayURL.lastPathComponent)")
