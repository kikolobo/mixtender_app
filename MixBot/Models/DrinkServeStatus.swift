//
//  Drink.swift
//  MixBot
//
//  Created by Francisco Lobo on 24/03/24.
//

import Foundation


struct DrinkServeStatus: Identifiable {
    var id = UUID()
    var drink: Drink
    var ingredients: [IngredientServeStatus]
    var totalWeightServed: Double
    var done: Bool = false
    var glassSize: Double
    
    mutating func updateIngredientStatusIdx(idx: Int, weight: Double, done: Bool) {
        ingredients[idx].weightServed = weight
        
        
        if (done == true) {
            ingredients[idx].done = done
            totalWeightServed = totalWeightServed + weight
            if (idx-1 == ingredients.count) {
                self.done = true
            }
        }
    }
    
}
