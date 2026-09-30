//
//  MenuEditorView.swift
//  MixBot
//

import SwiftUI

// Menu editor: add, edit, clone and delete drinks, then publish the whole
// menu to the server in one Save. Editing always starts from the live server
// version so the If-Match token is valid; nothing changes for other
// controllers until Save succeeds.

struct MenuEditorView: View {
    /// Called with the freshly resolved drinks after a successful save, so the
    /// main menu can update without waiting out KV's propagation delay.
    let onSaved: ([Drink]) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var menu: DrinkMenu?
    @State private var savedSnapshot: DrinkMenu?
    @State private var updatedAt = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var loadErrorText: String?
    @State private var alertMessage: String?
    @State private var showConflictAlert = false
    @State private var showDiscardConfirm = false

    private var hasChanges: Bool { menu != savedSnapshot }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading live menu…")
                        .controlSize(.large)
                } else if let loadErrorText {
                    VStack(spacing: 14) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(loadErrorText)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        Button("Try Again") {
                            Task { await load() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                } else if let menuBinding = Binding($menu) {
                    drinkList(menuBinding)
                }
            }
            .navigationTitle("Edit Menu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        if hasChanges {
                            showDiscardConfirm = true
                        } else {
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(.primary)
                    }
                    .accessibilityLabel("Close")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .disabled(!hasChanges || isSaving || menu == nil)
                }
            }
            .confirmationDialog("You have unsaved changes.", isPresented: $showDiscardConfirm, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            }
            .alert("Couldn't Save", isPresented: alertPresented) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertMessage ?? "")
            }
            .alert("Menu Changed Elsewhere", isPresented: $showConflictAlert) {
                Button("Reload Latest (discard my edits)", role: .destructive) {
                    Task { await load() }
                }
                Button("Keep Editing", role: .cancel) {}
            } message: {
                Text("Another controller saved a different version of the menu. Reload to get the latest; saving is blocked until you do.")
            }
        }
        .task { await load() }
        // The sheet is locked: slider drags and stray swipes must never close
        // the editor, so the close button is the only way out
        .interactiveDismissDisabled()
        .presentationDragIndicator(.hidden)
        .menuEditorSheetSizing()
    }

    private func drinkList(_ menu: Binding<DrinkMenu>) -> some View {
        List {
            Section {
                ForEach(menu.drinks) { $drink in
                    NavigationLink {
                        DrinkEditorView(drink: $drink, stations: menu.wrappedValue.stations)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(drink.name)
                                .font(.headline)
                            Text(summary(for: drink, stations: menu.wrappedValue.stations))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            delete(drink)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            clone(drink)
                        } label: {
                            Label("Clone", systemImage: "doc.on.doc")
                        }
                        .tint(.blue)
                    }
                }
            } footer: {
                Text("Swipe a drink to clone or delete it. Changes go live for every controller when you tap Save.")
            }

            Section {
                Button {
                    addDrink()
                } label: {
                    Label("Add Drink", systemImage: "plus.circle.fill")
                }
            }

            Section {
                NavigationLink {
                    StationEditorView(menu: menu)
                } label: {
                    HStack {
                        Label("Stations", systemImage: "drop.fill")
                        Spacer()
                        Text("\(menu.wrappedValue.stations.count)")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Robot")
            } footer: {
                Text("Configure what the robot pours at each station.")
            }
        }
    }

    private func summary(for drink: MenuDrink, stations: [Station]) -> String {
        let names = Dictionary(uniqueKeysWithValues: stations.map { ($0.id, $0.name) })
        let ingredients = drink.ingredients
            .map { $0.label ?? names[$0.stationId] ?? "Station \($0.stationId)" }
            .joined(separator: " · ")
        return "\(drink.totalQty) ml — \(ingredients)"
    }

    private func addDrink() {
        guard var menu, let firstStation = menu.stations.first else { return }
        let name = uniqueName("New Drink", in: menu)
        menu.drinks.append(MenuDrink(name: name,
                                     description: "",
                                     totalQty: 300,
                                     ingredients: [MenuIngredient(stationId: firstStation.id, percent: 100)]))
        self.menu = menu
    }

    private func clone(_ drink: MenuDrink) {
        guard var menu, let index = menu.drinks.firstIndex(where: { $0.id == drink.id }) else { return }
        // New editor ids throughout so the copy is fully independent
        let copy = MenuDrink(name: uniqueName("\(drink.name) Copy", in: menu),
                             description: drink.description,
                             totalQty: drink.totalQty,
                             ingredients: drink.ingredients.map {
                                 MenuIngredient(stationId: $0.stationId, percent: $0.percent, label: $0.label)
                             },
                             author: drink.author,
                             aiAssisted: drink.aiAssisted)
        menu.drinks.insert(copy, at: index + 1)
        self.menu = menu
    }

    private func delete(_ drink: MenuDrink) {
        menu?.drinks.removeAll { $0.id == drink.id }
    }

    private func uniqueName(_ base: String, in menu: DrinkMenu) -> String {
        let existing = Set(menu.drinks.map(\.name))
        if !existing.contains(base) { return base }
        var counter = 2
        while existing.contains("\(base) \(counter)") { counter += 1 }
        return "\(base) \(counter)"
    }

    private var alertPresented: Binding<Bool> {
        Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )
    }

    @MainActor
    private func load() async {
        isLoading = true
        loadErrorText = nil
        do {
            let live = try await MenuAPI.fetchLive()
            menu = live.menu
            savedSnapshot = live.menu
            updatedAt = live.updatedAt
        } catch {
            loadErrorText = "Couldn't load the live menu — editing needs a connection to the server.\n\(error.localizedDescription)"
        }
        isLoading = false
    }

    @MainActor
    private func save() async {
        guard let menu else { return }

        // Catch problems locally before a round-trip; the server enforces the
        // same rules regardless
        let problems = menu.validationProblems()
        guard problems.isEmpty else {
            alertMessage = "Please fix:\n• " + problems.joined(separator: "\n• ")
            return
        }

        isSaving = true
        defer { isSaving = false }
        do {
            updatedAt = try await MenuAPI.save(menu, ifMatch: updatedAt)
            savedSnapshot = menu
            if let drinks = menu.resolvedDrinks() {
                onSaved(drinks)
            }
            dismiss()
        } catch MenuAPIError.conflict {
            showConflictAlert = true
        } catch {
            alertMessage = error.localizedDescription
        }
    }
}

// Station configurator: stations are the robot's physical dispensers, so
// there is no add or delete — only rename, and reorder for when a liquor
// physically moves to a different dispenser. Reordering keeps the id sequence
// pinned to the positions and remaps every recipe to follow its liquor, after
// an explicit confirmation of what will change. Edits flow into the editor's
// DrinkMenu via the binding and publish with its Save.
struct StationEditorView: View {
    @Binding var menu: DrinkMenu

    @State private var pendingMove: PendingStationMove?

    var body: some View {
        List {
            Section {
                ForEach($menu.stations) { $station in
                    stationRow($station)
                }
                .onMove { source, destination in
                    // Stage the move behind a confirmation instead of applying
                    // it: silently renumbering recipes would be too surprising
                    pendingMove = PendingStationMove(stations: menu.stations,
                                                     source: source,
                                                     destination: destination)
                }
            } footer: {
                Text("What the robot pours at each station. Tap a station to rename it or describe its taste for AI Tender (\(Image(systemName: StationKind.valve.icon)) gravity valve, \(Image(systemName: StationKind.pump.icon)) pump). Tap Edit and drag a liquor to the station it physically moved to — every recipe updates to follow it.")
            }
        }
        .navigationTitle("Stations")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        .alert("Move \(pendingMove?.movedName ?? "Station")?",
               isPresented: pendingMovePresented,
               presenting: pendingMove) { _ in
            Button("Move") {
                // Clear the presentation state first and apply on the next
                // main-queue turn: mutating the menu while the alert is still
                // dismissing makes SwiftUI re-present it (it re-reads a stale
                // isPresented mid-rebuild), which demanded repeated taps
                guard let move = pendingMove else { return }
                pendingMove = nil
                DispatchQueue.main.async { apply(move) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { move in
            Text(move.summary)
        }
    }

    private func stationRow(_ station: Binding<Station>) -> some View {
        let value = station.wrappedValue
        return NavigationLink {
            StationDetailView(station: station)
        } label: {
            HStack(spacing: 12) {
                Text("\(value.id)")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color(.tertiarySystemGroupedBackground)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(value.name.isEmpty ? "Unnamed station" : value.name)
                        .font(.body)
                    Text(profileSummary(for: value))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: value.resolvedKind.icon)
                    .foregroundStyle(value.resolvedKind == .valve ? .teal : .orange)
                    .accessibilityLabel(value.resolvedKind.label)
            }
        }
    }

    private func profileSummary(for station: Station) -> String {
        var parts = [station.resolvedRole.label]
        if station.resolvedRole.isAlcoholic {
            parts.append("\(Int(station.resolvedAbv.rounded()))% ABV")
        }
        if let notes = station.notes, !notes.isEmpty {
            parts.append(notes)
        }
        return parts.joined(separator: " · ")
    }

    private var pendingMovePresented: Binding<Bool> {
        Binding(
            get: { pendingMove != nil },
            set: { if !$0 { pendingMove = nil } }
        )
    }

    /// Reassigns the fixed id sequence to the reordered stations and rewrites
    /// every recipe ingredient so it keeps pouring the same liquor.
    private func apply(_ move: PendingStationMove) {
        menu.stations = move.reordered
        for drinkIndex in menu.drinks.indices {
            for ingredientIndex in menu.drinks[drinkIndex].ingredients.indices {
                let oldId = menu.drinks[drinkIndex].ingredients[ingredientIndex].stationId
                if let newId = move.idMapping[oldId] {
                    menu.drinks[drinkIndex].ingredients[ingredientIndex].stationId = newId
                }
            }
        }
    }
}

// Everything about one station except its position: name, hardware kind, and
// the tasting profile AI Tender reads. Edits flow into the editor's DrinkMenu
// via the binding and publish with its Save.
struct StationDetailView: View {
    @Binding var station: Station

    var body: some View {
        Form {
            Section("Station \(station.id)") {
                TextField("Name", text: $station.name)
                Picker("Dispenser", selection: kindBinding) {
                    ForEach(StationKind.allCases, id: \.self) { kind in
                        Label(kind.label, systemImage: kind.icon).tag(kind)
                    }
                }
            }

            Section {
                Picker("Type", selection: roleBinding) {
                    ForEach(StationRole.allCases, id: \.self) { role in
                        Text(role.label).tag(role)
                    }
                }
                if station.resolvedRole.isAlcoholic {
                    HStack {
                        Text("Alcohol")
                        Spacer()
                        TextField("ABV", value: abvBinding, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                        Text("%")
                            .foregroundStyle(.secondary)
                    }
                }
                TextField("Tasting notes for AI Tender", text: notesBinding, axis: .vertical)
                    .lineLimit(2...5)
            } header: {
                Text("Taste Profile")
            } footer: {
                Text("AI Tender reads these when inventing drinks. Describe flavor, effect and what it mixes well with — e.g. “bitter, roasted; wakes you up; pairs with whiskey”.")
            }
        }
        .navigationTitle(station.name.isEmpty ? "Station" : station.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    // The wire format omits these when unset; the UI edits resolved values
    private var kindBinding: Binding<StationKind> {
        Binding(get: { station.resolvedKind }, set: { station.kind = $0 })
    }

    private var roleBinding: Binding<StationRole> {
        Binding(get: { station.resolvedRole }, set: { station.role = $0 })
    }

    private var abvBinding: Binding<Double> {
        Binding(get: { station.resolvedAbv }, set: { station.abv = min(max($0, 0), 100) })
    }

    private var notesBinding: Binding<String> {
        Binding(
            get: { station.notes ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                station.notes = trimmed.isEmpty ? nil : newValue
            }
        )
    }
}

/// A staged station drag: the reordered array with ids re-pinned to their
/// positions, the old→new id mapping for recipes, and a human summary of both.
struct PendingStationMove {
    let reordered: [Station]
    let idMapping: [Int: Int]
    let movedName: String
    let summary: String

    init(stations: [Station], source: IndexSet, destination: Int) {
        movedName = source.first.map { stations[$0].name } ?? "Station"

        // The id sequence and hardware kind stay pinned to the physical
        // positions; only the liquor names travel with the drag
        let positionIds = stations.map(\.id)
        let positionKinds = stations.map(\.kind)
        var moved = stations
        moved.move(fromOffsets: source, toOffset: destination)

        var mapping: [Int: Int] = [:]
        var lines: [String] = []
        for (position, station) in moved.enumerated() {
            mapping[station.id] = positionIds[position]
            if station.id != positionIds[position] {
                lines.append("\(station.name): station \(station.id) → \(positionIds[position])")
            }
            moved[position].id = positionIds[position]
            moved[position].kind = positionKinds[position]
        }

        reordered = moved
        idMapping = mapping
        summary = lines.joined(separator: "\n")
            + "\n\nAll recipes will be updated so every drink keeps pouring the same liquor."
    }
}

#Preview {
    MenuEditorView { _ in }
}
