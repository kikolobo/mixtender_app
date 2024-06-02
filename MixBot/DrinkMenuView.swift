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
                        NavigationLink(destination: DrinkDetailView(drink: drink)) {
                            Text(drink.name)
                        }
                    }
                }
                .listStyle(PlainListStyle())
                
                // Robot Status at the bottom
                VStack(spacing: 8) {
                    Text(remoteEngine.bluetoothEngine.comStatus)
                        .padding()
                        .font(.callout)
                    Text(remoteEngine.robotStatus.text ?? "--")
                        .padding()
                        .font(.callout)
                }
                .frame(maxWidth: .infinity)
                
            }
            .navigationTitle("Choose a Drink")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        fetchDrinks()
                    }) {
                        Image(systemName: "arrow.clockwise").foregroundColor(.primary)
                    }
                }
            }
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
        .environmentObject(RemoteEngine(targetPeripheralUUIDString: "4ac8a682-9736-4e5d-932b-e9b31405049c"))
}
