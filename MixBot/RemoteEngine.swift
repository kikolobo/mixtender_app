//
//  RemoteState.swift
//  MixBot
//
//  Created by Francisco Lobo on 20/04/24.
//

import Foundation
import Combine


class RemoteEngine: ObservableObject {    
    
    let bluetoothEngine: BluetoothEngine
    @Published var robotStatus: RobotStatus = RobotStatus()
    @Published var jobProgress = [JobProgress]()
    // Valve calibration session (robot settings); fed by "T" replies
    let valveCalibration: ValveCalibration
    // Empty-tray weight / scale zero (robot settings); fed by "K" replies
    let scaleZero: ScaleZero

    
    private var cancellables = Set<AnyCancellable>()

    #if targetEnvironment(simulator)
    // Demo mode: CoreBluetooth doesn't work in the simulator, so we fake the
    // connection and replay a realistic dispense so the full UI can be tested
    private var demoTask: Task<Void, Never>?
    private var demoValveRobot = DemoValveRobot()
    private var demoScaleRobot = DemoScaleRobot()
    #endif

    init(targetPeripheralUUIDString: String) {
        self.bluetoothEngine = BluetoothEngine(targetPeripheralUUIDString: targetPeripheralUUIDString)
        // CoreBluetooth delivers on the main queue (queue: nil), so the
        // calibration model is only ever touched from the main actor
        self.valveCalibration = MainActor.assumeIsolated { ValveCalibration() }
        self.scaleZero = MainActor.assumeIsolated { ScaleZero() }
        
        
        bluetoothEngine.objectWillChange
                    .sink { [weak self] _ in
                        self?.objectWillChange.send()
                    }
                    .store(in: &cancellables)
        
        bluetoothEngine.$rx
                   .sink { [weak self] rx in
                       self?.didReceivedMessage(rx)
                   }
                   .store(in: &cancellables)
        
        bluetoothEngine.$isConnected
            .sink { [weak self] isConnected in
                guard !isConnected, let self else { return }
                MainActor.assumeIsolated {
                    self.valveCalibration.connectionLost()
                    self.scaleZero.connectionLost()
                }
                self.failUnfinishedSteps()
            }
            .store(in: &cancellables)

        bluetoothEngine.$txReady
            .sink { [weak self] txReady in
                guard txReady else { return }
                print("[RemoteEngine] BLE TX is Ready \(String(describing: self?.bluetoothEngine.comStatus))")
                self?.bluetoothEngine.sendStringToPeripheral("ehlo")
            }
            .store(in: &cancellables)

        #if targetEnvironment(simulator)
        // Calibration commands are answered by a local stand-in for the firmware
        MainActor.assumeIsolated {
            valveCalibration.transmit = { [weak self] command in
                guard let self else { return }
                let replies = self.demoValveRobot.reply(to: command)
                Task { @MainActor [weak self] in
                    for reply in replies {
                        // A tray move takes a moment, like the real robot
                        try? await Task.sleep(for: reply.hasSuffix("=at") ? .milliseconds(1800) : .milliseconds(60))
                        self?.didReceivedMessage(reply)
                    }
                }
            }
            scaleZero.transmit = { [weak self] command in
                guard let self else { return }
                // Slight noise, like a real load cell
                self.demoScaleRobot.gross += Double.random(in: -0.2...0.2)
                let reply = self.demoScaleRobot.reply(to: command)
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(80))
                    self?.didReceivedMessage(reply)
                }
            }
        }
        bluetoothEngine.simulateConnect()
        robotStatus.isCupReady = true
        robotStatus.text = "Demo mode: simulated robot"
        #else
        MainActor.assumeIsolated {
            valveCalibration.transmit = { [weak self] command in
                print("[RemoteEngine] Calibration: \(command)")
                self?.bluetoothEngine.sendStringToPeripheral(command)
            }
            scaleZero.transmit = { [weak self] command in
                print("[RemoteEngine] Scale: \(command)")
                self?.bluetoothEngine.sendStringToPeripheral(command)
            }
        }
        #endif
    }

    func sendJobToRobot(_ drink: Drink) {
        guard !drink.ingredients.isEmpty else {
            print("[RemoteEngine] Drink has no ingredients, nothing to send")
            return
        }

        self.jobProgress.removeAll()
        
        var txString = "D:"
        var step = 0
        for ingredient in drink.ingredients {
            self.jobProgress.append(JobProgress(step: step, weight: 0.0, status: .Sent))
            
            let pct = Float(ingredient.percent) / 100
            let amt = Float(drink.totalQty) * pct
            txString += String(ingredient.stationId) + "=" + String(format: "%.2f", amt) + ","
            
            if (step==0) { self.jobProgress[0].status = .Processing}
            
            step = step + 1
        }
        
        txString = String(txString.dropLast())
        print("[RemoteEngine] Sending : \(txString)" )
        bluetoothEngine.sendStringToPeripheral(txString)
    }
    
    func beginDispensing(drink: Drink) {
        #if targetEnvironment(simulator)
        runDemoDispense(drink: drink)
        #else
        if (self.bluetoothEngine.isConnected == true) {
            self.sendJobToRobot(drink)
        }
        #endif
    }

    /// A job was sent and not every step has finished yet
    var isPouring: Bool {
        jobProgress.contains { $0.status != .Complete && $0.status != .Failed }
    }

    /// Since protocol v6 the robot stops a running job when the connection
    /// drops, but its S<i>=F messages can't reach us any more. Fail the
    /// unfinished steps locally so the pour screen reaches Done and says why.
    private func failUnfinishedSteps() {
        let unfinished = jobProgress.indices.filter {
            jobProgress[$0].status != .Complete && jobProgress[$0].status != .Failed
        }
        guard !unfinished.isEmpty else { return }
        for index in unfinished {
            jobProgress[index].status = .Failed
        }
        robotStatus.text = "Connection lost. The robot stopped the pour."
    }

    func cancelDispense() {
        #if targetEnvironment(simulator)
        demoTask?.cancel()
        demoTask = nil
        robotStatus.text = "Demo: dispensing cancelled"
        #else
        if (self.bluetoothEngine.isConnected == true) {
            bluetoothEngine.sendStringToPeripheral("C!")
        }
        #endif
        // The pour screen is gone; a later disconnect mustn't "fail" this job
        jobProgress.removeAll()
    }

    #if targetEnvironment(simulator)
    // Replays what the robot would send over BLE: each step goes Processing,
    // its weight ramps up to the target amount, then it completes
    private func runDemoDispense(drink: Drink) {
        demoTask?.cancel()
        jobProgress = drink.ingredients.indices.map {
            JobProgress(step: $0, weight: 0.0, status: .Sent)
        }

        let targets: [Float] = drink.ingredients.map {
            Float(drink.totalQty) * Float($0.percent) / 100
        }

        demoTask = Task { @MainActor [weak self] in
            for (step, target) in targets.enumerated() {
                guard let self, !Task.isCancelled else { return }

                self.jobProgress[step].status = .Processing
                self.robotStatus.text = "Demo: dispensing \(drink.ingredients[step].name)"

                let ticks = 30
                for tick in 1...ticks {
                    try? await Task.sleep(for: .milliseconds(100))
                    if Task.isCancelled { return }
                    self.jobProgress[step].weight = target * Float(tick) / Float(ticks)
                }

                self.jobProgress[step].status = .Complete
            }

            self?.robotStatus.text = "Demo: your drink is ready. Enjoy!"
        }
    }
    #endif
    
    func didReceivedMessage(_ message: String?) {
        guard let message else {
            print("[RemoteEngine] Invalid messageReceived parameter == nil")
            return
        }
        
        // Calibration replies first: they'd otherwise fall through both
        // parsers below and be logged as invalid
        if let valveMessage = parseValveMessage(message) {
            MainActor.assumeIsolated { valveCalibration.handle(valveMessage) }
            return
        }

        if let scaleMessage = parseScaleMessage(message) {
            MainActor.assumeIsolated { scaleZero.handle(scaleMessage) }
            return
        }

        if let newUpdate = makeStatusFrom(message: message) {
            guard jobProgress.indices.contains(newUpdate.step) else {
                print("[RemoteEngine] Ignoring progress for out-of-range step \(newUpdate.step)")
                return
            }
            self.jobProgress[newUpdate.step].update(with: newUpdate)
            return
        }
                        
        if (robotStatus.setFrom(text: message) == false) {
            print("[RemoteEngine] Invalid robotStatus ")
        }
        
        
    }
    
            

    
}
