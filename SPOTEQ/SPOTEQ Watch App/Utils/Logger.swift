//
//  Logger.swift
//  SPOTEQ Watch App
//
//  Unified logging for production builds.
//  In DEBUG builds all messages print to console.
//  In RELEASE builds only warnings and errors are emitted via os_log.
//

import Foundation
import os.log

enum AppLogger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.avishayportal.kiters.watchapp"

    static let general   = Logger(subsystem: subsystem, category: "general")
    static let location  = Logger(subsystem: subsystem, category: "location")
    static let motion    = Logger(subsystem: subsystem, category: "motion")
    static let workout   = Logger(subsystem: subsystem, category: "workout")
    static let jump      = Logger(subsystem: subsystem, category: "jump")
    static let session   = Logger(subsystem: subsystem, category: "session")
    static let storage   = Logger(subsystem: subsystem, category: "storage")
}
