//
//  Drink.swift
//  MixBot
//
//  Created by Francisco Lobo on 24/03/24.
//

import Foundation

struct JobProgress: Equatable {
    enum Result {
        case Processing
        case Complete
        case Failed
        case Sent
        case Unknown
    }
    
    var step: Int
    var weight: Float
    var status: Result
    
    mutating func update(with status: JobProgress) {
        if (self.step != status.step) {
            fatalError("[JobStatus] fatal error. Step missmatch")
        }
        
        
        if (status.weight != -1 && status.weight > 0.0) {
            self.weight = status.weight
        }
        
        self.status = status.status
    }
    
}



func update( status:inout JobProgress, from input: String) {
    let prefix = input.prefix(1)
    let trimmedString = String(input.dropFirst())
        
    // Split the string by '='
    let components = trimmedString.split(separator: "=", omittingEmptySubsequences: true)
    if components.count != 2 {
        print("[DrinkJobStatus] [interpretRobotStatus] [ERROR] Malformed Message. Missing component")
        return
    }
    
    // Extract and convert the numeric part
    let stepPart = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
    guard let step = Int(stepPart) else {
        print("[DrinkJobStatus] [interpretRobotStatus] [ERROR] Malformed Message. Cant extract step")
        return
    }
    
//    var result = JobStatus(step: step, weight: -1, status: .Unknown)
    
    if (prefix == "W") {
        let weightPart = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedWeight = weightPart.trimmingCharacters(in: CharacterSet(charactersIn: ";"))
        
        let w  = Float(cleanedWeight) ?? 0.0
        
        if (w > status.weight && status.weight != -1) {
            status.weight = w
        }
        
    } else if (prefix == "S") {
        let characterPart = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedCharacterPart = characterPart.trimmingCharacters(in: CharacterSet(charactersIn: ";"))
        
        if (cleanedCharacterPart == "P") {
            print("[DrinkJobStatus] [interpretRobotStatus] Step: \(stepPart) PROCESSING")
            status.status = .Processing
        } else if (cleanedCharacterPart == "C") {
            print("[DrinkJobStatus] [interpretRobotStatus] Step: \(stepPart) COMPLETED")
            status.status = .Complete
        } else {
            print("[DrinkJobStatus] [interpretRobotStatus] Step: \(stepPart) FAILED")
            status.status = .Failed
        }
    }
        
        
}



func makeStatusFrom(message input: String) -> JobProgress? {
    let prefix = input.prefix(1)
    let trimmedString = String(input.dropFirst())
        
    // Split the string by '='
    let components = trimmedString.split(separator: "=", omittingEmptySubsequences: true)
    if components.count != 2 {
        print("[DrinkJobStatus] [interpretRobotStatus] [ERROR] Malformed Message. Missing component")
        return nil
    }
    
    // Extract and convert the numeric part
    let stepPart = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
    guard let step = Int(stepPart) else {
        print("[DrinkJobStatus] [interpretRobotStatus] [ERROR] Malformed Message. Cant extract step")
        return nil
    }
    
    var result = JobProgress(step: step, weight: -1, status: .Unknown)
    
    if (prefix == "W") {
        let weightPart = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedWeight = weightPart.trimmingCharacters(in: CharacterSet(charactersIn: ";"))
        
        let w  = Float(cleanedWeight) ?? 0.0
        result.weight = w
        
    } else if (prefix == "S") {
        let characterPart = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedCharacterPart = characterPart.trimmingCharacters(in: CharacterSet(charactersIn: ";"))
        
        if (cleanedCharacterPart == "P") {
            print("[DrinkJobStatus] [interpretRobotStatus] Step: \(stepPart) PROCESSING")
            result.status = .Processing
        } else if (cleanedCharacterPart == "C") {
            print("[DrinkJobStatus] [interpretRobotStatus] Step: \(stepPart) COMPLETED")
            result.status = .Complete
        } else {
            print("[DrinkJobStatus] [interpretRobotStatus] Step: \(stepPart) FAILED")
            result.status = .Failed
        }
    } else {
        return nil
    }
        
    
    return result
}

