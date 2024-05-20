//
//  Drink.swift
//  MixBot
//
//  Created by Francisco Lobo on 24/03/24.
//

import Foundation


struct Drink: Identifiable {
    var id = UUID()
    var name: String
    var description: String?
    var totalQty: UInt
    var ingredients: [Ingredient]
}
