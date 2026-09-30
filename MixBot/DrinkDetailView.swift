import SwiftUI

struct DrinkDetailView: View {
    @State var drink: Drink
    @State private var weights: [Double]
    @State private var showChecklist = false // For navigation trigger
    @EnvironmentObject var remoteEngine: RemoteEngine

    // "Make It Your Own": save a modified mix as a new drink on the menu
    let onDrinkAdded: ([Drink]) -> Void
    // True for drinks born in the app (AI Tender) rather than on the menu:
    // saving is always offered and the drink's own name/description prefill
    let isCreation: Bool
    private let originalPercents: [Double]
    @State private var showCreationSheet = false
    @State private var newDrinkName = ""
    @State private var newDrinkAuthor = ""
    @State private var creationMessage: String?
    @State private var isSavingCreation = false

    // Same palette as the menu, cycled per ingredient
    private let accents: [Color] = [.purple, .pink, .orange, .teal, .indigo, .mint]

    init(drink: Drink, isCreation: Bool = false, onDrinkAdded: @escaping ([Drink]) -> Void = { _ in }) {
        self.drink = drink
        self.isCreation = isCreation
        self.onDrinkAdded = onDrinkAdded
        self.originalPercents = drink.ingredients.map(\.percent)
        // Seed from the recipe directly so the mix never flashes an
        // equal-split state before onAppear corrects it
        self._weights = State(initialValue: drink.ingredients.map(\.percent))
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

                if let author = drink.author, !author.isEmpty {
                    HStack(spacing: 4) {
                        Label("By \(author)", systemImage: "person.fill")
                        if drink.aiAssisted == true {
                            Image(systemName: "apple.intelligence")
                                .accessibilityLabel("Made with AI Tender")
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isModified || isCreation {
                    Button {
                        newDrinkName = isCreation ? drink.name : ""
                        newDrinkAuthor = ""
                        showCreationSheet = true
                    } label: {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.purple)
                    }
                    .disabled(isSavingCreation)
                    .accessibilityLabel("Make It Your Own")
                }
            }
        }
        .navigationDestination(isPresented: $showChecklist) {
            ProcessView(drink: drink)
        }
        .sheet(isPresented: $showCreationSheet) {
            MakeItYourOwnSheet(baseName: drink.name,
                               weights: weights,
                               colors: ingredientColors,
                               totalQty: drink.totalQty,
                               name: $newDrinkName,
                               author: $newDrinkAuthor) {
                Task { await saveCreation() }
            }
        }
        .alert("Menu", isPresented: creationMessagePresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(creationMessage ?? "")
        }
    }

    private var isModified: Bool {
        weights != originalPercents
    }

    private var creationMessagePresented: Binding<Bool> {
        Binding(
            get: { creationMessage != nil },
            set: { if !$0 { creationMessage = nil } }
        )
    }

    /// Appends the current mix to the live menu as a new drink. Add-only by
    /// design: changing or removing drinks requires the passcode-gated editor.
    @MainActor
    private func saveCreation() async {
        let name = newDrinkName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            creationMessage = "Please give your drink a name."
            return
        }

        isSavingCreation = true
        defer { isSavingCreation = false }
        do {
            var (menu, updatedAt) = try await MenuAPI.fetchLive()
            guard !menu.drinks.contains(where: { $0.name == name }) else {
                creationMessage = "A drink named '\(name)' already exists. Pick another name."
                return
            }

            // Round the mix and pin the sum to exactly 100 on the largest pour
            var percents = weights.map { $0.rounded() }
            if let maxIndex = percents.indices.max(by: { percents[$0] < percents[$1] }) {
                percents[maxIndex] += 100 - percents.reduce(0, +)
            }

            // Keep a label only where the serving name differs from the station name
            let stationNames = Dictionary(uniqueKeysWithValues: menu.stations.map { ($0.id, $0.name) })
            let ingredients = zip(drink.ingredients, percents).map { ingredient, percent in
                MenuIngredient(stationId: ingredient.stationId,
                               percent: percent,
                               label: ingredient.name == stationNames[ingredient.stationId] ? nil : ingredient.name)
            }

            let author = newDrinkAuthor.trimmingCharacters(in: .whitespaces)
            menu.drinks.append(MenuDrink(name: name,
                                         description: isCreation ? drink.description : "Based on \(drink.name)",
                                         totalQty: drink.totalQty,
                                         ingredients: ingredients,
                                         author: author.isEmpty ? nil : author,
                                         aiAssisted: drink.aiAssisted == true ? true : nil))

            _ = try await MenuAPI.save(menu, ifMatch: updatedAt)
            if let drinks = menu.resolvedDrinks() {
                onDrinkAdded(drinks)
            }
            creationMessage = "'\(name)' was added to the menu."
        } catch MenuAPIError.conflict {
            creationMessage = "The menu is being edited right now. Try again in a moment."
        } catch {
            creationMessage = error.localizedDescription
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

// Playful save dialog for "Make It Your Own", in the same visual language as
// the serving view: gradient sparkles badge, the mix being saved, bubbles.
struct MakeItYourOwnSheet: View {
    let baseName: String
    let weights: [Double]
    let colors: [Color]
    let totalQty: Int
    @Binding var name: String
    @Binding var author: String
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [.purple, .pink],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .shadow(color: .pink.opacity(0.35), radius: 10, y: 4)
                    Image(systemName: "sparkles")
                        .font(.title)
                        .foregroundStyle(.white)
                }
                .frame(width: 64, height: 64)
                .padding(.top, 26)

                VStack(spacing: 4) {
                    Text("Make It Your Own")
                        .font(.title2.bold())
                    Text("Your remix of \(baseName), saved to the menu for everyone to enjoy.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                MixProportionCard(weights: weights, colors: colors, totalQty: totalQty)

                VStack(spacing: 12) {
                    CreationField(icon: "wineglass.fill",
                                  tint: .purple,
                                  placeholder: "Name your drink",
                                  text: $name)
                    CreationField(icon: "person.fill",
                                  tint: .pink,
                                  placeholder: "Your name (optional)",
                                  text: $author)
                }

                Button {
                    dismiss()
                    onSave()
                } label: {
                    Label("Save to Menu", systemImage: "sparkles")
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
                .disabled(trimmedName.isEmpty)
                .opacity(trimmedName.isEmpty ? 0.45 : 1)
                .animation(.easeOut(duration: 0.15), value: trimmedName.isEmpty)

                Button("Cancel") {
                    dismiss()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.bottom, 12)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        // Typed names must never be lost to a stray swipe; the buttons are
        // the only way out
        .interactiveDismissDisabled()
        .presentationDragIndicator(.hidden)
        .presentationDetents([.height(600), .large])
    }
}

// Rounded input row matching the ingredient cards
struct CreationField: View {
    let icon: String
    let tint: Color
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 24)
            TextField(placeholder, text: $text)
                .autocorrectionDisabled()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        )
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
