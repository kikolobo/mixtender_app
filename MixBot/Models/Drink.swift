//
//  Drink.swift
//  MixBot
//
//  Created by Francisco Lobo on 24/03/24.
//

import Foundation


struct Drink: Identifiable, Codable {
    var name: String
    var description: String
    var totalQty: Int
    var ingredients: [Ingredient]

    // Stable across menu refreshes — a random UUID per decode broke sheet
    // identity and zoom transition matching when the menu reloaded
    var id: String { name }
}
