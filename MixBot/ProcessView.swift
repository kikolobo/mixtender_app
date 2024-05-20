//
//  ProcessView.swift
//  MixBot
//
//  Created by Francisco Lobo on 24/03/24.
//

import SwiftUI


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

struct ProcessView: View {
    let drink: Drink
    @State private var items: [ListItem] = []
    @State private var imageName = "circle"
    @State private var isProcessing = true
    @State private var currentStep = 0
    
    @Environment(\.presentationMode) var presentationMode
    @EnvironmentObject var remoteEngine: RemoteEngine

    
    
    init(drink: Drink) {
        self.drink = drink
        self._items = State(initialValue: drink.ingredients.map { ListItem(ingredient: $0, completed: false, working: false, weight: 0) })
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
            Text(remoteEngine.bluetoothEngine.robotStatus)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .padding()
                .font(.callout)
            Button(action: {
                if (self.isProcessing == true) {
                    print("[ProcessView] Cancel Request")
                    self.remoteEngine.cancelServing()
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
            remoteEngine.performServing(drink: self.drink)
        }.onChange(of: remoteEngine.bluetoothEngine.robotProcess?.step) {
            currentStep = remoteEngine.bluetoothEngine.robotProcess?.step ?? 0
            
        }.onChange(of: remoteEngine.bluetoothEngine.robotProcess?.status) {
            let step = currentStep
                        
            if (remoteEngine.bluetoothEngine.robotProcess?.status == .Complete) {
                self.items[step].completed = true
                self.items[step].working = false
                print("------------------>. Completed! \(step)")
                if (step == self.items.count-1) {
                    isProcessing = false
                }
            }
            
            if (remoteEngine.bluetoothEngine.robotProcess?.status == .Processing) {
                self.items[step].working = true
                self.items[step].completed = false
                print("------------------>. Processing! \(step)")
            }
        }.onChange(of: remoteEngine.bluetoothEngine.robotProcess?.weight) {
            let step = currentStep
//                if (self.items[step].completed == false && self.items[step].working == true) {
            if ( self.items[step].weight < remoteEngine.bluetoothEngine.robotProcess?.weight ?? 0) {
                self.items[step].weight = remoteEngine.bluetoothEngine.robotProcess?.weight ?? 0
            }
//                }
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
