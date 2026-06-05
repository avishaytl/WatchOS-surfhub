//
//  WatchChromeStyles.swift
//  Kiters Watch App
//
//  Shared watch UI chrome treatments.
//

import SwiftUI

private struct WatchScrollTopShadow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.72),
                        Color.black.opacity(0.28),
                        Color.black.opacity(0.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 18)
                .allowsHitTesting(false)
            }
    }
}

extension View {
    func watchScrollTopShadow() -> some View {
        modifier(WatchScrollTopShadow())
    }
}
