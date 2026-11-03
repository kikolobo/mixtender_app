//
//  ScaleZeroTests.swift
//  MixBotTests
//

import Testing
@testable import MixBot

// Scale setup parsing and session behavior, run against DemoScaleRobot as a
// stand-in for the firmware (PROTOCOL.md §A.8).

struct ScaleMessageParsingTests {
    @Test func readingLine() {
        #expect(parseScaleMessage("K=0.3,135.2,121.4,1,450.0,450.0,0") ==
                .reading(ScaleReading(absolute: 0.3, emptyTray: 135.2, defaultEmptyTray: 121.4, traySaved: true,
                                      maxCup: 450, defaultMaxCup: 450, maxCupSaved: false)))
    }

    @Test func ignoresExtraTrailingFields() {
        guard case .reading(let reading) = parseScaleMessage("K=-0.1,135.2,121.4,0,380.0,450.0,1,99,abc") else {
            Issue.record("Expected a reading")
            return
        }
        #expect(reading.absolute == -0.1)
        #expect(!reading.traySaved)
        #expect(reading.maxCup == 380)
        #expect(reading.maxCupSaved)
    }

    @Test func error() {
        #expect(parseScaleMessage("KE=busy") == .error("busy"))
    }

    @Test(arguments: ["K=0.3,135.2,121.4,1", "K=a,b,c,d,e,f,g", "KX=1", "K", "T1=147,50,147,50,0", "$0=Ready!"])
    func rejectsOtherMessages(message: String) {
        #expect(parseScaleMessage(message) == nil)
    }

    @Test func valveParserIgnoresScaleMessages() {
        #expect(parseValveMessage("K=0.3,135.2,121.4,1,450.0,450.0,0") == nil)
    }

    @Test(arguments: [(180.0, 230.0), (183.4, 240.0), (0.0, 50.0), (1990.0, 2000.0)])
    func suggestedMaxCup(cup: Double, expected: Double) {
        #expect(ScaleZero.suggestedMaxCup(forCup: cup) == expected)
    }
}

@MainActor
private final class ScaleHarness {
    var robot = DemoScaleRobot()
    var sent: [String] = []
    var robotAnswers = true
    let scale: ScaleZero

    init(replyTimeout: Duration = .milliseconds(100)) {
        scale = ScaleZero(replyTimeout: replyTimeout)
        scale.transmit = { [unowned self] command in
            sent.append(command)
            guard robotAnswers else { return }
            if let message = parseScaleMessage(robot.reply(to: command)) {
                scale.handle(message)
            }
        }
    }
}

@MainActor
struct ScaleZeroSessionTests {
    @Test func checkFindsAnUnzeroedRobot() {
        let harness = ScaleHarness()
        harness.scale.check()
        #expect(harness.sent == ["K?"])
        #expect(harness.scale.availability == .available)
        #expect(harness.scale.needsSetup)
    }

    @Test func noReplyMeansUnsupported() async {
        let harness = ScaleHarness()
        harness.robotAnswers = false
        harness.scale.check()
        #expect(harness.scale.availability == .checking)
        try? await Task.sleep(for: .milliseconds(250))
        #expect(harness.scale.availability == .unsupported)
    }

    @Test func zeroSavesTheTray() {
        let harness = ScaleHarness()
        let scale = harness.scale
        scale.check()
        scale.zero()
        #expect(harness.sent.last == "KZ")
        #expect(scale.didZero)
        #expect(!scale.isWorking)
        #expect(!scale.needsSetup)
        #expect(abs(scale.reading?.absolute ?? 99) < 0.1)
    }

    @Test func busyRefusalShowsANotice() {
        let harness = ScaleHarness()
        harness.robot.isBusy = true
        let scale = harness.scale
        scale.check()
        scale.zero()
        #expect(!scale.didZero)
        #expect(!scale.isWorking)
        #expect(scale.notice?.hasPrefix("Robot is busy") == true)
        #expect(scale.needsSetup)
    }

    @Test func setAndResetMaxCup() {
        let harness = ScaleHarness()
        let scale = harness.scale
        scale.check()
        scale.setMaxCup(380)
        #expect(harness.sent.last == "KM=380.0")
        #expect(scale.reading?.maxCup == 380)
        #expect(scale.reading?.maxCupSaved == true)

        scale.resetMaxCup()
        #expect(harness.sent.last == "KMR")
        #expect(scale.reading?.maxCup == 450)
        #expect(scale.reading?.maxCupSaved == false)
    }

    @Test func outOfRangeMaxCupIsNotSent() {
        let harness = ScaleHarness()
        let scale = harness.scale
        scale.check()
        scale.setMaxCup(5)
        #expect(harness.sent == ["K?"])
        #expect(scale.notice == "Enter 20–2000 g.")
    }

    @Test func pollingDoesNotPileUp() {
        let harness = ScaleHarness()
        harness.robotAnswers = false
        harness.scale.refresh()
        harness.scale.refresh()
        #expect(harness.sent == ["K?"])
    }

    @Test func disconnectForgetsTheRobot() {
        let harness = ScaleHarness()
        let scale = harness.scale
        scale.check()
        scale.connectionLost()
        #expect(scale.reading == nil)
        #expect(scale.availability == .idle)
    }
}
