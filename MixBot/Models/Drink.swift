//
//  Drink.swift
//  MixBot
//
//  Created by Francisco Lobo on 24/03/24.
//

import Foundation


struct Drink: Identifiable, Codable {
    var id = UUID()
    var name: String
    var description: String
    var totalQty: Int
    var ingredients: [Ingredient]
    
    enum CodingKeys: CodingKey {        
        case name
        case description
        case totalQty
        case ingredients
    }
}
