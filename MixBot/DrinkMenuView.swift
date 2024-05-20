import SwiftUI

struct DrinkMenuView: View {
    @EnvironmentObject var remoteEngine: RemoteEngine
    
    let drinks: [Drink] = [
        Drink(name: "Gin and Tonic", 
              description: "A refreshing classic.",
              totalQty: 300,
              ingredients: [
            Ingredient(name: "Gin", stationId: 1, percent: 30.0),
            Ingredient(name: "Tonic Water", stationId: 2, percent: 20.0)
        ]),
        Drink(name: "Charro Negro", 
              description: "A tequila-based cocktail.",
              totalQty: 300,
              ingredients: [
            Ingredient(name: "Tequila", stationId: 1, percent: 10)
        ]),
        Drink(name: "Tequila Soda", 
              description: "Simple and straightforward.",
              totalQty: 300,
              ingredients: [
            Ingredient(name: "Tequila", stationId: 1, percent: 10)
        ])
    ]

    var body: some View {
           NavigationStack {
               List {
                   // Drink items
                   ForEach(drinks) { drink in
                       if remoteEngine.bluetoothEngine.isConnected {
                           
                                              NavigationLink(destination: DrinkDetailView(drink: drink)) {
                                                  Text(drink.name)
                                              }
                                          } else {
                                              Text(drink.name)
                                                  .opacity(0.5) // Dim the text to indicate it's disabled
                                          }
                   }
                   
                   // Robot Status at the bottom
                   Section {
                       Text(remoteEngine.bluetoothEngine.comStatus)
                           .frame(maxWidth: .infinity, alignment: .center)
                           .padding()
                           .font(.callout)
                           .foregroundColor(.secondary)
                       Text(remoteEngine.bluetoothEngine.robotStatus)
                           .frame(maxWidth: .infinity, alignment: .center)
                           .padding()
                           .font(.callout)
                           .foregroundColor(.secondary)
                   }.listRowBackground(Color.clear) // Removes the default styling and background of list rows
                       .listRowInsets(EdgeInsets())
               }
               
               .navigationTitle("Choose a Drink")
           }.onAppear() {
               remoteEngine.bluetoothEngine.connect()
           }
       }
}

#Preview {
    DrinkMenuView()
}
