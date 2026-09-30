//
//  DrinkEditorView.swift
//  MixBot
//

import SwiftUI

// Form for a single drink inside the menu editor. Edits flow straight into
// the editor's DrinkMenu via bindings; nothing is published until the editor's
// Save button PUTs the whole menu.
//
// Percent sliders auto-balance like the serving view: moving one slider
// redistributes the difference across the others so the total stays at 100.

struct DrinkEditorView: View {
    @Binding var drink: MenuDrink
    let stations: [Station]

    var body: some View {
        Form {
            Section("Drink") {
                TextField("Name", text: $drink.name)
                TextField("Description", text: $drink.description, axis: .vertical)
                TextField("Author (optional)", text: authorBinding)
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
                    IngredientEditorRow(ingredient: $ingredient,
                                        stations: stations,
                                        percent: balancedPercent(for: ingredient.id))
                }
                .onDelete { offsets in
                    drink.ingredients.remove(atOffsets: offsets)
                    rebalanceAfterRemoval()
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

    // The wire format omits author when empty; the UI edits it as plain text
    private var authorBinding: Binding<String> {
        Binding(
            get: { drink.author ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                drink.author = trimmed.isEmpty ? nil : newValue
            }
        )
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

    /// Binding for one ingredient's slider that keeps the total pinned at 100
    /// by redistributing the change across the other ingredients.
    private func balancedPercent(for id: UUID) -> Binding<Double> {
        Binding(
            get: { drink.ingredients.first { $0.id == id }?.percent ?? 0 },
            set: { newValue in
                guard let index = drink.ingredients.firstIndex(where: { $0.id == id }) else { return }
                let delta = newValue - drink.ingredients[index].percent
                drink.ingredients[index].percent = newValue
                adjustOthers(except: index, by: delta)
            }
        )
    }

    // Same redistribution approach as the serving view's sliders, plus a
    // residual fix so rounding can never leave the sum off 100 (the menu
    // would fail validation on save otherwise)
    private func adjustOthers(except excludedIndex: Int, by delta: Double) {
        var percents = drink.ingredients.map(\.percent)

        guard percents.count > 1 else {
            drink.ingredients[excludedIndex].percent = 100
            return
        }

        let otherIndexes = percents.indices.filter { $0 != excludedIndex }
        let sumOfOthers = otherIndexes.reduce(0) { $0 + percents[$1] }

        // Redistribute the delta among the other sliders proportionally
        if sumOfOthers > 0 {
            for i in otherIndexes {
                percents[i] = max(0, percents[i] - (percents[i] / sumOfOthers) * delta)
            }
        } else {
            for i in otherIndexes {
                percents[i] = max(0, percents[i] - delta / Double(percents.count - 1))
            }
        }

        percents[excludedIndex] = min(max(percents[excludedIndex], 0), 100)
        percents = percents.map { $0.rounded() }

        // Pin the sum to exactly 100 on the largest other ingredient
        let residual = 100 - percents.reduce(0, +)
        if residual != 0, let target = otherIndexes.max(by: { percents[$0] < percents[$1] }) {
            percents[target] = min(max(percents[target] + residual, 0), 100)
        }

        for (i, value) in percents.enumerated() {
            drink.ingredients[i].percent = value
        }
    }

    /// After deleting an ingredient, scale the remaining ones back to 100.
    private func rebalanceAfterRemoval() {
        guard !drink.ingredients.isEmpty else { return }
        let sum = percentSum
        if sum > 0 {
            for i in drink.ingredients.indices {
                drink.ingredients[i].percent = (drink.ingredients[i].percent * 100 / sum).rounded()
            }
        } else {
            let share = (100.0 / Double(drink.ingredients.count)).rounded()
            for i in drink.ingredients.indices {
                drink.ingredients[i].percent = share
            }
        }
        // Pin rounding drift on the largest ingredient
        let residual = 100 - percentSum
        if residual != 0, let target = drink.ingredients.indices.max(by: { drink.ingredients[$0].percent < drink.ingredients[$1].percent }) {
            drink.ingredients[target].percent += residual
        }
    }
}

struct IngredientEditorRow: View {
    @Binding var ingredient: MenuIngredient
    let stations: [Station]
    let percent: Binding<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Station", selection: $ingredient.stationId) {
                ForEach(stations) { station in
                    Text(station.name).tag(station.id)
                }
            }

            HStack(spacing: 10) {
                Slider(value: percent, in: 0...100, step: 1)
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
