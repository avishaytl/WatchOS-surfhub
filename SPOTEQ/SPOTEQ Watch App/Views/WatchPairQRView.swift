import CoreGraphics
import Foundation
import SwiftUI
import WatchKit

struct WatchPairQRView: View {
    var onPaired: (String) -> Void

    @State private var request: WatchAuth.PairingRequest?
    @State private var phase: Phase = .loading
    @State private var loadTask: Task<Void, Never>?
    @State private var pollTask: Task<Void, Never>?

    enum Phase: Equatable {
        case loading
        case showing
        case expired
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 12) {
            switch phase {
            case .loading:
                ProgressView()
                    .padding(.top, 20)
                Text(L("account.pair_preparing"))
                    .font(.caption2)
                    .foregroundColor(.gray)

            case .showing:
                Text(L("account.pair_scan_title"))
                    .font(.headline)
                    .multilineTextAlignment(.center)

                qrImage

                Text(L("account.pair_scan_hint"))
                    .font(.caption2)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)

                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 2)

                Text(L("account.pair_waiting"))
                    .font(.caption2)
                    .foregroundColor(.gray)

            case .expired:
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.system(size: 30))
                    .foregroundColor(.gray)
                    .padding(.top, 16)
                Text(L("account.pair_expired"))
                    .font(.headline)
                Button(L("account.pair_new_code")) {
                    start()
                }
                .buttonStyle(.borderedProminent)

            case .failed(let message):
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 30))
                    .foregroundColor(.orange)
                    .padding(.top, 16)
                Text(message)
                    .font(.caption2)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                Button(L("account.try_again")) {
                    start()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .onAppear(perform: start)
        .onDisappear {
            loadTask?.cancel()
            pollTask?.cancel()
        }
    }

    private var qrImage: some View {
        Group {
            if let payload = request?.qrPayload, let image = Self.makeQRCode(payload) {
                Image(decorative: image, scale: 1, orientation: .up)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 132, height: 132)
                    .padding(8)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                ProgressView()
                    .frame(width: 132, height: 132)
            }
        }
    }

    @MainActor
    private func start() {
        loadTask?.cancel()
        pollTask?.cancel()
        request = nil
        phase = .loading

        loadTask = Task {
            do {
                let newRequest = try await WatchAuth.requestPairing(
                    deviceName: Self.deviceName(),
                    deviceModel: Self.deviceModel()
                )
                await MainActor.run {
                    request = newRequest
                    phase = .showing
                    beginPolling(code: newRequest.code, expiresAt: newRequest.expiresAt)
                }
            } catch {
                await MainActor.run {
                    phase = .failed(L("account.pair_start_failed"))
                }
            }
        }
    }

    @MainActor
    private func beginPolling(code: String, expiresAt: Date) {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                if Date() >= expiresAt {
                    await MainActor.run { phase = .expired }
                    return
                }

                switch await WatchAuth.pollPairing(code: code) {
                case .approved(let uid, _):
                    await MainActor.run { onPaired(uid) }
                    return
                case .expired:
                    await MainActor.run { phase = .expired }
                    return
                case .failed(let message):
                    await MainActor.run { phase = .failed(message) }
                    return
                case .pending:
                    break
                }

                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private static func makeQRCode(_ payload: String) -> CGImage? {
        WatchQRCode.makeImage(payload)
    }

    private static func deviceName() -> String? {
        WKInterfaceDevice.current().name
    }

    private static func deviceModel() -> String? {
        WKInterfaceDevice.current().model
    }
}

private enum WatchQRCode {
    private static let size = 29
    private static let dataCodewordCount = 44
    private static let eccCodewordCount = 26
    private static let maskPattern = 0

    static func makeImage(_ text: String, scale: Int = 5, quietZone: Int = 4) -> CGImage? {
        guard let modules = makeModules(text) else { return nil }
        let moduleCount = size + quietZone * 2
        let pixelCount = moduleCount * scale
        var pixels = [UInt8](repeating: 255, count: pixelCount * pixelCount * 4)

        for y in 0..<size {
            for x in 0..<size where modules[y][x] {
                let startX = (x + quietZone) * scale
                let startY = (y + quietZone) * scale
                for py in startY..<(startY + scale) {
                    for px in startX..<(startX + scale) {
                        let offset = (py * pixelCount + px) * 4
                        pixels[offset] = 0
                        pixels[offset + 1] = 0
                        pixels[offset + 2] = 0
                        pixels[offset + 3] = 255
                    }
                }
            }
        }

        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        return CGImage(
            width: pixelCount,
            height: pixelCount,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: pixelCount * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private static func makeModules(_ text: String) -> [[Bool]]? {
        guard let dataCodewords = encodeData(text) else { return nil }
        let codewords = dataCodewords + reedSolomonRemainder(dataCodewords, degree: eccCodewordCount)
        var modules = Array(repeating: Array(repeating: false, count: size), count: size)
        var isFunction = Array(repeating: Array(repeating: false, count: size), count: size)

        drawFunctionPatterns(modules: &modules, isFunction: &isFunction)
        drawCodewords(codewords, modules: &modules, isFunction: isFunction)
        applyMask(modules: &modules, isFunction: isFunction)
        drawFormatBits(modules: &modules)
        return modules
    }

    private static func encodeData(_ text: String) -> [Int]? {
        let bytes = [UInt8](text.utf8)
        let capacityBits = dataCodewordCount * 8
        guard bytes.count <= 42 else { return nil }

        var bits: [Bool] = []
        appendBits(0b0100, count: 4, to: &bits)
        appendBits(bytes.count, count: 8, to: &bits)
        for byte in bytes {
            appendBits(Int(byte), count: 8, to: &bits)
        }

        appendBits(0, count: min(4, capacityBits - bits.count), to: &bits)
        while bits.count % 8 != 0 {
            bits.append(false)
        }

        var codewords = stride(from: 0, to: bits.count, by: 8).map { index in
            bits[index..<(index + 8)].reduce(0) { ($0 << 1) | ($1 ? 1 : 0) }
        }
        var pad = 0xEC
        while codewords.count < dataCodewordCount {
            codewords.append(pad)
            pad = pad == 0xEC ? 0x11 : 0xEC
        }
        return codewords
    }

    private static func drawFunctionPatterns(
        modules: inout [[Bool]],
        isFunction: inout [[Bool]]
    ) {
        drawFinderPattern(x: 0, y: 0, modules: &modules, isFunction: &isFunction)
        drawFinderPattern(x: size - 7, y: 0, modules: &modules, isFunction: &isFunction)
        drawFinderPattern(x: 0, y: size - 7, modules: &modules, isFunction: &isFunction)
        drawAlignmentPattern(x: 22, y: 22, modules: &modules, isFunction: &isFunction)

        for i in 8..<(size - 8) {
            setFunctionModule(i, 6, i % 2 == 0, modules: &modules, isFunction: &isFunction)
            setFunctionModule(6, i, i % 2 == 0, modules: &modules, isFunction: &isFunction)
        }

        reserveFormatModules(isFunction: &isFunction)
        setFunctionModule(8, size - 8, true, modules: &modules, isFunction: &isFunction)
    }

    private static func drawFinderPattern(
        x: Int,
        y: Int,
        modules: inout [[Bool]],
        isFunction: inout [[Bool]]
    ) {
        for dy in -1...7 {
            for dx in -1...7 {
                let xx = x + dx
                let yy = y + dy
                guard (0..<size).contains(xx), (0..<size).contains(yy) else { continue }
                let isSeparator = dx == -1 || dx == 7 || dy == -1 || dy == 7
                let isRing = dx == 0 || dx == 6 || dy == 0 || dy == 6
                let isCenter = (2...4).contains(dx) && (2...4).contains(dy)
                modules[yy][xx] = !isSeparator && (isRing || isCenter)
                isFunction[yy][xx] = true
            }
        }
    }

    private static func drawAlignmentPattern(
        x: Int,
        y: Int,
        modules: inout [[Bool]],
        isFunction: inout [[Bool]]
    ) {
        for dy in -2...2 {
            for dx in -2...2 {
                let distance = max(abs(dx), abs(dy))
                setFunctionModule(
                    x + dx,
                    y + dy,
                    distance != 1,
                    modules: &modules,
                    isFunction: &isFunction
                )
            }
        }
    }

    private static func reserveFormatModules(isFunction: inout [[Bool]]) {
        for i in 0..<6 {
            isFunction[i][8] = true
            isFunction[8][i] = true
        }
        isFunction[7][8] = true
        isFunction[8][8] = true
        isFunction[8][7] = true
        isFunction[8][size - 8] = true

        for i in 0..<8 {
            isFunction[8][size - 1 - i] = true
        }
        for i in 8..<15 {
            isFunction[size - 15 + i][8] = true
        }
    }

    private static func drawCodewords(
        _ codewords: [Int],
        modules: inout [[Bool]],
        isFunction: [[Bool]]
    ) {
        let bits = codewords.flatMap { byte in
            (0..<8).reversed().map { ((byte >> $0) & 1) != 0 }
        }
        var bitIndex = 0
        var right = size - 1
        var upward = true

        while right > 0 {
            if right == 6 {
                right -= 1
            }
            for verticalOffset in 0..<size {
                let y = upward ? size - 1 - verticalOffset : verticalOffset
                for x in [right, right - 1] where !isFunction[y][x] {
                    modules[y][x] = bitIndex < bits.count ? bits[bitIndex] : false
                    bitIndex += 1
                }
            }
            upward.toggle()
            right -= 2
        }
    }

    private static func applyMask(modules: inout [[Bool]], isFunction: [[Bool]]) {
        for y in 0..<size {
            for x in 0..<size where !isFunction[y][x] && (x + y) % 2 == 0 {
                modules[y][x].toggle()
            }
        }
    }

    private static func drawFormatBits(modules: inout [[Bool]]) {
        let bits = formatBits(errorCorrectionLevel: 0, mask: maskPattern)
        for i in 0..<6 {
            modules[i][8] = bit(bits, i)
            modules[8][i] = bit(bits, i)
        }
        modules[7][8] = bit(bits, 6)
        modules[8][8] = bit(bits, 7)
        modules[8][7] = bit(bits, 8)

        for i in 9..<15 {
            modules[8][14 - i] = bit(bits, i)
        }
        for i in 0..<8 {
            modules[8][size - 1 - i] = bit(bits, i)
        }
        for i in 8..<15 {
            modules[size - 15 + i][8] = bit(bits, i)
        }
        modules[size - 8][8] = true
    }

    private static func setFunctionModule(
        _ x: Int,
        _ y: Int,
        _ isDark: Bool,
        modules: inout [[Bool]],
        isFunction: inout [[Bool]]
    ) {
        modules[y][x] = isDark
        isFunction[y][x] = true
    }

    private static func appendBits(_ value: Int, count: Int, to bits: inout [Bool]) {
        guard count > 0 else { return }
        for i in (0..<count).reversed() {
            bits.append(((value >> i) & 1) != 0)
        }
    }

    private static func formatBits(errorCorrectionLevel: Int, mask: Int) -> Int {
        let data = (errorCorrectionLevel << 3) | mask
        var remainder = data << 10
        let generator = 0x537
        for i in stride(from: 14, through: 10, by: -1) {
            if ((remainder >> i) & 1) != 0 {
                remainder ^= generator << (i - 10)
            }
        }
        return ((data << 10) | remainder) ^ 0x5412
    }

    private static func bit(_ value: Int, _ index: Int) -> Bool {
        ((value >> index) & 1) != 0
    }

    private static func reedSolomonRemainder(_ data: [Int], degree: Int) -> [Int] {
        let divisor = reedSolomonDivisor(degree)
        var result = Array(repeating: 0, count: degree)
        for byte in data {
            let factor = byte ^ result.removeFirst()
            result.append(0)
            for i in 0..<degree {
                result[i] ^= finiteMultiply(divisor[i], factor)
            }
        }
        return result
    }

    private static func reedSolomonDivisor(_ degree: Int) -> [Int] {
        var result = Array(repeating: 0, count: degree)
        result[degree - 1] = 1
        var root = 1
        for _ in 0..<degree {
            for i in 0..<degree {
                result[i] = finiteMultiply(result[i], root)
                if i + 1 < degree {
                    result[i] ^= result[i + 1]
                }
            }
            root = finiteMultiply(root, 0x02)
        }
        return result
    }

    private static func finiteMultiply(_ x: Int, _ y: Int) -> Int {
        var z = 0
        var a = x
        var b = y
        while b != 0 {
            if (b & 1) != 0 {
                z ^= a
            }
            a <<= 1
            if (a & 0x100) != 0 {
                a ^= 0x11D
            }
            b >>= 1
        }
        return z
    }
}
