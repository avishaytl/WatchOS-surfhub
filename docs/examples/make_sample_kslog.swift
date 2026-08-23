import Foundation

private struct Header: Codable {
    let app: String
    let format: String
    let version: Int
    let session: String
    let date: String
    let mode: String
    let devMode: Bool
    let sampleRateHz: Int
    let parameters: Parameters
    let columns: [String]
}

private struct Parameters: Codable {
    let minSpeed: Double
    let takeoffG: Double
    let landingG: Double
    let minAirtime: Double
    let maxAirtime: Double
    let cooldown: Double
}

private enum State: UInt8 {
    case idle = 0
    case riding = 1
    case airborne = 2
    case cooldown = 3
}

private let columns = "idx,t,ax,ay,az,aM,gx,gy,gz,gM,gvX,gvY,gvZ,baro,baseBaro,spd,lowG,state,evt"
private let outDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
let binaryURL = outDir.appendingPathComponent("sample-session.kslog")
let hexURL = outDir.appendingPathComponent("sample-session.kslog.hex")
let previewURL = outDir.appendingPathComponent("sample-session.kslog.preview.txt")

private func makeHeader() -> Data {
    let header = Header(
        app: "SPOTEQ",
        format: "kslog",
        version: 1,
        session: "sample-session-0001",
        date: "20260613_120000",
        mode: "Standard",
        devMode: false,
        sampleRateHz: 50,
        parameters: Parameters(
            minSpeed: 15.0 / 3.6,
            takeoffG: 1.5,
            landingG: 2.0,
            minAirtime: 0.5,
            maxAirtime: 8.0,
            cooldown: 1.5
        ),
        columns: columns.components(separatedBy: ",")
    )
    let encoder = JSONEncoder()
    if #available(macOS 10.13, *) {
        encoder.outputFormatting = [.sortedKeys]
    }
    let json = (try? encoder.encode(header)) ?? Data()

    var data = Data()
    data.append(contentsOf: "KSLG".utf8)
    data.append(1)
    data.append(0)
    data.appendUInt16(UInt16(clamping: json.count))
    data.append(json.prefix(Int(UInt16.max)))
    return data
}

private func makeEvent(
    index: UInt32,
    tMs: UInt32,
    speed: Double,
    state: State,
    event: String
) -> Data {
    let eventData = Data(event.utf8.prefix(Int(UInt16.max)))
    var data = Data()
    data.append(2)
    data.appendUInt32(index)
    data.appendUInt32(tMs)
    data.appendUInt16(scaledUInt16(speed, scale: 100))
    data.append(state.rawValue)
    data.appendUInt16(UInt16(eventData.count))
    data.append(eventData)
    return data
}

private func makeSample(
    index: UInt32,
    tMs: UInt32,
    ax: Double,
    ay: Double,
    az: Double,
    aM: Double,
    gx: Double,
    gy: Double,
    gz: Double,
    gM: Double,
    gvX: Double,
    gvY: Double,
    gvZ: Double,
    baro: Double?,
    baseBaro: Double?,
    speed: Double,
    lowG: UInt16,
    state: State,
    event: String = ""
) -> Data {
    let eventData = Data(event.utf8.prefix(Int(UInt16.max)))
    var data = Data()
    data.append(1)
    data.appendUInt32(index)
    data.appendUInt32(tMs)
    data.appendInt16(scaledInt16(ax, scale: 1000))
    data.appendInt16(scaledInt16(ay, scale: 1000))
    data.appendInt16(scaledInt16(az, scale: 1000))
    data.appendInt16(scaledInt16(aM, scale: 1000))
    data.appendInt16(scaledInt16(gx, scale: 1000))
    data.appendInt16(scaledInt16(gy, scale: 1000))
    data.appendInt16(scaledInt16(gz, scale: 1000))
    data.appendInt16(scaledInt16(gM, scale: 1000))
    data.appendInt16(scaledInt16(gvX, scale: 1000))
    data.appendInt16(scaledInt16(gvY, scale: 1000))
    data.appendInt16(scaledInt16(gvZ, scale: 1000))
    data.appendInt32(scaledInt32(baro, scale: 100))
    data.appendInt32(scaledInt32(baseBaro, scale: 100))
    data.appendUInt16(scaledUInt16(speed, scale: 100))
    data.appendUInt16(lowG)
    data.append(state.rawValue)
    data.appendUInt16(UInt16(eventData.count))
    data.append(eventData)
    return data
}

var log = makeHeader()
log.append(makeEvent(index: 1, tMs: 0, speed: 0, state: .idle, event: "state->IDLE"))
log.append(makeSample(
    index: 2, tMs: 200,
    ax: 0.015, ay: -0.010, az: 0.020, aM: 0.027,
    gx: 0.020, gy: 0.010, gz: 0.000, gM: 0.022,
    gvX: 0.000, gvY: 0.000, gvZ: -1.000,
    baro: 1013.24, baseBaro: 1013.24,
    speed: 0.0, lowG: 0, state: .idle
))
log.append(makeEvent(index: 3, tMs: 1200, speed: 5.20, state: .riding, event: "state->RIDING"))
log.append(makeSample(
    index: 4, tMs: 1220,
    ax: 1.820, ay: 0.080, az: 0.420, aM: 1.870,
    gx: 2.450, gy: 1.110, gz: 0.620, gM: 2.760,
    gvX: 0.010, gvY: -0.040, gvZ: -0.999,
    baro: 1013.20, baseBaro: 1013.24,
    speed: 5.20, lowG: 0, state: .riding, event: "release"
))
log.append(makeEvent(index: 5, tMs: 1300, speed: 5.40, state: .airborne, event: "state->AIRBORNE"))
log.append(makeSample(
    index: 6, tMs: 1800,
    ax: 0.210, ay: -0.040, az: 0.120, aM: 0.250,
    gx: 4.200, gy: 1.800, gz: 0.900, gM: 4.650,
    gvX: 0.020, gvY: -0.030, gvZ: -0.999,
    baro: 1013.09, baseBaro: 1013.24,
    speed: 5.40, lowG: 0, state: .airborne
))
log.append(makeSample(
    index: 7, tMs: 3220,
    ax: 2.150, ay: 0.150, az: 0.610, aM: 2.240,
    gx: 1.200, gy: 0.400, gz: 0.200, gM: 1.280,
    gvX: 0.010, gvY: -0.020, gvZ: -0.999,
    baro: 1013.22, baseBaro: 1013.24,
    speed: 5.10, lowG: 0, state: .airborne, event: "land"
))
log.append(makeEvent(
    index: 8,
    tMs: 3600,
    speed: 5.10,
    state: .cooldown,
    event: "JUMP ACCEPTED h=1.3m air=1.9s rot=0 conf=0.74 src=kinematic land=hardImpact"
))

try log.write(to: binaryURL, options: .atomic)
try makeHexDump(log).write(to: hexURL, atomically: true, encoding: .utf8)
try makePreviewText().write(to: previewURL, atomically: true, encoding: .utf8)

private func scaledInt16(_ value: Double?, scale: Double) -> Int16 {
    guard let value, value.isFinite else { return Int16.min }
    return Int16(clamping: Int((value * scale).rounded()))
}

private func scaledInt32(_ value: Double?, scale: Double) -> Int32 {
    guard let value, value.isFinite else { return Int32.min }
    return Int32(clamping: Int((value * scale).rounded()))
}

private func scaledUInt16(_ value: Double, scale: Double) -> UInt16 {
    guard value.isFinite else { return 0 }
    return UInt16(clamping: max(0, Int((value * scale).rounded())))
}

private func makeHexDump(_ data: Data) -> String {
    let bytes = [UInt8](data)
    var lines: [String] = []
    var offset = 0
    while offset < bytes.count {
        let chunk = bytes[offset..<min(offset + 16, bytes.count)]
        let hex = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
        let paddedHex = hex.padding(toLength: 16 * 3 - 1, withPad: " ", startingAt: 0)
        let ascii = chunk.map { byte -> String in
            (byte >= 32 && byte <= 126) ? String(UnicodeScalar(byte)) : "."
        }.joined()
        lines.append(String(format: "%08x  %@  |%@|", offset, paddedHex, ascii))
        offset += 16
    }
    return lines.joined(separator: "\n") + "\n"
}

private func makePreviewText() -> String {
    """
    SPOTEQ Session Log
    File: sample-session.kslog
    Size: \(log.count) bytes
    Format: binary kslog v1
    session: sample-session-0001
    date: 20260613_120000
    mode: Standard
    devMode: false
    sampleRate: 50 Hz
    minSpeed(m/s): 4.17
    takeoffG(g): 1.50
    landingG(g): 2.00
    minAirtime(s): 0.50
    maxAirtime(s): 8.00
    cooldown(s): 1.50

    CSV preview decoded from binary:
    \(columns)
    1,0.000,,,,,,,,,,,,,,0.00,,idle,state->IDLE
    2,0.200,0.015,-0.010,0.020,0.027,0.020,0.010,0.000,0.022,0.000,0.000,-1.000,1013.24,1013.24,0.00,0,idle,
    3,1.200,,,,,,,,,,,,,,5.20,,riding,state->RIDING
    4,1.220,1.820,0.080,0.420,1.870,2.450,1.110,0.620,2.760,0.010,-0.040,-0.999,1013.20,1013.24,5.20,0,riding,release
    5,1.300,,,,,,,,,,,,,,5.40,,airborne,state->AIRBORNE
    6,1.800,0.210,-0.040,0.120,0.250,4.200,1.800,0.900,4.650,0.020,-0.030,-0.999,1013.09,1013.24,5.40,0,airborne,
    7,3.220,2.150,0.150,0.610,2.240,1.200,0.400,0.200,1.280,0.010,-0.020,-0.999,1013.22,1013.24,5.10,0,airborne,land
    8,3.600,,,,,,,,,,,,,,5.10,,cooldown,JUMP ACCEPTED h=1.3m air=1.9s rot=0 conf=0.74 src=kinematic land=hardImpact
    """
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendUInt32(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendInt16(_ value: Int16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendInt32(_ value: Int32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
