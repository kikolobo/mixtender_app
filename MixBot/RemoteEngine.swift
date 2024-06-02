//
//  RemoteState.swift
//  MixBot
//
//  Created by Francisco Lobo on 20/04/24.
//

import Foundation
import Combine



struct RobotStatus {
    enum StatusType {
        case Cup
        case Text
        case Unknown
    }
    
    var isCupReady:Bool?
    var text: String?
    var type: StatusType = .Unknown
    
    mutating func setFrom(text input: String) -> Bool {
        guard input.first == "$" else {
              return false
          }

          let components = input.dropFirst().split(separator: "=", maxSplits: 1, omittingEmptySubsequences: true)
          if components.count != 2 {
              print("[BLE][getStatusMessage][ERROR] Malformatted status message, does not contain enough components")
              return false
          }
          
        let messageTypeComp = Int(components[0])
        let cleanedTextComp = String(components[1])
        
        switch messageTypeComp {
        case 0:
            type = .Text
            text = cleanedTextComp
        case 1:
            type = .Cup
            if (cleanedTextComp == "1") { isCupReady = true } else { isCupReady = false }
        default:
            type = .Unknown
            isCupReady = nil
            text = nil
        }
        
      return true
    }
}


class RemoteEngine: ObservableObject {    
    @Published var isReady: Bool = false
    @Published var stateMessage: String = ""
    @Published var robotStatus: RobotStatus = RobotStatus()
    @Published var bluetoothEngine: BluetoothEngine
    @Published var jobProgress = [JobProgress]()

    
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
                           self?.stateMessage = "Connected"
                       }
                       else {
                           self?.stateMessage = "Not Connected"
                       }
                   }
                   .store(in: &cancellables)
        
        bluetoothEngine.$rx
                   .sink { [weak self] rx in
                       self?.didReceivedMessage(rx)
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
        self.stateMessage = "Requesting Drink..."
        if (self.bluetoothEngine.isConnected == true) {
            self.sendJobToRobot(drink)
        }
    }
    
    func cancelServing() {
        self.stateMessage = "Cancel Requested"
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
            self.jobProgress[newUpdate.step].update(with: newUpdate)
            return
        }
                        
        if (robotStatus.setFrom(text: message) == false) {
            print("[RemoteEngine] Invalid robotStatus ")
        }
        
        
    }
    
            

    
}
