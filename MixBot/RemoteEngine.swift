//
//  RemoteState.swift
//  MixBot
//
//  Created by Francisco Lobo on 20/04/24.
//

import Foundation
import Combine


class RemoteEngine: ObservableObject {    
    @Published var isReady: Bool = false
    @Published var statusMessage: String = ""
    @Published var bluetoothEngine: BluetoothEngine
    @Published var jobStatus = [JobStatus]()
    
    private var cancellables = Set<AnyCancellable>()
    
    init(targetPeripheralUUIDString: String) {
        self.bluetoothEngine = BluetoothEngine(targetPeripheralUUIDString: targetPeripheralUUIDString)
        
        
        bluetoothEngine.objectWillChange
                    .sink { [weak self] _ in
                        self?.objectWillChange.send()
                    }
                    .store(in: &cancellables)
        
        bluetoothEngine.$isConnected
                   .sink { [weak self] isConnected in
                       // Handle isConnected change
                       if (isConnected == true) {
                           self?.statusMessage = "Connected"
                       }
                       else {
                           self?.statusMessage = "Not Connected"
                       }
                   }
                   .store(in: &cancellables)
        
        bluetoothEngine.$rx
                   .sink { [weak self] isConnected in
                       self?.messageReceived(self?.bluetoothEngine.rx)
                   }
                   .store(in: &cancellables)
        
        bluetoothEngine.$txReady
            .sink { [weak self] txReady in
                print("[RemoteEngine] BLE TX is Ready \(String(describing: self?.bluetoothEngine.comStatus))")
                self?.bluetoothEngine.sendStringToPeripheral("ehlo")
            }
            .store(in: &cancellables)
    }
    
    func sendJobToRobot(_ drink: Drink) {
        
        self.jobStatus.removeAll()
        
        var txString = "D:"
        var step = 0
        for ingredient in drink.ingredients {
            let pct = Float(ingredient.percent) / 100
            let amt = Float(drink.totalQty) * pct
            txString += String(ingredient.stationId) + "=" + String(format: "%.2f", amt) + ","
            self.jobStatus.append(JobStatus(step: step, weight: amt, status: .Sent))
            step = step + 1
        }
        
        txString = String(txString.dropLast())
        print("[RemoteEngine] Sending : \(txString)" )
        
        
        bluetoothEngine.sendStringToPeripheral(txString)
    }
    
    func performServing(drink: Drink) {
        self.statusMessage = "Requesting Drink..."
        if (self.bluetoothEngine.isConnected == true) {
            sendJobToRobot(drink)
        }
    }
    
    func cancelServing() {
        self.statusMessage = "Cancel Requested"
        if (self.bluetoothEngine.isConnected == true) {
            bluetoothEngine.sendStringToPeripheral("C!")
        }
    }
    
    func messageReceived(_ message: String?) {
        guard let message else {
            print("[RemoteEngine] Invalid messageReceived parameter == nil")
            return
        }
        
        guard let jobUpdate = makeStatusFrom(message: message) else {
            print("[RemoteEngine][messageReceived] Not a valid Status Message (ignoring): " + message)
            return
        }
        
//        print("[RemoteEngine][messageReceived] jobStatus Upated = [\(jobUpdate.step)]")
        self.jobStatus[jobUpdate.step].step = jobUpdate.step
        self.jobStatus[jobUpdate.step].weight = jobUpdate.weight
        self.jobStatus[jobUpdate.step].status = jobUpdate.status
        
    }
    
}
