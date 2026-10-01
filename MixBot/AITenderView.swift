//
//  AITenderView.swift
//  MixBot
//

import SwiftUI
import FoundationModels

// AI Tender: an on-device bartender (FoundationModels) that invents a drink
// from whatever the robot's stations currently hold. The result opens in the
// standard DrinkDetailView for slider fine-tuning, serving, and "Make It Your
// Own" publishing with the guest's name and the aiAssisted provenance flag.
//
// The menu card that opens this sheet only appears when the system model is
// available, so this view can assume the model exists. The pantry comes from
// the live menu so suggestions always match what's physically loaded.

// What the model must produce, as JSON text. Guided generation would be the
// natural fit, but Apple's default guardrails flag alcohol content and the
// permissive guardrail mode only applies to plain String responses — so the
// model writes JSON and the app parses it. The app validates station ids and
// normalizes percents afterwards regardless, because the model can't be
// trusted with arithmetic.
struct AIGeneratedDrink: Decodable {
    // Asked for first so the model commits to matching ingredients before
    // it writes the recipe (a cheap chain-of-thought for a small model)
    var reasoning: String?
    var name: String
    var description: String
    var ingredients: [AIGeneratedIngredient]
}

struct AIGeneratedIngredient: Decodable {
    var stationId: Int
    var percent: Int
}

struct AITenderView: View {
    /// Forwarded to DrinkDetailView so a saved creation updates the menu.
    let onDrinkAdded: ([Drink]) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var stations: [Station] = []
    @State private var loadErrorText: String?
    @State private var isLoading = true

    @State private var request = ""
    @State private var selectedMoods: Set<String> = []
    @State private var isMixing = false
    @State private var mixErrorText: String?
    @State private var creation: Drink?
    @State private var showCreation = false
    @State private var session: LanguageModelSession?
    @State private var lastRequestKey = ""

    private static let moods = ["Refreshing", "Strong", "Sweet", "Sour", "Bitter",
                                "Dessert", "Light", "Wake Me Up", "Surprise me"]

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Checking what's on tap…")
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
                            Task { await loadStations() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                } else {
                    creationForm
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(.primary)
                    }
                    .accessibilityLabel("Close")
                }
            }
            .navigationDestination(isPresented: $showCreation) {
                if let creation {
                    DrinkDetailView(drink: creation, isCreation: true, onDrinkAdded: onDrinkAdded)
                        .id(creation.id)
                }
            }
        }
        .task { await loadStations() }
        .interactiveDismissDisabled()
        .presentationDragIndicator(.hidden)
        .drinkSheetSizing()
    }

    private var creationForm: some View {
        ScrollView {
            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [.purple, .pink],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .shadow(color: .pink.opacity(0.35), radius: 10, y: 4)
                    Image(systemName: "apple.intelligence")
                        .font(.title)
                        .foregroundStyle(.white)
                }
                .frame(width: 64, height: 64)
                .padding(.top, 10)

                VStack(spacing: 4) {
                    Text("AI Tender")
                        .font(.title2.bold())
                    Text("Tell me what you're craving and I'll invent a drink from what's on tap.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                    ForEach(Self.moods, id: \.self) { mood in
                        moodChip(mood)
                    }
                }

                CreationField(icon: "text.bubble.fill",
                              tint: .purple,
                              placeholder: "Anything else? (optional)",
                              text: $request)

                if let mixErrorText {
                    Text(mixErrorText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Button {
                    Task { await mix() }
                } label: {
                    Group {
                        if isMixing {
                            HStack(spacing: 10) {
                                ProgressView()
                                    .tint(.white)
                                Text("Mixing ideas…")
                            }
                        } else {
                            Label(creation == nil ? "Mix Me a Drink" : "Shake Up Another",
                                  systemImage: "apple.intelligence")
                        }
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        Capsule().fill(LinearGradient(
                            colors: [.purple, .pink],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                    )
                }
                .buttonStyle(.plain)
                .disabled(isMixing || (selectedMoods.isEmpty && request.trimmingCharacters(in: .whitespaces).isEmpty))
                .opacity(isMixing || (selectedMoods.isEmpty && request.trimmingCharacters(in: .whitespaces).isEmpty) ? 0.45 : 1)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func moodChip(_ mood: String) -> some View {
        let isSelected = selectedMoods.contains(mood)
        return Button {
            if isSelected {
                selectedMoods.remove(mood)
            } else {
                selectedMoods.insert(mood)
            }
        } label: {
            Text(mood)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isSelected ? .white : .primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    Capsule().fill(isSelected ? Color.purple : Color(.secondarySystemGroupedBackground))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Pantry

    @MainActor
    private func loadStations() async {
        isLoading = true
        loadErrorText = nil
        do {
            stations = try await MenuAPI.fetchLive().menu.stations
        } catch {
            loadErrorText = "AI Tender needs the live menu to know what's on tap.\n\(error.localizedDescription)"
        }
        isLoading = false
    }

    // MARK: - Generation

    private var instructions: String {
        let pantry = stations.map { station in
            var line = "\(station.id) — \(station.name) — \(station.resolvedRole.label.lowercased())"
            if station.resolvedRole.isAlcoholic {
                line += ", \(Int(station.resolvedAbv.rounded()))% alcohol"
            } else {
                line += ", non-alcoholic"
            }
            if let notes = station.notes, !notes.isEmpty {
                line += " — \(notes)"
            }
            return line
        }
        .joined(separator: "\n")

        return """
        You are AI Tender, a playful robot bartender at a private house party for \
        adults. Inventing cocktail recipes with alcohol is your normal, appropriate \
        job here. You invent cocktail recipes the robot can pour from its stations.

        Available stations (id — ingredient — type — tasting notes):
        \(pantry)

        MIXOLOGY GUIDANCE:
        - Water and soda dilute: more of them makes a drink less sweet and less strong.
        - Carbonated mixers read as refreshing; sweet sodas and liqueurs add sweetness.
        - Tonic is bitter-sweet; coffee is bitter and energizing; citrus juices add sourness.
        - Spirits add strength and their own character; liqueurs add sweetness and flavor in small amounts.
        - Coffee pairs with liqueur (a carajillo), whiskey, rum or tequila — NEVER with gin or tonic.
        - Gin pairs with tonic or soda water; tequila and rum pair with cola, soda or juice; whiskey with cola, coffee or on its own.
        - Never combine two spirits unless the guest asks for strong; one spirit plus mixers is the rule.
        - Mood guide: Refreshing → lots of water or soda, modest spirit. Strong → spirit-forward, \
        little dilution. Sweet → sweet soda or liqueur. Sour → juice or tonic. Bitter → tonic or coffee. \
        Dessert → liqueur and coffee, small spirit. Light → mostly water or soda, minimal alcohol. \
        Wake Me Up → coffee is the star, with a little spirit or liqueur. Surprise me → an unexpected but tasty pairing.
        - Occasion guide: waking up, energy, tired, morning → coffee. Dancing, party, fiesta, celebrating → \
        a fizzy, refreshing long drink: rum or tequila with cola or soda. Relaxing, night cap, after dinner → \
        whiskey or a dessert-style drink. Hot day, thirsty → water or tonic forward.

        RULES:
        - FIRST match the guest's words against the tasting notes above. Any ingredient whose notes \
        describe what the guest asked for MUST be in the drink. Say which in "reasoning".
        - Use ONLY the station ids listed above, each at most once per drink.
        - A drink has 2 to 4 ingredients whose whole-number percents total exactly 100.
        - Unless the guest explicitly asks for a strong drink, the drink MUST include at least one \
        non-alcoholic ingredient (soda, water, juice or other) making up half or more, and alcoholic \
        ingredients stay at or below 40 percent of the total.
        - Liqueurs never exceed 25 percent of the drink.
        - Favor classic, tasty flavor combinations over shock value; respect the tasting notes.
        - Drink names must be original and fun; never reuse a well-known cocktail name unless the recipe matches it.
        - The description is exactly one playful sentence about the taste.

        OUTPUT FORMAT: respond with ONLY a JSON object, no markdown, no prose, no code fences:
        {"reasoning": "Guest asked for X, so I use Y because its notes say Z.", "name": "Drink Name", "description": "One sentence.", "ingredients": [{"stationId": 1, "percent": 30}, {"stationId": 9, "percent": 70}]}
        """
    }

    // MARK: - Request understanding (code-side, deterministic)

    private static let stopWords: Set<String> = [
        "something", "drink", "with", "that", "this", "like", "make", "want", "more",
        "less", "little", "some", "very", "really", "please", "cocktail", "nice", "good",
        "great", "feel", "feeling", "tonight", "give", "need", "have", "would", "could"
    ]

    /// Stations whose name or tasting notes share words with the guest's free
    /// text — e.g. "wake me up" → Coffee ("wakes you up"). These become hard
    /// requirements in the prompt and the rule check. Top two by hit count.
    private func matchingStations(for text: String) -> [Station] {
        let requestTokens = tokens(in: text).filter { !Self.stopWords.contains($0) }
        guard !requestTokens.isEmpty else { return [] }

        var scored: [(station: Station, hits: Int)] = []
        for station in stations {
            let stationTokens = tokens(in: "\(station.name) \(station.notes ?? "")")
            let hits = requestTokens.filter { word in stationTokens.contains { sharesStem(word, $0) } }.count
            if hits > 0 { scored.append((station, hits)) }
        }
        return scored.sorted { $0.hits > $1.hits }.prefix(2).map(\.station)
    }

    private func tokens(in text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter }
            .map(String.init)
            .filter { $0.count >= 4 }
    }

    // Crude stemming: "wake" / "wakes" / "waking" agree on their first letters
    private func sharesStem(_ a: String, _ b: String) -> Bool {
        let length = min(a.count, b.count, 5)
        return a.prefix(length) == b.prefix(length)
    }

    /// Hard rules the model may have ignored, phrased as corrections it can
    /// act on in one follow-up turn.
    private func ruleProblems(in generated: AIGeneratedDrink, required: [Station], allowStrong: Bool) -> [String] {
        let byId = Dictionary(uniqueKeysWithValues: stations.map { ($0.id, $0) })
        let used = Set(generated.ingredients.map(\.stationId))
        var problems: [String] = []

        for station in required where !used.contains(station.id) {
            problems.append("It must include \(station.name) (id \(station.id)) because its notes match the request.")
        }

        let mixerShare = generated.ingredients
            .filter { byId[$0.stationId]?.resolvedRole.isAlcoholic == false }
            .reduce(0) { $0 + $1.percent }
        if !allowStrong, mixerShare < 50 {
            problems.append("It must include at least one non-alcoholic ingredient (soda, water, juice or other) making up half or more of the drink.")
        }

        let liqueurShare = generated.ingredients
            .filter { byId[$0.stationId]?.resolvedRole == .liqueur }
            .reduce(0) { $0 + $1.percent }
        if liqueurShare > 25 {
            problems.append("Keep liqueurs at or below 25 percent.")
        }

        let spiritCount = generated.ingredients
            .filter { byId[$0.stationId]?.resolvedRole == .spirit }
            .count
        if !allowStrong, spiritCount > 1 {
            problems.append("Use only one spirit; replace the others with mixers.")
        }

        // Pairing sanity: coffee and gin/tonic fight each other
        let coffeeIds = Set(stations.filter { tokens(in: $0.notes ?? "").contains { sharesStem($0, "coffee") } || tokens(in: $0.name).contains("coffee") }.map(\.id))
        // Name match, not tokens: "gin" is too short for the tokenizer
        let ginIds = Set(stations.filter { station in
            let name = station.name.lowercased()
            return name.contains("gin") || name.contains("tonic")
        }.map(\.id))
        if !used.isDisjoint(with: coffeeIds), !used.isDisjoint(with: ginIds) {
            problems.append("Coffee never mixes with gin or tonic; pair the coffee with liqueur, whiskey, rum or tequila instead.")
        }
        return problems
    }

    /// Pulls the JSON object out of the model's reply, tolerating stray prose
    /// or code fences around it.
    private func parseDrink(from reply: String) -> AIGeneratedDrink? {
        guard let start = reply.firstIndex(of: "{"),
              let end = reply.lastIndex(of: "}"),
              start < end else { return nil }
        let json = String(reply[start...end])
        return try? JSONDecoder().decode(AIGeneratedDrink.self, from: Data(json.utf8))
    }

    private func looksLikeRefusal(_ reply: String) -> Bool {
        let lowered = reply.lowercased()
        return lowered.contains("i can't") || lowered.contains("i cannot")
            || lowered.contains("sorry") || lowered.contains("unable to")
    }

    @MainActor
    private func mix() async {
        let text = request.trimmingCharacters(in: .whitespaces)
        let wants = (selectedMoods.sorted() + [text])
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        let lowered = text.lowercased()
        let wantsStrong = selectedMoods.contains("Strong")
            || lowered.contains("strong") || lowered.contains("boozy")

        // A changed request starts a fresh session so earlier drinks can't
        // bias the new one; the same request reuses it so "Shake Up Another"
        // can be told to differ from what came before
        let requestKey = wants.lowercased()
        let isRepeat = requestKey == lastRequestKey && session != nil
        if !isRepeat { session = nil }
        lastRequestKey = requestKey

        // Deterministic nudge: the app, not the model, spots which tasting
        // notes match the request ("wake me up" → Coffee's "wakes you up")
        var required = matchingStations(for: text)
        if selectedMoods.contains("Wake Me Up"),
           let coffee = stations.first(where: { station in
               tokens(in: station.notes ?? "").contains { sharesStem($0, "wakes") }
           }),
           !required.contains(where: { $0.id == coffee.id }) {
            required.append(coffee)
        }

        var prompt = "The guest wants: \(wants). Invent one drink for them."
        if !required.isEmpty {
            let list = required.map { "\($0.name) (id \($0.id))" }.joined(separator: " and ")
            prompt += " Pantry check: the tasting notes of \(list) match this request, so the drink MUST include \(required.count == 1 ? "it" : "both")."
        }
        if isRepeat {
            prompt += " Make it clearly different from your previous suggestions."
        }

        isMixing = true
        mixErrorText = nil
        defer { isMixing = false }
        do {
            // Permissive guardrails: the default ones reject alcohol content
            // outright ("May contain unsafe content"). Only honored for String
            // responses, hence the JSON contract above.
            let activeSession = session ?? LanguageModelSession(
                model: SystemLanguageModel(guardrails: .permissiveContentTransformations),
                instructions: instructions
            )
            session = activeSession

            var reply = try await activeSession.respond(to: prompt).content
            print("[AITender] Reply: \(reply)")
            var generated = parseDrink(from: reply)
            if generated == nil, !looksLikeRefusal(reply) {
                // One corrective retry: small models sometimes wrap or narrate
                reply = try await activeSession.respond(
                    to: "Respond again with ONLY the JSON object for that drink, nothing else."
                ).content
                print("[AITender] Retry reply: \(reply)")
                generated = parseDrink(from: reply)
            }

            // One corrective round if a hard rule was ignored; keep the first
            // answer if the correction comes back unparseable
            if let candidate = generated {
                let problems = ruleProblems(in: candidate, required: required, allowStrong: wantsStrong)
                if !problems.isEmpty {
                    print("[AITender] Rule problems: \(problems)")
                    reply = try await activeSession.respond(
                        to: "Fix your drink. " + problems.joined(separator: " ") + " Respond with ONLY the corrected JSON object."
                    ).content
                    print("[AITender] Corrected reply: \(reply)")
                    generated = parseDrink(from: reply) ?? candidate
                }
            }

            guard let generated else {
                mixErrorText = looksLikeRefusal(reply)
                    ? "AI Tender politely declined that one. Try different moods or words."
                    : "AI Tender's answer came out garbled. Shake again!"
                return
            }
            guard let drink = drink(from: generated, allowStrong: wantsStrong, required: required) else {
                mixErrorText = "That idea didn't map to the robot's stations. Try again!"
                return
            }
            creation = drink
            showCreation = true
        } catch {
            // localizedDescription collapses every GenerationError into "The
            // operation couldn't be completed"; reflecting the value keeps the
            // case name and the framework's debug description
            let detail = String(reflecting: error)
            print("[AITender] Generation failed: \(detail)")
            mixErrorText = friendlyMessage(for: error, detail: detail)
        }
    }

    /// Turns a FoundationModels failure into something a guest can act on.
    private func friendlyMessage(for error: Error, detail: String) -> String {
        let lowered = detail.lowercased()
        if lowered.contains("guardrail") || lowered.contains("refusal") || lowered.contains("unsafe content") {
            return "AI Tender couldn't help with that request. Try different words or moods."
        }
        if lowered.contains("ratelimit") || lowered.contains("rate limit") || lowered.contains("concurrent") {
            return "AI Tender is busy. Give it a second and try again."
        }
        if lowered.contains("context") {
            return "AI Tender lost the thread. Close and reopen to start fresh."
        }
        if lowered.contains("asset") || lowered.contains("notready") {
            return "The on-device model is still getting ready. Try again shortly."
        }
        if lowered.contains("decoding") {
            return "AI Tender's answer came out garbled. Shake again!"
        }
        return "AI Tender hit a snag: \(detail)"
    }

    /// Maps the model's output onto the pantry and enforces the house rules
    /// with real station roles — the model's judgment and arithmetic are
    /// never trusted: drops unknown stations, merges duplicates, injects any
    /// required ingredient it skipped, guarantees a mixer unless the guest
    /// asked for strong, caps liqueurs and total alcohol, then re-normalizes
    /// percents so they sum to exactly 100.
    private func drink(from generated: AIGeneratedDrink, allowStrong: Bool, required: [Station]) -> Drink? {
        let byId = Dictionary(uniqueKeysWithValues: stations.map { ($0.id, $0) })

        var merged: [Int: Double] = [:]
        var order: [Int] = []
        for item in generated.ingredients {
            guard byId[item.stationId] != nil, item.percent > 0 else { continue }
            if merged[item.stationId] == nil { order.append(item.stationId) }
            merged[item.stationId, default: 0] += Double(item.percent)
        }
        guard !order.isEmpty else { return nil }

        var ingredients = order.map { stationId in
            Ingredient(name: byId[stationId]?.name ?? "Station \(stationId)",
                       stationId: stationId,
                       percent: merged[stationId] ?? 0)
        }
        func currentTotal() -> Double { ingredients.reduce(0) { $0 + $1.percent } }
        func role(of ingredient: Ingredient) -> StationRole { byId[ingredient.stationId]?.resolvedRole ?? .other }

        // Anything the tasting notes demanded but the model still skipped
        // joins at a supporting 20 percent
        for station in required where !ingredients.contains(where: { $0.stationId == station.id }) {
            ingredients.append(Ingredient(name: station.name, stationId: station.id, percent: currentTotal() * 0.2))
        }

        // No mixer at all (tequila + liqueur, anyone?) gets the mildest one
        // available at half the drink, unless strong was requested
        if !allowStrong, !ingredients.contains(where: { !role(of: $0).isAlcoholic }) {
            let preference: [StationRole] = [.water, .soda, .juice, .other]
            if let mixer = preference.lazy.compactMap({ wanted in stations.first { $0.resolvedRole == wanted } }).first {
                ingredients.append(Ingredient(name: mixer.name, stationId: mixer.id, percent: currentTotal()))
            }
        }

        // Share caps: scale the capped group down and hand the difference to
        // everything else, proportionally
        func cap(_ group: (Ingredient) -> Bool, at cap: Double) {
            let total = currentTotal()
            guard total > 0 else { return }
            let groupShare = ingredients.filter(group).reduce(0) { $0 + $1.percent } / total * 100
            let restShare = 100 - groupShare
            guard groupShare > cap, restShare > 0 else { return }
            let groupScale = cap / groupShare
            let restScale = (100 - cap) / restShare
            for index in ingredients.indices {
                ingredients[index].percent *= group(ingredients[index]) ? groupScale : restScale
            }
        }
        cap({ role(of: $0) == .liqueur }, at: 25)
        if !allowStrong {
            cap({ role(of: $0).isAlcoholic }, at: 45)
        }

        let total = currentTotal()
        guard total > 0 else { return nil }
        for index in ingredients.indices {
            ingredients[index].percent = (ingredients[index].percent * 100 / total).rounded()
        }
        // Pin rounding drift on the largest pour
        let residual = 100 - ingredients.reduce(0) { $0 + $1.percent }
        if residual != 0,
           let target = ingredients.indices.max(by: { ingredients[$0].percent < ingredients[$1].percent }) {
            ingredients[target].percent += residual
        }

        let name = generated.name.trimmingCharacters(in: .whitespaces)
        return Drink(name: name.isEmpty ? "AI Special" : name,
                     description: generated.description.trimmingCharacters(in: .whitespaces),
                     totalQty: 300,
                     ingredients: ingredients,
                     aiAssisted: true)
    }
}

#Preview {
    AITenderView { _ in }
        .environmentObject(RemoteEngine(targetPeripheralUUIDString: "4ac8a682-9736-4e5d-932b-e9b31405049c"))
}
