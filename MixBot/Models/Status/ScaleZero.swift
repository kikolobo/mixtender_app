//
//  ScaleZero.swift
//  MixBot
//

import Foundation
import Observation

// Empty-tray weight over BLE ("K" messages, PROTOCOL.md §A.8, since v7).
// Cup detection and the 450 g "cup is not empty" check use the scale reading
// minus a stored empty-tray weight. The load cell's zero drifts, so a stale
// value makes an empty cup read as "Cup is not empty". Zeroing (KZ) with the
// tray empty re-measures it; the robot saves it in flash.

/// The robot's `K=<absolute>,<emptyTray>,<default>,<saved>` reply.
struct ScaleReading: Equatable {
    /// What the robot reads above the empty tray right now (≈ 0 when empty)
    var absolute: Double
    /// The empty-tray weight in use
    var emptyTray: Double
    /// The factory empty-tray weight
    var defaultEmptyTray: Double
    /// A value is saved in flash; false = never zeroed, running on the factory value
    var saved: Bool
}

enum ScaleMessage: Equatable {
    case reading(ScaleReading)
    case error(String)
}

/// Parses `K=<absolute>,<emptyTray>,<default>,<saved>` or `KE=<code>`.
/// Returns nil for anything else.
func parseScaleMessage(_ input: String) -> ScaleMessage? {
    guard input.first == "K" else { return nil }
    let parts = input.dropFirst().split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }

    let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
    switch parts[0] {
    case "E":
        return .error(value)
    case "":
        let fields = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let numbers = fields.compactMap(Double.init)
        guard fields.count == 4, numbers.count == 4 else { return nil }
        return .reading(ScaleReading(absolute: numbers[0],
                                     emptyTray: numbers[1],
                                     defaultEmptyTray: numbers[2],
                                     saved: numbers[3] == 1))
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
    static let replyTimeout: Duration = .milliseconds(1500)

    private(set) var availability: Availability = .idle
    private(set) var reading: ScaleReading?
    /// Waiting for the reply to KZ or KR
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
    var needsSetup: Bool { reading?.saved == false }

    var canControl: Bool { availability == .available && !isWorking }

    // MARK: Commands

    /// Asks for the current values; also how support is detected.
    func check() {
        if reading == nil { availability = .checking }
        refresh()
    }

    /// K? for live weight; skipped while one is already waiting so polling
    /// never piles up commands.
    func refresh() {
        guard !inFlight.contains("K?") else { return }
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
        if command == "KZ" || command == "KR" { isWorking = false }

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
                notice = "That weight is out of range."
            default:
                notice = "The robot didn't understand a scale command."
            }
        }
    }

    // MARK: Internals

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
    /// Raw scale reading: tray plus whatever is on it
    var gross = 135.2
    /// A job running, drink waiting or tray away: KZ is refused
    var isBusy = false
    private(set) var emptyTray = DemoScaleRobot.defaultEmptyTray
    private(set) var saved = false

    mutating func reply(to command: String) -> String {
        switch command {
        case "K?":
            break
        case "KZ":
            if isBusy { return "KE=busy" }
            emptyTray = gross
            saved = true
        case "KR":
            emptyTray = Self.defaultEmptyTray
            saved = false
        case _ where command.hasPrefix("KT="):
            guard let grams = Double(command.dropFirst(3)) else { return "KE=bad" }
            guard (-20000...20000).contains(grams) else { return "KE=range" }
            emptyTray = grams
            saved = true
        default:
            return "KE=bad"
        }
        return "K=" + [gross - emptyTray, emptyTray, Self.defaultEmptyTray]
            .map { String(format: "%.1f", $0) }
            .joined(separator: ",") + ",\(saved ? 1 : 0)"
    }
}
