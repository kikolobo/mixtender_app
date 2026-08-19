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
    
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var remoteEngine: RemoteEngine

    
    init(drink: Drink) {
        self.drink = drink
        self._items = State(initialValue: drink.ingredients.map { ListItem(ingredient: $0, completed: false, working: false, weight: 0.0) })
    }

    var body: some View {
        VStack(spacing: 14) {
            ServingGlassView(items: items, totalQty: drink.totalQty) { index in
                items[index].completed.toggle()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text(remoteEngine.robotStatus.text ?? "--")
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .font(.callout)
                .foregroundStyle(.secondary)
            Button(action: {
                if (self.isProcessing == true) {
                    print("[ProcessView] Cancel Request")
                    self.remoteEngine.cancelDispense()
                } else {
                    print("[ProcessView] Closing View")
                }
               dismiss()

            }) {
                Text(self.isProcessing ? "Cancel" : "Done!")
                    .bold()
                    .frame(maxWidth: .infinity, minHeight: 20)
                    
                       }
            .buttonStyle(isProcessing ? AnyButtonStyle(RedButtonStyle()) : AnyButtonStyle(GreenButtonStyle()))

        }
        .padding()
        // Keep the progress view at a comfortable width on iPad
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .background(Color(.systemGroupedBackground))
        // Don't let a swipe close the sheet while the robot is dispensing
        .interactiveDismissDisabled(isProcessing)
        .onAppear() {
            remoteEngine.beginDispensing(drink: self.drink)
        }.onChange(of: remoteEngine.jobProgress) {
            var finishedCount = 0
            for newItem in remoteEngine.jobProgress {
                let step = newItem.step
                guard self.items.indices.contains(step) else {
                    print("[ProcessView] Ignoring progress for out-of-range step \(step)")
                    continue
                }

                switch newItem.status {
                case .Complete:
                    self.items[step].completed = true
                    self.items[step].working = false
                    self.items[step].failed = false
                    finishedCount += 1
                case .Processing:
                    self.items[step].working = true
                    self.items[step].completed = false
                case .Failed:
                    self.items[step].failed = true
                    self.items[step].working = false
                    self.items[step].completed = false
                    finishedCount += 1
                default:
                    break
                }

                self.items[step].weight = newItem.weight
            }

            // Failed steps also count as finished so the view can't get stuck in "Cancel"
            if (finishedCount >= self.items.count) {
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
    var failed: Bool = false

    var imageName: String {
        if failed == true {
            return "xmark.circle.fill"
        } else if working == true && completed == false {
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
