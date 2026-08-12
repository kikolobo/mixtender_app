import SwiftUI

struct DrinkDetailView: View {
    @State var drink: Drink
    @State private var weights: [Double]
    @State private var showChecklist = false // For navigation trigger
    @EnvironmentObject var remoteEngine: RemoteEngine

    // Same palette as the menu, cycled per ingredient
    private let accents: [Color] = [.purple, .pink, .orange, .teal, .indigo, .mint]

    init(drink: Drink) {
        self.drink = drink
        let count = drink.ingredients.count
        let initialWeight = count > 0 ? 100.0 / Double(count) : 0
        self._weights = State(initialValue: Array(repeating: initialWeight, count: count))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if !drink.description.isEmpty {
                    Text(drink.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                MixProportionCard(
                    weights: weights,
                    colors: ingredientColors,
                    totalQty: drink.totalQty
                )

                ForEach(drink.ingredients.indices, id: \.self) { index in
                    IngredientSliderCard(
                        name: drink.ingredients[index].name,
                        color: ingredientColors[index],
                        percent: Binding(
                            get: { self.weights[index] },
                            set: { newValue in
                                let delta = newValue - self.weights[index]
                                self.weights[index] = newValue
                                adjustSliders(except: index, by: delta)
                            }
                        ),
                        amount: weights[index] / 100 * Double(drink.totalQty)
                    )
                }
            }
            .padding()
            // Keep the formula at a comfortable width on iPad instead of stretching edge to edge
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .safeAreaInset(edge: .bottom) {
            bottomActionBar
        }
        .onChange(of: self.weights) {
            for (idx, weight) in weights.enumerated() {
                self.drink.ingredients[idx].percent = weight
            }
        }
        .onAppear() {
            for (idx, ingredient) in drink.ingredients.enumerated() {
                weights[idx] = ingredient.percent
            }
        }
        .navigationTitle(drink.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showChecklist) {
            ProcessView(drink: drink)
        }
    }

    private var ingredientColors: [Color] {
        drink.ingredients.indices.map { accents[$0 % accents.count] }
    }

    @ViewBuilder
    private var bottomActionBar: some View {
        VStack(spacing: 0) {
            if remoteEngine.bluetoothEngine.isConnected {
                if remoteEngine.robotStatus.isCupReady == true {
                    Button(action: {
                        self.showChecklist = true // Trigger navigation
                    }) {
                        Text("SERVE MY DRINK!")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                Capsule().fill(LinearGradient(
                                    colors: [.purple, .pink],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ))
                            )
                    }
                    .buttonStyle(.plain)
                } else {
                    StatusHint(icon: "cup.and.saucer.fill", text: "Please place your cup")
                }
            } else {
                StatusHint(icon: "antenna.radiowaves.left.and.right.slash", text: "Robot not connected")
            }
        }
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func adjustSliders(except excludedIndex: Int, by delta: Double) {
        // With a single ingredient there is nothing to redistribute and the
        // count - 1 divisions below would divide by zero
        guard weights.count > 1 else {
            if !weights.isEmpty { weights[excludedIndex] = 100 }
            return
        }

        let otherIndexes = weights.indices.filter { $0 != excludedIndex }
        let sumOfOthers = otherIndexes.reduce(0) { $0 + weights[$1] }

        // Redistribute the delta among other sliders proportionally
        if sumOfOthers > 0 {
            for i in otherIndexes {
                weights[i] = max(0, weights[i] - (weights[i] / sumOfOthers) * delta)
            }
        } else {
            for i in otherIndexes {
                weights[i] = max(0, weights[i] - delta / Double(weights.count - 1))
            }
        }

        // Ensure the current slider stays within bounds
        weights[excludedIndex] = min(max(weights[excludedIndex], 0), 100)

        // Normalize the weights to ensure they sum up to 100
        let total = weights.reduce(0, +)
        if total != 100 {
            let correction = (100 - total) / Double(weights.count - 1)
            for i in otherIndexes {
                weights[i] = min(max(weights[i] + correction, 0), 100)
            }
        }

        // Round weights to nearest integer
        weights = weights.map { round($0) }
    }
}

// Horizontal bar showing each ingredient's share of the final drink
struct MixProportionCard: View {
    let weights: [Double]
    let colors: [Color]
    let totalQty: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your Mix")
                    .font(.headline)
                Spacer()
                Text("\(totalQty) ml")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geometry in
                let total = max(weights.reduce(0, +), 1)
                HStack(spacing: 2) {
                    ForEach(weights.indices, id: \.self) { index in
                        Rectangle()
                            .fill(colors[index])
                            .frame(width: max(0, weights[index] / total) * geometry.size.width)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: weights)
            }
            .frame(height: 16)
            .clipShape(Capsule())
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        )
    }
}

struct IngredientSliderCard: View {
    let name: String
    let color: Color
    @Binding var percent: Double
    let amount: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 10, height: 10)
                Text(name)
                    .font(.headline)
                Spacer()
                Text("\(Int(percent))%")
                    .font(.headline)
                    .monospacedDigit()
                Text("\(Int(amount)) ml")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Slider(value: $percent, in: 0...100)
                .tint(color)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        )
    }
}

struct StatusHint: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Capsule().fill(Color(.secondarySystemGroupedBackground)))
    }
}

#Preview {
    NavigationStack {
        DrinkDetailView(drink: Drink(name: "Margarita",
                                     description: "Classic tequila cocktail with a citrus kick",
                                     totalQty: 300,
                                     ingredients: [Ingredient(name: "Tequila", stationId: 1, percent: 40),
                                                   Ingredient(name: "Triple Sec", stationId: 2, percent: 30),
                                                   Ingredient(name: "Lime Juice", stationId: 3, percent: 30)]))
            .environmentObject(RemoteEngine(targetPeripheralUUIDString: "4ac8a682-9736-4e5d-932b-e9b31405049c"))
    }
}
