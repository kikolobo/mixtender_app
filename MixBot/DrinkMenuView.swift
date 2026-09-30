import SwiftUI

struct DrinkMenuView: View {
    @EnvironmentObject var remoteEngine: RemoteEngine

    @State private var drinks: [Drink] = []
    @State private var selectedDrink: Drink?
    @State private var showMenuEditor = false
    @State private var showPasscodePrompt = false
    @State private var passcodeAccepted = false
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
            // Open the editor from onDismiss, not from the success callback:
            // presenting one sheet while another is mid-dismissal gets dropped
            .sheet(isPresented: $showPasscodePrompt, onDismiss: {
                if passcodeAccepted {
                    passcodeAccepted = false
                    showMenuEditor = true
                }
            }) {
                PasscodeSheet {
                    passcodeAccepted = true
                }
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
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                selectedDrink = nil
                            } label: {
                                Image(systemName: "xmark")
                                    .foregroundStyle(.primary)
                            }
                            .accessibilityLabel("Close")
                        }
                    }
            }
            .zoomTransition(sourceID: drink.id, in: zoomNamespace)
            .drinkSheetSizing()
            // The sheet is locked: dragging the sliders near the top edge must
            // never swipe the drink away, so the close button is the only way out
            .interactiveDismissDisabled()
            .presentationDragIndicator(.hidden)
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

// Presentation helpers shared by the drink and editor sheets.
extension View {
    func zoomTransitionSource(id: some Hashable, in namespace: Namespace.ID) -> some View {
        self.matchedTransitionSource(id: id, in: namespace)
    }

    func zoomTransition(sourceID: some Hashable, in namespace: Namespace.ID) -> some View {
        self.navigationTransition(.zoom(sourceID: sourceID, in: namespace))
    }

    // Sized between .form (too cramped) and .page (covers almost everything)
    // on iPad; no effect on iPhone, where sheets are always full-size.
    func drinkSheetSizing() -> some View {
        self.presentationSizing(DrinkSheetSizing())
    }

    // The editor holds a drink list plus nested forms, so on iPad it gets the
    // largest standard sheet; no effect on iPhone.
    func menuEditorSheetSizing() -> some View {
        self.presentationSizing(.page)
    }
}

private struct DrinkSheetSizing: PresentationSizing {
    func proposedSize(for root: PresentationSizingRoot, context: PresentationSizingContext) -> ProposedViewSize {
        ProposedViewSize(width: 680, height: 800)
    }
}

// 4-digit numeric keypad gating the menu editor, in the app's visual
// language. Wrong codes shake and clear; the right code unlocks immediately.
struct PasscodeSheet: View {
    let onUnlock: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var digits = ""
    @State private var failedAttempts = 0
    @State private var unlocked = false

    private static let keypadRows: [[String]] = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        ["", "0", "⌫"]
    ]

    var body: some View {
        VStack(spacing: 22) {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(.primary)
                }
                .accessibilityLabel("Close")
                Spacer()
            }
            .padding(.top, 18)

            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [.purple, .pink],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .shadow(color: .pink.opacity(0.35), radius: 10, y: 4)
                Image(systemName: unlocked ? "lock.open.fill" : "lock.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
            }
            .frame(width: 56, height: 56)

            VStack(spacing: 4) {
                Text("Editor Passcode")
                    .font(.title3.bold())
                Text("Enter the 4-digit code")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                ForEach(0..<4, id: \.self) { index in
                    Circle()
                        .fill(index < digits.count ? Color.purple : Color(.tertiarySystemGroupedBackground))
                        .frame(width: 14, height: 14)
                }
            }
            .modifier(PasscodeShake(animatableData: CGFloat(failedAttempts)))

            VStack(spacing: 12) {
                ForEach(Self.keypadRows, id: \.self) { row in
                    HStack(spacing: 24) {
                        ForEach(row, id: \.self) { key in
                            keypadButton(key)
                        }
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity)
        .background(Color(.systemGroupedBackground))
        .sensoryFeedback(.error, trigger: failedAttempts)
        .sensoryFeedback(.success, trigger: unlocked)
        .interactiveDismissDisabled()
        .presentationDragIndicator(.hidden)
        .presentationDetents([.height(620)])
    }

    @ViewBuilder
    private func keypadButton(_ key: String) -> some View {
        if key.isEmpty {
            Color.clear.frame(width: 72, height: 72)
        } else {
            Button {
                tap(key)
            } label: {
                Group {
                    if key == "⌫" {
                        Image(systemName: "delete.left")
                            .font(.title3)
                    } else {
                        Text(key)
                            .font(.title2.weight(.medium))
                            .monospacedDigit()
                    }
                }
                .foregroundStyle(.primary)
                .frame(width: 72, height: 72)
                .background(
                    Circle()
                        .fill(Color(.secondarySystemGroupedBackground))
                        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func tap(_ key: String) {
        guard !unlocked else { return }
        if key == "⌫" {
            if !digits.isEmpty { digits.removeLast() }
            return
        }
        guard digits.count < 4 else { return }
        digits += key

        guard digits.count == 4 else { return }
        if digits == MenuAPI.editorPasscode {
            unlocked = true
            onUnlock()
            // Give the open-lock icon a beat before the sheet slides away
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                dismiss()
            }
        } else {
            // Let the 4th dot render before shaking and clearing
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.default) { failedAttempts += 1 }
                digits = ""
            }
        }
    }
}

// Same wiggle as the serving glass's failure shake (that one is private to
// its file)
private struct PasscodeShake: GeometryEffect {
    var travel: CGFloat = 8
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(
            CGAffineTransform(translationX: travel * sin(animatableData * .pi * 6), y: 0)
        )
    }
}

struct DrinkCard: View {
    let drink: Drink
    let accent: Color

    private var ingredientSummary: String {
        drink.ingredients.map { $0.name }.joined(separator: " · ")
    }

    // Factory recipes are the house defaults; a byline only means something
    // for drinks people created themselves
    private var displayAuthor: String? {
        guard let author = drink.author, !author.isEmpty,
              author.caseInsensitiveCompare("Factory") != .orderedSame else { return nil }
        return author
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
                if let displayAuthor {
                    HStack(spacing: 4) {
                        Label("By \(displayAuthor)", systemImage: "person.fill")
                        if drink.aiAssisted == true {
                            Image(systemName: "apple.intelligence")
                                .accessibilityLabel("Made with AI Tender")
                        }
                    }
                    .font(.caption2)
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
