//
//  WatchPairQR.swift
//  SurfHubWatch
//
//  QR-pairing UI (WATCH_AUTH.md §2.6). The watch HAS NO CAMERA, so it DISPLAYS a
//  QR and the PHONE scans it (device-authorization, like Apple TV sign-in):
//
//    1. requestPairing → show the returned `qrPayload` as a QR on the watch.
//    2. The rider opens the SurfHub PHONE app → Settings → Connect watch → "Scan
//       watch QR code", points the phone camera at this QR, and taps Connect.
//    3. We poll every ~2 s; on `.approved` the session is stored → go to recording.
//    4. On `.expired` (5-min TTL) offer to generate a fresh QR.
//
//  QR rendering uses CoreImage's CIQRCodeGenerator (no third-party dependency).
//  This is a REFERENCE for the watch team — adapt freely (Kotlin/Wear OS would do
//  the same two calls + a QR view).
//

import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
#if os(watchOS)
import WatchKit
#endif

struct WatchPairQRView: View {
    /// Called with the rider's UID once the phone approves.
    var onPaired: (String) -> Void

    @State private var request: WatchAuth.PairingRequest?
    @State private var phase: Phase = .loading
    @State private var pollTask: Task<Void, Never>?

    enum Phase { case loading, showing, expired, failed(String) }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                switch phase {
                case .loading:
                    ProgressView().padding(.top, 24)
                    Text("Preparing code…").font(.caption2).foregroundStyle(.secondary)

                case .showing:
                    Text("Scan with your phone")
                        .font(.headline)
                    if let qr = request?.qrPayload, let img = Self.qrImage(qr) {
                        Image(uiImage: img)
                            .interpolation(.none)        // keep QR crisp
                            .resizable()
                            .scaledToFit()
                            .frame(width: 132, height: 132)
                            .padding(8)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    Text("In the SurfHub app on your phone: Settings → Connect watch → Scan watch QR code.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    ProgressView()
                        .controlSize(.small)
                        .padding(.top, 2)
                    Text("Waiting for approval…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                case .expired:
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.system(size: 30)).foregroundStyle(.secondary).padding(.top, 16)
                    Text("Code expired").font(.headline)
                    Button("Show a new code") { start() }
                        .buttonStyle(.borderedProminent)

                case .failed(let msg):
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 30)).foregroundStyle(.orange).padding(.top, 16)
                    Text(msg).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Try again") { start() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal)
        }
        .onAppear(perform: start)
        .onDisappear { pollTask?.cancel() }
    }

    // MARK: Flow

    private func start() {
        pollTask?.cancel()
        phase = .loading
        Task {
            do {
                let req = try await WatchAuth.requestPairing(
                    deviceName: Self.deviceName(),
                    deviceModel: Self.deviceModel()
                )
                await MainActor.run { request = req; phase = .showing }
                beginPolling(code: req.code, expiresAt: req.expiresAt)
            } catch {
                await MainActor.run { phase = .failed("Couldn’t start pairing. Check your connection.") }
            }
        }
    }

    private func beginPolling(code: String, expiresAt: Date) {
        pollTask = Task {
            while !Task.isCancelled {
                if Date() >= expiresAt {
                    await MainActor.run { phase = .expired }
                    return
                }
                switch await WatchAuth.pollPairing(code: code) {
                case .approved(let uid):
                    await MainActor.run { onPaired(uid) }
                    return
                case .expired:
                    await MainActor.run { phase = .expired }
                    return
                case .error(let msg):
                    await MainActor.run { phase = .failed(msg) }
                    return
                case .pending:
                    break
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000) // ~2 s
            }
        }
    }

    // MARK: QR rendering

    private static func qrImage(_ string: String) -> UIImage? {
        let ctx = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // Scale up so the small CIImage renders sharply on the watch.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cg = ctx.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: Device identity (shown to the rider in the phone's approval prompt)

    private static func deviceName() -> String? {
        #if os(watchOS)
        return WKInterfaceDevice.current().name
        #else
        return nil
        #endif
    }
    private static func deviceModel() -> String? {
        #if os(watchOS)
        return WKInterfaceDevice.current().model   // e.g. "Apple Watch"
        #else
        return nil
        #endif
    }
}
