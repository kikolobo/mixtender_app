import SwiftUI

struct DrinkMenuView: View {
    @EnvironmentObject var remoteEngine: RemoteEngine
    
    @State private var drinks: [Drink] = []
    
    var body: some View {
        NavigationStack {
            VStack {
                List {
                    // Drink items
                    ForEach(drinks) { drink in
//                        if remoteEngine.bluetoothEngine.isConnected == false {
//                            Text(drink.name)
//                                .opacity(0.5) // Dim the text to indicate it's disabled
//                        } else {
                            NavigationLink(destination: DrinkDetailView(drink: drink)) {
                                Text(drink.name)
//                            }
                        }
                    }
                }
                .listStyle(PlainListStyle())
                
                
                // Robot Status at the bottom
                VStack(spacing: 8) {
                    Text(remoteEngine.bluetoothEngine.comStatus)
                        .padding()
                        .font(.callout)
                        .foregroundColor(.secondary)
                    Text(remoteEngine.bluetoothEngine.robotStatus)
                        .padding()
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                
            }
            .navigationTitle("Choose a Drink")             
        }
        .onAppear {
            remoteEngine.bluetoothEngine.connect()
            fetchDrinks()
        }
    }
    
    private func fetchDrinks() {
        downloadAndCacheMenu { downloadedDrinks in
            if let downloadedDrinks = downloadedDrinks {
                self.drinks = downloadedDrinks
                print("[DrinkMenu] Using Live ONLINE Menu:")                
            } else {
                
                if let cachedDrinks = getDrinksCachedFile() {
                    self.drinks = cachedDrinks
                    print("[DrinkMenu] Using Local/Cached Menu")
                } else {
                    self.drinks = loadLocalDrinks()
                    print("[DrinkMenu] Using Local/Bundled Menu")
                }
            }
        }
    }
}

#Preview {
    DrinkMenuView()
        .environmentObject(RemoteEngine(targetPeripheralUUIDString:  "4ac8a682-9736-4e5d-932b-e9b31405049c"))
}
