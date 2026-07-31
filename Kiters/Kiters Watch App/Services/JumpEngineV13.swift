//
//  JumpEngineV13.swift
//  Kiters Watch App
//
//  V13 absolute-altitude jump engine.
//
//  Design:
//  - Absolute altitude is the detection source. A jump opens when the absolute
//    altitude rises over a 3-5 s baseline average by the configured threshold.
//    IMU and GPS are optional metrics only; they must not block detection.
//  - Keeps rolling altitude/IMU/GPS history for robust baselines and metrics.
//    History may refine an already-open candidate; it must not originate jumps
//    from arbitrary local peaks after the fact.
//  - Jump condition is absolute-altitude rise over a short window:
//      1.0 m -> 1.0 s, 1.5 m -> 1.5 s, 2.0 m -> 2.0 s.
//  - Height is max absolute altitude minus the pre-jump baseline average.
//  - Airtime is the start of the rise window to landing-return time.
//  - GPS speed/distance are GPS-derived metrics only.
//

import Foundation

// MARK: - Config

public struct V13Config {
    // CMAltimeter owns the hardware delivery cadence. This preference controls
    // the maximum cadence at which live absolute-altitude callbacks are handed
    // to V13 (and the repeated-value heartbeat used by replay).
    public var absoluteAltitudeSampleIntervalSec = 0.5

    // User preference: a fully validated jump is reported/counted only at or
    // above this height. It must not influence candidate recall or timing.
    public var minCountedHeightM = 1.0

    // Internal detection thresholds. Keeping metres and seconds independent is
    // intentional: changing the user's counted-height preference must not move
    // takeoff/landing timestamps or prevent a valid arc from being analysed.
    public var candidateRiseM = 1.0
    public var takeoffWindowSec = 1.0
    public var landingDescentM = 0.5

    // GPS-derived metrics. V13 detection is barometer-only by default, so these
    // fields are reported/tunable but are not used as jump gates.
    public var minGpsSpeedMS = 0.0
    public var minGpsDistanceM = 0.0

    // Landing: prefer an absolute return to the pre-jump baseline. The stable
    // window remains as a fallback/diagnostic path after the return signal.
    public var landingStableSec = 2.0
    public var landingStableDeltaM = 0.25
    public var landingStableRangeM = 0.6
    public var landingReturnBandM = 0.75

    // Time bounds applied only after the altitude jump/landing sequence is complete.
    // There is intentionally no maximum jump height: magnitude is reported as
    // measured and validity comes from baseline, arc, airtime and landing shape.
    public var minAirtimeSec = 1.0
    public var maxAirtimeSec = 12.0
    public var maxFlightSec = 20.0

    // Compatibility/tuning fields kept for existing settings UI and callers.
    // IMU remains metrics-only in V13 simple mode.
    public var bufferSec = 60.0
    public var triggerAccelG = 1.8
    public var triggerGyroRadS = 4.0
    public var preTriggerLeadSec = 0.0
    public var emptyCandidateCloseSec = 0.0
    public var retriggerGuardSec = 0.8
    public var takeoffWindowSlackSec = 0.15
    // Takeoff baseline: average absolute altitude over the 3-5 seconds before
    // takeoff. The jump condition is current absolute altitude minus this
    // baseline average.
    public var baselineWindowSec = 4.0
    public var minBaselineSamples = 3
    public var maxBaselineNoiseRangeM = 1.0
    public var startupWarmupSec = 8.0
    public var baselineGapSec = 0.0
    public var postLandingGapSec = 0.0
    public var postBaselineWindowSec = 2.0
    public var maxBaselineDriftM = 2.0
    public var spikeToleranceM = 0.0
    public var peakNeighborhoodSec = 0.0
    public var minArcSamples = 1
    public var landingImpactG = 1.9
    public var crossingBandM = 0.0
    public var maxResultDelaySec = 2.5
    public var gpsMatchToleranceSec = 2.5
    public var takeoffEvidenceLeadSec = 0.5
    public var takeoffEvidenceTailSec = 0.8
    public var landingEvidenceWindowSec = 0.8

    // The compact binary stream retains every IMU sample. Structured JSON
    // snapshots are deliberately slower so an airborne candidate cannot create
    // hundreds of JSON encodes/dispatch blocks per second on Apple Watch.
    public var structuredIMUAuditIntervalSec = 0.25

    public init() {}
}

// MARK: - Structured calculation audit

/// One evaluated V13 condition. `passed == nil` means the condition could not
/// yet be evaluated because an earlier prerequisite (for example a baseline)
/// was not available.
public struct V13AuditCondition: Codable {
    public let id: String
    public let actual: Double?
    public let comparator: String
    public let expected: Double?
    public let passed: Bool?
    public let unit: String

    public init(id: String,
                actual: Double?,
                comparator: String,
                expected: Double?,
                passed: Bool?,
                unit: String = "") {
        self.id = id
        self.actual = actual
        self.comparator = comparator
        self.expected = expected
        self.passed = passed
        self.unit = unit
    }
}

/// Written once at the beginning of a V13 audit stream so an uploaded log can
/// be understood without matching it to a particular app build.
public struct V13AuditParameterDefinition: Codable {
    public let id: String
    public let unit: String
    public let formula: String
    public let descriptionHe: String

    public init(id: String, unit: String, formula: String, descriptionHe: String) {
        self.id = id
        self.unit = unit
        self.formula = formula
        self.descriptionHe = descriptionHe
    }
}

/// Future-proof JSON payload stored in KSLG record tag 12. Values are split
/// into numeric and text dictionaries to keep decoding simple in Swift, CLI
/// tools and cloud analytics.
public struct V13AuditRecord: Codable {
    public let schemaVersion: Int
    public var sequence: UInt64
    public var sessionID: String
    public let monotonicTime: TimeInterval
    public let kind: String
    public let stage: String
    public let action: String
    public let decision: String
    public let candidateID: Int?
    public let reason: String?
    public let values: [String: Double]
    public let labels: [String: String]
    public let conditions: [V13AuditCondition]
    public let definitions: [V13AuditParameterDefinition]
    public let counts: [String: Int]

    public init(monotonicTime: TimeInterval,
                kind: String = "event",
                stage: String,
                action: String,
                decision: String = "observed",
                candidateID: Int? = nil,
                reason: String? = nil,
                values: [String: Double] = [:],
                labels: [String: String] = [:],
                conditions: [V13AuditCondition] = [],
                definitions: [V13AuditParameterDefinition] = [],
                counts: [String: Int] = [:]) {
        self.schemaVersion = 1
        self.sequence = 0
        self.sessionID = ""
        self.monotonicTime = monotonicTime
        self.kind = kind
        self.stage = stage
        self.action = action
        self.decision = decision
        self.candidateID = candidateID
        self.reason = reason
        self.values = values.filter { $0.value.isFinite }
        self.labels = labels
        self.conditions = conditions
        self.definitions = definitions
        self.counts = counts
    }
}

/// Session-scoped audit coordinator for V13. Engine/adapter events can arrive
/// before SessionLogger has opened the KSLG file, so the service buffers that
/// short prefix and drains it in order as soon as the sink is attached.
public final class V13CalculationLogService {
    public static let shared = V13CalculationLogService()
    public typealias Sink = (V13AuditRecord) -> Void

    private let lock = NSLock()
    private var isActive = false
    private var sessionID = ""
    private var nextSequence: UInt64 = 1
    private var pending: [V13AuditRecord] = []
    private var sink: Sink?
    private var counts: [String: Int] = [:]
    private let maximumPendingRecords = 512

    public init() {}

    public func beginSession(sessionID: String, t: TimeInterval) {
        lock.lock()
        isActive = true
        self.sessionID = sessionID
        nextSequence = 1
        pending.removeAll(keepingCapacity: true)
        sink = nil
        counts.removeAll(keepingCapacity: true)
        lock.unlock()

        record(V13AuditRecord(
            monotonicTime: t,
            kind: "schema",
            stage: "session",
            action: "auditSchema",
            decision: "started",
            labels: [
                "engine": "v13-pure",
                "conditionStatus": "passed=true עבר, false נכשל, null טרם ניתן לחישוב",
                "storage": "KSLG v2 record tag 12; uploaded with the session log"
            ],
            definitions: Self.parameterDefinitions
        ))
        lifecycle(t: t, action: "sessionStarted")
    }

    public func configure(_ cfg: V13Config, t: TimeInterval) {
        record(V13AuditRecord(
            monotonicTime: t,
            kind: "configuration",
            stage: "session",
            action: "effectiveConfiguration",
            decision: "installed",
            values: Self.configurationValues(cfg),
            labels: [
                "detectionSource": "absoluteAltitude",
                "imuRole": "metricsOnly",
                "gpsRole": "metricsOnly"
            ]
        ))
    }

    public func attachSink(_ newSink: @escaping Sink) {
        lock.lock()
        guard isActive else {
            lock.unlock()
            return
        }
        sink = newSink
        let buffered = pending
        pending.removeAll(keepingCapacity: true)
        lock.unlock()

        // No sensors are started before this attachment in a live session; the
        // copy also keeps the lock away from file I/O and JSON encoding.
        buffered.forEach(newSink)
    }

    public func detachSink() {
        lock.lock()
        sink = nil
        lock.unlock()
    }

    public func lifecycle(t: TimeInterval,
                          action: String,
                          decision: String = "transition",
                          reason: String? = nil,
                          values: [String: Double] = [:],
                          labels: [String: String] = [:]) {
        record(V13AuditRecord(
            monotonicTime: t,
            stage: "session",
            action: action,
            decision: decision,
            reason: reason,
            values: values,
            labels: labels
        ))
    }

    public func endSession(t: TimeInterval, durationSec: Double, reportedJumpCount: Int) {
        var target: Sink?
        var summary: V13AuditRecord

        lock.lock()
        guard isActive else {
            lock.unlock()
            return
        }
        let snapshot = counts
        summary = V13AuditRecord(
            monotonicTime: t,
            kind: "summary",
            stage: "session",
            action: "sessionEnded",
            decision: "completed",
            values: [
                "durationSec": max(0, durationSec),
                "reportedJumpCount": Double(max(0, reportedJumpCount))
            ],
            counts: snapshot
        )
        summary.sequence = nextSequence
        summary.sessionID = sessionID
        nextSequence &+= 1
        counts["totalRecords", default: 0] += 1
        counts["stage.session", default: 0] += 1
        counts["decision.completed", default: 0] += 1
        target = sink
        if target == nil {
            if pending.count == maximumPendingRecords {
                pending.removeFirst()
            }
            pending.append(summary)
        }
        isActive = false
        lock.unlock()

        target?(summary)
    }

    public func record(_ unstamped: V13AuditRecord) {
        var stamped = unstamped
        var target: Sink?

        lock.lock()
        guard isActive else {
            lock.unlock()
            return
        }
        stamped.sequence = nextSequence
        stamped.sessionID = sessionID
        nextSequence &+= 1
        counts["totalRecords", default: 0] += 1
        counts["stage.\(stamped.stage)", default: 0] += 1
        counts["decision.\(stamped.decision)", default: 0] += 1
        if let reason = stamped.reason, !reason.isEmpty {
            counts["reason.\(reason)", default: 0] += 1
        }
        target = sink
        if target == nil {
            if pending.count == maximumPendingRecords {
                pending.removeFirst()
                counts["bufferOverflowDropped", default: 0] += 1
            }
            pending.append(stamped)
        }
        lock.unlock()

        target?(stamped)
    }

    private static func configurationValues(_ c: V13Config) -> [String: Double] {
        [
            "minCountedHeightM": c.minCountedHeightM,
            "absoluteAltitudeSampleIntervalSec": c.absoluteAltitudeSampleIntervalSec,
            "candidateRiseM": c.candidateRiseM,
            "takeoffWindowSec": c.takeoffWindowSec,
            "takeoffWindowSlackSec": c.takeoffWindowSlackSec,
            "landingDescentM": c.landingDescentM,
            "landingStableSec": c.landingStableSec,
            "landingStableDeltaM": c.landingStableDeltaM,
            "landingStableRangeM": c.landingStableRangeM,
            "landingReturnBandM": c.landingReturnBandM,
            "minAirtimeSec": c.minAirtimeSec,
            "maxAirtimeSec": c.maxAirtimeSec,
            "maxFlightSec": c.maxFlightSec,
            "retriggerGuardSec": c.retriggerGuardSec,
            "baselineWindowSec": c.baselineWindowSec,
            "minBaselineSamples": Double(c.minBaselineSamples),
            "maxBaselineNoiseRangeM": c.maxBaselineNoiseRangeM,
            "startupWarmupSec": c.startupWarmupSec,
            "postBaselineWindowSec": c.postBaselineWindowSec,
            "maxBaselineDriftM": c.maxBaselineDriftM,
            "minArcSamples": Double(c.minArcSamples),
            "landingImpactG": c.landingImpactG,
            "maxResultDelaySec": c.maxResultDelaySec,
            "gpsMatchToleranceSec": c.gpsMatchToleranceSec,
            "takeoffEvidenceLeadSec": c.takeoffEvidenceLeadSec,
            "takeoffEvidenceTailSec": c.takeoffEvidenceTailSec,
            "landingEvidenceWindowSec": c.landingEvidenceWindowSec,
            "structuredIMUAuditIntervalSec": c.structuredIMUAuditIntervalSec,
            "bufferSec": c.bufferSec
        ]
    }

    private static let parameterDefinitions: [V13AuditParameterDefinition] = [
        .init(id: "absoluteAltitudeM", unit: "m", formula: "CMAbsoluteAltitudeData.altitude", descriptionHe: "גובה מוחלט נכנס; זהו מקור הזיהוי הראשי של מנוע 13."),
        .init(id: "absoluteAccuracyM", unit: "m", formula: "CMAbsoluteAltitudeData.accuracy", descriptionHe: "דיוק ערוץ הגובה; משמש לסינון re-anchor ונתונים לא אמינים לפני הכניסה למנוע."),
        .init(id: "absoluteAltitudeSampleIntervalSec", unit: "s", formula: "user configuration; 0.25...1.0", descriptionHe: "המרווח המינימלי בין דגימות Absolute שמועברות לחישוב. Core Motion עשוי לספק נתונים לאט יותר."),
        .init(id: "baselineAverageM", unit: "m", formula: "average(altitude in baselineWindowSec before takeoff window)", descriptionHe: "גובה הייחוס לפני הקפיצה שממנו נמדד הגובה הסופי."),
        .init(id: "baselineRangeM", unit: "m", formula: "max(baseline)-min(baseline)", descriptionHe: "רעש חלון הבסיס; טווח גדול מדי מונע פתיחת מועמד."),
        .init(id: "shortWindowRiseM", unit: "m", formula: "currentAltitude-firstAltitudeInTakeoffWindow", descriptionHe: "העלייה בתוך חלון ההמראה הקצר."),
        .init(id: "baselineRiseM", unit: "m", formula: "currentAltitude-baselineAverage", descriptionHe: "עלייה מעל קו הבסיס; חייבת לעבור את candidateRiseM."),
        .init(id: "candidateRiseM", unit: "m", formula: "configuration", descriptionHe: "סף פנימי לפתיחת מועמד; אינו סף הספירה הסופי."),
        .init(id: "minCountedHeightM", unit: "m", formula: "user configuration", descriptionHe: "סף גובה סופי לאחר שכל בדיקות הפיזיקה והנחיתה עברו."),
        .init(id: "heightM", unit: "m", formula: "maximumAltitude-baselineAverage", descriptionHe: "גובה הקפיצה המחושב מהבסיס עד האפקס."),
        .init(id: "apexAltitudeM", unit: "m", formula: "max(altitude during candidate)", descriptionHe: "הגובה המקסימלי שנמדד במועמד."),
        .init(id: "descentFromPeakM", unit: "m", formula: "apexAltitude-currentAltitude", descriptionHe: "ירידה מהאפקס; פותחת מעקב נחיתה לאחר landingDescentM."),
        .init(id: "airtimeSec", unit: "s", formula: "landingTime-takeoffTime", descriptionHe: "זמן האוויר בין תחילת חלון העלייה לבין רגע הנחיתה."),
        .init(id: "ballisticAirtimeSec", unit: "s", formula: "2*sqrt(2*height/9.80665)", descriptionHe: "זמן בליסטי תאורטי המשמש לבדיקת קשת מהירה מדי."),
        .init(id: "minimumCoherentAirtimeSec", unit: "s", formula: "max(minAirtimeSec, ballisticAirtimeSec*0.55)", descriptionHe: "זמן מינימלי מקל שבו הקשת עדיין נחשבת פיזיקלית עקבית."),
        .init(id: "landingReturnDeltaM", unit: "m", formula: "currentAltitude-baselineAverage", descriptionHe: "מרחק הגובה הנוכחי מקו הבסיס בעת בדיקת חזרה לנחיתה."),
        .init(id: "landingStableRangeM", unit: "m", formula: "max(landingWindow)-min(landingWindow)", descriptionHe: "טווח הגבהים בחלון נחיתה יציב חלופי."),
        .init(id: "baselineShiftM", unit: "m", formula: "postLandingBaseline-preJumpBaseline", descriptionHe: "שינוי datum בין ההמראה לנחיתה; שינוי גדול פוסל את התוצאה."),
        .init(id: "verticalRateMS", unit: "m/s", formula: "deltaAltitude/deltaTime", descriptionHe: "קצב העלייה או הירידה בין שתי דגימות גובה."),
        .init(id: "accelG", unit: "g", formula: "magnitude(userAcceleration)", descriptionHe: "תאוצה למדדי המראה/נחיתה בלבד; אינה תנאי לזיהוי ב-V13."),
        .init(id: "gyroRadS", unit: "rad/s", formula: "magnitude(rotationRate)", descriptionHe: "מהירות סיבוב למדדי rotation בלבד; אינה תנאי לזיהוי."),
        .init(id: "rotationTurns", unit: "turns", formula: "integral(gyroRadS*dt)/(2*pi)", descriptionHe: "מספר סיבובים משוער בזמן הקשת."),
        .init(id: "impactEnergy", unit: "g²*s", formula: "sum(max(0,accelG-1)^2*dt above landingImpactG)", descriptionHe: "מדד אנרגיית פגיעה באזור הנחיתה."),
        .init(id: "gpsSpeedMS", unit: "m/s", formula: "CLLocation.speed", descriptionHe: "מהירות GPS למדדים בלבד; אינה חוסמת זיהוי."),
        .init(id: "distanceM", unit: "m", formula: "haversine(launch,landing), fallback speed*airtime", descriptionHe: "מרחק אופקי בין מיקום ההמראה לנחיתה או אומדן מהירות כפול זמן."),
        .init(id: "confidence", unit: "0...1", formula: "base score + landing/GPS adjustments", descriptionHe: "ציון איכות התוצאה לאחר שכל תנאי החובה עברו."),
        .init(id: "resultDelaySec", unit: "s", formula: "emittedAt-landingTime", descriptionHe: "השהיה בין רגע הנחיתה לבין הפקת התוצאה."),
        .init(id: "altitudePointCount", unit: "samples", formula: "count(altitude between takeoff and landing)", descriptionHe: "מספר דגימות הגובה ששימשו לבניית הקשת."),
        .init(id: "takeoffWindowSec", unit: "s", formula: "configuration", descriptionHe: "אורך חלון העלייה שממנו נגזר זמן ההמראה."),
        .init(id: "takeoffWindowSlackSec", unit: "s", formula: "configuration", descriptionHe: "מרווח נוסף לשימור דגימות סביב חלון ההמראה."),
        .init(id: "takeoffWindowReady", unit: "condition", formula: "windowDuration >= takeoffWindowSec*0.8", descriptionHe: "מוודא שהצטבר מספיק זמן לפני שבודקים עלייה."),
        .init(id: "startupWarmupSec", unit: "s", formula: "configuration", descriptionHe: "זמן ההתחממות הנדרש לערוץ הגובה לפני פתיחת מועמד."),
        .init(id: "sensorWarmup", unit: "condition", formula: "warmupElapsed >= startupWarmupSec", descriptionHe: "מונע פתיחת קפיצה לפני שנבנה הקשר מספק מתחילת הסשן."),
        .init(id: "baselineWindowSec", unit: "s", formula: "configuration", descriptionHe: "אורך היסטוריית הגובה שלפני ההמראה לחישוב baseline."),
        .init(id: "minBaselineSamples", unit: "samples", formula: "configuration", descriptionHe: "מספר דגימות מינימלי הדרוש ל-baseline תקף."),
        .init(id: "baselineSamples", unit: "condition", formula: "baselineSampleCount >= minBaselineSamples", descriptionHe: "בודק שנאספו מספיק דגימות לפני חלון ההמראה."),
        .init(id: "maxBaselineNoiseRangeM", unit: "m", formula: "configuration", descriptionHe: "טווח הרעש המרבי המותר ב-baseline לפני קפיצה."),
        .init(id: "baselineNoise", unit: "condition", formula: "baselineRangeM <= maxBaselineNoiseRangeM", descriptionHe: "פוסל פתיחת מועמד כאשר קו הבסיס רועש מדי."),
        .init(id: "takeoffFloor", unit: "condition", formula: "firstAltitude-baseline >= -landingReturnBandM*0.65", descriptionHe: "מונע התאוששות מדיפת לחץ מתחת ל-baseline מלהיראות כהמראה."),
        .init(id: "shortWindowRise", unit: "condition", formula: "shortWindowRiseM >= candidateRiseM", descriptionHe: "דורש עלייה ממשית בתוך חלון ההמראה הקצר."),
        .init(id: "baselineRise", unit: "condition", formula: "baselineRiseM >= candidateRiseM", descriptionHe: "דורש שהגובה הנוכחי יהיה מעל ממוצע ה-baseline, לא רק מעל נקודה נמוכה."),
        .init(id: "retriggerGuardSec", unit: "s", formula: "configuration", descriptionHe: "זמן חסימה קצר לאחר נחיתה לפני פתיחת מועמד חדש."),
        .init(id: "retriggerGuard", unit: "condition", formula: "timeSinceLastLanding >= retriggerGuardSec", descriptionHe: "מונע זיהוי כפול של אותה נחיתה כקפיצה נוספת."),
        .init(id: "newApex", unit: "condition", formula: "currentAltitude > previousMaximum", descriptionHe: "קובע אם הדגימה הנוכחית מחליפה את הגובה המקסימלי."),
        .init(id: "landingDescentM", unit: "m", formula: "configuration", descriptionHe: "הירידה המינימלית מהאפקס לפני שמתחילים לאסוף חלון נחיתה."),
        .init(id: "landingDescent", unit: "condition", formula: "descentFromPeakM >= landingDescentM", descriptionHe: "מאשר שהמועמד עבר מעלייה לשלב ירידה."),
        .init(id: "landingReturnBandM", unit: "m", formula: "configuration", descriptionHe: "המרחק המרבי מעל baseline שנחשב חזרה לנחיתה."),
        .init(id: "returnedToBaseline", unit: "condition", formula: "currentAltitude-baseline <= landingReturnBandM", descriptionHe: "בודק שהגובה חזר לאזור קו הבסיס שלפני ההמראה."),
        .init(id: "clearedBaseline", unit: "condition", formula: "apex-baseline >= candidateRiseM", descriptionHe: "מוודא שהקשת אכן התרוממה מספיק לפני חזרה ל-baseline."),
        .init(id: "landingStableSec", unit: "s", formula: "configuration", descriptionHe: "משך חלון הנחיתה היציב במסלול החלופי."),
        .init(id: "landingStableDeltaM", unit: "m", formula: "configuration", descriptionHe: "שינוי הגובה המרבי בין תחילת חלון הנחיתה לסופו."),
        .init(id: "stableWindowTime", unit: "condition", formula: "landingWindowDuration >= landingStableSec", descriptionHe: "בודק שחלון הנחיתה נמשך מספיק זמן."),
        .init(id: "stableWindowDelta", unit: "condition", formula: "abs(last-first) <= landingStableDeltaM", descriptionHe: "בודק שהנחיתה לא ממשיכה לעלות או לרדת באופן חד."),
        .init(id: "stableWindowRange", unit: "condition", formula: "max-min <= landingStableRangeM", descriptionHe: "בודק שכל דגימות חלון הנחיתה נמצאות בטווח יציב."),
        .init(id: "minAirtimeSec", unit: "s", formula: "configuration", descriptionHe: "זמן האוויר המינימלי לתוצאה תקפה."),
        .init(id: "maxAirtimeSec", unit: "s", formula: "configuration", descriptionHe: "זמן האוויר המרבי לתוצאה תקפה לאחר זיהוי נחיתה."),
        .init(id: "minimumAirtime", unit: "condition", formula: "airtimeSec >= minAirtimeSec", descriptionHe: "גבול הזמן התחתון של הקפיצה."),
        .init(id: "maximumAirtime", unit: "condition", formula: "airtimeSec <= maxAirtimeSec", descriptionHe: "גבול הזמן העליון של הקפיצה."),
        .init(id: "maxFlightSec", unit: "s", formula: "configuration", descriptionHe: "timeout בטיחות למועמד שלא נמצאה לו נחיתה."),
        .init(id: "maxFlight", unit: "condition", formula: "flightElapsed <= maxFlightSec", descriptionHe: "סוגר מועמד שנשאר airborne מעבר לזמן המרבי."),
        .init(id: "maxResultDelaySec", unit: "s", formula: "configuration", descriptionHe: "ההשהיה המרבית המותרת להפקת תוצאה לאחר נחיתה."),
        .init(id: "resultFreshness", unit: "condition", formula: "resultDelaySec <= maxResultDelaySec+0.1", descriptionHe: "מונע הפקת קפיצה היסטורית מאוחרת."),
        .init(id: "minArcSamples", unit: "samples", formula: "configuration", descriptionHe: "מספר דגימות הגובה המינימלי בקשת."),
        .init(id: "minimumArcSamples", unit: "condition", formula: "altitudePointCount >= minArcSamples", descriptionHe: "בודק שיש מספיק נקודות לבניית קשת."),
        .init(id: "interiorApex", unit: "condition", formula: "0 < apexIndex < lastIndex", descriptionHe: "דורש אפקס בתוך הקשת ולא בקצה הראשון או האחרון."),
        .init(id: "coherentAirtime", unit: "condition", formula: "airtime+0.05 >= minimumCoherentAirtimeSec", descriptionHe: "בודק שגובה הקפיצה וזמן האוויר אינם סותרים פיזיקלית."),
        .init(id: "progressiveAscent", unit: "condition", formula: "meaningfulAscentSteps >= 2 for long arcs", descriptionHe: "בקשת גבוהה דורש עלייה הדרגתית ולא קפיצת datum מלבנית."),
        .init(id: "progressiveDescent", unit: "condition", formula: "meaningfulDescentSteps >= 2 for long arcs", descriptionHe: "בקשת גבוהה דורש ירידה הדרגתית ולא פולס רעש."),
        .init(id: "ascentInterior", unit: "condition", formula: "has point between 10%-90% height before apex", descriptionHe: "דורש נקודת ביניים בצד העלייה של קשת גבוהה."),
        .init(id: "descentInterior", unit: "condition", formula: "has point between 10%-90% height after apex", descriptionHe: "דורש נקודת ביניים בצד הירידה של קשת גבוהה."),
        .init(id: "maxBaselineDriftM", unit: "m", formula: "configuration", descriptionHe: "שינוי ה-baseline המרבי המותר בין המראה לנחיתה."),
        .init(id: "baselineDrift", unit: "condition", formula: "abs(baselineShiftM) <= maxBaselineDriftM", descriptionHe: "פוסל קשת כשנקודת הייחוס זזה יותר מדי בזמן הקפיצה."),
        .init(id: "countedHeight", unit: "condition", formula: "heightM >= minCountedHeightM", descriptionHe: "החלטת הספירה הסופית שמופעלת רק לאחר כל בדיקות החיישן והקשת."),
        .init(id: "landingImpactG", unit: "g", formula: "configuration", descriptionHe: "סף התאוצה שמעליו מצטבר impactEnergy; מדד בלבד."),
        .init(id: "landingImpact", unit: "condition", formula: "accelG >= landingImpactG", descriptionHe: "מסמן דגימת פגיעה לצורך מדד הנחיתה ואינו חוסם את הקפיצה."),
        .init(id: "gpsMatchToleranceSec", unit: "s", formula: "configuration", descriptionHe: "מרחק הזמן המרבי להתאמת נקודת GPS להמראה או לנחיתה."),
        .init(id: "takeoffEvidenceLeadSec", unit: "s", formula: "configuration", descriptionHe: "היסטוריית IMU לפני ההמראה לחישוב takeoffG."),
        .init(id: "takeoffEvidenceTailSec", unit: "s", formula: "configuration", descriptionHe: "חלון IMU אחרי ההמראה לחישוב takeoffG."),
        .init(id: "landingEvidenceWindowSec", unit: "s", formula: "configuration", descriptionHe: "חלון IMU סביב הנחיתה לחישוב landingG ו-impact."),
        .init(id: "bufferSec", unit: "s", formula: "configuration", descriptionHe: "אורך היסטוריית הגובה, IMU ו-GPS הנשמרת בזיכרון לחישובים."),
        .init(id: "usableAbsoluteAccuracy", unit: "condition", formula: "accuracy <= 12m", descriptionHe: "שער האיכות של ערוץ הגובה המוחלט לפני כניסה למנוע."),
        .init(id: "belowReanchorSentinel", unit: "condition", formula: "accuracy < 100m", descriptionHe: "מזהה sentinel של Core Motion בזמן re-anchor."),
        .init(id: "absoluteSampleInterval", unit: "condition", formula: "timeSinceLastProcessedAltitude >= absoluteAltitudeSampleIntervalSec", descriptionHe: "מגביל את כל דגימות הגובה, כולל ערך שהשתנה, לקצב העיבוד שנבחר."),
        .init(id: "repeatedAltitudeHeartbeat", unit: "condition", formula: "timeSinceSameValue >= 0.9s", descriptionHe: "heartbeat קבוע לנתוני ZOH ישנים/Replay; קצב העיבוד החי נשלט בנפרד לפני הכניסה למנוע."),
        .init(id: "structuredIMUAuditIntervalSec", unit: "s", formula: "configuration", descriptionHe: "קצב snapshot של חישובי IMU המפורטים; הזרם הגולמי נשמר במלואו."),
        .init(id: "datumReset", unit: "event", formula: "accuracy/sentinel/downward-staircase guard", descriptionHe: "איפוס היסטוריית המנוע כשמקור הגובה משנה נקודת ייחוס."),
        .init(id: "phase", unit: "state", formula: "idle|airborne", descriptionHe: "מצב מכונת המצבים לפני ואחרי כל פעולה.")
    ]
}

// MARK: - Output

public enum V13TriggerSource: String {
    case imu
    case altitude
}

public struct V13ProfilePoint {
    public let tOffsetSec: Double
    public let relHeightM: Double
}

public struct V13Jump {
    public let heightM: Double
    public let airtimeSec: Double
    public let takeoffT: TimeInterval
    public let landingT: TimeInterval
    public let apexT: TimeInterval

    public let peakAltitudeM: Double
    public let baselinePreM: Double
    public let baselinePostM: Double?
    public let baselineRefM: Double
    public let baselineShifted: Bool
    public let driftSuspect: Bool

    public let maxAscentRateMS: Double
    public let maxDescentRateMS: Double

    public let takeoffG: Double
    public let landingG: Double
    public let peakG: Double
    public let prePopImpulseG: Double
    public let maxRotationRadS: Double
    public let rotationTurns: Double
    public let impactEnergy: Double

    public let takeoffSpeedMS: Double?
    public let landingSpeedMS: Double?
    public let distanceM: Double?
    public let launchLat: Double?
    public let launchLng: Double?
    public let landingLat: Double?
    public let landingLng: Double?

    public let altitudePointCount: Int
    public let confidence: Double
    public let triggerSource: V13TriggerSource
    public let emittedAtT: TimeInterval
    public let profile: [V13ProfilePoint]
}

public protocol JumpEngineV13Delegate: AnyObject {
    func jumpDetected(_ jump: V13Jump)
}

// MARK: - Engine

public final class JumpEngineV13 {
    public weak var delegate: JumpEngineV13Delegate?
    public var onDebug: (TimeInterval, String) -> Void = { _, _ in }
    public var onAudit: (V13AuditRecord) -> Void = { _ in }

    private let cfg: V13Config

    private struct AltPt {
        let t: TimeInterval
        let alt: Double
    }

    private struct ImuPt {
        let t: TimeInterval
        let accelG: Double
        let gyroRadS: Double
    }

    private struct GpsPt {
        let t: TimeInterval
        let lat: Double
        let lng: Double
        let spd: Double
    }

    private struct BaselineStats {
        let average: Double
        let range: Double
        let count: Int
    }

    private struct MotionEvidence {
        let takeoffG: Double
        let landingG: Double
        let peakG: Double
        let maxGyro: Double
        let rotationIntegral: Double
        let impactEnergy: Double
    }

    private struct ActiveJump {
        let candidateID: Int
        let takeoffT: TimeInterval
        let baselineAlt: Double
        let launchGPS: GpsPt?

        var maxAlt: Double
        var apexT: TimeInterval
        var previousAlt: AltPt
        var landingWindow: [AltPt]
        var altitudePointCount: Int
        var maxAscentRate: Double
        var maxDescentRate: Double

        var takeoffG: Double
        var landingG: Double
        var peakG: Double
        var maxGyro: Double
        var rotationIntegral: Double
        var impactEnergy: Double
        var previousIMU: ImuPt?
        var lastIMUAuditT: TimeInterval
    }

    private enum Phase {
        case idle
        case airborne(ActiveJump)
    }

    private var phase: Phase = .idle
    private var takeoffWindow: [AltPt] = []
    private var latestGPS: GpsPt?
    private var firstAltitudeT: TimeInterval?
    private var lastAltT = -Double.infinity
    private var lastImuT = -Double.infinity
    private var lastGpsT = -Double.infinity
    private var lastLandedT = -Double.infinity
    private var altitudeHistory: [AltPt] = []
    private var imuHistory: [ImuPt] = []
    private var gpsHistory: [GpsPt] = []
    private var emittedPeakTimes: [TimeInterval] = []
    private var nextCandidateID = 1
    // The buffered scan re-evaluates unclaimed peaks on every altitude sample,
    // so an identical rejection would otherwise be logged dozens of times.
    private var lastRejectDebug = ""

    public init(_ cfg: V13Config = V13Config()) {
        self.cfg = cfg
    }

    public func reset() {
        phase = .idle
        takeoffWindow.removeAll(keepingCapacity: true)
        latestGPS = nil
        firstAltitudeT = nil
        lastAltT = -Double.infinity
        lastImuT = -Double.infinity
        lastGpsT = -Double.infinity
        lastLandedT = -Double.infinity
        altitudeHistory.removeAll(keepingCapacity: true)
        imuHistory.removeAll(keepingCapacity: true)
        gpsHistory.removeAll(keepingCapacity: true)
        emittedPeakTimes.removeAll(keepingCapacity: true)
        nextCandidateID = 1
        audit(
            t: ProcessInfo.processInfo.systemUptime,
            stage: "engine",
            action: "reset",
            decision: "transition",
            labels: ["phaseBefore": "any", "phaseAfter": "idle"]
        )
    }

    // MARK: Inputs

    public func addAltitude(t: TimeInterval, altitudeM: Double) {
        guard t.isFinite, altitudeM.isFinite, t > lastAltT else {
            audit(
                t: t.isFinite ? t : ProcessInfo.processInfo.systemUptime,
                stage: "input",
                action: "altitude",
                decision: "dropped",
                reason: !t.isFinite || !altitudeM.isFinite ? "nonFinite" : "nonMonotonicTimestamp",
                values: ["altitudeM": altitudeM, "lastAltitudeT": lastAltT]
            )
            return
        }
        lastAltT = t
        if firstAltitudeT == nil { firstAltitudeT = t }
        let p = AltPt(t: t, alt: altitudeM)
        altitudeHistory.append(p)
        prune(&altitudeHistory, before: p.t - cfg.bufferSec)
        pruneEmittedPeaks(now: p.t)

        switch phase {
        case .idle:
            ingestIdleAltitude(p)

        case .airborne(var jump):
            ingestAirborneAltitude(p, jump: &jump)
        }

        // Do not scan arbitrary historical peaks here. The former buffered
        // origin path produced 14/14 false FINALs on the 2026-07-11 zero-jump
        // session, including stale classifications 46-56 seconds late.
    }

    public func addIMU(t: TimeInterval, accelG: Double, gyroRadS: Double) {
        guard t.isFinite, accelG.isFinite, gyroRadS.isFinite, t > lastImuT else {
            audit(
                t: t.isFinite ? t : ProcessInfo.processInfo.systemUptime,
                stage: "input",
                action: "imu",
                decision: "dropped",
                reason: !t.isFinite || !accelG.isFinite || !gyroRadS.isFinite ? "nonFinite" : "nonMonotonicTimestamp"
            )
            return
        }
        lastImuT = t

        let p = ImuPt(t: t, accelG: max(0, accelG), gyroRadS: max(0, gyroRadS))
        imuHistory.append(p)
        prune(&imuHistory, before: t - cfg.bufferSec)

        // The raw 200 Hz IMU stream is already in KSLG. In idle V13 deliberately
        // performs no IMU calculation, so structured records start only while a
        // candidate is airborne.
        guard case .airborne(var jump) = phase else { return }

        if t - jump.takeoffT <= 0.6 {
            jump.takeoffG = max(jump.takeoffG, p.accelG)
        }
        jump.peakG = max(jump.peakG, p.accelG)
        jump.maxGyro = max(jump.maxGyro, p.gyroRadS)

        if let prev = jump.previousIMU, p.t > prev.t {
            let dt = p.t - prev.t
            jump.rotationIntegral += p.gyroRadS * dt
            if p.accelG >= cfg.landingImpactG {
                let over = max(0, p.accelG - 1.0)
                jump.impactEnergy += over * over * dt
            }
        }
        jump.previousIMU = p
        phase = .airborne(jump)
        if t - jump.lastIMUAuditT >= cfg.structuredIMUAuditIntervalSec {
            jump.lastIMUAuditT = t
            phase = .airborne(jump)
            audit(
                t: t,
                stage: "motionMetrics",
                action: "integrateIMU",
                decision: "metricsOnly",
                candidateID: jump.candidateID,
                values: [
                    "accelG": p.accelG,
                    "gyroRadS": p.gyroRadS,
                    "takeoffG": jump.takeoffG,
                    "peakG": jump.peakG,
                    "maxGyroRadS": jump.maxGyro,
                    "rotationTurns": jump.rotationIntegral / (2 * .pi),
                    "impactEnergy": jump.impactEnergy,
                    "structuredAuditIntervalSec": cfg.structuredIMUAuditIntervalSec
                ],
                conditions: [
                    .init(id: "landingImpact", actual: p.accelG, comparator: ">=", expected: cfg.landingImpactG, passed: p.accelG >= cfg.landingImpactG, unit: "g")
                ]
            )
        }
    }

    public func addGPS(t: TimeInterval, lat: Double, lng: Double, speedMS: Double) {
        guard t.isFinite, t > lastGpsT else {
            audit(
                t: t.isFinite ? t : ProcessInfo.processInfo.systemUptime,
                stage: "input",
                action: "gps",
                decision: "dropped",
                reason: t.isFinite ? "nonMonotonicTimestamp" : "nonFiniteTimestamp"
            )
            return
        }
        lastGpsT = t
        let p = GpsPt(t: t, lat: lat, lng: lng, spd: max(0, speedMS))
        latestGPS = p
        gpsHistory.append(p)
        prune(&gpsHistory, before: t - cfg.bufferSec)
        audit(
            t: t,
            stage: "gpsMetrics",
            action: "storeGPS",
            decision: "metricsOnly",
            values: ["latitude": lat, "longitude": lng, "gpsSpeedMS": p.spd],
            labels: ["detectionGate": "false"]
        )
    }

    public func addSubmersion(t: TimeInterval, submerged: Bool) {
        // V13 simple mode intentionally does not use water/IMU as a condition.
        audit(
            t: t,
            stage: "input",
            action: "submersion",
            decision: "ignoredForDetection",
            values: ["submerged": submerged ? 1 : 0],
            labels: ["role": "diagnosticOnly"]
        )
    }

    public func flush(now: TimeInterval) -> [V13Jump] {
        let emittedAt = max(now, lastAltT)

        guard case .airborne(let jump) = phase else {
            audit(t: emittedAt, stage: "session", action: "flush", decision: "noActiveCandidate")
            return []
        }
        phase = .idle
        takeoffWindow.removeAll(keepingCapacity: true)

        if let stable = stableLanding(from: jump.landingWindow),
           let result = makeJump(from: jump, stable: stable, emittedAt: emittedAt, reason: "flush"),
           markPeakIfNew(result.apexT) {
            audit(
                t: emittedAt,
                stage: "session",
                action: "flush",
                decision: "accepted",
                candidateID: jump.candidateID,
                values: ["heightM": result.heightM, "airtimeSec": result.airtimeSec]
            )
            return [result]
        }

        audit(
            t: emittedAt,
            stage: "result",
            action: "candidateClosed",
            decision: "rejected",
            candidateID: jump.candidateID,
            reason: "sessionEndedBeforeStableLanding"
        )
        onDebug(emittedAt, "REJECT reason=sessionEndedBeforeStableLanding")
        return []
    }

    // MARK: Idle / takeoff

    private func ingestIdleAltitude(_ p: AltPt) {
        takeoffWindow.append(p)
        prune(&takeoffWindow, before: p.t - cfg.takeoffWindowSec - cfg.takeoffWindowSlackSec)

        guard let first = takeoffWindow.first else { return }
        let retriggerElapsed = p.t - lastLandedT
        let retriggerReady = !lastLandedT.isFinite || retriggerElapsed >= cfg.retriggerGuardSec
        let takeoffWindowDuration = p.t - first.t
        let takeoffWindowReady = takeoffWindowDuration >= cfg.takeoffWindowSec * 0.8
        let warmupElapsed = firstAltitudeT.map { first.t - $0 }
        let warmupReady = warmupElapsed.map { $0 >= cfg.startupWarmupSec } ?? false
        let baselineSampleCount = altitudeHistory.reduce(into: 0) { count, point in
            if point.t >= first.t - cfg.baselineWindowSec && point.t < first.t {
                count += 1
            }
        }
        let baseline = baselineStats(before: first.t)
        let baselineReady = baselineSampleCount >= cfg.minBaselineSamples && baseline != nil
        let baselineQuiet = baseline.map { $0.range <= cfg.maxBaselineNoiseRangeM }
        let takeoffFloorDelta = baseline.map { first.alt - $0.average }
        let takeoffFloorReady = takeoffFloorDelta.map { $0 >= -cfg.landingReturnBandM * 0.65 }
        let shortWindowRise = p.alt - first.alt
        let shortWindowReady = shortWindowRise >= cfg.candidateRiseM
        let baselineRise = baseline.map { p.alt - $0.average }
        let baselineRiseReady = baselineRise.map { $0 >= cfg.candidateRiseM }

        let firstFailure: String? = {
            if !retriggerReady { return "retriggerGuard" }
            if !takeoffWindowReady { return "takeoffWindowFilling" }
            if !warmupReady { return "sensorWarmup" }
            if !baselineReady { return "baselineNotReady" }
            if baselineQuiet == false { return "baselineNoisy" }
            if takeoffFloorReady == false { return "takeoffBelowBaseline" }
            if !shortWindowReady { return "shortWindowRise" }
            if baselineRiseReady == false { return "baselineRise" }
            return nil
        }()

        audit(
            t: p.t,
            stage: "takeoff",
            action: "evaluateCandidate",
            decision: firstFailure == nil ? "passed" : "waiting",
            reason: firstFailure,
            values: [
                "absoluteAltitudeM": p.alt,
                "firstWindowAltitudeM": first.alt,
                "takeoffWindowDurationSec": takeoffWindowDuration,
                "takeoffWindowSampleCount": Double(takeoffWindow.count),
                "warmupElapsedSec": warmupElapsed ?? .nan,
                "baselineAverageM": baseline?.average ?? .nan,
                "baselineRangeM": baseline?.range ?? .nan,
                "baselineSampleCount": Double(baselineSampleCount),
                "shortWindowRiseM": shortWindowRise,
                "baselineRiseM": baselineRise ?? .nan
            ],
            labels: ["phaseBefore": "idle", "phaseAfter": firstFailure == nil ? "airborne" : "idle"],
            conditions: [
                .init(id: "retriggerGuard", actual: finite(retriggerElapsed), comparator: ">=", expected: cfg.retriggerGuardSec, passed: retriggerReady, unit: "s"),
                .init(id: "takeoffWindowReady", actual: takeoffWindowDuration, comparator: ">=", expected: cfg.takeoffWindowSec * 0.8, passed: takeoffWindowReady, unit: "s"),
                .init(id: "sensorWarmup", actual: warmupElapsed, comparator: ">=", expected: cfg.startupWarmupSec, passed: warmupReady, unit: "s"),
                .init(id: "baselineSamples", actual: Double(baselineSampleCount), comparator: ">=", expected: Double(cfg.minBaselineSamples), passed: baselineReady, unit: "samples"),
                .init(id: "baselineNoise", actual: baseline?.range, comparator: "<=", expected: cfg.maxBaselineNoiseRangeM, passed: baselineQuiet, unit: "m"),
                .init(id: "takeoffFloor", actual: takeoffFloorDelta, comparator: ">=", expected: -cfg.landingReturnBandM * 0.65, passed: takeoffFloorReady, unit: "m"),
                .init(id: "shortWindowRise", actual: shortWindowRise, comparator: ">=", expected: cfg.candidateRiseM, passed: shortWindowReady, unit: "m"),
                .init(id: "baselineRise", actual: baselineRise, comparator: ">=", expected: cfg.candidateRiseM, passed: baselineRiseReady, unit: "m")
            ]
        )

        guard retriggerReady else { return }
        guard takeoffWindowReady else { return }
        guard warmupReady else {
            rejectDebug(p.t, "REJECT(candidate) reason=sensorWarmup")
            return
        }

        guard let baseline else {
            rejectDebug(p.t, "REJECT(candidate) reason=baselineNotReady")
            return
        }
        guard baseline.range <= cfg.maxBaselineNoiseRangeM else {
            rejectDebug(p.t, "REJECT(candidate) reason=baselineNoisy range=\(fmt(baseline.range))")
            return
        }
        guard first.alt >= baseline.average - cfg.landingReturnBandM * 0.65 else {
            rejectDebug(p.t, "REJECT(candidate) reason=takeoffBelowBaseline delta=\(fmt(first.alt - baseline.average))")
            return
        }
        // Gate against the baseline average, never against the lowest/first
        // point. A pressure dip followed by recovery should not become the
        // baseline by itself.
        guard shortWindowRise >= cfg.candidateRiseM else {
            rejectDebug(p.t, "REJECT(candidate) reason=shortWindowRise rise=\(fmt(shortWindowRise)) "
                + "min=\(fmt(cfg.candidateRiseM))")
            return
        }
        let rise = p.alt - baseline.average
        guard rise >= cfg.candidateRiseM else {
            rejectDebug(p.t, "REJECT(candidate) reason=baselineRise rise=\(fmt(rise)) "
                + "min=\(fmt(cfg.candidateRiseM))")
            return
        }

        beginJump(
            triggerT: first.t,
            baselineAlt: baseline.average,
            triggerAlt: p.alt,
            launchGPS: gpsPoint(near: first.t),
            altitudePointCount: takeoffWindow.count,
            maxAscentRate: ascentRate(in: takeoffWindow),
            triggerPoint: p
        )
    }

    private func beginJump(triggerT: TimeInterval,
                           baselineAlt: Double,
                           triggerAlt: Double,
                           launchGPS: GpsPt?,
                           altitudePointCount: Int,
                           maxAscentRate: Double,
                           triggerPoint p: AltPt) {
        let candidateID = nextCandidateID
        nextCandidateID += 1
        let jump = ActiveJump(
            candidateID: candidateID,
            takeoffT: triggerT,
            baselineAlt: baselineAlt,
            launchGPS: launchGPS,
            maxAlt: triggerAlt,
            apexT: p.t,
            previousAlt: p,
            landingWindow: [],
            altitudePointCount: altitudePointCount,
            maxAscentRate: maxAscentRate,
            maxDescentRate: 0,
            takeoffG: 0,
            landingG: 0,
            peakG: 0,
            maxGyro: 0,
            rotationIntegral: 0,
            impactEnergy: 0,
            previousIMU: nil,
            lastIMUAuditT: -Double.infinity
        )

        phase = .airborne(jump)
        audit(
            t: p.t,
            stage: "takeoff",
            action: "candidateOpened",
            decision: "transition",
            candidateID: candidateID,
            values: [
                "takeoffT": triggerT,
                "baselineAverageM": baselineAlt,
                "absoluteAltitudeM": triggerAlt,
                "baselineRiseM": triggerAlt - baselineAlt,
                "altitudePointCount": Double(altitudePointCount),
                "maxAscentRateMS": maxAscentRate,
                "launchGPSAvailable": launchGPS == nil ? 0 : 1
            ],
            labels: ["phaseBefore": "idle", "phaseAfter": "airborne"]
        )
        onDebug(p.t, "CANDIDATE altitude rise=\(fmt(triggerAlt - baselineAlt))m baseline=\(fmt(baselineAlt))")
        takeoffWindow.removeAll(keepingCapacity: true)
    }

    // MARK: Airborne / landing

    private func ingestAirborneAltitude(_ p: AltPt, jump: inout ActiveJump) {
        let previous = jump.previousAlt
        let verticalRate = p.t > previous.t ? (p.alt - previous.alt) / (p.t - previous.t) : 0
        let previousMaximum = jump.maxAlt
        updateRates(with: p, jump: &jump)
        jump.altitudePointCount += 1

        let isNewApex = p.alt > jump.maxAlt
        if isNewApex {
            jump.maxAlt = p.alt
            jump.apexT = p.t
            jump.landingWindow.removeAll(keepingCapacity: true)
        } else {
            let descendedFromPeak = jump.maxAlt - p.alt >= cfg.landingDescentM
            if descendedFromPeak {
                jump.landingWindow.append(p)
                prune(&jump.landingWindow, before: p.t - cfg.landingStableSec)
            } else {
                jump.landingWindow.removeAll(keepingCapacity: true)
            }
        }

        let descentFromPeak = jump.maxAlt - p.alt
        let returnedToBaseline = p.alt <= jump.baselineAlt + cfg.landingReturnBandM
        let descendedEnough = descentFromPeak >= cfg.landingDescentM
        let clearedBaseline = jump.maxAlt - jump.baselineAlt >= cfg.candidateRiseM
        let baselineReturnReady = returnedToBaseline && descendedEnough && clearedBaseline
        let flightElapsed = p.t - jump.takeoffT

        let landingFirst = jump.landingWindow.first
        let landingLast = jump.landingWindow.last
        let stableDuration = landingFirst.flatMap { first in landingLast.map { $0.t - first.t + 0.05 } }
        let landingValues = jump.landingWindow.map(\.alt)
        let stableRange = landingValues.min().flatMap { lo in landingValues.max().map { $0 - lo } }
        let stableDelta = landingFirst.flatMap { first in landingLast.map { abs($0.alt - first.alt) } }
        let stableTimeReady = stableDuration.map { $0 >= cfg.landingStableSec } ?? false
        let stableDeltaReady = stableDelta.map { $0 <= cfg.landingStableDeltaM }
        let stableRangeReady = stableRange.map { $0 <= cfg.landingStableRangeM }
        let stableLandingReady = stableTimeReady && stableDeltaReady == true && stableRangeReady == true

        let stepDecision: String
        if isNewApex {
            stepDecision = "newApex"
        } else if baselineReturnReady {
            stepDecision = "baselineReturnReady"
        } else if flightElapsed > cfg.maxFlightSec {
            stepDecision = "maxFlightExceeded"
        } else if stableLandingReady {
            stepDecision = "stableLandingReady"
        } else {
            stepDecision = "tracking"
        }

        audit(
            t: p.t,
            stage: isNewApex ? "apex" : "landing",
            action: "evaluateFlightSample",
            decision: stepDecision,
            candidateID: jump.candidateID,
            values: [
                "absoluteAltitudeM": p.alt,
                "previousAltitudeM": previous.alt,
                "previousApexAltitudeM": previousMaximum,
                "apexAltitudeM": jump.maxAlt,
                "heightM": jump.maxAlt - jump.baselineAlt,
                "descentFromPeakM": descentFromPeak,
                "landingReturnDeltaM": p.alt - jump.baselineAlt,
                "verticalRateMS": verticalRate,
                "maxAscentRateMS": jump.maxAscentRate,
                "maxDescentRateMS": jump.maxDescentRate,
                "flightElapsedSec": flightElapsed,
                "landingWindowDurationSec": stableDuration ?? .nan,
                "landingStableDeltaM": stableDelta ?? .nan,
                "landingStableRangeM": stableRange ?? .nan,
                "altitudePointCount": Double(jump.altitudePointCount)
            ],
            labels: ["phaseBefore": "airborne", "phaseAfter": baselineReturnReady || stableLandingReady ? "validation" : "airborne"],
            conditions: [
                .init(id: "newApex", actual: p.alt, comparator: ">", expected: previousMaximum, passed: isNewApex, unit: "m"),
                .init(id: "landingDescent", actual: descentFromPeak, comparator: ">=", expected: cfg.landingDescentM, passed: descendedEnough, unit: "m"),
                .init(id: "returnedToBaseline", actual: p.alt - jump.baselineAlt, comparator: "<=", expected: cfg.landingReturnBandM, passed: returnedToBaseline, unit: "m"),
                .init(id: "clearedBaseline", actual: jump.maxAlt - jump.baselineAlt, comparator: ">=", expected: cfg.candidateRiseM, passed: clearedBaseline, unit: "m"),
                .init(id: "maxFlight", actual: flightElapsed, comparator: "<=", expected: cfg.maxFlightSec, passed: flightElapsed <= cfg.maxFlightSec, unit: "s"),
                .init(id: "stableWindowTime", actual: stableDuration, comparator: ">=", expected: cfg.landingStableSec, passed: stableTimeReady, unit: "s"),
                .init(id: "stableWindowDelta", actual: stableDelta, comparator: "<=", expected: cfg.landingStableDeltaM, passed: stableDeltaReady, unit: "m"),
                .init(id: "stableWindowRange", actual: stableRange, comparator: "<=", expected: cfg.landingStableRangeM, passed: stableRangeReady, unit: "m")
            ]
        )

        if let landing = baselineReturnLanding(from: p, jump: jump) {
            audit(
                t: p.t,
                stage: "landing",
                action: "landingDetected",
                decision: "transition",
                candidateID: jump.candidateID,
                reason: "baselineReturn",
                values: ["landingT": landing.landingT, "postLandingBaselineM": landing.baseline],
                labels: ["phaseBefore": "airborne", "phaseAfter": "validation"]
            )
            if let result = makeJump(from: jump, stable: landing, emittedAt: p.t, reason: "baselineReturn") {
                if markPeakIfNew(result.apexT) {
                    delegate?.jumpDetected(result)
                    onDebug(p.t, "JUMP h=\(result.heightM)m air=\(result.airtimeSec)s baseline=\(result.baselinePostM ?? result.baselinePreM) latency=\(fmt(result.emittedAtT - result.landingT))s")
                } else {
                    audit(
                        t: p.t,
                        stage: "result",
                        action: "emitJump",
                        decision: "suppressed",
                        candidateID: jump.candidateID,
                        reason: "duplicateApex"
                    )
                }
            }
            lastLandedT = landing.landingT
            phase = .idle
            takeoffWindow = [p]
            return
        }

        if p.t - jump.takeoffT > cfg.maxFlightSec {
            audit(
                t: p.t,
                stage: "result",
                action: "candidateClosed",
                decision: "rejected",
                candidateID: jump.candidateID,
                reason: "maxFlightExceeded",
                values: ["airtimeSec": p.t - jump.takeoffT]
            )
            onDebug(p.t, "REJECT reason=maxFlightExceeded air=\(fmt(p.t - jump.takeoffT))")
            phase = .idle
            takeoffWindow = [p]
            return
        }

        if let stable = stableLanding(from: jump.landingWindow) {
            audit(
                t: p.t,
                stage: "landing",
                action: "landingDetected",
                decision: "transition",
                candidateID: jump.candidateID,
                reason: "stableLanding",
                values: [
                    "landingT": stable.landingT,
                    "postLandingBaselineM": stable.baseline,
                    "landingStableRangeM": stable.range
                ],
                labels: ["phaseBefore": "airborne", "phaseAfter": "validation"]
            )
            if let result = makeJump(from: jump, stable: stable, emittedAt: p.t, reason: "stableLanding") {
                if markPeakIfNew(result.apexT) {
                    delegate?.jumpDetected(result)
                    onDebug(p.t, "JUMP h=\(result.heightM)m air=\(result.airtimeSec)s baseline=\(result.baselinePostM ?? result.baselinePreM) latency=\(fmt(result.emittedAtT - result.landingT))s")
                } else {
                    audit(
                        t: p.t,
                        stage: "result",
                        action: "emitJump",
                        decision: "suppressed",
                        candidateID: jump.candidateID,
                        reason: "duplicateApex"
                    )
                }
            }
            lastLandedT = stable.landingT
            phase = .idle
            takeoffWindow = jump.landingWindow
            return
        }

        phase = .airborne(jump)
    }

    // MARK: Buffered altitude reconstruction

    private func scanBufferedAltitude(now: TimeInterval, allowOpenTail: Bool = false) {
        guard altitudeHistory.count >= 4 else { return }

        let lookbackSec = cfg.takeoffWindowSec + cfg.takeoffWindowSlackSec
        let minTakeoffDt = max(0.25, cfg.takeoffWindowSec * 0.45)
        let minDescentM = cfg.landingDescentM
        let postWindowSec = max(0.5, cfg.landingStableSec)

        for peakIdx in 1..<(altitudeHistory.count - 1) {
            let peak = altitudeHistory[peakIdx]
            guard peak.t <= now else { continue }
            guard !isPeakAlreadyEmitted(peak.t) else { continue }
            guard isBufferedLocalPeak(at: peakIdx) else { continue }
            guard allowOpenTail || now - peak.t >= min(0.8, postWindowSec) else { continue }

            guard let takeoffIdx = bufferedTakeoffIndex(
                beforePeakAt: peakIdx,
                lookbackSec: lookbackSec,
                minTakeoffDt: minTakeoffDt
            ) else { continue }

            let takeoff = altitudeHistory[takeoffIdx]
            guard peak.alt - takeoff.alt >= cfg.candidateRiseM else { continue }

            guard let landingIdx = bufferedStableLandingIndex(
                afterPeakAt: peakIdx,
                baseline: takeoff,
                peak: peak,
                minDescentM: minDescentM,
                postWindowSec: postWindowSec
            ) else { continue }

            let landing = altitudeHistory[landingIdx]
            guard allowOpenTail || now + 0.05 >= landing.t + postWindowSec else { continue }

            let postEnd = min(now, landing.t + postWindowSec)
            let postWindow = altitudeHistory.filter { $0.t >= landing.t && $0.t <= postEnd }
            let stable = relaxedLanding(from: postWindow, fallback: landing)
            guard stable.isStable else { continue }

            guard let result = makeBufferedJump(
                takeoffIdx: takeoffIdx,
                peakIdx: peakIdx,
                landingIdx: landingIdx,
                stable: stable,
                emittedAt: now
            ) else { continue }

            guard markPeakIfNew(result.apexT) else { continue }
            delegate?.jumpDetected(result)
            lastLandedT = max(lastLandedT, result.landingT)
            onDebug(now, "JUMP(buffered) h=\(result.heightM)m air=\(result.airtimeSec)s stable=\(stable.isStable) baseline=\(result.baselineRefM)")
        }
    }

    private func isBufferedLocalPeak(at idx: Int) -> Bool {
        guard idx > 0, idx + 1 < altitudeHistory.count else { return false }
        let p = altitudeHistory[idx]
        return p.alt >= altitudeHistory[idx - 1].alt && p.alt >= altitudeHistory[idx + 1].alt
    }

    private func bufferedTakeoffIndex(beforePeakAt peakIdx: Int,
                                      lookbackSec: Double,
                                      minTakeoffDt: Double) -> Int? {
        let peak = altitudeHistory[peakIdx]
        let candidates = (0..<peakIdx).filter { idx in
            let dt = peak.t - altitudeHistory[idx].t
            return dt >= minTakeoffDt && dt <= lookbackSec
        }

        let qualifying = candidates.filter { peak.alt - altitudeHistory[$0].alt >= cfg.candidateRiseM }
        return qualifying.min(by: { altitudeHistory[$0].alt < altitudeHistory[$1].alt })
    }

    private func bufferedLandingIndex(afterPeakAt peakIdx: Int,
                                      baseline: AltPt,
                                      peak: AltPt,
                                      minDescentM: Double) -> Int? {
        guard peakIdx + 1 < altitudeHistory.count else { return nil }

        let returnAltitude = baseline.alt + cfg.landingReturnBandM
        var firstDescent: Int?
        for idx in (peakIdx + 1)..<altitudeHistory.count {
            let p = altitudeHistory[idx]
            if p.alt <= returnAltitude {
                return idx
            }
            if firstDescent == nil, peak.alt - p.alt >= minDescentM {
                firstDescent = idx
            }
        }
        return firstDescent
    }

    private func bufferedStableLandingIndex(afterPeakAt peakIdx: Int,
                                            baseline: AltPt,
                                            peak: AltPt,
                                            minDescentM: Double,
                                            postWindowSec: Double) -> Int? {
        guard peakIdx + 1 < altitudeHistory.count else { return nil }

        let returnAltitude = baseline.alt + cfg.landingReturnBandM
        for idx in (peakIdx + 1)..<altitudeHistory.count {
            let p = altitudeHistory[idx]
            let returnedToBase = p.alt <= returnAltitude
            let descendedEnough = peak.alt - p.alt >= minDescentM
            guard returnedToBase || descendedEnough else { continue }

            let endT = p.t + postWindowSec
            let window = altitudeHistory.filter { $0.t >= p.t && $0.t <= endT }
            guard let last = window.last, last.t - p.t + 0.05 >= postWindowSec else { continue }
            if relaxedLanding(from: window, fallback: p).isStable {
                return idx
            }
        }
        return nil
    }

    private func relaxedLanding(from window: [AltPt],
                                fallback: AltPt) -> (landingT: TimeInterval, baseline: Double, range: Double, isStable: Bool) {
        let points = window.isEmpty ? [fallback] : window
        let values = points.map(\.alt)
        let lo = values.min() ?? fallback.alt
        let hi = values.max() ?? fallback.alt
        let delta = abs((points.last ?? fallback).alt - (points.first ?? fallback).alt)
        let range = hi - lo
        let isStable = delta <= cfg.landingStableDeltaM && range <= cfg.landingStableRangeM
        return (fallback.t, median(values), range, isStable)
    }

    private func makeBufferedJump(takeoffIdx: Int,
                                  peakIdx: Int,
                                  landingIdx: Int,
                                  stable: (landingT: TimeInterval, baseline: Double, range: Double, isStable: Bool),
                                  emittedAt: TimeInterval) -> V13Jump? {
        let takeoff = altitudeHistory[takeoffIdx]
        let peak = altitudeHistory[peakIdx]
        let landing = altitudeHistory[landingIdx]
        guard stable.isStable else {
            rejectDebug(emittedAt, "REJECT(buffered) reason=unstableLanding")
            return nil
        }
        // Height is measured from the pre-jump absolute-altitude baseline
        // average. The landing baseline is diagnostic only.
        guard let preStats = baselineStats(before: takeoff.t) else {
            rejectDebug(emittedAt, "REJECT(buffered) reason=baselineNotReady")
            return nil
        }
        let preBaseline = preStats.average
        let baselineShift = stable.baseline - preBaseline
        let baselineRef = preBaseline
        let height = peak.alt - baselineRef
        let airtime = landing.t - takeoff.t
        let landingGPS = gpsPoint(near: landing.t)
        let launchGPS = gpsPoint(near: takeoff.t)
        let distance = gpsDistance(from: launchGPS, to: landingGPS, airtime: airtime)
        let motion = motionEvidence(takeoffT: takeoff.t, landingT: landing.t)

        guard airtime >= cfg.minAirtimeSec, airtime <= cfg.maxAirtimeSec else {
            rejectDebug(emittedAt, "REJECT(buffered) reason=airtimeOutOfRange air=\(fmt(airtime))")
            return nil
        }
        guard emittedAt - landing.t <= cfg.maxResultDelaySec + 0.1 else {
            rejectDebug(emittedAt, "REJECT(buffered) reason=staleResult delay=\(fmt(emittedAt - landing.t))")
            return nil
        }
        guard landingIdx - takeoffIdx + 1 >= cfg.minArcSamples else {
            rejectDebug(emittedAt, "REJECT(buffered) reason=tooFewAltitudeSamples")
            return nil
        }
        let segment = Array(altitudeHistory[takeoffIdx...landingIdx])
        guard validateArcShape(points: segment,
                               baselineM: baselineRef,
                               peakM: peak.alt,
                               takeoffT: takeoff.t,
                               landingT: landing.t,
                               emittedAt: emittedAt,
                               debugPrefix: "REJECT(buffered)") else { return nil }
        guard abs(baselineShift) <= cfg.maxBaselineDriftM else {
            rejectDebug(emittedAt, "REJECT(buffered) reason=landingDatumShift delta=\(fmt(baselineShift))")
            return nil
        }
        // The user preference is intentionally last: first decide whether this
        // is a physically coherent jump, then decide whether it is counted.
        guard height >= cfg.minCountedHeightM else {
            rejectDebug(emittedAt, "REJECT(buffered) reason=belowCountedHeight "
                + "h=\(fmt(height)) min=\(fmt(cfg.minCountedHeightM))")
            return nil
        }
        let rates = altitudeRates(in: segment)
        let baselineShifted = abs(baselineShift) > cfg.landingReturnBandM
        let driftSuspect = abs(baselineShift) > cfg.maxBaselineDriftM

        var confidence = stable.isStable ? 0.72 : 0.58
        if height >= cfg.minCountedHeightM + 0.5 { confidence += 0.08 }
        if launchGPS != nil { confidence += 0.08 }
        if distance != nil { confidence += 0.04 }
        if baselineShifted { confidence -= 0.06 }
        if driftSuspect { confidence -= 0.12 }
        confidence = min(max(confidence, 0.05), 1.0)

        return V13Jump(
            heightM: round2(height),
            airtimeSec: round2(airtime),
            takeoffT: takeoff.t,
            landingT: landing.t,
            apexT: peak.t,
            peakAltitudeM: round2(peak.alt),
            baselinePreM: round2(preBaseline),
            baselinePostM: round2(stable.baseline),
            baselineRefM: round2(baselineRef),
            baselineShifted: baselineShifted,
            driftSuspect: driftSuspect,
            maxAscentRateMS: round2(rates.ascent),
            maxDescentRateMS: round2(rates.descent),
            takeoffG: round2(motion.takeoffG),
            landingG: round2(motion.landingG),
            peakG: round2(motion.peakG),
            prePopImpulseG: round2(motion.takeoffG),
            maxRotationRadS: round2(motion.maxGyro),
            rotationTurns: round2(motion.rotationIntegral / (2 * .pi)),
            impactEnergy: round2(motion.impactEnergy),
            takeoffSpeedMS: launchGPS.map { round2($0.spd) },
            landingSpeedMS: landingGPS.map { round2($0.spd) },
            distanceM: distance.map(round2),
            launchLat: coordinate(launchGPS?.lat, launchGPS?.lng)?.lat,
            launchLng: coordinate(launchGPS?.lat, launchGPS?.lng)?.lng,
            landingLat: coordinate(landingGPS?.lat, landingGPS?.lng)?.lat,
            landingLng: coordinate(landingGPS?.lat, landingGPS?.lng)?.lng,
            altitudePointCount: segment.count,
            confidence: confidence,
            triggerSource: .altitude,
            emittedAtT: emittedAt,
            profile: [
                V13ProfilePoint(tOffsetSec: 0, relHeightM: round2(takeoff.alt - baselineRef)),
                V13ProfilePoint(tOffsetSec: round2(peak.t - takeoff.t), relHeightM: round2(peak.alt - baselineRef)),
                V13ProfilePoint(tOffsetSec: round2(landing.t - takeoff.t), relHeightM: round2(landing.alt - baselineRef))
            ]
        )
    }

    private func stableLanding(from window: [AltPt]) -> (landingT: TimeInterval, baseline: Double, range: Double)? {
        guard let first = window.first, let last = window.last else { return nil }
        guard last.t - first.t + 0.05 >= cfg.landingStableSec else { return nil }

        let values = window.map(\.alt)
        guard let lo = values.min(), let hi = values.max() else { return nil }
        let delta = abs(last.alt - first.alt)
        let range = hi - lo
        guard delta <= cfg.landingStableDeltaM, range <= cfg.landingStableRangeM else { return nil }

        return (first.t, median(values), range)
    }

    private func baselineReturnLanding(from p: AltPt,
                                       jump: ActiveJump) -> (landingT: TimeInterval, baseline: Double, range: Double)? {
        let returnedToBaseline = p.alt <= jump.baselineAlt + cfg.landingReturnBandM
        let descendedFromPeak = jump.maxAlt - p.alt >= cfg.landingDescentM
        let clearedBaseline = jump.maxAlt - jump.baselineAlt >= cfg.candidateRiseM
        guard returnedToBaseline, descendedFromPeak, clearedBaseline else { return nil }
        return (p.t, p.alt, 0)
    }

    private func makeJump(from jump: ActiveJump,
                          stable: (landingT: TimeInterval, baseline: Double, range: Double),
                          emittedAt: TimeInterval,
                          reason: String) -> V13Jump? {
        // Height is measured from the pre-jump absolute-altitude baseline
        // average. The landing baseline is diagnostic only.
        let baselineRef = jump.baselineAlt
        let height = jump.maxAlt - baselineRef
        let airtime = stable.landingT - jump.takeoffT
        let landingGPS = gpsPoint(near: stable.landingT)
        let distance = gpsDistance(from: jump.launchGPS, to: landingGPS, airtime: airtime)
        let motion = motionEvidence(takeoffT: jump.takeoffT, landingT: stable.landingT)
        let resultDelay = emittedAt - stable.landingT

        audit(
            t: emittedAt,
            stage: "metrics",
            action: "calculateCandidateMetrics",
            decision: "calculated",
            candidateID: jump.candidateID,
            values: [
                "heightM": height,
                "airtimeSec": airtime,
                "takeoffT": jump.takeoffT,
                "landingT": stable.landingT,
                "apexT": jump.apexT,
                "baselineAverageM": jump.baselineAlt,
                "postLandingBaselineM": stable.baseline,
                "apexAltitudeM": jump.maxAlt,
                "resultDelaySec": resultDelay,
                "altitudePointCount": Double(jump.altitudePointCount),
                "takeoffG": motion.takeoffG,
                "landingG": motion.landingG,
                "peakG": motion.peakG,
                "maxGyroRadS": motion.maxGyro,
                "rotationTurns": motion.rotationIntegral / (2 * .pi),
                "impactEnergy": motion.impactEnergy,
                "takeoffSpeedMS": jump.launchGPS?.spd ?? .nan,
                "landingSpeedMS": landingGPS?.spd ?? .nan,
                "distanceM": distance ?? .nan
            ],
            labels: [
                "landingMethod": reason,
                "distanceMethod": jump.launchGPS != nil && landingGPS != nil ? "haversine" : (jump.launchGPS != nil ? "speedTimesAirtime" : "unavailable")
            ]
        )

        guard airtime >= cfg.minAirtimeSec, airtime <= cfg.maxAirtimeSec else {
            audit(
                t: emittedAt,
                stage: "validation",
                action: "airtimeRange",
                decision: "rejected",
                candidateID: jump.candidateID,
                reason: "airtimeOutOfRange",
                values: ["airtimeSec": airtime],
                conditions: [
                    .init(id: "minimumAirtime", actual: airtime, comparator: ">=", expected: cfg.minAirtimeSec, passed: airtime >= cfg.minAirtimeSec, unit: "s"),
                    .init(id: "maximumAirtime", actual: airtime, comparator: "<=", expected: cfg.maxAirtimeSec, passed: airtime <= cfg.maxAirtimeSec, unit: "s")
                ]
            )
            onDebug(emittedAt, "REJECT reason=airtimeOutOfRange air=\(fmt(airtime)) via=\(reason)")
            return nil
        }
        audit(
            t: emittedAt,
            stage: "validation",
            action: "airtimeRange",
            decision: "passed",
            candidateID: jump.candidateID,
            values: ["airtimeSec": airtime]
        )

        guard resultDelay <= cfg.maxResultDelaySec + 0.1 else {
            audit(
                t: emittedAt,
                stage: "validation",
                action: "resultFreshness",
                decision: "rejected",
                candidateID: jump.candidateID,
                reason: "staleResult",
                values: ["resultDelaySec": resultDelay],
                conditions: [
                    .init(id: "resultFreshness", actual: resultDelay, comparator: "<=", expected: cfg.maxResultDelaySec + 0.1, passed: false, unit: "s")
                ]
            )
            onDebug(emittedAt, "REJECT reason=staleResult delay=\(fmt(resultDelay))")
            return nil
        }
        audit(t: emittedAt, stage: "validation", action: "resultFreshness", decision: "passed", candidateID: jump.candidateID, values: ["resultDelaySec": resultDelay])

        guard jump.altitudePointCount >= cfg.minArcSamples else {
            audit(
                t: emittedAt,
                stage: "validation",
                action: "altitudeSampleCount",
                decision: "rejected",
                candidateID: jump.candidateID,
                reason: "tooFewAltitudeSamples",
                values: ["altitudePointCount": Double(jump.altitudePointCount)],
                conditions: [
                    .init(id: "minimumArcSamples", actual: Double(jump.altitudePointCount), comparator: ">=", expected: Double(cfg.minArcSamples), passed: false, unit: "samples")
                ]
            )
            onDebug(emittedAt, "REJECT reason=tooFewAltitudeSamples n=\(jump.altitudePointCount)")
            return nil
        }
        audit(t: emittedAt, stage: "validation", action: "altitudeSampleCount", decision: "passed", candidateID: jump.candidateID, values: ["altitudePointCount": Double(jump.altitudePointCount)])

        let segment = altitudeHistory.filter { $0.t >= jump.takeoffT && $0.t <= stable.landingT }
        guard validateArcShape(points: segment,
                               baselineM: baselineRef,
                               peakM: jump.maxAlt,
                               takeoffT: jump.takeoffT,
                               landingT: stable.landingT,
                               emittedAt: emittedAt,
                               debugPrefix: "REJECT",
                               candidateID: jump.candidateID) else { return nil }
        let baselineShift = stable.baseline - jump.baselineAlt
        guard abs(baselineShift) <= cfg.maxBaselineDriftM else {
            audit(
                t: emittedAt,
                stage: "validation",
                action: "baselineDrift",
                decision: "rejected",
                candidateID: jump.candidateID,
                reason: "landingDatumShift",
                values: ["baselineShiftM": baselineShift],
                conditions: [
                    .init(id: "baselineDrift", actual: abs(baselineShift), comparator: "<=", expected: cfg.maxBaselineDriftM, passed: false, unit: "m")
                ]
            )
            onDebug(emittedAt, "REJECT reason=landingDatumShift delta=\(fmt(baselineShift)) via=\(reason)")
            return nil
        }
        audit(t: emittedAt, stage: "validation", action: "baselineDrift", decision: "passed", candidateID: jump.candidateID, values: ["baselineShiftM": baselineShift])

        // Run every sensor/shape validator before applying the user's display
        // preference. It is a counted-height decision, not a jump detector gate.
        guard height >= cfg.minCountedHeightM else {
            audit(
                t: emittedAt,
                stage: "validation",
                action: "countedHeight",
                decision: "rejected",
                candidateID: jump.candidateID,
                reason: "belowCountedHeight",
                values: ["heightM": height],
                conditions: [
                    .init(id: "countedHeight", actual: height, comparator: ">=", expected: cfg.minCountedHeightM, passed: false, unit: "m")
                ]
            )
            onDebug(emittedAt, "REJECT reason=belowCountedHeight h=\(fmt(height)) "
                + "min=\(fmt(cfg.minCountedHeightM)) via=\(reason)")
            return nil
        }
        audit(t: emittedAt, stage: "validation", action: "countedHeight", decision: "passed", candidateID: jump.candidateID, values: ["heightM": height])
        let baselineShifted = abs(baselineShift) > cfg.landingReturnBandM
        let driftSuspect = abs(baselineShift) > cfg.maxBaselineDriftM

        var confidence = 0.65
        if stable.range <= cfg.landingStableDeltaM { confidence += 0.1 }
        if jump.launchGPS != nil { confidence += 0.1 }
        if distance != nil { confidence += 0.05 }
        if driftSuspect { confidence -= 0.15 }
        confidence = min(max(confidence, 0.05), 1.0)

        let result = V13Jump(
            heightM: round2(height),
            airtimeSec: round2(airtime),
            takeoffT: jump.takeoffT,
            landingT: stable.landingT,
            apexT: jump.apexT,
            peakAltitudeM: round2(jump.maxAlt),
            baselinePreM: round2(jump.baselineAlt),
            baselinePostM: round2(stable.baseline),
            baselineRefM: round2(baselineRef),
            baselineShifted: baselineShifted,
            driftSuspect: driftSuspect,
            maxAscentRateMS: round2(jump.maxAscentRate),
            maxDescentRateMS: round2(jump.maxDescentRate),
            takeoffG: round2(motion.takeoffG),
            landingG: round2(motion.landingG),
            peakG: round2(motion.peakG),
            prePopImpulseG: round2(motion.takeoffG),
            maxRotationRadS: round2(motion.maxGyro),
            rotationTurns: round2(motion.rotationIntegral / (2 * .pi)),
            impactEnergy: round2(motion.impactEnergy),
            takeoffSpeedMS: jump.launchGPS.map { round2($0.spd) },
            landingSpeedMS: landingGPS.map { round2($0.spd) },
            distanceM: distance.map(round2),
            launchLat: coordinate(jump.launchGPS?.lat, jump.launchGPS?.lng)?.lat,
            launchLng: coordinate(jump.launchGPS?.lat, jump.launchGPS?.lng)?.lng,
            landingLat: coordinate(landingGPS?.lat, landingGPS?.lng)?.lat,
            landingLng: coordinate(landingGPS?.lat, landingGPS?.lng)?.lng,
            altitudePointCount: jump.altitudePointCount,
            confidence: confidence,
            triggerSource: .altitude,
            emittedAtT: emittedAt,
            profile: [
                V13ProfilePoint(tOffsetSec: 0, relHeightM: round2(jump.baselineAlt - baselineRef)),
                V13ProfilePoint(tOffsetSec: round2(jump.apexT - jump.takeoffT), relHeightM: round2(jump.maxAlt - baselineRef)),
                V13ProfilePoint(tOffsetSec: round2(stable.landingT - jump.takeoffT), relHeightM: 0)
            ]
        )
        audit(
            t: emittedAt,
            stage: "result",
            action: "emitJump",
            decision: "accepted",
            candidateID: jump.candidateID,
            values: [
                "heightM": result.heightM,
                "airtimeSec": result.airtimeSec,
                "apexAltitudeM": result.peakAltitudeM,
                "baselineAverageM": result.baselinePreM,
                "postLandingBaselineM": result.baselinePostM ?? result.baselinePreM,
                "maxAscentRateMS": result.maxAscentRateMS,
                "maxDescentRateMS": result.maxDescentRateMS,
                "takeoffSpeedMS": result.takeoffSpeedMS ?? .nan,
                "landingSpeedMS": result.landingSpeedMS ?? .nan,
                "distanceM": result.distanceM ?? .nan,
                "confidence": result.confidence,
                "resultDelaySec": result.emittedAtT - result.landingT
            ],
            labels: ["landingMethod": reason, "triggerSource": result.triggerSource.rawValue]
        )
        return result
    }

    // MARK: Helpers

    /// A height value has no upper validity limit. Every sampled curve needs an
    /// interior apex and a deliberately lenient physical airtime. When that
    /// height implies a multi-second flight, it must also contain a progressive
    /// ascent and descent. This preserves sparse ~1 Hz small jumps while
    /// rejecting large rectangular datum/noise pulses.
    private func validateArcShape(points: [AltPt],
                                  baselineM: Double,
                                  peakM: Double,
                                  takeoffT: TimeInterval,
                                  landingT: TimeInterval,
                                  emittedAt: TimeInterval,
                                  debugPrefix: String,
                                  candidateID: Int? = nil) -> Bool {
        let height = peakM - baselineM
        let peakIdx = points.indices.max(by: { points[$0].alt < points[$1].alt })
        let hasInteriorPeak = height > 0
            && points.count >= 3
            && peakIdx.map { $0 > points.startIndex && $0 < points.index(before: points.endIndex) } == true
        guard hasInteriorPeak, let peakIdx else {
            audit(
                t: emittedAt,
                stage: "validation",
                action: "arcShape",
                decision: "rejected",
                candidateID: candidateID,
                reason: "arcMissingInteriorPeak",
                values: ["heightM": height, "altitudePointCount": Double(points.count)],
                conditions: [
                    .init(id: "interiorApex", actual: peakIdx.map(Double.init), comparator: "inside", expected: points.count >= 2 ? Double(points.count - 1) : nil, passed: false, unit: "index")
                ]
            )
            onDebug(emittedAt, "\(debugPrefix) reason=arcMissingInteriorPeak")
            return false
        }

        let airtime = landingT - takeoffT
        let ballisticAirtime = 2.0 * sqrt(2.0 * height / 9.80665)
        let minimumCoherentAirtime = max(cfg.minAirtimeSec, ballisticAirtime * 0.55)
        guard airtime + 0.05 >= minimumCoherentAirtime else {
            audit(
                t: emittedAt,
                stage: "validation",
                action: "arcPhysics",
                decision: "rejected",
                candidateID: candidateID,
                reason: "arcTooFast",
                values: [
                    "heightM": height,
                    "airtimeSec": airtime,
                    "ballisticAirtimeSec": ballisticAirtime,
                    "minimumCoherentAirtimeSec": minimumCoherentAirtime
                ],
                conditions: [
                    .init(id: "coherentAirtime", actual: airtime + 0.05, comparator: ">=", expected: minimumCoherentAirtime, passed: false, unit: "s")
                ]
            )
            onDebug(emittedAt, "\(debugPrefix) reason=arcTooFast air=\(fmt(airtime)) "
                + "min=\(fmt(minimumCoherentAirtime)) h=\(fmt(height))")
            return false
        }

        // At the measured ~1 Hz effective cadence, short real jumps may contain
        // only one ascent and one descent frame. Once the height-implied minimum
        // flight spans at least two seconds, a real arc must expose intermediate
        // samples on both sides; a datum pulse/plateau will not.
        guard minimumCoherentAirtime >= 2.0 else {
            audit(
                t: emittedAt,
                stage: "validation",
                action: "arcShape",
                decision: "passed",
                candidateID: candidateID,
                values: [
                    "heightM": height,
                    "airtimeSec": airtime,
                    "ballisticAirtimeSec": ballisticAirtime,
                    "minimumCoherentAirtimeSec": minimumCoherentAirtime,
                    "altitudePointCount": Double(points.count)
                ],
                labels: ["progressiveStepCheck": "notRequiredForShortArc"]
            )
            return true
        }

        let meaningfulStepM = max(0.05, min(0.5, height * 0.03))
        var ascentSteps = 0
        if peakIdx > points.startIndex {
            for idx in points.index(after: points.startIndex)...peakIdx {
                let previous = points.index(before: idx)
                if points[idx].alt - points[previous].alt >= meaningfulStepM {
                    ascentSteps += 1
                }
            }
        }

        var descentSteps = 0
        if peakIdx < points.index(before: points.endIndex) {
            for idx in points.index(after: peakIdx)..<points.endIndex {
                let previous = points.index(before: idx)
                if points[previous].alt - points[idx].alt >= meaningfulStepM {
                    descentSteps += 1
                }
            }
        }

        let lowerBand = baselineM + height * 0.1
        let upperBand = baselineM + height * 0.9
        let hasAscentInterior = points[..<peakIdx].contains { $0.alt > lowerBand && $0.alt < upperBand }
        let descentStart = points.index(after: peakIdx)
        let hasDescentInterior = points[descentStart...].contains { $0.alt > lowerBand && $0.alt < upperBand }
        guard ascentSteps >= 2, descentSteps >= 2, hasAscentInterior, hasDescentInterior else {
            audit(
                t: emittedAt,
                stage: "validation",
                action: "arcProgression",
                decision: "rejected",
                candidateID: candidateID,
                reason: "arcNotProgressive",
                values: [
                    "ascentStepCount": Double(ascentSteps),
                    "descentStepCount": Double(descentSteps),
                    "meaningfulStepM": meaningfulStepM,
                    "ascentInteriorPresent": hasAscentInterior ? 1 : 0,
                    "descentInteriorPresent": hasDescentInterior ? 1 : 0
                ],
                conditions: [
                    .init(id: "progressiveAscent", actual: Double(ascentSteps), comparator: ">=", expected: 2, passed: ascentSteps >= 2, unit: "steps"),
                    .init(id: "progressiveDescent", actual: Double(descentSteps), comparator: ">=", expected: 2, passed: descentSteps >= 2, unit: "steps"),
                    .init(id: "ascentInterior", actual: hasAscentInterior ? 1 : 0, comparator: "==", expected: 1, passed: hasAscentInterior),
                    .init(id: "descentInterior", actual: hasDescentInterior ? 1 : 0, comparator: "==", expected: 1, passed: hasDescentInterior)
                ]
            )
            onDebug(emittedAt, "\(debugPrefix) reason=arcNotProgressive "
                + "up=\(ascentSteps) down=\(descentSteps) midUp=\(hasAscentInterior) midDown=\(hasDescentInterior)")
            return false
        }

        audit(
            t: emittedAt,
            stage: "validation",
            action: "arcProgression",
            decision: "passed",
            candidateID: candidateID,
            values: [
                "ascentStepCount": Double(ascentSteps),
                "descentStepCount": Double(descentSteps),
                "meaningfulStepM": meaningfulStepM
            ]
        )
        return true
    }

    private func updateRates(with p: AltPt, jump: inout ActiveJump) {
        let prev = jump.previousAlt
        if p.t > prev.t {
            let rate = (p.alt - prev.alt) / (p.t - prev.t)
            jump.maxAscentRate = max(jump.maxAscentRate, rate)
            jump.maxDescentRate = min(jump.maxDescentRate, rate)
        }
        jump.previousAlt = p
    }

    private func ascentRate(in points: [AltPt]) -> Double {
        guard points.count >= 2 else { return 0 }
        var best = 0.0
        for idx in 1..<points.count {
            let a = points[idx - 1]
            let b = points[idx]
            guard b.t > a.t else { continue }
            best = max(best, (b.alt - a.alt) / (b.t - a.t))
        }
        return best
    }

    private func altitudeRates(in points: [AltPt]) -> (ascent: Double, descent: Double) {
        guard points.count >= 2 else { return (0, 0) }
        var ascent = 0.0
        var descent = 0.0
        for idx in 1..<points.count {
            let a = points[idx - 1]
            let b = points[idx]
            guard b.t > a.t else { continue }
            let rate = (b.alt - a.alt) / (b.t - a.t)
            ascent = max(ascent, rate)
            descent = min(descent, rate)
        }
        return (ascent, descent)
    }

    private func rejectDebug(_ t: TimeInterval, _ msg: String) {
        guard msg != lastRejectDebug else { return }
        lastRejectDebug = msg
        onDebug(t, msg)
    }

    private func audit(t: TimeInterval,
                       stage: String,
                       action: String,
                       decision: String,
                       candidateID: Int? = nil,
                       reason: String? = nil,
                       values: [String: Double] = [:],
                       labels: [String: String] = [:],
                       conditions: [V13AuditCondition] = []) {
        onAudit(V13AuditRecord(
            monotonicTime: t,
            stage: stage,
            action: action,
            decision: decision,
            candidateID: candidateID,
            reason: reason,
            values: values,
            labels: labels,
            conditions: conditions
        ))
    }

    private func finite(_ value: Double) -> Double? {
        value.isFinite ? value : nil
    }

    private func prune(_ points: inout [AltPt], before cutoff: TimeInterval) {
        // AltPt also backs the short takeoff window, whose first point defines
        // takeoff time. Expire it immediately; this stream is only a few Hz.
        pruneExpiredPrefix(&points, before: cutoff, minimumBatch: 1) { $0.t }
    }

    private func prune(_ points: inout [ImuPt], before cutoff: TimeInterval) {
        // `Array.removeFirst()` for every 200 Hz sample shifted the entire
        // 60-second (~12k item) history on every callback after warm-up. Remove
        // expired samples in one contiguous batch instead.
        pruneExpiredPrefix(&points, before: cutoff, minimumBatch: 256) { $0.t }
    }

    private func prune(_ points: inout [GpsPt], before cutoff: TimeInterval) {
        pruneExpiredPrefix(&points, before: cutoff, minimumBatch: 1) { $0.t }
    }

    private func pruneExpiredPrefix<T>(_ points: inout [T],
                                       before cutoff: TimeInterval,
                                       minimumBatch: Int,
                                       timestamp: (T) -> TimeInterval) {
        guard points.count >= minimumBatch,
              timestamp(points[0]) < cutoff else { return }

        var end = 0
        while end < points.count, timestamp(points[end]) < cutoff {
            end += 1
        }
        guard end >= minimumBatch else { return }
        points.removeFirst(end)
    }

    private func pruneEmittedPeaks(now: TimeInterval) {
        emittedPeakTimes.removeAll { now - $0 > cfg.bufferSec }
    }

    private func isPeakAlreadyEmitted(_ peakT: TimeInterval) -> Bool {
        let minSeparation = max(2.0, cfg.retriggerGuardSec)
        return emittedPeakTimes.contains { abs($0 - peakT) < minSeparation }
    }

    private func markPeakIfNew(_ peakT: TimeInterval) -> Bool {
        guard !isPeakAlreadyEmitted(peakT) else { return false }
        emittedPeakTimes.append(peakT)
        return true
    }

    private func gpsPoint(near t: TimeInterval) -> GpsPt? {
        gpsHistory
            .filter { abs($0.t - t) <= cfg.gpsMatchToleranceSec }
            .min { abs($0.t - t) < abs($1.t - t) }
    }

    private func motionEvidence(takeoffT: TimeInterval, landingT: TimeInterval) -> MotionEvidence {
        let takeoff = imuHistory.filter {
            $0.t >= takeoffT - cfg.takeoffEvidenceLeadSec
                && $0.t <= takeoffT + cfg.takeoffEvidenceTailSec
        }
        let landing = imuHistory.filter {
            $0.t >= landingT - cfg.landingEvidenceWindowSec
                && $0.t <= landingT + cfg.landingEvidenceWindowSec
        }
        let arc = imuHistory.filter {
            $0.t >= takeoffT - cfg.takeoffEvidenceLeadSec
                && $0.t <= landingT + cfg.landingEvidenceWindowSec
        }

        var rotationIntegral = 0.0
        var impactEnergy = 0.0
        if arc.count >= 2 {
            for idx in 1..<arc.count {
                let previous = arc[idx - 1]
                let current = arc[idx]
                let dt = max(0, current.t - previous.t)
                rotationIntegral += current.gyroRadS * dt
                if current.accelG >= cfg.landingImpactG {
                    let over = max(0, current.accelG - 1.0)
                    impactEnergy += over * over * dt
                }
            }
        }

        return MotionEvidence(
            takeoffG: takeoff.map(\.accelG).max() ?? 0,
            landingG: landing.map(\.accelG).max() ?? 0,
            peakG: arc.map(\.accelG).max() ?? 0,
            maxGyro: arc.map(\.gyroRadS).max() ?? 0,
            rotationIntegral: rotationIntegral,
            impactEnergy: impactEnergy
        )
    }

    private func gpsDistance(from a: GpsPt?, to b: GpsPt?, airtime: Double) -> Double? {
        if let a, let b, coordinate(a.lat, a.lng) != nil, coordinate(b.lat, b.lng) != nil {
            return haversineM(a.lat, a.lng, b.lat, b.lng)
        }
        if let a {
            return a.spd * airtime
        }
        return nil
    }

    private func coordinate(_ lat: Double?, _ lng: Double?) -> (lat: Double, lng: Double)? {
        guard let lat, let lng, lat != 0 || lng != 0 else { return nil }
        return (lat, lng)
    }

    private func haversineM(_ lat1: Double, _ lng1: Double, _ lat2: Double, _ lng2: Double) -> Double {
        let r = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLng = (lng2 - lng1) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLng / 2) * sin(dLng / 2)
        return 2 * r * asin(min(1, h.squareRoot()))
    }

    private func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    private func baselineStats(before t: TimeInterval) -> BaselineStats? {
        let values = altitudeHistory
            .filter { $0.t >= t - cfg.baselineWindowSec && $0.t < t }
            .map(\.alt)
        guard values.count >= cfg.minBaselineSamples,
              let lo = values.min(), let hi = values.max() else { return nil }
        return BaselineStats(average: average(values), range: hi - lo, count: values.count)
    }

    /// Average altitude over the `baselineWindowSec` seconds strictly before
    /// `t`. Kept for the dormant buffered-refinement code; live candidates use
    /// `baselineStats`.
    private func robustBaseline(before t: TimeInterval, fallback: Double) -> Double {
        baselineStats(before: t)?.average ?? fallback
    }

    private func round2(_ v: Double) -> Double {
        (v * 100).rounded() / 100
    }

    private func fmt(_ v: Double) -> String {
        String(format: "%.2f", v)
    }
}
