//
//  ValveCalibration.swift
//  MixBot
//

import Foundation
import Observation

// Valve calibration over BLE ("T" messages, see NOTES_FROM_FIRMWARE.md).
// The six gravity-valve stations are servos with an open and a closed angle
// (0–180°). Changes are live on the robot as soon as they're sent and used
// by real pours, but only survive a reboot once saved with TW<id>.
// Since protocol v3 (PROTOCOL.md §A.7) a valve only opens with the tray
// under it: TM<id> moves the tray there and reports TM<id>=at on arrival.

/// One valve's calibration as last reported by the robot.
struct ValveState: Equatable {
    let id: Int
    var open: Int
    var closed: Int
    var defaultOpen: Int
    var defaultClosed: Int
    /// The valve has a calibration in flash (not that it matches the live angles)
    var saved: Bool

    var openTrim: Int { open - defaultOpen }
    var closedTrim: Int { closed - defaultClosed }
}

enum ValveMessage: Equatable {
    case valve(ValveState)
    /// `TM<id>=moving` (accepted, on its way) or `TM<id>=at` (arrived); 0 = park
    case tray(id: Int, arrived: Bool)
    case error(String)
    case closedAll
}

/// Parses a calibration reply: `T<id>=<open>,<closed>,<defOpen>,<defClosed>,<saved>`,
/// `TM<id>=moving|at`, `TE=<code>` or `TX=ok`. Returns nil for anything else.
func parseValveMessage(_ input: String) -> ValveMessage? {
    guard input.first == "T" else { return nil }
    let parts = input.dropFirst().split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }

    let head = parts[0]
    let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)

    switch head {
    case "E":
        return .error(value)
    case "X":
        return .closedAll
    case _ where head.first == "M":
        guard let id = Int(head.dropFirst()) else { return nil }
        switch value {
        case "moving": return .tray(id: id, arrived: false)
        case "at": return .tray(id: id, arrived: true)
        default: return nil
        }
    default:
        guard let id = Int(head) else { return nil }
        let numbers = value.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count == 5 else { return nil }
        return .valve(ValveState(id: id,
                                 open: numbers[0],
                                 closed: numbers[1],
                                 defaultOpen: numbers[2],
                                 defaultClosed: numbers[3],
                                 saved: numbers[4] == 1))
    }
}

/// Calibration session state and the safety rules around it. The robot's
/// replies are the source of truth for angles; the app only tracks what it
/// asked for until the reply confirms it.
@Observable
@MainActor
final class ValveCalibration {
    enum Availability: Equatable {
        case idle
        case checking
        case available
        case unsupported
    }

    /// Where the tray is, as far as the robot has told us.
    enum TrayPosition: Equatable {
        /// Parked, or not known (e.g. after TX or a reconnect)
        case unknown
        case moving(to: Int)
        /// The robot confirmed the tray is under this valve
        case at(Int)
        /// Firmware without TM (before protocol v3) can't move the tray, so
        /// the user must confirm the glass is under the valve before each open
        case manual
    }

    nonisolated static let valveIds = 1...6
    nonisolated static let angleRange = 0...180
    /// An open valve with no interaction for this long is closed automatically
    static let autoCloseSeconds = 8.0
    /// Old firmware ignores T?; no reply in this window means "not supported"
    static let replyTimeout: Duration = .milliseconds(1500)
    /// A tray move normally takes a few seconds
    nonisolated static let trayMoveTimeout: Duration = .seconds(12)

    private(set) var availability: Availability = .idle
    private(set) var valves: [Int: ValveState] = [:]
    /// The valve the app last commanded open. Only one is ever open at a time.
    private(set) var openValveId: Int?
    private(set) var tray: TrayPosition = .unknown
    /// Still waiting for some of the T? replies (they arrive one by one)
    private(set) var isListing = false
    /// Valves with live changes on the robot that aren't saved to flash
    private(set) var unsavedIds: Set<Int> = []
    /// The robot refused calibration because a drink is pouring
    private(set) var isBusy = false
    /// When the open valve will be closed automatically
    private(set) var autoCloseAt: Date?
    /// Last error or notice for the UI; the view clears it
    var notice: String?

    /// Angles requested but not yet confirmed by a reply
    private(set) var targetOpen: [Int: Int] = [:]
    private(set) var targetClosed: [Int: Int] = [:]

    /// Writes one command to the robot; installed by RemoteEngine
    @ObservationIgnored var transmit: (String) -> Void = { _ in }

    @ObservationIgnored private let commandSpacing: Duration
    @ObservationIgnored private let openTapLockout: Duration
    @ObservationIgnored private let trayMoveTimeout: Duration
    /// Angle taps before this are ignored: the tap that confirmed the glass
    /// warning can land on the +1 button that appears where the alert was
    @ObservationIgnored private var acceptOpenTapsAfter: ContinuousClock.Instant?
    @ObservationIgnored private let clock = ContinuousClock()
    @ObservationIgnored private var lastSend: ContinuousClock.Instant?
    /// Commands waiting for their turn; `key` lets rapid angle taps coalesce
    @ObservationIgnored private var queue: [(key: String?, command: String)] = []
    @ObservationIgnored private var queueTask: Task<Void, Never>?
    /// Sent commands awaiting their reply, oldest first (one reply each)
    @ObservationIgnored private var inFlight: [String] = []
    /// Open angle before the current open session, restored on cancel
    @ObservationIgnored private var originalOpen: [Int: Int] = [:]
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var autoCloseTask: Task<Void, Never>?
    @ObservationIgnored private var trayTimeoutTask: Task<Void, Never>?

    /// - Parameters:
    ///   - commandSpacing: minimum gap between queued commands; the firmware
    ///     asks for at most ~5 servo moves per second.
    ///   - openTapLockout: how long after opening a valve angle taps are ignored.
    ///   - trayMoveTimeout: how long to wait for TM<id>=at before giving up.
    init(commandSpacing: Duration = .milliseconds(200),
         openTapLockout: Duration = .milliseconds(500),
         trayMoveTimeout: Duration = ValveCalibration.trayMoveTimeout) {
        self.commandSpacing = commandSpacing
        self.openTapLockout = openTapLockout
        self.trayMoveTimeout = trayMoveTimeout
    }

    var canControl: Bool { availability == .available && !isBusy }

    /// The valve may be opened: the robot confirmed the tray is under it, or
    /// (manual mode) the UI must ask the user to confirm the glass first.
    func isTrayReady(for id: Int) -> Bool {
        tray == .at(id) || tray == .manual
    }

    func openAngle(_ id: Int) -> Int? { targetOpen[id] ?? valves[id]?.open }
    func closedAngle(_ id: Int) -> Int? { targetClosed[id] ?? valves[id]?.closed }

    // MARK: Session

    /// Entering the calibration screen: ask for every valve's state.
    func begin() {
        isBusy = false
        if valves.isEmpty { availability = .checking }
        enqueue("T?")

        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.replyTimeout)
            guard !Task.isCancelled, let self else { return }
            self.isListing = false
            guard self.valves.isEmpty else { return }
            self.availability = .unsupported
            self.inFlight.removeAll()
        }
    }

    /// Leaving the screen or backgrounding: put back any unsaved open-angle
    /// change and close every valve.
    func end() {
        var commands: [String] = []
        if let id = openValveId {
            commands += restoreOpenCommands(for: id)
        }
        commands.append("TX")
        sendNow(commands)
        finishOpenSession()
        trayTimeoutTask?.cancel()
        // TX closes all valves and parks the tray
        if tray != .manual { tray = .unknown }
    }

    /// The BLE link dropped; the firmware closes all valves on disconnect.
    func connectionLost() {
        queue.removeAll()
        inFlight.removeAll()
        isListing = false
        timeoutTask?.cancel()
        trayTimeoutTask?.cancel()
        finishOpenSession()
        targetOpen.removeAll()
        targetClosed.removeAll()
        // The firmware parks on disconnect, and may be reflashed meanwhile
        tray = .unknown
        availability = .idle
    }

    /// After a "busy" refusal, try again once the pour is over.
    func retry() {
        notice = nil
        begin()
    }

    // MARK: Tray

    /// Moves the tray under a valve (the firmware closes all valves first).
    /// Opening stays disabled until the robot reports TM<id>=at.
    func moveTray(to id: Int) {
        guard canControl, tray != .manual, Self.valveIds.contains(id) else { return }
        if tray == .at(id) || tray == .moving(to: id) { return }
        if let open = openValveId {
            // Put back any unsaved open-angle change; TM itself closes the valve
            sendNow(restoreOpenCommands(for: open))
            finishOpenSession()
        }
        tray = .moving(to: id)
        enqueue("TM\(id)")

        trayTimeoutTask?.cancel()
        let timeout = trayMoveTimeout
        trayTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, self.tray == .moving(to: id) else { return }
            self.tray = .unknown
            self.notice = "The tray didn't reach valve \(id). Check the robot and try again."
        }
    }

    // MARK: Open position (pours!)

    func open(_ id: Int) {
        // Never open unless the tray is confirmed under this valve (or, on
        // firmware that can't move it, the UI has had the user confirm)
        guard canControl, isTrayReady(for: id), let current = openAngle(id) else { return }
        if let other = openValveId, other != id {
            sendNow(restoreOpenCommands(for: other) + ["TC\(other)"])
            finishOpenSession()
        }
        originalOpen[id] = current
        openValveId = id
        acceptOpenTapsAfter = clock.now + openTapLockout
        // Keyed like the angle taps, so a quick Cancel drops it if it hasn't
        // gone out yet instead of opening the valve after the close
        enqueue("TO\(id)", key: "TO\(id)")
        armAutoClose(id)
    }

    func nudgeOpen(_ id: Int, by delta: Int) {
        guard canControl, openValveId == id, let current = openAngle(id) else { return }
        if let acceptOpenTapsAfter, clock.now < acceptOpenTapsAfter { return }
        let target = clamped(current + delta)
        guard target != current else { return }
        targetOpen[id] = target
        enqueue("TO\(id)=\(target)", key: "TO\(id)")
        armAutoClose(id)
    }

    /// Done: close immediately and save the open angle that was found.
    func finishOpen(_ id: Int) {
        guard openValveId == id else { return }
        var commands: [String] = []
        // An angle tap still waiting in the queue is the one the user saw
        if queue.contains(where: { $0.key == "TO\(id)" }), let target = targetOpen[id] {
            commands.append("TO\(id)=\(target)")
        }
        commands.append("TC\(id)")
        sendNow(commands)
        finishOpenSession()
        enqueue("TW\(id)")
    }

    /// Cancel (or auto-close): close immediately without saving. The original
    /// open angle is sent back first; the valve is already open, so this
    /// pours nothing extra, and both commands go out back to back.
    func cancelOpen(_ id: Int) {
        guard openValveId == id else { return }
        sendNow(restoreOpenCommands(for: id) + ["TC\(id)"])
        finishOpenSession()
    }

    // MARK: Closed position (no pour)

    func nudgeClosed(_ id: Int, by delta: Int) {
        guard canControl, openValveId == nil, let current = closedAngle(id) else { return }
        let target = clamped(current + delta)
        guard target != current else { return }
        targetClosed[id] = target
        unsavedIds.insert(id)
        enqueue("TC\(id)=\(target)", key: "TC\(id)")
    }

    func save(_ id: Int) {
        guard canControl, openValveId == nil else { return }
        enqueue("TW\(id)")
    }

    /// Factory angles, closed, and saved so they survive a reboot.
    func resetToFactory(_ id: Int) {
        guard canControl, openValveId == nil else { return }
        targetOpen[id] = nil
        targetClosed[id] = nil
        enqueue("TR\(id)")
        enqueue("TC\(id)")
        enqueue("TW\(id)")
    }

    // MARK: Replies

    func handle(_ message: ValveMessage) {
        // TM<id>=at arrives seconds later, after other replies: it answers no
        // particular command, so it mustn't consume the in-flight queue
        if case .tray(let id, arrived: true) = message {
            trayArrived(at: id)
            return
        }

        let command = inFlight.isEmpty ? nil : inFlight.removeFirst()
        if command == "T?", !inFlight.contains("T?") {
            isListing = false
        }

        switch message {
        case .tray(let id, _):
            // TM accepted and on its way; =at follows
            if id != 0 { tray = .moving(to: id) }

        case .valve(let state):
            valves[state.id] = state
            availability = .available
            timeoutTask?.cancel()
            if targetOpen[state.id] == state.open { targetOpen[state.id] = nil }
            if targetClosed[state.id] == state.closed { targetClosed[state.id] = nil }
            if command?.hasPrefix("TW") == true {
                unsavedIds.remove(state.id)
            }

        case .closedAll:
            openValveId = nil
            if tray != .manual { tray = .unknown }

        case .error(let code):
            targetOpen.removeAll()
            targetClosed.removeAll()
            let wasTrayMove = command?.hasPrefix("TM") == true
            if wasTrayMove {
                trayTimeoutTask?.cancel()
                tray = .unknown
            }
            switch code {
            case "bad" where wasTrayMove:
                // Firmware from before protocol v3 doesn't know TM
                tray = .manual
                notice = "This robot can't move the tray for calibration. You'll be asked to confirm the glass is under the valve before it opens."
            case "tray", "moving":
                // The open was refused: the tray isn't (yet) under the valve
                finishOpenSession()
                if code == "tray" { tray = .unknown }
                notice = code == "tray"
                    ? "The tray isn't under that valve. Move it there first."
                    : "The tray is still moving. Wait until it arrives."
            case "pump":
                print("[ValveCalibration] TE=pump: a pump station was offered for calibration")
                notice = "That station is a pump; pumps don't need calibration."
            case "busy":
                isBusy = true
                // Whatever was asked didn't happen, including an open
                finishOpenSession()
                notice = "The robot is busy: pouring, starting up, or a finished drink is waiting on the tray. Remove it or wait, then try again."
            case "flash":
                notice = "The robot couldn't save to its memory. Try saving again."
            case "angle":
                notice = "That angle is out of range (0–180°)."
            case "valve":
                notice = "The robot doesn't have that valve."
            default:
                notice = "The robot didn't understand a calibration command."
            }
        }
    }

    private func trayArrived(at id: Int) {
        trayTimeoutTask?.cancel()
        tray = id == 0 ? .unknown : .at(id)
    }

    // MARK: Internals

    private func clamped(_ angle: Int) -> Int {
        min(max(angle, Self.angleRange.lowerBound), Self.angleRange.upperBound)
    }

    /// Puts the pre-session open angle back if this session changed it.
    private func restoreOpenCommands(for id: Int) -> [String] {
        guard let original = originalOpen[id], openAngle(id) != original else { return [] }
        targetOpen[id] = original
        return ["TO\(id)=\(original)"]
    }

    private func finishOpenSession() {
        if let id = openValveId { originalOpen[id] = nil }
        openValveId = nil
        autoCloseTask?.cancel()
        autoCloseTask = nil
        autoCloseAt = nil
    }

    private func armAutoClose(_ id: Int) {
        autoCloseTask?.cancel()
        autoCloseAt = Date().addingTimeInterval(Self.autoCloseSeconds)
        autoCloseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.autoCloseSeconds))
            guard !Task.isCancelled, let self, self.openValveId == id else { return }
            self.cancelOpen(id)
            self.notice = "Valve \(id) closed automatically after \(Int(Self.autoCloseSeconds)) s without activity. Nothing was saved."
        }
    }

    /// Rate-limited, ordered sending. Consecutive angle taps for the same
    /// valve collapse into the latest one.
    private func enqueue(_ command: String, key: String? = nil) {
        if let key, let last = queue.last, last.key == key {
            queue[queue.count - 1].command = command
        } else {
            queue.append((key, command))
        }

        guard queueTask == nil else { return }
        queueTask = Task { [weak self] in
            while let self, !self.queue.isEmpty {
                if let lastSend = self.lastSend {
                    let wait = (lastSend + self.commandSpacing) - self.clock.now
                    if wait > .zero { try? await Task.sleep(for: wait) }
                }
                guard !self.queue.isEmpty else { break }
                self.send(self.queue.removeFirst().command)
            }
            self?.queueTask = nil
        }
    }

    /// Safety commands skip the queue, and drop queued angle moves that
    /// would otherwise run after them and reopen a valve.
    private func sendNow(_ commands: [String]) {
        queue.removeAll { $0.key != nil }
        for command in commands {
            send(command)
        }
    }

    private func send(_ command: String) {
        lastSend = clock.now
        if command == "T?" {
            isListing = true
            inFlight += Array(repeating: command, count: Self.valveIds.count)
        } else {
            inFlight.append(command)
        }
        transmit(command)
    }
}

/// A stand-in for the firmware's calibration handler, used by the simulator
/// demo mode and by tests. Mirrors PROTOCOL.md §A.7 (v4): the tray must be
/// moved under a valve with TM before it opens, and pump ids are refused.
struct DemoValveRobot {
    /// Old firmware (before v3) answers TM with TE=bad
    var supportsTray = true
    /// Where the tray is; nil = parked
    private(set) var trayAt: Int?
    private var valves: [Int: ValveState] = Dictionary(uniqueKeysWithValues: ValveCalibration.valveIds.map {
        ($0, ValveState(id: $0, open: 147, closed: 50, defaultOpen: 147, defaultClosed: 50, saved: false))
    })

    mutating func reply(to command: String) -> [String] {
        if command == "T?" {
            return ValveCalibration.valveIds.compactMap { valves[$0].map(Self.line) }
        }
        if command == "TX" {
            trayAt = nil
            return ["TX=ok"]
        }

        let body = command.dropFirst()
        guard command.first == "T", let operation = body.first else { return ["TE=bad"] }
        let parts = body.dropFirst().split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard let idPart = parts.first, let id = Int(idPart) else { return ["TE=bad"] }

        if operation == "M" {
            guard supportsTray, parts.count == 1 else { return ["TE=bad"] }
            if (7...9).contains(id) { return ["TE=pump"] }
            guard id == 0 || valves[id] != nil else { return ["TE=valve"] }
            // The real tray takes a few seconds between these two
            trayAt = id == 0 ? nil : id
            return ["TM\(id)=moving", "TM\(id)=at"]
        }

        if (7...9).contains(id) { return ["TE=pump"] }
        guard var valve = valves[id] else { return ["TE=valve"] }

        var angle: Int?
        if parts.count == 2 {
            guard let value = Int(parts[1]) else { return ["TE=bad"] }
            guard ValveCalibration.angleRange.contains(value) else { return ["TE=angle"] }
            angle = value
        }

        switch operation {
        case "O":
            if supportsTray && trayAt != id { return ["TE=tray"] }
            if let angle { valve.open = angle }
        case "C":
            if let angle { valve.closed = angle }
        case "W" where angle == nil:
            valve.saved = true
        case "R" where angle == nil:
            valve.open = valve.defaultOpen
            valve.closed = valve.defaultClosed
        default:
            return ["TE=bad"]
        }

        valves[id] = valve
        return [Self.line(valve)]
    }

    static func line(_ valve: ValveState) -> String {
        "T\(valve.id)=\(valve.open),\(valve.closed),\(valve.defaultOpen),\(valve.defaultClosed),\(valve.saved ? 1 : 0)"
    }
}
