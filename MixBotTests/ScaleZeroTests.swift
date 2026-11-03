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
        #expect(parseScaleMessage("K=0.3,135.2,121.4,1,450.0,450.0,0,10.0,10.0,0") ==
                .reading(ScaleReading(absolute: 0.3, emptyTray: 135.2, defaultEmptyTray: 121.4, traySaved: true,
                                      maxCup: 450, defaultMaxCup: 450, maxCupSaved: false,
                                      minCup: 10, defaultMinCup: 10, minCupSaved: false)))
    }

    @Test func ignoresExtraTrailingFields() {
        guard case .reading(let reading) = parseScaleMessage("K=-0.1,135.2,121.4,0,380.0,450.0,1,150.0,10.0,1,99,abc") else {
            Issue.record("Expected a reading")
            return
        }
        #expect(reading.absolute == -0.1)
        #expect(!reading.traySaved)
        #expect(reading.maxCup == 380)
        #expect(reading.maxCupSaved)
        #expect(reading.minCup == 150)
        #expect(reading.minCupSaved)
    }

    @Test func error() {
        #expect(parseScaleMessage("KE=busy") == .error("busy"))
    }

    @Test(arguments: ["K=0.3,135.2,121.4,1", "K=0.3,135.2,121.4,1,450.0,450.0,0", "K=a,b,c,d,e,f,g,h,i,j", "KX=1", "K", "T1=147,50,147,50,0", "$0=Ready!"])
    func rejectsOtherMessages(message: String) {
        #expect(parseScaleMessage(message) == nil)
    }

    @Test func valveParserIgnoresScaleMessages() {
        #expect(parseValveMessage("K=0.3,135.2,121.4,1,450.0,450.0,0,10.0,10.0,0") == nil)
    }

    @Test(arguments: [(180.0, 150.0, 230.0), (183.4, 150.0, 240.0), (20.0, 5.0, 70.0),
                      (0.0, 5.0, 50.0), (1990.0, 1960.0, 2000.0)])
    func suggestedWindow(cup: Double, min: Double, max: Double) {
        let window = ScaleZero.suggestedWindow(forCup: cup)
        #expect(window.min == min)
        #expect(window.max == max)
        #expect(ScaleZero.isValidWindow(min: window.min, max: window.max))
    }

    @Test func windowRules() {
        #expect(ScaleZero.isValidWindow(min: 10, max: 450))
        #expect(ScaleZero.isValidWindow(min: 430, max: 450))
        #expect(!ScaleZero.isValidWindow(min: 431, max: 450))
        #expect(!ScaleZero.isValidWindow(min: 4, max: 450))
        #expect(!ScaleZero.isValidWindow(min: 10, max: 2001))
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

    @Test func setAndResetMinCup() {
        let harness = ScaleHarness()
        let scale = harness.scale
        scale.check()
        scale.setMinCup(120)
        #expect(harness.sent.last == "KN=120.0")
        #expect(scale.reading?.minCup == 120)
        #expect(scale.reading?.minCupSaved == true)

        scale.resetMinCup()
        #expect(harness.sent.last == "KNR")
        #expect(scale.reading?.minCup == 10)
        #expect(scale.reading?.minCupSaved == false)
    }

    @Test func minTooCloseToMaxIsNotSent() {
        let harness = ScaleHarness()
        let scale = harness.scale
        scale.check()
        scale.setMinCup(440)
        scale.setMaxCup(3)
        #expect(harness.sent == ["K?"])
        #expect(scale.notice == ScaleZero.rangeNotice)
    }

    @Test func raisingTheWindowSendsMaxFirst() {
        let harness = ScaleHarness()
        let scale = harness.scale
        scale.check()
        // Min 600 is above today's max of 450, so KN first would be refused
        scale.setCupWindow(min: 600, max: 700)
        #expect(Array(harness.sent.suffix(2)) == ["KM=700.0", "KN=600.0"])
        #expect(scale.reading?.minCup == 600)
        #expect(scale.reading?.maxCup == 700)
        #expect(scale.notice == nil)
        #expect(!scale.isWorking)
    }

    @Test func loweringTheWindowSendsMinFirst() {
        let harness = ScaleHarness()
        let scale = harness.scale
        scale.check()
        scale.setCupWindow(min: 600, max: 700)
        // Max 300 is below the current min of 600, so KM first would be refused
        scale.setCupWindow(min: 150, max: 300)
        #expect(Array(harness.sent.suffix(2)) == ["KN=150.0", "KM=300.0"])
        #expect(scale.reading?.minCup == 150)
        #expect(scale.reading?.maxCup == 300)
        #expect(scale.notice == nil)
    }

    @Test func robotRangeRefusalShowsTheNotice() {
        let harness = ScaleHarness()
        let scale = harness.scale
        scale.check()
        scale.setCupWindow(min: 600, max: 700)
        // KMR would put the default max (450) under the min of 600
        scale.resetMaxCup()
        #expect(scale.notice == ScaleZero.rangeNotice)
        #expect(scale.reading?.maxCup == 700)
    }

    @Test func pollingDoesNotPileUp() {
        let harness = ScaleHarness()
        harness.robotAnswers = false
        harness.scale.refresh()
        harness.scale.refresh()
        #expect(harness.sent == ["K?"])
    }

    @Test func pollingWaitsForASettingChange() {
        let harness = ScaleHarness()
        let scale = harness.scale
        scale.check()
        harness.robotAnswers = false
        scale.zero()
        scale.refresh()
        #expect(harness.sent == ["K?", "KZ"])
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
