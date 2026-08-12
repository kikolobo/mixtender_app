import Foundation
import CoreBluetooth
import Combine



class BluetoothEngine: NSObject, ObservableObject, CBCentralManagerDelegate {
    @Published var comStatus: String = "Disconnected"
    @Published var rx: String = ""
    @Published var isConnected: Bool = false
    @Published var txReady = false
    
    private var shouldConnectOnReady = true
    private var isManualDisconnect = false

    private var centralManager: CBCentralManager?
    private let targetPeripheralUUID: CBUUID
    private var discoveredPeripheral: CBPeripheral?

    // Initialize with the UUID of the device you want to connect to
    init(targetPeripheralUUIDString: String) {
        self.targetPeripheralUUID = CBUUID(string: targetPeripheralUUIDString)
        super.init()
        self.centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            print("[BLE] Ready")
            comStatus = "Searching for robot"
            if (shouldConnectOnReady == true)  {
                connect()
            }
        default:
            print("[BLE] Not Available")
            comStatus = "Bluetooth not Available"
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        comStatus = "\(peripheral.name ?? "robot") discovered"
        discoveredPeripheral = peripheral
        centralManager?.stopScan()
        centralManager?.connect(peripheral, options: nil)
        print("[BLE] " + comStatus)
    }

    //Connected CallBack
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnected = true
        comStatus = "\(peripheral.name ?? "robot") found"
        print("[BLE] " + comStatus)
        self.discoveredPeripheral = peripheral
        peripheral.delegate = self
//        let serviceUUID = CBUUID(string: "4ac8a682-9736-4e5d-932b-e9b31405049c")
        peripheral.discoverServices(nil)

    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("[BLE] Failed to connect: \(error?.localizedDescription ?? "unknown error")")
        isConnected = false
        txReady = false
        comStatus = "Connection failed, retrying"
        centralManager?.scanForPeripherals(withServices: [targetPeripheralUUID], options: nil)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("[BLE] Disconnected: \(error?.localizedDescription ?? "no error")")
        isConnected = false
        txReady = false
        discoveredPeripheral = nil

        if isManualDisconnect {
            isManualDisconnect = false
            comStatus = "Disconnected"
        } else {
            comStatus = "Connection lost, searching for robot"
            centralManager?.scanForPeripherals(withServices: [targetPeripheralUUID], options: nil)
        }
    }

    func connect() {
        shouldConnectOnReady = false
        print("[BLE] Called connect()")
        guard let centralManager = centralManager, centralManager.state == .poweredOn else {
            print("[BLE] BLE is Off")
            comStatus = "Bluetooth is off"
            shouldConnectOnReady = true
            return
        }
        
        centralManager.scanForPeripherals(withServices: [targetPeripheralUUID], options: nil)
    }
    
    func disconnect() {
        guard let centralManager = centralManager, let discoveredPeripheral = discoveredPeripheral else { return }
        isManualDisconnect = true
        centralManager.cancelPeripheralConnection(discoveredPeripheral)
        isConnected = false
        txReady = false
        comStatus = "Disconnected"
    }
    
    func simulateConnect() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.isConnected = true
            self.comStatus = "Robot is Connected (Sim)"
        }
    }
    
    func stopScanning() {
        centralManager?.stopScan()
        comStatus = "Stopped scanning"
    }
}


extension BluetoothEngine: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("[BLE] Error writing value to characteristic: \(characteristic.uuid) \(error.localizedDescription)")
            // Handle error as needed
        } else {
            print("[BLE] Successfully wrote value to characteristic")
            // Handle success as needed
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        if let error = error {
            print("[BLE] Error discovering services: \(error.localizedDescription)")
            return
        }

        print("[BLE] peripheral didDiscoverServices: ")
        guard let services = peripheral.services else { return }
        for service in services {
            print("     S>" + service.uuid.uuidString)
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        if let error = error {
            print("[BLE] Error discovering characteristics: \(error.localizedDescription)")
            return
        }

        print("[BLE] peripheral didDiscoverCharacteristicsFor: " + service.uuid.uuidString)

        guard let characteristics = service.characteristics else { return }
        for characteristic in characteristics {
            print("    C>" + characteristic.uuid.uuidString)
            if characteristic.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }

        if service.uuid == targetPeripheralUUID {
            txReady = true
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: (any Error)?) {
        print("[BLE] peripheral didUpdateNotificationStateFor:  Characteristic " + characteristic.uuid.uuidString)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("[BLE] Error updating value for characteristic: \(error.localizedDescription)")
            return
        }

        guard let data = characteristic.value else {
            print("[BLE] No data RX")
            return
        }

        if let message = String(data: data, encoding: .utf8) {
            rx = message

            if (findCharacteristicForSending() == characteristic) {
                print("[BLE] RX ControlMSG: \(message)")
            }
        } else {
            print("[BLE] RX Conversion Failed")
        }
    }
    
}



extension BluetoothEngine {
    // Helper function to find the appropriate characteristic for sending data
    private func findCharacteristicForSending() -> CBCharacteristic? {
        guard let peripheral = discoveredPeripheral else { return nil }

        // Replace "YOUR_CHARACTERISTIC_UUID" with the UUID of the characteristic you want to write to
        let characteristicUUID = CBUUID(string: "4ac8a682-9736-4e5d-932b-e9b31405049c")
        
       
        // Find the characteristic matching the UUID
        if let service = peripheral.services?.first(where: { $0.uuid == targetPeripheralUUID }),
           let characteristic = service.characteristics?.first(where: { $0.uuid == characteristicUUID }) {
            return characteristic
        } else {
            print("[BLE] Control Characteristic not found")
            return nil
        }
    }
    
    private func findCharacteristicForRobotStatus() -> CBCharacteristic? {
        guard let peripheral = discoveredPeripheral else { return nil }

        // Replace "YOUR_CHARACTERISTIC_UUID" with the UUID of the characteristic you want to write to
        let characteristicUUID = CBUUID(string: "6bcdd021-ffa5-4522-9454-a21d025d6562")
        
       
        // Find the characteristic matching the UUID
        if let service = peripheral.services?.first(where: { $0.uuid == targetPeripheralUUID }),
           let characteristic = service.characteristics?.first(where: { $0.uuid == characteristicUUID }) {
            return characteristic
        } else {
            print("[BLE] Control Characteristic not found")
            return nil
        }
    }
    
    
    // Function to send a string to the connected BLE device
    func sendStringToPeripheral(_ string: String) {
        guard let peripheral = discoveredPeripheral, let characteristic = findCharacteristicForSending() else {
            print("[BLE] No connected peripheral or characteristic found")
            return
        }

        guard let data = string.data(using: .utf8) else {
            print("[BLE] Could not encode message as UTF-8")
            return
        }
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
    }
}
