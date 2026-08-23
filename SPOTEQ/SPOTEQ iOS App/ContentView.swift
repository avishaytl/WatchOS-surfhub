import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "applewatch")
                .font(.system(size: 80))
                .foregroundStyle(.blue)

            Text("SPOTEQ")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Open SPOTEQ on your\nApple Watch to start tracking\nyour kitesurfing sessions.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()

            Text("SPOTEQ is a standalone Apple Watch app.\nNo iPhone needed during sessions.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 32)
        }
    }
}

#Preview {
    ContentView()
}
