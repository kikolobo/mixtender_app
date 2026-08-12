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
        if (self.bluetoothEngine.isConnected == true) {
            self.sendJobToRobot(drink)
        }
    }
    
    func cancelDispense() {
        if (self.bluetoothEngine.isConnected == true) {
            bluetoothEngine.sendStringToPeripheral("C!")
        }
    }
    
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
