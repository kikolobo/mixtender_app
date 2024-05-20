//
//  Ingredient.swift
//  MixBot
//
//  Created by Francisco Lobo on 24/03/24.
//

import Foundation

struct Ingredient: Identifiable {
    var id = UUID()
    var name: String
    var stationId: Int
    var percent: Double
}
