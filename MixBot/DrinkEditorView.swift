//
//  DrinkEditorView.swift
//  MixBot
//

import SwiftUI

// Form for a single drink inside the menu editor. Edits flow straight into
// the editor's DrinkMenu via bindings; nothing is published until the editor's
// Save button PUTs the whole menu.

struct DrinkEditorView: View {
    @Binding var drink: MenuDrink
    let stations: [Station]

    var body: some View {
        Form {
            Section("Drink") {
                TextField("Name", text: $drink.name)
                TextField("Description", text: $drink.description, axis: .vertical)
                HStack {
                    Text("Total Quantity")
                    Spacer()
                    TextField("ml", value: $drink.totalQty, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                    Text("ml")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach($drink.ingredients) { $ingredient in
                    IngredientEditorRow(ingredient: $ingredient, stations: stations)
                }
                .onDelete { offsets in
                    drink.ingredients.remove(atOffsets: offsets)
                }

                Button {
                    addIngredient()
                } label: {
                    Label("Add Ingredient", systemImage: "plus.circle.fill")
                }
            } header: {
                Text("Ingredients")
            } footer: {
                percentFooter
            }
        }
        .navigationTitle(drink.name.isEmpty ? "New Drink" : drink.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var percentSum: Double {
        drink.ingredients.reduce(0) { $0 + $1.percent }
    }

    @ViewBuilder
    private var percentFooter: some View {
        if drink.ingredients.isEmpty {
            Label("Add at least one ingredient", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        } else if abs(percentSum - 100) <= DrinkMenu.percentTolerance {
            Label("Percents add up to 100%", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Label("Percents add up to \(Int(percentSum.rounded()))% — they must total 100%",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private func addIngredient() {
        // Prefer a station the drink doesn't use yet, seeded with whatever
        // percent is still missing from 100
        let used = Set(drink.ingredients.map(\.stationId))
        guard let station = stations.first(where: { !used.contains($0.id) }) ?? stations.first else { return }
        let remaining = max(0, min(100, 100 - percentSum))
        drink.ingredients.append(MenuIngredient(stationId: station.id, percent: remaining))
    }
}

struct IngredientEditorRow: View {
    @Binding var ingredient: MenuIngredient
    let stations: [Station]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Station", selection: $ingredient.stationId) {
                ForEach(stations) { station in
                    Text(station.name).tag(station.id)
                }
            }

            HStack(spacing: 10) {
                Slider(value: $ingredient.percent, in: 0...100, step: 1)
                Text("\(Int(ingredient.percent))%")
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }

            TextField("Display name (optional, defaults to station)", text: labelBinding)
                .font(.subheadline)
        }
        .padding(.vertical, 2)
    }

    // The wire format omits label when empty; the UI edits it as plain text
    private var labelBinding: Binding<String> {
        Binding(
            get: { ingredient.label ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                ingredient.label = trimmed.isEmpty ? nil : newValue
            }
        )
    }
}

#Preview {
    struct PreviewHost: View {
        @State private var drink = MenuDrink(
            name: "Margarita",
            description: "Classic tequila cocktail",
            totalQty: 300,
            ingredients: [
                MenuIngredient(stationId: 1, percent: 40),
                MenuIngredient(stationId: 9, percent: 60, label: "Tonic Water")
            ]
        )

        var body: some View {
            NavigationStack {
                DrinkEditorView(drink: $drink,
                                stations: [Station(id: 1, name: "Tequila"),
                                           Station(id: 3, name: "Gin"),
                                           Station(id: 9, name: "Tonic")])
            }
        }
    }
    return PreviewHost()
}
