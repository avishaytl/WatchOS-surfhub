//
//  LocalizationHelper.swift
//  SPOTEQ
//
//  Helper for managing app localization and RTL support
//

import SwiftUI

/// Helper function to get localized strings
func L(_ key: String) -> String {
    if let languageCode = UserDefaults.standard.string(forKey: "appLanguage") {
        if let path = Bundle.main.path(forResource: languageCode, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return NSLocalizedString(key, bundle: bundle, comment: "")
        }
    }
    return NSLocalizedString(key, comment: "")
}

/// Language options
enum AppLanguage: String, CaseIterable {
    case english = "en"
    case hebrew = "he"
    
    var displayName: String {
        switch self {
        case .english: return "English"
        case .hebrew: return "עברית"
        }
    }
    
    var isRTL: Bool {
        self == .hebrew
    }
}

/// Extension to manage language changes
extension UserDefaults {
    var appLanguage: AppLanguage {
        get {
            if let languageCode = string(forKey: "appLanguage"),
               let language = AppLanguage(rawValue: languageCode) {
                return language
            }
            return .english
        }
        set {
            set(newValue.rawValue, forKey: "appLanguage")
        }
    }
}

/// View modifier for RTL support
struct RTLModifier: ViewModifier {
    @AppStorage("appLanguage") private var languageCode: String = "en"
    
    func body(content: Content) -> some View {
        content
            .environment(\.layoutDirection, languageCode == "he" ? .rightToLeft : .leftToRight)
    }
}

extension View {
    func applyRTL() -> some View {
        modifier(RTLModifier())
    }
}
