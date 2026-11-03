//
//  RobotProtocolTests.swift
//  MixBotTests
//

import Testing
@testable import MixBot

// Covers the robot message parsing and the firmware limits described in
// FIRMWARE_INTERFACE.md.

struct JobProgressTests {
    @Test func weightMessageKeepsCompletedState() throws {
        var step = JobProgress(step: 0, weight: 0, status: .Processing)
        step.update(with: try #require(makeStatusFrom(message: "W0=74.9")))
        step.update(with: try #require(makeStatusFrom(message: "S0=C")))

        // A late weight must not knock the step back out of Complete
        step.update(with: try #require(makeStatusFrom(message: "W0=75.2")))

        #expect(step.status == .Complete)
        #expect(step.weight == 75.2)
    }

    @Test func weightMessageKeepsProcessingState() throws {
        var step = JobProgress(step: 1, weight: 0, status: .Processing)
        step.update(with: try #require(makeStatusFrom(message: "W1=12.5;")))

        #expect(step.status == .Processing)
        #expect(step.weight == 12.5)
    }

    @Test(arguments: [("S2=P", JobProgress.Result.Processing),
                      ("S2=C", .Complete),
                      ("S2=F", .Failed)])
    func stateMessages(message: String, expected: JobProgress.Result) throws {
        let parsed = try #require(makeStatusFrom(message: message))
        #expect(parsed.step == 2)
        #expect(parsed.status == expected)
    }

    @Test func statusMessagesAreNotStepProgress() {
        #expect(makeStatusFrom(message: "$1=1") == nil)
        #expect(makeStatusFrom(message: "A=ok") == nil)
    }
}

struct RobotLimitsTests {
    private func menu(totalQty: Int = 300, stationId: Int = 1) -> DrinkMenu {
        DrinkMenu(version: 2,
                  stations: [Station(id: stationId, name: "Tequila")],
                  drinks: [MenuDrink(name: "Shot",
                                     description: "",
                                     totalQty: totalQty,
                                     ingredients: [MenuIngredient(stationId: stationId, percent: 100)])])
    }

    @Test func withinLimitsHasNoProblems() {
        #expect(menu().robotLimitProblems().isEmpty)
        #expect(menu(totalQty: RobotLimits.maxPourQty, stationId: 9).robotLimitProblems().isEmpty)
    }

    @Test func oversizedDrinkIsFlagged() {
        #expect(menu(totalQty: 451).robotLimitProblems().count == 1)
    }

    @Test func unknownStationIsFlagged() {
        #expect(menu(stationId: 10).robotLimitProblems().count == 1)
    }

    @Test func outOfLimitsMenuStillLoads() throws {
        // Loading stays lenient; only the affected drink is blocked from serving
        let drinks = try #require(menu(totalQty: 500).resolvedDrinks())
        #expect(drinks.first?.pourBlockReason != nil)
    }

    @Test func pourableDrinkHasNoBlockReason() throws {
        let drinks = try #require(menu().resolvedDrinks())
        #expect(drinks.first?.pourBlockReason == nil)
    }

    @Test func drinkWithUnknownStationIsBlocked() throws {
        let drinks = try #require(menu(stationId: 12).resolvedDrinks())
        #expect(drinks.first?.pourBlockReason != nil)
    }
}

@MainActor
struct DisconnectDuringPourTests {
    @Test func unfinishedStepsFailWhenTheConnectionDrops() {
        let engine = RemoteEngine(targetPeripheralUUIDString: "94635d24-cf8d-4ff8-9191-de713f39db89")
        engine.jobProgress = [JobProgress(step: 0, weight: 75, status: .Complete),
                              JobProgress(step: 1, weight: 20, status: .Processing),
                              JobProgress(step: 2, weight: 0, status: .Sent)]

        // The robot stops the job on disconnect (protocol v6), but its
        // S<i>=F messages can't arrive, so the app finishes the steps itself
        engine.bluetoothEngine.isConnected = false

        #expect(engine.jobProgress.map(\.status) == [.Complete, .Failed, .Failed])
        #expect(engine.robotStatus.text == "Connection lost. The robot stopped the pour.")
    }

    @Test func finishedPourIsLeftAlone() {
        let engine = RemoteEngine(targetPeripheralUUIDString: "94635d24-cf8d-4ff8-9191-de713f39db89")
        engine.jobProgress = [JobProgress(step: 0, weight: 50, status: .Complete)]
        let textBefore = engine.robotStatus.text

        engine.bluetoothEngine.isConnected = false

        #expect(engine.jobProgress.map(\.status) == [.Complete])
        #expect(engine.robotStatus.text == textBefore)
    }
}
