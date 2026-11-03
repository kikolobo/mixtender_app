//
//  ScaleZero.swift
//  MixBot
//

import Foundation
import Observation

// Scale setup over BLE ("K" messages, PROTOCOL.md §A.8, since v7). Three
// settings, all saved in flash by the robot:
// - the empty-tray weight: cup detection and the "cup is not empty" check use
//   the scale reading minus this. The load cell's zero drifts, so a stale
//   value makes an empty cup read as "Cup is not empty". Zeroing (KZ) with
//   the tray empty re-measures it.
// - the cup weight window, above the empty tray:
//     ≤ min cup weight     → "Please add a cup" (no cup)
//     min … max            → "Ready!" ($1=1)
//     > max cup weight     → "Cup is not empty"
//   KN=<grams> / KM=<grams>, both 5–2000 g, min at least 20 g below max.

/// The robot's `K=<absolute>,<emptyTray>,<defaultTray>,<traySaved>,
/// <maxCup>,<defaultMaxCup>,<maxCupSaved>,<minCup>,<defaultMinCup>,<minCupSaved>` reply.
struct ScaleReading: Equatable {
    /// What the robot reads above the empty tray right now (≈ 0 when empty)
    var absolute: Double
    /// The empty-tray weight in use
    var emptyTray: Double
    /// The factory empty-tray weight
    var defaultEmptyTray: Double
    /// An empty-tray value is saved in flash; false = never zeroed, running on the factory value
    var traySaved: Bool
    /// The heaviest empty cup accepted, in use
    var maxCup: Double
    var defaultMaxCup: Double
    var maxCupSaved: Bool
    /// The lightest empty cup accepted (at or below = no cup), in use
    var minCup: Double
    var defaultMinCup: Double
    var minCupSaved: Bool
}

enum ScaleMessage: Equatable {
    case reading(ScaleReading)
    case error(String)
}

/// Parses a `K=` reading (10 fields; extra trailing fields are ignored, as the
/// protocol asks) or `KE=<code>`. Returns nil for anything else.
func parseScaleMessage(_ input: String) -> ScaleMessage? {
    guard input.first == "K" else { return nil }
    let parts = input.dropFirst().split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }

    let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
    switch parts[0] {
    case "E":
        return .error(value)
    case "":
        let fields = value.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count >= 10 else { return nil }
        let numbers = fields.prefix(10).compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count == 10 else { return nil }
        return .reading(ScaleReading(absolute: numbers[0],
                                     emptyTray: numbers[1],
                                     defaultEmptyTray: numbers[2],
                                     traySaved: numbers[3] == 1,
                                     maxCup: numbers[4],
                                     defaultMaxCup: numbers[5],
                                     maxCupSaved: numbers[6] == 1,
                                     minCup: numbers[7],
                                     defaultMinCup: numbers[8],
                                     minCupSaved: numbers[9] == 1))
    default:
        return nil
    }
}

/// Scale zero session state. Every K command gets exactly one reply, so
/// replies are matched to commands in order.
@Observable
@MainActor
final class ScaleZero {
    enum Availability: Equatable {
        case idle
        case checking
        case available
        case unsupported
    }

    /// Firmware before v7 ignores K?; no reply in this window means "not supported"
    nonisolated static let replyTimeout: Duration = .milliseconds(1500)

    /// Allowed min and max cup weight (KN= / KM=)
    nonisolated static let cupLimitRange: ClosedRange<Double> = 5...2000
    /// The min must stay at least this far below the max
    nonisolated static let minCupGap = 20.0
    /// Margins around a measured empty cup when suggesting the window
    nonisolated static let minCupMargin = 30.0
    nonisolated static let maxCupMargin = 50.0
    nonisolated static let rangeNotice = "Enter 5–2000 g, with min at least 20 g below max."

    private(set) var availability: Availability = .idle
    private(set) var reading: ScaleReading?
    /// Waiting for the reply to a command that changes a setting
    private(set) var isWorking = false
    /// Set when a KZ succeeded; cleared when a new zero starts
    private(set) var didZero = false
    /// Last error or notice for the UI; the view clears it
    var notice: String?

    /// Writes one command to the robot; installed by RemoteEngine
    @ObservationIgnored var transmit: (String) -> Void = { _ in }

    /// Sent commands awaiting their reply, oldest first
    @ObservationIgnored private var inFlight: [String] = []
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private let replyTimeout: Duration

    init(replyTimeout: Duration = ScaleZero.replyTimeout) {
        self.replyTimeout = replyTimeout
    }

    /// The robot has never been zeroed and runs on the factory value
    var needsSetup: Bool { reading?.traySaved == false }

    var canControl: Bool { availability == .available && !isWorking }

    // MARK: Commands

    /// Opening the zero screen: forget the last result and read fresh values.
    func start() {
        didZero = false
        notice = nil
        check()
    }

    /// Asks for the current values; also how support is detected.
    func check() {
        if reading == nil { availability = .checking }
        refresh()
    }

    /// K? for live weight; skipped while one is already waiting so polling
    /// never piles up commands, and while a setting change is waiting so a
    /// poll reply can't be mistaken for its answer.
    func refresh() {
        guard !isWorking, !inFlight.contains("K?") else { return }
        send("K?")
    }

    /// The current reading becomes the empty tray. The tray must be empty.
    func zero() {
        guard canControl else { return }
        didZero = false
        notice = nil
        isWorking = true
        send("KZ")
    }

    /// Back to the factory empty-tray weight; the saved value is erased.
    func resetToDefault() {
        guard canControl else { return }
        didZero = false
        notice = nil
        isWorking = true
        send("KR")
    }

    /// Sets the heaviest empty cup the robot accepts.
    func setMaxCup(_ grams: Double) {
        guard let reading else { return }
        setCupWindow(min: reading.minCup, max: grams)
    }

    /// Sets the lightest empty cup the robot accepts.
    func setMinCup(_ grams: Double) {
        guard let reading else { return }
        setCupWindow(min: grams, max: reading.maxCup)
    }

    /// Sets the min and/or max cup weight, sending only what changes. With
    /// both, the order keeps min ≥ 20 g below max after each command, or
    /// the robot refuses the first one with KE=range.
    func setCupWindow(min newMin: Double, max newMax: Double) {
        guard canControl, let reading else { return }
        guard Self.isValidWindow(min: newMin, max: newMax) else {
            notice = Self.rangeNotice
            return
        }
        let setMin = newMin != reading.minCup ? "KN=" + String(format: "%.1f", newMin) : nil
        let setMax = newMax != reading.maxCup ? "KM=" + String(format: "%.1f", newMax) : nil
        // Max first is safe if the current min fits under the new max
        let maxFirst = Self.isValidWindow(min: reading.minCup, max: newMax)
        let commands = (maxFirst ? [setMax, setMin] : [setMin, setMax]).compactMap { $0 }
        guard !commands.isEmpty else { return }
        notice = nil
        isWorking = true
        commands.forEach(send)
    }

    /// Max cup weight back to the factory value; the saved value is erased.
    func resetMaxCup() {
        reset("KMR")
    }

    /// Min cup weight back to the factory value; the saved value is erased.
    func resetMinCup() {
        reset("KNR")
    }

    nonisolated static func isValidWindow(min: Double, max: Double) -> Bool {
        cupLimitRange.contains(min) && cupLimitRange.contains(max) && min <= max - minCupGap
    }

    /// The window to offer for an empty cup weighing `cup`: min = cup − 30 g
    /// (rounded down to 10 g), max = cup + 50 g (rounded up to 10 g), in range.
    nonisolated static func suggestedWindow(forCup cup: Double) -> (min: Double, max: Double) {
        let lower = cupLimitRange.lowerBound, upper = cupLimitRange.upperBound
        let maxCup = Swift.min(Swift.max(((cup + maxCupMargin) / 10).rounded(.up) * 10, lower + minCupGap), upper)
        let minCup = Swift.min(Swift.max(((cup - minCupMargin) / 10).rounded(.down) * 10, lower), maxCup - minCupGap)
        return (minCup, maxCup)
    }

    /// The BLE link dropped; the robot may be reflashed meanwhile.
    func connectionLost() {
        inFlight.removeAll()
        timeoutTask?.cancel()
        isWorking = false
        didZero = false
        reading = nil
        availability = .idle
    }

    // MARK: Replies

    func handle(_ message: ScaleMessage) {
        let command = inFlight.isEmpty ? nil : inFlight.removeFirst()
        if inFlight.isEmpty { timeoutTask?.cancel() }
        // A window change can be two commands; done once both are answered
        if command != "K?" { isWorking = inFlight.contains { $0 != "K?" } }

        switch message {
        case .reading(let reading):
            self.reading = reading
            availability = .available
            if command == "KZ" { didZero = true }

        case .error(let code):
            switch code {
            case "busy":
                notice = "Robot is busy (job running, drink waiting, or tray moving). Try again when it's idle."
            case "scale":
                notice = "Scale not responding."
            case "flash":
                notice = "Couldn't save."
            case "range":
                notice = Self.rangeNotice
            default:
                notice = "The robot didn't understand a scale command."
            }
        }
    }

    // MARK: Internals

    private func reset(_ command: String) {
        guard canControl else { return }
        notice = nil
        isWorking = true
        send(command)
    }

    private func send(_ command: String) {
        inFlight.append(command)
        transmit(command)
        armTimeout()
    }

    /// No reply at all: before any reading that means old firmware; after
    /// one, a lost reply that mustn't leave the screen stuck.
    private func armTimeout() {
        timeoutTask?.cancel()
        let timeout = replyTimeout
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, !self.inFlight.isEmpty else { return }
            let waitedForChange = self.inFlight.contains { $0 != "K?" }
            self.inFlight.removeAll()
            self.isWorking = false
            if self.reading == nil {
                self.availability = .unsupported
            } else if waitedForChange {
                self.notice = "The robot didn't answer. Check the connection and try again."
            }
        }
    }
}

/// A stand-in for the firmware's K handler, used by the simulator demo mode
/// and by tests. Mirrors PROTOCOL.md §A.8 (v7).
struct DemoScaleRobot {
    static let defaultEmptyTray = 121.38
    static let defaultMaxCup = 450.0
    static let defaultMinCup = 10.0
    /// Raw scale reading: tray plus whatever is on it
    var gross = 135.2
    /// A job running, drink waiting or tray away: KZ is refused
    var isBusy = false
    private(set) var emptyTray = DemoScaleRobot.defaultEmptyTray
    private(set) var traySaved = false
    private(set) var maxCup = DemoScaleRobot.defaultMaxCup
    private(set) var maxCupSaved = false
    private(set) var minCup = DemoScaleRobot.defaultMinCup
    private(set) var minCupSaved = false

    mutating func reply(to command: String) -> String {
        switch command {
        case "K?":
            break
        case "KZ":
            if isBusy { return "KE=busy" }
            emptyTray = gross
            traySaved = true
        case "KR":
            emptyTray = Self.defaultEmptyTray
            traySaved = false
        case "KMR":
            guard ScaleZero.isValidWindow(min: minCup, max: Self.defaultMaxCup) else { return "KE=range" }
            maxCup = Self.defaultMaxCup
            maxCupSaved = false
        case "KNR":
            guard ScaleZero.isValidWindow(min: Self.defaultMinCup, max: maxCup) else { return "KE=range" }
            minCup = Self.defaultMinCup
            minCupSaved = false
        case _ where command.hasPrefix("KT="):
            guard let grams = Double(command.dropFirst(3)) else { return "KE=bad" }
            guard (-20000...20000).contains(grams) else { return "KE=range" }
            emptyTray = grams
            traySaved = true
        case _ where command.hasPrefix("KM="):
            guard let grams = Double(command.dropFirst(3)) else { return "KE=bad" }
            guard ScaleZero.isValidWindow(min: minCup, max: grams) else { return "KE=range" }
            maxCup = grams
            maxCupSaved = true
        case _ where command.hasPrefix("KN="):
            guard let grams = Double(command.dropFirst(3)) else { return "KE=bad" }
            guard ScaleZero.isValidWindow(min: grams, max: maxCup) else { return "KE=range" }
            minCup = grams
            minCupSaved = true
        default:
            return "KE=bad"
        }
        let fields = [String(format: "%.1f", gross - emptyTray),
                      String(format: "%.1f", emptyTray),
                      String(format: "%.1f", Self.defaultEmptyTray),
                      traySaved ? "1" : "0",
                      String(format: "%.1f", maxCup),
                      String(format: "%.1f", Self.defaultMaxCup),
                      maxCupSaved ? "1" : "0",
                      String(format: "%.1f", minCup),
                      String(format: "%.1f", Self.defaultMinCup),
                      minCupSaved ? "1" : "0"]
        return "K=" + fields.joined(separator: ",")
    }
}
