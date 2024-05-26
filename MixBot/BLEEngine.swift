import Foundation
import CoreBluetooth
import Combine


struct ProcessStatus: Equatable {
    enum Result {
        case Processing
        case Complete
        case Failed
        case Unknown
    }
    
    var step: Int
    var weight: Float
    var status: Result
}


class BluetoothEngine: NSObject, ObservableObject, CBCentralManagerDelegate {
    @Published var comStatus: String = "Disconnected"
    @Published var robotStatus: String = ""
    @Published var cupStatus: Bool = false
    @Published var robotProcess: ProcessStatus?
    @Published var rx: String = ""
    @Published var isConnected: Bool = false
    @Published var txReady = false
    
    var shouldConnectOnReady = true
    
    
    
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
            // Start scanning for devices
            centralManager?.scanForPeripherals(withServices: [targetPeripheralUUID], options: nil)
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
        print("[BLE] peripheral didDiscoverServices: ")
        for service in peripheral.services! {
            print("     S>" + service.uuid.uuidString)
            service.peripheral?.delegate = self
            service.peripheral?.discoverCharacteristics(nil, for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        print("[BLE] peripheral didDiscoverCharacteristicsFor: " + service.uuid.uuidString)
        
        for characteristic in service.characteristics! {
            print("    C>" + characteristic.uuid.uuidString)
            peripheral.setNotifyValue(true, for: characteristic)
        }
        
        txReady = true
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
            
            if (findCharacteristicForRobotStatus() == characteristic) {
                print("[BLE] RX StatusMSG: \(message)")
                
                if let process = interpretRobotStatus(message) {
                    robotProcess = process
                } else if let status = getStatusMessage(message) {
                    if (status.0 == 0) {
                        robotStatus = status.1
                    } else if (status.0 == 1) {
                        cupStatus = (status.1 == "1") ? true : false
                    }
                }
                
            }
            
            if (findCharacteristicForSending() == characteristic) {
                print("[BLE] RX ControlMSG: \(message)")
            }
            
            
            // Handle the received message as needed
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

        let data = string.data(using: .utf8) // Convert the string to data
        peripheral.writeValue(data!, for: characteristic, type: .withResponse)
    }
}


func interpretRobotStatus(_ input: String) -> ProcessStatus? {
    // Check if the string starts with 'S' and remove it
    let prefix = input.prefix(1)
        let trimmedString = String(input.dropFirst())
        
        // Split the string by '='
        let components = trimmedString.split(separator: "=", omittingEmptySubsequences: true)
        if components.count != 2 {
            print("[BLE] [interpretRobotStatus] [ERROR] Malformed Message. Missing component")
            return nil
        }
        
        // Extract and convert the numeric part
        let stepPart = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let step = Int(stepPart) else {
            print("[BLE] [interpretRobotStatus] [ERROR] Malformed Message. Cant extract step")
            return nil
        }
    
    var result = ProcessStatus(step: 0, weight: -1, status: .Unknown)
    result.step = step
        
    
    if (prefix == "W") {
        let weightPart = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedWeight = weightPart.trimmingCharacters(in: CharacterSet(charactersIn: ";"))
        result.weight = Float(cleanedWeight) ?? 0
    } else if (prefix == "S") {
        // Extract the character part, remove semicolon if exists
        let characterPart = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedCharacterPart = characterPart.trimmingCharacters(in: CharacterSet(charactersIn: ";"))
        
        
        
        if (cleanedCharacterPart == "P") {
            print("[BLE] [interpretRobotStatus] Step: \(stepPart) PROCESSING")
            result.status = .Processing
        } else if (cleanedCharacterPart == "C") {
        
            print("[BLE] [interpretRobotStatus] Step: \(stepPart) COMPLETED")
            result.status = .Complete
        } else {
            print("[BLE] [interpretRobotStatus] Step: \(stepPart) FAILED")
        
            result.status = .Failed
        }
    } else {        
        return nil
    }
        
    
    return result
}

func getStatusMessage(_ input: String) -> (Int, String)? {
    guard input.first == "$" else {
          return nil
      }

      let components = input.dropFirst().split(separator: "=", maxSplits: 1, omittingEmptySubsequences: true)
      if components.count != 2 {
          print("[BLE][getStatusMessage][ERROR] Malformatted status message, does not contain enough components")
          return nil
      }
      
      let messageType = Int(components[0])
      let cleanedStatus = String(components[1])

    return (messageType, cleanedStatus) as? (Int, String)
}
