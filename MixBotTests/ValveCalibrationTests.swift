//
//  ValveCalibrationTests.swift
//  MixBotTests
//

import Testing
@testable import MixBot

// Calibration parsing and the safety behavior of the session model, run
// against DemoValveRobot as a stand-in for the firmware.

struct ValveMessageParsingTests {
    @Test func valveLine() {
        #expect(parseValveMessage("T3=150,47,147,50,1") ==
                .valve(ValveState(id: 3, open: 150, closed: 47, defaultOpen: 147, defaultClosed: 50, saved: true)))
    }

    @Test func trayMessages() {
        #expect(parseValveMessage("TM3=moving") == .tray(id: 3, arrived: false))
        #expect(parseValveMessage("TM3=at") == .tray(id: 3, arrived: true))
        #expect(parseValveMessage("TM0=at") == .tray(id: 0, arrived: true))
        #expect(parseValveMessage("TM3=sideways") == nil)
    }

    @Test func errorAndAck() {
        #expect(parseValveMessage("TE=busy") == .error("busy"))
        #expect(parseValveMessage("TX=ok") == .closedAll)
    }

    @Test(arguments: ["T3=150,47", "T=1,2,3,4,5", "Tx", "W0=12", "$0=Ready!"])
    func rejectsOtherMessages(message: String) {
        #expect(parseValveMessage(message) == nil)
    }
}

@MainActor
private final class Harness {
    var robot = DemoValveRobot()
    var sent: [String] = []
    var robotAnswers = true
    let calibration: ValveCalibration

    init(spacing: Duration = .zero, openTapLockout: Duration = .zero, trayMoveTimeout: Duration = .seconds(5)) {
        calibration = ValveCalibration(commandSpacing: spacing,
                                       openTapLockout: openTapLockout,
                                       trayMoveTimeout: trayMoveTimeout)
        calibration.transmit = { [unowned self] command in
            sent.append(command)
            guard robotAnswers else { return }
            for reply in robot.reply(to: command) {
                if let message = parseValveMessage(reply) {
                    calibration.handle(message)
                }
            }
        }
    }

    /// Lets the rate-limited send queue drain
    func settle() async {
        try? await Task.sleep(for: .milliseconds(50))
    }

    /// Moves the tray under a valve and waits for the robot's confirmation
    func trayAt(_ id: Int) async {
        calibration.moveTray(to: id)
        for _ in 0..<60 where calibration.tray != .at(id) {
            try? await Task.sleep(for: .milliseconds(50))
        }
        sent.removeAll()
    }

    func started() async -> Harness {
        calibration.begin()
        await settle()
        sent.removeAll()
        return self
    }
}

@MainActor
struct ValveCalibrationSessionTests {
    @Test func beginListsAllValves() async {
        let harness = await Harness().started()
        #expect(harness.calibration.availability == .available)
        #expect(harness.calibration.valves.count == 6)
        #expect(!harness.calibration.isListing)
    }

    @Test func listingStaysOpenUntilTheLastReply() async {
        let harness = Harness()
        harness.robotAnswers = false
        let calibration = harness.calibration

        calibration.begin()
        await harness.settle()
        #expect(calibration.isListing)

        var robot = DemoValveRobot()
        let lines = robot.reply(to: "T?")
        for line in lines.prefix(5) {
            if let message = parseValveMessage(line) { calibration.handle(message) }
        }
        #expect(calibration.isListing)

        if let last = lines.last, let message = parseValveMessage(last) {
            calibration.handle(message)
        }
        #expect(!calibration.isListing)
    }

    @Test func doneClosesThenSavesTheFoundAngle() async {
        let harness = await Harness().started()
        let calibration = harness.calibration
        await harness.trayAt(1)

        calibration.open(1)
        await harness.settle()
        calibration.nudgeOpen(1, by: 1)
        await harness.settle()
        calibration.nudgeOpen(1, by: 1)
        await harness.settle()
        calibration.finishOpen(1)
        await harness.settle()

        #expect(harness.sent == ["TO1", "TO1=148", "TO1=149", "TC1", "TW1"])
        #expect(calibration.valves[1]?.open == 149)
        #expect(calibration.valves[1]?.saved == true)
        #expect(calibration.openValveId == nil)
        #expect(calibration.unsavedIds.isEmpty)
    }

    @Test func cancelRestoresTheOriginalAngleAndCloses() async {
        let harness = await Harness().started()
        let calibration = harness.calibration

        await harness.trayAt(2)
        calibration.open(2)
        await harness.settle()
        calibration.nudgeOpen(2, by: 3)
        await harness.settle()
        calibration.cancelOpen(2)
        await harness.settle()

        #expect(harness.sent.suffix(2) == ["TO2=147", "TC2"])
        #expect(calibration.valves[2]?.open == 147)
        #expect(calibration.valves[2]?.saved == false)
        #expect(calibration.openValveId == nil)
    }

    @Test func cancelDropsQueuedMovesSoNothingReopens() async {
        // Slow queue: the angle tap is still waiting when Cancel is pressed
        let harness = await Harness(spacing: .seconds(1)).started()
        let calibration = harness.calibration

        await harness.trayAt(3)
        calibration.open(3)
        calibration.nudgeOpen(3, by: 1)
        calibration.cancelOpen(3)
        await harness.settle()

        #expect(!harness.sent.contains("TO3=148"))
        #expect(harness.sent.last == "TC3")
    }

    @Test func tapsRightAfterOpeningAreIgnored() async {
        // The tap confirming the glass warning can land on +1 underneath it
        let harness = await Harness(openTapLockout: .milliseconds(300)).started()
        let calibration = harness.calibration
        await harness.trayAt(1)

        calibration.open(1)
        calibration.nudgeOpen(1, by: 1)
        #expect(calibration.openAngle(1) == 147)

        try? await Task.sleep(for: .milliseconds(350))
        calibration.nudgeOpen(1, by: 1)
        #expect(calibration.openAngle(1) == 148)
    }

    @Test func rapidTapsCoalesce() async {
        let harness = await Harness(spacing: .milliseconds(100)).started()
        let calibration = harness.calibration

        calibration.nudgeClosed(4, by: -1)
        calibration.nudgeClosed(4, by: -1)
        calibration.nudgeClosed(4, by: -1)
        try? await Task.sleep(for: .milliseconds(300))

        // Three taps, only the latest angle reaches the servo
        #expect(harness.sent == ["TC4=47"])
        #expect(calibration.valves[4]?.closed == 47)
    }

    @Test func closedTrimIsUnsavedUntilSaved() async {
        let harness = await Harness().started()
        let calibration = harness.calibration

        calibration.nudgeClosed(5, by: 2)
        await harness.settle()
        #expect(calibration.unsavedIds == [5])

        calibration.save(5)
        await harness.settle()
        #expect(calibration.unsavedIds.isEmpty)
        #expect(calibration.valves[5]?.saved == true)
    }

    @Test func endClosesEverything() async {
        let harness = await Harness().started()
        let calibration = harness.calibration

        await harness.trayAt(6)
        calibration.open(6)
        await harness.settle()
        calibration.end()

        #expect(harness.sent.last == "TX")
        #expect(calibration.openValveId == nil)
        // TX also parks the tray
        #expect(calibration.tray == .unknown)
    }

    @Test func busyDisablesCalibration() async {
        let harness = await Harness().started()
        let calibration = harness.calibration

        await harness.trayAt(1)
        calibration.open(1)
        calibration.handle(.error("busy"))

        #expect(calibration.isBusy)
        #expect(!calibration.canControl)
        #expect(calibration.openValveId == nil)
    }

    // MARK: Tray safety (protocol v3)

    @Test func openIsRefusedUntilTheTrayArrives() async {
        let harness = await Harness().started()
        let calibration = harness.calibration

        calibration.open(1)
        await harness.settle()

        #expect(harness.sent.isEmpty)
        #expect(calibration.openValveId == nil)
    }

    @Test func trayMoveThenOpen() async {
        let harness = await Harness().started()
        let calibration = harness.calibration

        calibration.moveTray(to: 4)
        await harness.settle()
        #expect(harness.sent == ["TM4"])
        #expect(calibration.tray == .at(4))
        #expect(!calibration.isTrayReady(for: 3))

        calibration.open(4)
        await harness.settle()
        #expect(harness.sent.last == "TO4")
        #expect(calibration.openValveId == 4)
    }

    @Test func openWaitsWhileTheTrayIsMoving() async {
        let harness = await Harness().started()
        let calibration = harness.calibration
        harness.robotAnswers = false

        calibration.moveTray(to: 2)
        calibration.handle(.tray(id: 2, arrived: false))
        calibration.open(2)

        #expect(calibration.tray == .moving(to: 2))
        #expect(calibration.openValveId == nil)
    }

    @Test func oldFirmwareFallsBackToUserConfirmation() async {
        let harness = await Harness().started()
        let calibration = harness.calibration
        harness.robot.supportsTray = false

        calibration.moveTray(to: 1)
        await harness.settle()

        #expect(calibration.tray == .manual)
        #expect(calibration.notice != nil)
        // The UI asks the user before each open in this mode
        #expect(calibration.isTrayReady(for: 1))
    }

    @Test func trayRefusalEndsTheOpen() async {
        let harness = await Harness().started()
        let calibration = harness.calibration
        await harness.trayAt(5)

        calibration.open(5)
        calibration.handle(.error("tray"))

        #expect(calibration.openValveId == nil)
        #expect(calibration.tray == .unknown)
    }

    @Test func trayThatNeverArrivesTimesOut() async {
        let harness = await Harness(trayMoveTimeout: .milliseconds(200)).started()
        let calibration = harness.calibration
        harness.robotAnswers = false

        calibration.moveTray(to: 3)
        try? await Task.sleep(for: .milliseconds(350))

        #expect(calibration.tray == .unknown)
        #expect(calibration.notice != nil)
    }

    @Test func demoRobotEnforcesTheTrayAndRefusesPumps() {
        var robot = DemoValveRobot()
        #expect(robot.reply(to: "TO1") == ["TE=tray"])
        #expect(robot.reply(to: "TM8") == ["TE=pump"])
        #expect(robot.reply(to: "TM1") == ["TM1=moving", "TM1=at"])
        #expect(robot.reply(to: "TO1") == ["T1=147,50,147,50,0"])
    }

    @Test func noReplyMeansUnsupported() async {
        let harness = Harness()
        harness.robotAnswers = false

        harness.calibration.begin()
        try? await Task.sleep(for: .milliseconds(1700))

        #expect(harness.calibration.availability == .unsupported)
    }
}
