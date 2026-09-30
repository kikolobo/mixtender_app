//
//  DrinkMenu.swift
//  MixBot
//

import Foundation

// Wire format for the v2 menu file (drinks_v2.json). Stations are defined
// once at the top of the file and recipes reference them by id, so a
// station's name is edited in one place instead of in every recipe.
// The menu is decoded and validated here, then resolved into the runtime
// Drink/Ingredient models — the views and the BLE payload never see this
// format.

struct DrinkMenu: Codable {
    var version: Int
    var stations: [Station]
    var drinks: [MenuDrink]
}

struct Station: Codable {
    var id: Int
    var name: String
}

struct MenuDrink: Codable {
    var name: String
    var description: String
    var totalQty: Int
    var ingredients: [MenuIngredient]
}

struct MenuIngredient: Codable {
    var stationId: Int
    var percent: Double
    // Optional display-name override; the station name is used when absent
    var label: String?
}

extension DrinkMenu {
    // Hand-edited files may carry small rounding noise in percent sums
    private static let percentTolerance = 0.5

    /// Validates the menu and resolves each ingredient's display name from
    /// the station definitions (or its label override). Returns nil with a
    /// printed reason on any integrity error, so callers can fall back to a
    /// known-good copy instead of pouring from a miswired recipe.
    func resolvedDrinks() -> [Drink]? {
        var stationNames: [Int: String] = [:]
        for station in stations {
            guard stationNames[station.id] == nil else {
                print("[DrinkMenu] Duplicate station id \(station.id)")
                return nil
            }
            stationNames[station.id] = station.name
        }

        var resolved: [Drink] = []
        for drink in drinks {
            guard !drink.ingredients.isEmpty else {
                print("[DrinkMenu] Drink '\(drink.name)' has no ingredients")
                return nil
            }

            let percentSum = drink.ingredients.reduce(0) { $0 + $1.percent }
            guard abs(percentSum - 100) <= Self.percentTolerance else {
                print("[DrinkMenu] Drink '\(drink.name)' percents sum to \(percentSum), expected 100")
                return nil
            }

            var ingredients: [Ingredient] = []
            for ingredient in drink.ingredients {
                guard let stationName = stationNames[ingredient.stationId] else {
                    print("[DrinkMenu] Drink '\(drink.name)' references unknown station \(ingredient.stationId)")
                    return nil
                }
                ingredients.append(Ingredient(name: ingredient.label ?? stationName,
                                              stationId: ingredient.stationId,
                                              percent: ingredient.percent))
            }

            resolved.append(Drink(name: drink.name,
                                  description: drink.description,
                                  totalQty: drink.totalQty,
                                  ingredients: ingredients))
        }

        return resolved
    }
}
