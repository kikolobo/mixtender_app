//
//  ProcessView.swift
//  MixBot
//
//  Created by Francisco Lobo on 24/03/24.
//

import SwiftUI

struct ProcessView: View {
    let drink: Drink
    @State private var items: [ListItem] = []
    @State private var isProcessing = true
    
    @Environment(\.presentationMode) var presentationMode
    @EnvironmentObject var remoteEngine: RemoteEngine

    
    init(drink: Drink) {
        self.drink = drink
        self._items = State(initialValue: drink.ingredients.map { ListItem(ingredient: $0, completed: false, working: false, weight: 0.0) })
    }

    var body: some View {
        List {
            ForEach($items) { $item in
                HStack {
                    // First column for the ingredient name
                    Text(item.ingredient.name)
                        .frame(width: 120, alignment: .leading)  // Adjust width as needed
                    
                    Spacer()

                    // Second column for the weight
                    Text(String(format: "%.2f", item.weight))  // Formatting to 2 decimal places
                        .frame(width: 60, alignment: .trailing)  // Adjust width as needed

                    Spacer()

                    // Third column for the icon
                    Image(systemName: item.imageName)
                        .foregroundColor(item.completed ? .green : .gray)
                        .frame(width: 30, alignment: .center)  // Adjust width as needed
                        .onTapGesture {
                            item.completed.toggle()
                        }
                }
            }
            Text(remoteEngine.robotStatus.text ?? "--")
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .padding()
                .font(.callout)
            Button(action: {
                if (self.isProcessing == true) {
                    print("[ProcessView] Cancel Request")
                    self.remoteEngine.cancelDispense()
                } else {
                    print("[ProcessView] Closing View")
                }
               self.presentationMode.wrappedValue.dismiss()
                
            }) {
                Text(self.isProcessing ? "Cancel" : "Done!")
                    .bold()
                    .frame(maxWidth: .infinity, minHeight: 20)
                    
                       }
            .buttonStyle(isProcessing ? AnyButtonStyle(RedButtonStyle()) : AnyButtonStyle(GreenButtonStyle()))
           
        }.onAppear() {
            remoteEngine.beginDispensing(drink: self.drink)
        }.onChange(of: remoteEngine.jobProgress) {
            var completedCount = 0
            for newItem in remoteEngine.jobProgress {
                let step = newItem.step
                if (newItem.status == .Complete) {
                    self.items[step].completed = true
                    self.items[step].working = false
                    completedCount = completedCount + 1
                } else if (newItem.status == .Processing) {
                    self.items[step].working = true
                    self.items[step].completed = false
                }
                                
                self.items[step].weight = newItem.weight
            }
            
            if (completedCount >= self.items.count) {
                self.isProcessing = false
            }
        }
    }
}

struct RedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding()
            .background(Color.red)
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
    }
}
struct GreenButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding()
            .background(Color.green)
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
    }
}

struct AnyButtonStyle: ButtonStyle {
    private let _makeBody: (Configuration) -> AnyView
    @EnvironmentObject var bluetoothEngine: BluetoothEngine

    init<Style: ButtonStyle>(_ style: Style) {
        _makeBody = { configuration in AnyView(style.makeBody(configuration: configuration)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        _makeBody(configuration)
    }
}

struct ListItem: Identifiable {
    var id: UUID { ingredient.id }
    var ingredient: Ingredient
    var completed: Bool
    var working: Bool
    var weight: Float
    
    var imageName: String {
        if working == true && completed == false {
            return "play.circle"
        } else if completed == true {
            return "checkmark.circle.fill"
        } else {
            return "circle"
        }
    }
}


// Define a preview for your SwiftUI view
//
//#Preview {
//             
//        ProcessView(drink: Drink(name: "Test Drink", totalQty: 100, ingredients: [
//            Ingredient(name: "Tequila", stationId: 1, percent: 10),
//            Ingredient(name: "Tequila", stationId: 1, percent: 10),
//            Ingredient(name: "Tequila", stationId: 1, percent: 10),
//            Ingredient(name: "Tequila", stationId: 1, percent: 10),
//            ]))
//}
