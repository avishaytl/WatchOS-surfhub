//
//  SplashView.swift
//  SPOTEQ Watch App
//
//  The SPOTEQ launch screen: the app mark and wordmark over black, held
//  briefly, then handed over to ContentView.
//
//  It is an OVERLAY, not a gate. ContentView is mounted underneath from the
//  first frame and `requestPermissionsOnLaunch()` runs on schedule, so the
//  app is already warm when the splash fades — the splash costs the user
//  `holdSec`, not a load. On a watch that budget has to stay small: a wrist
//  is raised for a few seconds at a time, and anything that reads as a delay
//  on a phone reads as a hang here.
//

import SwiftUI

struct SplashView: View {
    /// How long the mark stays up once it has finished appearing.
    static let holdSec: Double = 0.9
    private static let fadeInSec: Double = 0.45

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        ZStack {
            // Opaque: this covers the live UI, so anything translucent would
            // show ContentView flickering through it as that view settles.
            Color.black.ignoresSafeArea()

            VStack(spacing: 10) {
                Image("SpoteqMark")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 84)

                Image("SpoteqWordmark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 108)
            }
            .opacity(shown ? 1 : 0)
            // Reduce Motion is a request to drop movement, not visibility, so
            // the fade stays and only the scale goes.
            .scaleEffect(shown || reduceMotion ? 1 : 0.88)
            .accessibilityElement()
            .accessibilityLabel("SPOTEQ")
        }
        .onAppear {
            guard !shown else { return }
            withAnimation(.easeOut(duration: Self.fadeInSec)) { shown = true }
        }
    }

    /// Total time the splash owns the screen, fade-in included.
    static var totalSec: Double { fadeInSec + holdSec }
}

#Preview {
    SplashView()
}
