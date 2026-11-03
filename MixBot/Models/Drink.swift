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
    var author: String? = nil
    var aiAssisted: Bool? = nil

    // Stable across menu refreshes — a random UUID per decode broke sheet
    // identity and zoom transition matching when the menu reloaded
    var id: String { name }

    /// Why the robot would refuse this drink, or nil when it can be poured.
    /// Checked before offering SERVE so an out-of-limits recipe never turns
    /// into a pour where every step fails.
    var pourBlockReason: String? {
        if totalQty > RobotLimits.maxPourQty {
            return "Too large for the glass (max \(RobotLimits.maxPourQty) ml)"
        }
        if ingredients.contains(where: { !RobotLimits.stationIds.contains($0.stationId) }) {
            return "Uses a station the robot doesn't have"
        }
        return nil
    }
}
