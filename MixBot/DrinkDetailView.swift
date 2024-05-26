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
    @EnvironmentObject var remoteEngine: RemoteEngine
    
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
                if (remoteEngine.bluetoothEngine.isConnected == true) {
                    if (remoteEngine.bluetoothEngine.cupStatus == true) {
                        DividerButton(title: "SERVE MY DRINK!", action: {
                            self.showChecklist = false // Trigger navigation
                        })
                    } else {
                        Text("Please place your cup").frame(maxWidth: .infinity, alignment: .center)
                            .padding().font(.headline)
                    }
                } else {
                    Text("Robot not connected").frame(maxWidth: .infinity, alignment: .center)
                        .padding().font(.headline)
                }
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

struct CustomSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let accentColor: Color
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.gray.opacity(0.3))
                    .frame(height: 6)
                
                Capsule()
                    .fill(accentColor)
                    .frame(width: CGFloat(self.value / (self.range.upperBound - self.range.lowerBound)) * geometry.size.width, height: 6)
                
                Circle()
                    .fill(accentColor)
                    .frame(width: 20, height: 20)
                    .offset(x: CGFloat(self.value / (self.range.upperBound - self.range.lowerBound)) * geometry.size.width - 10)
                    .gesture(
                        DragGesture()
                            .onChanged { gesture in
                                let newValue = Double(gesture.location.x / geometry.size.width) * (self.range.upperBound - self.range.lowerBound)
                                self.value = min(max(self.range.lowerBound, newValue), self.range.upperBound)
                            }
                    )
            }
        }
        .frame(height: 20)
    }
}

#Preview {
    DrinkDetailView(drink: Drink(name: "vermont", description: "", totalQty: 300, ingredients: [Ingredient(name: "Tequila", stationId: 1, percent: 33), Ingredient(name: "Gim", stationId: 1, percent: 33), Ingredient(name: "Mezcal", stationId: 1, percent: 33)])).environmentObject(RemoteEngine(targetPeripheralUUIDString:  "4ac8a682-9736-4e5d-932b-e9b31405049c"))
}
