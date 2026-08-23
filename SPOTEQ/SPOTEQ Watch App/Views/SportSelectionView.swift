//
//  SportSelectionView.swift
//  SPOTEQ
//
//  Sport selection sheet
//

import SwiftUI

struct SportSelectionView: View {
    @EnvironmentObject var sessionManager: SessionManager
    @Binding var isPresented: Bool
    @AppStorage("appLanguage") private var languageCode: String = "en"
    
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text(L("sport.select_sport"))
                    .font(.headline)
                    .padding(.top)
                
                ForEach(Sport.allCases, id: \.self) { sport in
                    Button(action: {
                        startSession(sport: sport)
                    }) {
                        Text(sportDisplayName(sport))
                            .font(.body)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .padding(.horizontal, 12)
                            .background(Color.clear)
                            .overlay(
                                Rectangle()
                                    .strokeBorder(Color.gray.opacity(0.3), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
                
                Button(L("session.cancel")) {
                    isPresented = false
                }
                .foregroundColor(.gray)
                .padding()
            }
            .padding()
        }
        // .watchScrollTopShadow()
        .environment(\.layoutDirection, languageCode == "he" ? .rightToLeft : .leftToRight)
    }
    
    private func sportDisplayName(_ sport: Sport) -> String {
        switch sport {
        case .kiteboarding: return L("sport.kitesurfing")
        // case .windsurfing: return L("sport.windsurfing")
        // case .wingfoiling: return L("sport.wingfoiling")
        // case .surfing: return L("sport.surfing")
        }
    }
    
    private func startSession(sport: Sport) {
        print("� Starting session with \(sport.displayName)")
        sessionManager.startSession(sport: sport)
        isPresented = false
    }
}

struct SportSelectionView_Previews: PreviewProvider {
    static var previews: some View {
        SportSelectionView(isPresented: .constant(true))
            .environmentObject(SessionManager())
    }
}
