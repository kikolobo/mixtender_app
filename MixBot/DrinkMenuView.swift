import SwiftUI

struct DrinkMenuView: View {
    @EnvironmentObject var remoteEngine: RemoteEngine

    @State private var drinks: [Drink] = []
    @State private var selectedDrink: Drink?
    @State private var showMenuEditor = false
    @State private var showPasscodePrompt = false
    @State private var passcodeInput = ""
    @State private var showWrongPasscode = false
    @Namespace private var zoomNamespace

    // Accent colors cycled through the drink cards
    private let accents: [Color] = [.purple, .pink, .orange, .teal, .indigo, .mint]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if drinks.isEmpty {
                    Spacer()
                    ProgressView("Loading menu…")
                        .controlSize(.large)
                    Spacer()
                } else {
                    ScrollView {
                        // Adaptive grid: one column on iPhone, two or three on iPad
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 12)], spacing: 12) {
                            ForEach(Array(drinks.enumerated()), id: \.element.id) { index, drink in
                                Button {
                                    // Ignore taps that race a sheet dismissal — reassigning the
                                    // item mid-dismiss makes SwiftUI reuse the old sheet's state
                                    guard selectedDrink == nil else { return }
                                    selectedDrink = drink
                                } label: {
                                    DrinkCard(drink: drink, accent: accents[index % accents.count])
                                }
                                .buttonStyle(.plain)
                                .zoomTransitionSource(id: drink.id, in: zoomNamespace)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 8)
                        .padding(.bottom, 12)
                    }
                }

                RobotStatusBar(
                    isConnected: remoteEngine.bluetoothEngine.isConnected,
                    comStatus: remoteEngine.bluetoothEngine.comStatus,
                    robotText: remoteEngine.robotStatus.text
                )
            }
            .background(BubblesBackground().ignoresSafeArea())
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Choose a Drink")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: {
                        passcodeInput = ""
                        showPasscodePrompt = true
                    }) {
                        Image(systemName: "square.and.pencil").foregroundColor(.primary)
                    }
                    .accessibilityLabel("Edit Menu")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        fetchDrinks()
                    }) {
                        Image(systemName: "arrow.clockwise").foregroundColor(.primary)
                    }
                }
            }
            // Attached here (not next to the drink sheet) so both sheets can coexist
            .sheet(isPresented: $showMenuEditor) {
                MenuEditorView { savedDrinks in
                    // Update straight from the saved data: a server refetch right
                    // after a save can still return the previous version (KV
                    // propagation delay)
                    self.drinks = savedDrinks
                }
            }
            .alert("Editor Passcode", isPresented: $showPasscodePrompt) {
                SecureField("Passcode", text: $passcodeInput)
                Button("Unlock") {
                    if passcodeInput == MenuAPI.editorPasscode {
                        showMenuEditor = true
                    } else {
                        showWrongPasscode = true
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Wrong Passcode", isPresented: $showWrongPasscode) {
                Button("OK", role: .cancel) {}
            }
        }
        .sheet(item: $selectedDrink) { drink in
            NavigationStack {
                DrinkDetailView(drink: drink, onDrinkAdded: { savedDrinks in
                    self.drinks = savedDrinks
                })
                    // Force fresh view state per drink so a lingering
                    // presentation can never show the previous formula
                    .id(drink.id)
            }
            .zoomTransition(sourceID: drink.id, in: zoomNamespace)
            .drinkSheetSizing()
            .presentationDragIndicator(.visible)
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

// Zoom transition helpers: the card-to-sheet zoom needs iOS 18; on iOS 17
// these are no-ops and the sheet uses the standard slide-up presentation.
extension View {
    @ViewBuilder
    func zoomTransitionSource(id: some Hashable, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            self.matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    @ViewBuilder
    func zoomTransition(sourceID: some Hashable, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            self.navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        } else {
            self
        }
    }

    // Sized between .form (too cramped) and .page (covers almost everything)
    // on iPad; no effect on iPhone, where sheets are always full-size.
    @ViewBuilder
    func drinkSheetSizing() -> some View {
        if #available(iOS 18.0, *) {
            self.presentationSizing(DrinkSheetSizing())
        } else {
            self
        }
    }
}

@available(iOS 18.0, *)
private struct DrinkSheetSizing: PresentationSizing {
    func proposedSize(for root: PresentationSizingRoot, context: PresentationSizingContext) -> ProposedViewSize {
        ProposedViewSize(width: 680, height: 800)
    }
}

struct DrinkCard: View {
    let drink: Drink
    let accent: Color

    private var ingredientSummary: String {
        drink.ingredients.map { $0.name }.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(LinearGradient(
                        colors: [accent, accent.opacity(0.55)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                Image(systemName: "wineglass.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
            }
            .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 3) {
                Text(drink.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                if !drink.description.isEmpty {
                    Text(drink.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if !ingredientSummary.isEmpty {
                    Text(ingredientSummary)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        // Fill the grid cell so cards in the same row get equal height
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        )
    }
}

struct RobotStatusBar: View {
    let isConnected: Bool
    let comStatus: String
    let robotText: String?

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isConnected ? Color.green : Color.orange)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 1) {
                Text(comStatus)
                    .font(.footnote.weight(.medium))
                if let robotText, !robotText.isEmpty {
                    Text(robotText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Capsule().fill(.ultraThinMaterial))
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    DrinkMenuView()
        .environmentObject(RemoteEngine(targetPeripheralUUIDString: "4ac8a682-9736-4e5d-932b-e9b31405049c"))
}

#Preview("Drink Cards") {
    ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 12)], spacing: 12) {
            DrinkCard(drink: Drink(name: "Margarita",
                                   description: "Classic tequila cocktail with a citrus kick",
                                   totalQty: 300,
                                   ingredients: [Ingredient(name: "Tequila", stationId: 1, percent: 40),
                                                 Ingredient(name: "Triple Sec", stationId: 2, percent: 30),
                                                 Ingredient(name: "Lime Juice", stationId: 3, percent: 30)]),
                      accent: .purple)
            DrinkCard(drink: Drink(name: "Negroni",
                                   description: "Bitter, bold and perfectly balanced",
                                   totalQty: 250,
                                   ingredients: [Ingredient(name: "Gin", stationId: 1, percent: 34),
                                                 Ingredient(name: "Campari", stationId: 2, percent: 33),
                                                 Ingredient(name: "Vermouth", stationId: 3, percent: 33)]),
                      accent: .pink)
            DrinkCard(drink: Drink(name: "Paloma",
                                   description: "",
                                   totalQty: 350,
                                   ingredients: [Ingredient(name: "Tequila", stationId: 1, percent: 30),
                                                 Ingredient(name: "Grapefruit Soda", stationId: 4, percent: 70)]),
                      accent: .orange)
        }
        .padding()
    }
    .background(Color(.systemGroupedBackground))
}
