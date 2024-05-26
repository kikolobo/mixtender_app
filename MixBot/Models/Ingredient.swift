//
//  Ingredient.swift
//  MixBot
//
//  Created by Francisco Lobo on 24/03/24.
//

import Foundation

struct Ingredient: Identifiable, Codable {
    var id = UUID()
    var name: String
    var stationId: Int
    var percent: Double
    
    enum CodingKeys: CodingKey {     
        case name
        case stationId
        case percent
    }
}
