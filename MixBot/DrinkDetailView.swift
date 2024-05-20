//
//  DrinkDetailView.swift
//  MixBot
//
//  Created by Francisco Lobo on 21/03/24.
//

import SwiftUI

import SwiftUI

import SwiftUI

struct DividerButton: View {
    let title: String
    let action: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            Button(action: action) {
                Text(title)
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderedProminent)
            
            .listRowInsets(EdgeInsets()).padding()
        }
    }
}

struct DrinkDetailView: View {
    @State var drink: Drink
    @State private var weights: [Double]
    @State private var showChecklist = false // For navigation trigger
    
    init(drink: Drink) {
        self.drink = drink
        let initialWeight = 100.0 / Double(drink.ingredients.count)
        self._weights = State(initialValue: Array(repeating: initialWeight, count: drink.ingredients.count))
    }

    var body: some View {
        VStack {
            List {
                ForEach(drink.ingredients.indices, id: \.self) { index in
                    VStack {
                        Text(drink.ingredients[index].name)
                            .font(.headline)
                        Slider(value: Binding(
                            get: { self.weights[index] },
                            set: { newValue in
                                let delta = newValue - self.weights[index]
                                self.weights[index] = newValue
                                adjustSliders(except: index, by: delta)
                            }
                        ), in: 0...100)
                        Text("\(Int(self.weights[index]))%")
                    }
                }
                DividerButton(title: "SERVE", action: {
                    self.showChecklist = true // Trigger navigation
                })
            }
        }.onChange(of: self.weights) {
            for (idx, weight) in weights.enumerated() {
                self.drink.ingredients[idx].percent = weight
                print("Updated Ingredient: " + self.drink.ingredients[idx].name + " = " + String(self.drink.ingredients[idx].percent))
            }
        }
        .onAppear() {
            for (idx, ingredient) in drink.ingredients.enumerated() {
                weights[idx] = ingredient.percent
                print("Assign Weight from Ingredient: " + self.drink.ingredients[idx].name + " = " + String(self.drink.ingredients[idx].percent))
            }
        }
        .navigationTitle(drink.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showChecklist) {
            ProcessView(drink: drink)
        }
    }

    private func adjustSliders(except excludedIndex: Int, by delta: Double) {
        let otherIndexes = weights.indices.filter { $0 != excludedIndex }
        let sumOfOthers = otherIndexes.reduce(0) { $0 + weights[$1] }

        for i in otherIndexes {
            if sumOfOthers > 0 {
                // Proportionally adjust other sliders to account for the change in the current slider.
                weights[i] = max(0, weights[i] - (weights[i] / sumOfOthers) * delta)
            } else {
                // If sumOfOthers is 0 or negative, it means the current slider is set to 100 or more,
                // set other sliders to 0.
                weights[i] = 0
            }
        }

        // Ensure the total doesn't exceed 100 due to rounding errors.
        let total = weights.reduce(0, +)
        if total != 100 {
            weights[excludedIndex] += 100 - total
        }
    }
}


#Preview {
    DrinkDetailView(drink: Drink(name: "vermont", totalQty: 100, ingredients: [Ingredient(name: "Tequila", stationId: 1, percent: 100), Ingredient(name: "Gim", stationId: 1, percent: 100), Ingredient(name: "Mezcal", stationId: 1, percent: 100)]))
}
