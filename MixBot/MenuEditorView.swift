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
                    Button("Cancel") {
                        if hasChanges {
                            showDiscardConfirm = true
                        } else {
                            dismiss()
                        }
                    }
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
        .interactiveDismissDisabled(hasChanges)
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
                             })
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

#Preview {
    MenuEditorView { _ in }
}
