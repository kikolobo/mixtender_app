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

    
    private var cancellables = Set<AnyCancellable>()

    #if targetEnvironment(simulator)
    // Demo mode: CoreBluetooth doesn't work in the simulator, so we fake the
    // connection and replay a realistic dispense so the full UI can be tested
    private var demoTask: Task<Void, Never>?
    #endif

    init(targetPeripheralUUIDString: String) {
        self.bluetoothEngine = BluetoothEngine(targetPeripheralUUIDString: targetPeripheralUUIDString)
        
        
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
        
        bluetoothEngine.$txReady
            .sink { [weak self] txReady in
                guard txReady else { return }
                print("[RemoteEngine] BLE TX is Ready \(String(describing: self?.bluetoothEngine.comStatus))")
                self?.bluetoothEngine.sendStringToPeripheral("ehlo")
            }
            .store(in: &cancellables)

        #if targetEnvironment(simulator)
        bluetoothEngine.simulateConnect()
        robotStatus.isCupReady = true
        robotStatus.text = "Demo mode: simulated robot"
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
