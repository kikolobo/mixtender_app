//
//  Ingredient.swift
//  MixBot
//
//  Created by Francisco Lobo on 24/03/24.
//

import Foundation

struct IngredientServeStatus: Identifiable {
    var id = UUID()
    var ingredient: Ingredient
    var done: Bool
    var weightServed: Double
}
