//
//  WatchPairScan.swift  — DEPRECATED, replaced by WatchPairQR.swift
//
//  An earlier design had the WATCH scan a QR shown on the phone. That is wrong:
//  the watch has no camera. The correct flow is the reverse — the WATCH DISPLAYS
//  a QR and the PHONE scans it (device-authorization, WATCH_AUTH.md §2.6).
//
//  See WatchPairQR.swift (shows the QR + polls) and WatchAuth.requestPairing /
//  WatchAuth.pollPairing. This file is intentionally empty so it compiles to
//  nothing; delete it from the Xcode project when convenient.
//
