//
//  DrinkMenu.swift
//  MixBot
//

import Foundation

// Wire format for the v2 menu file (drinks_v2.json / mixbot-api). Stations are
// defined once at the top of the file and recipes reference them by id, so a
// station's name is edited in one place instead of in every recipe.
// The menu is decoded and validated here, then resolved into the runtime
// Drink/Ingredient models — the views and the BLE payload never see this
// format.

struct DrinkMenu: Codable, Equatable {
    var version: Int
    var stations: [Station]
    var drinks: [MenuDrink]
}

struct Station: Codable, Identifiable, Equatable {
    var id: Int
    var name: String
}

struct MenuDrink: Codable, Identifiable, Equatable {
    // Editor identity only (stable while editing); not part of the wire format
    var id = UUID()
    var name: String
    var description: String
    var totalQty: Int
    var ingredients: [MenuIngredient]

    enum CodingKeys: CodingKey {
        case name
        case description
        case totalQty
        case ingredients
    }
}

struct MenuIngredient: Codable, Identifiable, Equatable {
    // Editor identity only (stable while editing); not part of the wire format
    var id = UUID()
    var stationId: Int
    var percent: Double
    // Optional display-name override; the station name is used when absent
    var label: String?

    enum CodingKeys: CodingKey {
        case stationId
        case percent
        case label
    }
}

extension DrinkMenu {
    // Hand-edited files may carry small rounding noise in percent sums
    static let percentTolerance = 0.5

    /// Every integrity problem in the menu, in human-readable form.
    /// Mirrors the server-side validation in mixbot-api so the editor can
    /// catch problems before a save round-trip.
    func validationProblems() -> [String] {
        var problems: [String] = []

        if version != 2 {
            problems.append("version must be 2 (got \(version))")
        }

        var stationIds = Set<Int>()
        if stations.isEmpty {
            problems.append("At least one station is required")
        }
        for station in stations {
            if !stationIds.insert(station.id).inserted {
                problems.append("Duplicate station id \(station.id)")
            }
            if station.name.trimmingCharacters(in: .whitespaces).isEmpty {
                problems.append("Station \(station.id) needs a name")
            }
        }

        if drinks.isEmpty {
            problems.append("The menu needs at least one drink")
        }

        var drinkNames = Set<String>()
        for drink in drinks {
            let name = drink.name.trimmingCharacters(in: .whitespaces)
            if name.isEmpty {
                problems.append("A drink is missing its name")
            } else if !drinkNames.insert(name).inserted {
                // Drink names are the app's stable identity for cards and sheets
                problems.append("Duplicate drink name '\(name)'")
            }

            if drink.totalQty <= 0 {
                problems.append("'\(drink.name)': total quantity must be positive")
            }

            guard !drink.ingredients.isEmpty else {
                problems.append("'\(drink.name)': needs at least one ingredient")
                continue
            }

            for ingredient in drink.ingredients {
                if !stationIds.contains(ingredient.stationId) {
                    problems.append("'\(drink.name)': references unknown station \(ingredient.stationId)")
                }
                if ingredient.percent < 0 || ingredient.percent > 100 {
                    problems.append("'\(drink.name)': percent must be between 0 and 100")
                }
            }

            let percentSum = drink.ingredients.reduce(0) { $0 + $1.percent }
            if abs(percentSum - 100) > Self.percentTolerance {
                problems.append("'\(drink.name)': percents sum to \(Int(percentSum.rounded())), expected 100")
            }
        }

        return problems
    }

    /// Validates the menu and resolves each ingredient's display name from
    /// the station definitions (or its label override). Returns nil with a
    /// printed reason on any integrity error, so callers can fall back to a
    /// known-good copy instead of pouring from a miswired recipe.
    func resolvedDrinks() -> [Drink]? {
        let problems = validationProblems()
        guard problems.isEmpty else {
            for problem in problems {
                print("[DrinkMenu] \(problem)")
            }
            return nil
        }

        let stationNames = Dictionary(uniqueKeysWithValues: stations.map { ($0.id, $0.name) })
        return drinks.map { drink in
            Drink(name: drink.name,
                  description: drink.description,
                  totalQty: drink.totalQty,
                  ingredients: drink.ingredients.map { ingredient in
                      Ingredient(name: ingredient.label ?? stationNames[ingredient.stationId] ?? "Station \(ingredient.stationId)",
                                 stationId: ingredient.stationId,
                                 percent: ingredient.percent)
                  })
        }
    }
}
