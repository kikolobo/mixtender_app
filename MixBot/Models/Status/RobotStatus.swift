//
//  RobotStatus.swift
//  MixBot
//
//  Created by Francisco Lobo on 02/06/24.
//

import Foundation

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
