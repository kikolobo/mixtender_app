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
    @Published var drinkServeStatus: DrinkServeStatus?
    
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
                       self?.newMessageArrived()
                   }
                   .store(in: &cancellables)
        
        bluetoothEngine.$txReady
            .sink { [weak self] txReady in
                print("[RemoteEngine] BLE TX is Ready \(String(describing: self?.bluetoothEngine.comStatus))")
                self?.bluetoothEngine.sendStringToPeripheral("ehlo")
            }
            .store(in: &cancellables)
    }
    
    func sendIngredientsToRobot(_ drink: Drink) {
        var txString = "D:"
        
        for ingredient in drink.ingredients {
            let pct = Float(ingredient.percent) / 100
            let amt = Float(drink.totalQty) * pct
            txString += String(ingredient.stationId) + "=" + String(format: "%.2f", amt) + ","
        }
        
        txString = String(txString.dropLast())
        print("[RemoteEngine] Sending : \(txString)" )
        
        
        bluetoothEngine.sendStringToPeripheral(txString)
    }
    
    func performServing(drink: Drink) {
        self.statusMessage = "Requesting Drink..."
        if (self.bluetoothEngine.isConnected == true) {
            sendIngredientsToRobot(drink)
        }
    }
    
    func cancelServing() {
        self.statusMessage = "Cancel Requested"
        if (self.bluetoothEngine.isConnected == true) {
            bluetoothEngine.sendStringToPeripheral("C!")
        }
    }
    
    func newMessageArrived() {
        print("[RemoteEngine] RX: " + bluetoothEngine.rx)
    }
    
}
