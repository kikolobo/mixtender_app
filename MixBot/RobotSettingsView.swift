//
//  RobotSettingsView.swift
//  MixBot
//

import SwiftUI

// Passcode-protected robot settings: valve calibration, trimming the open
// and closed servo angles of the six gravity-valve stations over BLE ("T"
// messages, see NOTES_FROM_FIRMWARE.md), and scale setup: the empty-tray
// weight (zero) and the min/max empty-cup weight ("K" messages, PROTOCOL.md §A.8).
//
// Safety rules (from the firmware notes, plus app-side extras):
// - a "place a glass on the tray" prompt before the first tray move / open
// - a valve only opens once the robot confirms the tray is under it
//   (TM<id>=at), or, on firmware that can't move the tray, after the user
//   confirms the glass is under that valve, every time
// - one valve open at a time, with Done / Cancel always on screen while open
// - an open valve auto-closes after 8 s without interaction
// - everything closes (TX) when leaving, backgrounding, or disconnecting
// - calibration is disabled while the robot reports it's pouring

struct RobotSettingsView: View {
    @EnvironmentObject var remoteEngine: RemoteEngine
    @Environment(\.dismiss) private var dismiss

    @State private var stations: [Station] = loadKnownStations()

    private var scale: ScaleZero { remoteEngine.scaleZero }
    private var isConnected: Bool { remoteEngine.bluetoothEngine.isConnected }

    var body: some View {
        NavigationStack {
            List {
                Section("Robot") {
                    LabeledContent("Connection", value: remoteEngine.bluetoothEngine.comStatus)
                    if let text = remoteEngine.robotStatus.text {
                        LabeledContent("Status", value: text)
                    }
                }

                Section {
                    NavigationLink {
                        ValveCalibrationListView(calibration: remoteEngine.valveCalibration,
                                                 stations: stations)
                    } label: {
                        Label("Valve Calibration", systemImage: "dial.medium")
                    }
                } footer: {
                    Text("Trim where each gravity valve opens and closes.")
                }

                // Firmware before v7 has no K commands: hide the action
                if scale.availability != .unsupported {
                    Section {
                        NavigationLink {
                            ScaleZeroView(scale: scale)
                        } label: {
                            HStack {
                                Label("Scale Setup", systemImage: "scalemass")
                                Spacer()
                                if scale.availability == .checking {
                                    ProgressView()
                                } else if scale.needsSetup {
                                    NotSetUpBadge()
                                } else if let reading = scale.reading {
                                    Text("Cup \(Int(reading.minCup.rounded()))–\(Int(reading.maxCup.rounded())) g")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(!isConnected || scale.availability != .available)
                    } footer: {
                        Text("Zero the scale and set the lightest and heaviest empty glass. Do this if an empty cup shows “Cup is not empty” or isn't seen.")
                    }
                }
            }
            .task(id: isConnected) {
                if isConnected { scale.check() }
            }
            .navigationTitle("Robot Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(.primary)
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
        // Safety net: however the sheet goes away, no valve stays open
        .onDisappear { remoteEngine.valveCalibration.end() }
        .interactiveDismissDisabled()
        .presentationDragIndicator(.hidden)
        .menuEditorSheetSizing()
    }
}

// MARK: - Zero scale

/// Guided re-measure of the empty tray (KZ), an optional check with an empty
/// cup (live K? polling) that can set the cup window from it, the min/max
/// cup weight editors (KN / KM, resets KNR / KMR), and the empty-tray values
/// with a reset (KR).
struct ScaleZeroView: View {
    let scale: ScaleZero

    @EnvironmentObject var remoteEngine: RemoteEngine

    @State private var showZeroConfirm = false
    @State private var showResetConfirm = false
    @State private var isCheckingCup = false

    private var isConnected: Bool { remoteEngine.bluetoothEngine.isConnected }
    // KZ is also refused during valve calibration, but that session always
    // ends before this screen can be reached
    private var canControl: Bool { scale.canControl && isConnected && !remoteEngine.isPouring }

    var body: some View {
        List {
            if !isConnected {
                Section {
                    Label("The robot isn't connected.", systemImage: "antenna.radiowaves.left.and.right.slash")
                        .foregroundStyle(.secondary)
                }
            } else if remoteEngine.isPouring {
                Section {
                    Label("A drink is pouring. Wait until it's done.", systemImage: "hourglass")
                        .foregroundStyle(.orange)
                }
            }

            if let notice = scale.notice {
                Section {
                    HStack(alignment: .top) {
                        Label(notice, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button {
                            scale.notice = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss")
                    }
                }
            }

            Section {
                Text("Remove the cup and everything else from the tray, then zero the scale.")
                Button {
                    showZeroConfirm = true
                } label: {
                    HStack {
                        Label("Zero Scale", systemImage: "scalemass")
                        if scale.isWorking {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(!canControl)
            } header: {
                Text("1. Empty the Tray")
            } footer: {
                Text("If a cup is on the tray while zeroing, the robot counts it as part of the tray and will say “Please add a cup” with the cup still on. Zero again with the tray empty to fix it.")
            }

            if scale.didZero, let reading = scale.reading {
                Section("2. Result") {
                    Label("Scale zeroed and saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    if !isCheckingCup {
                        LabeledContent("Reading now", value: grams(reading.absolute))
                    }
                }

                Section {
                    if isCheckingCup {
                        LabeledContent("Cup weight") {
                            Text(grams(reading.absolute))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                        }
                        LabeledContent("Robot says", value: remoteEngine.robotStatus.text ?? "–")
                        LabeledContent("OK to serve", value: remoteEngine.robotStatus.isCupReady == true ? "Yes" : "No")
                        // Something is on the tray (the lowest min the robot allows);
                        // the cup may still be under the current min, which is the point
                        if reading.absolute >= ScaleZero.cupLimitRange.lowerBound {
                            let window = ScaleZero.suggestedWindow(forCup: reading.absolute)
                            Button("Set Cup Window to \(Int(window.min))–\(Int(window.max)) g") {
                                scale.setCupWindow(min: window.min, max: window.max)
                            }
                            .disabled(!canControl)
                        }
                        Button("Stop Checking") { isCheckingCup = false }
                    } else {
                        Button("Check with an Empty Cup") { isCheckingCup = true }
                            .disabled(!isConnected)
                    }
                } header: {
                    Text("3. Check (Optional)")
                } footer: {
                    Text("Place an empty glass on the tray. Its weight should show here, and the robot should say “Ready!”. You can set the cup window from it: its weight − \(Int(ScaleZero.minCupMargin)) g to + \(Int(ScaleZero.maxCupMargin)) g.")
                }
            }

            Section {
                CupLimitEditor(title: "Min cup",
                               value: scale.reading?.minCup,
                               defaultValue: scale.reading?.defaultMinCup,
                               isSaved: scale.reading?.minCupSaved == true,
                               canControl: canControl,
                               resetMessage: "Anything at or below the factory default will count as no cup again.",
                               onSave: scale.setMinCup,
                               onReset: scale.resetMinCup)
                CupLimitEditor(title: "Max cup",
                               value: scale.reading?.maxCup,
                               defaultValue: scale.reading?.defaultMaxCup,
                               isSaved: scale.reading?.maxCupSaved == true,
                               canControl: canControl,
                               resetMessage: "The robot will accept empty cups up to the factory default again.",
                               onSave: scale.setMaxCup,
                               onReset: scale.resetMaxCup)
            } header: {
                Text("Cup Weight Window")
            } footer: {
                Text("An empty glass must weigh more than the min and no more than the max. At or below the min the robot says “Please add a cup”; above the max, “Cup is not empty”. Set the min a bit below your lightest glass and the max a bit above your heaviest. 5–2000 g, min at least \(Int(ScaleZero.minCupGap)) g below max.")
            }

            Section {
                LabeledContent("Reading now", value: scale.reading.map { grams($0.absolute) } ?? "–")
                LabeledContent("Empty tray", value: scale.reading.map { grams($0.emptyTray) } ?? "–")
                LabeledContent("Factory default", value: scale.reading.map { grams($0.defaultEmptyTray) } ?? "–")
                LabeledContent("Saved on robot") {
                    if scale.needsSetup {
                        NotSetUpBadge()
                    } else {
                        Text(scale.reading == nil ? "–" : "Yes")
                    }
                }
                Button("Reset to Default", role: .destructive) {
                    showResetConfirm = true
                }
                .disabled(!canControl || scale.reading?.traySaved != true)
            } header: {
                Text("Advanced: Empty Tray")
            } footer: {
                Text("Reset erases the saved value; the robot goes back to the factory empty-tray weight.")
            }
        }
        .navigationTitle("Scale Setup")
        .navigationBarTitleDisplayMode(.inline)
        .task { scale.start() }
        // Live reading while the screen is open; the firmware asks for at
        // most 2 K? per second
        .task(id: isConnected) {
            guard isConnected else { return }
            while !Task.isCancelled {
                scale.refresh()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        .onChange(of: isConnected) { _, connected in
            if !connected { isCheckingCup = false }
        }
        .alert("Is the Tray Empty?", isPresented: $showZeroConfirm) {
            Button("Zero Now") {
                isCheckingCup = false
                scale.zero()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Remove the cup and anything else from the tray first. Whatever is on it now becomes the empty tray.")
        }
        .alert("Reset Empty Tray?", isPresented: $showResetConfirm) {
            Button("Reset", role: .destructive) {
                isCheckingCup = false
                scale.resetToDefault()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The robot will use the factory empty-tray weight again. An empty cup may show “Cup is not empty” until you zero the scale.")
        }
    }

    private func grams(_ value: Double) -> String {
        String(format: "%.1f g", value)
    }
}

/// One end of the cup weight window: the value in use with an editor,
/// and a reset to the factory value.
private struct CupLimitEditor: View {
    let title: String
    let value: Double?
    let defaultValue: Double?
    let isSaved: Bool
    let canControl: Bool
    let resetMessage: String
    let onSave: (Double) -> Void
    let onReset: () -> Void

    @State private var text = ""
    @State private var showResetConfirm = false
    @FocusState private var isFocused: Bool

    var body: some View {
        LabeledContent {
            HStack {
                TextField("Grams", text: $text)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 90)
                    .focused($isFocused)
                    .submitLabel(.done)
                    .onSubmit(save)
                Text("g")
                    .foregroundStyle(.secondary)
                Button("Save", action: save)
                    .buttonStyle(.borderless)
                    .disabled(!canControl || entered == nil || entered == value)
            }
        } label: {
            Text(title)
            Text(subtitle)
        }
        // The editor follows the robot's value unless the user is typing
        .onChange(of: value, initial: true) { _, value in
            guard !isFocused, let value else { return }
            text = formatGrams(value)
        }

        Button("Reset \(title) to Default", role: .destructive) {
            showResetConfirm = true
        }
        .disabled(!canControl || !isSaved)
        .alert("Reset \(title) Weight?", isPresented: $showResetConfirm) {
            Button("Reset", role: .destructive, action: onReset)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(resetMessage)
        }
    }

    private var subtitle: String {
        guard let defaultValue else { return "–" }
        return "Default \(formatGrams(defaultValue)) g" + (isSaved ? " · Saved" : "")
    }

    /// The typed weight; accepts a decimal comma too
    private var entered: Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    private func save() {
        isFocused = false
        // Out-of-window values get the firmware's range notice
        guard let grams = entered else { return }
        onSave(grams)
    }

    /// "450" or "452.5": whole grams without a trailing ".0"
    private func formatGrams(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

/// The robot has never been zeroed (K reply with saved=0)
private struct NotSetUpBadge: View {
    var body: some View {
        Text("Not set up")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.orange.opacity(0.15)))
    }
}

// Shared look for the calibration screens
private enum ValveColors {
    static let open = Color.green
    static let closed = Color.blue
}

/// "+3", "−2", "±0": trims read as offsets from the factory angle
func formatTrim(_ trim: Int) -> String {
    if trim == 0 { return "±0" }
    return trim > 0 ? "+\(trim)" : "−\(-trim)"
}

// MARK: - Valve grid

struct ValveCalibrationListView: View {
    let calibration: ValveCalibration
    let stations: [Station]

    @EnvironmentObject var remoteEngine: RemoteEngine
    @Environment(\.scenePhase) private var scenePhase

    /// The valve screen being shown; tracked so leaving for it doesn't count
    /// as leaving calibration (which would park the tray)
    @State private var selectedValve: Int?

    private var isConnected: Bool { remoteEngine.bluetoothEngine.isConnected }

    /// The firmware's real valve list (T? replies), minus anything the menu
    /// calls a pump: pumps have no servo to calibrate
    private var calibratableValves: [ValveState] {
        calibration.valves.values
            .filter { valve in stations.first { $0.id == valve.id }?.resolvedKind != .pump }
            .sorted { $0.id < $1.id }
    }

    /// Valve stations in the menu that the robot didn't report. Only known
    /// once every T? reply is in; they arrive one by one.
    private var uncalibratableStations: [Station] {
        guard !calibration.isListing else { return [] }
        return stations.filter { $0.resolvedKind == .valve && calibration.valves[$0.id] == nil }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                content
            }
            .padding()
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Valve Calibration")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: isConnected) {
            if isConnected { calibration.begin() }
        }
        .navigationDestination(item: $selectedValve) { id in
            ValveCalibrationDetailView(calibration: calibration,
                                       valveId: id,
                                       stationName: stationName(id))
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { calibration.end() }
        }
        .onDisappear {
            // Leaving calibration (not just opening a valve): close and park
            if selectedValve == nil { calibration.end() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !isConnected {
            ContentUnavailableView("Robot Not Connected",
                                   systemImage: "antenna.radiowaves.left.and.right.slash",
                                   description: Text("Calibration needs a Bluetooth connection to the robot."))
                .padding(.top, 60)
        } else {
            switch calibration.availability {
            case .idle, .checking:
                ProgressView("Asking the robot…")
                    .controlSize(.large)
                    .padding(.top, 80)
            case .unsupported:
                ContentUnavailableView {
                    Label("Not Supported", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("This robot's firmware doesn't support valve calibration. Update the firmware and try again.")
                } actions: {
                    Button("Try Again") { calibration.begin() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.top, 60)
            case .available:
                if calibration.isBusy {
                    BusyBanner(calibration: calibration)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], spacing: 16) {
                    ForEach(calibratableValves, id: \.id) { valve in
                        Button {
                            selectedValve = valve.id
                        } label: {
                            ValveCard(valve: valve,
                                      name: stationName(valve.id),
                                      isUnsaved: calibration.unsavedIds.contains(valve.id),
                                      trayHere: calibration.tray == .at(valve.id))
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Separate grid: sharing ids with the valve cards above would
                // confuse SwiftUI's identity when a valve's reply arrives late
                if !uncalibratableStations.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], spacing: 16) {
                        ForEach(uncalibratableStations) { station in
                            UncalibratableCard(station: station)
                        }
                    }
                }

                Text("Trims are relative to the factory position. Pumps (stations 7–9) don't need calibration.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
        }
    }

    private func stationName(_ id: Int) -> String {
        stations.first { $0.id == id }?.name ?? "Station \(id)"
    }
}

/// Grid card: station, a mini dial of the valve's travel, and both trims.
private struct ValveCard: View {
    let valve: ValveState
    let name: String
    let isUnsaved: Bool
    var trayHere = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                StationNumber(id: valve.id)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.headline)
                    Text(trayHere ? "Station \(valve.id) · Tray here" : "Station \(valve.id)")
                        .font(.caption)
                        .foregroundStyle(trayHere ? Color.green : .secondary)
                }
                Spacer()
                SaveBadge(valve: valve, isUnsaved: isUnsaved)
            }

            ServoDial(valve: valve, position: valve.closed, style: .compact)
                .frame(height: 96)

            HStack {
                TrimChip(title: "Closed", trim: valve.closedTrim, color: ValveColors.closed)
                Spacer()
                TrimChip(title: "Open", trim: valve.openTrim, color: ValveColors.open)
                Image(systemName: "chevron.right")
                    .font(.footnote.bold())
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 6)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 22).fill(Color(.secondarySystemGroupedBackground)))
        .contentShape(RoundedRectangle(cornerRadius: 22))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens calibration for this valve")
    }
}

/// A menu valve station the robot didn't list: shown, but not offered.
private struct UncalibratableCard: View {
    let station: Station

    var body: some View {
        HStack(spacing: 12) {
            StationNumber(id: station.id)
                .saturation(0)
            VStack(alignment: .leading, spacing: 2) {
                Text(station.name)
                    .font(.headline)
                Text("Station \(station.id) · Not calibratable on this robot")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 22).fill(Color(.secondarySystemGroupedBackground).opacity(0.6)))
        .accessibilityElement(children: .combine)
    }
}

private struct TrimChip: View {
    let title: String
    let trim: Int
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title)
                .foregroundStyle(.secondary)
            Text(formatTrim(trim))
                .bold()
                .monospacedDigit()
        }
        .font(.subheadline)
    }
}

private struct StationNumber: View {
    let id: Int

    var body: some View {
        Text("\(id)")
            .font(.title3.bold())
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(Circle().fill(LinearGradient(colors: [.purple, .pink],
                                                     startPoint: .topLeading,
                                                     endPoint: .bottomTrailing)))
            .accessibilityHidden(true)
    }
}

private struct SaveBadge: View {
    let valve: ValveState
    let isUnsaved: Bool

    var body: some View {
        let (text, color): (String, Color) = isUnsaved
            ? ("Unsaved", .orange)
            : (valve.saved ? ("Saved", .green) : ("Factory", .secondary))
        Text(text)
            .font(.caption.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}

private struct BusyBanner: View {
    let calibration: ValveCalibration

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "hourglass")
                .font(.title3)
                .foregroundStyle(.orange)
            Text("The robot is pouring a drink. Calibration is paused.")
                .font(.subheadline)
            Spacer()
            Button("Try Again") { calibration.retry() }
                .buttonStyle(.bordered)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.orange.opacity(0.12)))
    }
}

// MARK: - Servo dial

/// Half-circle gauge of one servo's 0–180° range: the travel between the
/// closed and open angles, factory marks, both markers, and an arm showing
/// where the valve is right now. Markers and arm animate between angles.
struct ServoDial: View {
    enum Style {
        case full
        case compact
    }

    enum Focus {
        case none
        case open
        case closed
    }

    let valve: ValveState
    /// Angles to draw; pending targets override the last confirmed reply
    var openAngle: Int?
    var closedAngle: Int?
    /// Where the arm points now
    let position: Int
    var style: Style = .full
    var focus: Focus = .none

    private var open: Int { openAngle ?? valve.open }
    private var closed: Int { closedAngle ?? valve.closed }
    private var isCompact: Bool { style == .compact }

    var body: some View {
        GeometryReader { proxy in
            let lineWidth: CGFloat = isCompact ? 8 : 16
            let labelRoom: CGFloat = isCompact ? 4 : 30
            let radius = max(10, min(proxy.size.width / 2, proxy.size.height) - lineWidth / 2 - labelRoom)
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height - (isCompact ? 6 : 26))

            ZStack {
                Canvas { context, _ in
                    drawScale(in: &context, center: center, radius: radius, lineWidth: lineWidth)
                }

                // Open and closed markers ride on the track
                marker(angle: closed, color: ValveColors.closed, emphasized: focus == .closed,
                       center: center, radius: radius, lineWidth: lineWidth)
                marker(angle: open, color: ValveColors.open, emphasized: focus == .open,
                       center: center, radius: radius, lineWidth: lineWidth)

                // Servo arm
                let armLength = radius - lineWidth * 0.6
                Capsule()
                    .fill(Color.primary.opacity(0.85))
                    .frame(width: isCompact ? 3 : 6, height: armLength)
                    .rotationEffect(.degrees(Double(position) - 90), anchor: .bottom)
                    .position(x: center.x, y: center.y - armLength / 2)
                Circle()
                    .fill(Color.primary)
                    .frame(width: isCompact ? 10 : 18, height: isCompact ? 10 : 18)
                    .position(center)
            }
            .animation(.spring(duration: 0.35), value: position)
            .animation(.spring(duration: 0.35), value: open)
            .animation(.spring(duration: 0.35), value: closed)
        }
        .accessibilityElement()
        .accessibilityLabel("Servo dial")
        .accessibilityValue("Arm at \(position) degrees. Open position \(open) degrees, closed position \(closed) degrees.")
    }

    /// Screen point for a servo angle: 0° at the left, 90° up, 180° right.
    private func point(_ angle: Double, center: CGPoint, radius: CGFloat) -> CGPoint {
        let theta = (180 + angle) * .pi / 180
        return CGPoint(x: center.x + radius * cos(theta), y: center.y + radius * sin(theta))
    }

    private func arc(from start: Double, to end: Double, center: CGPoint, radius: CGFloat) -> Path {
        Path { path in
            let steps = max(2, Int(abs(end - start)))
            for step in 0...steps {
                let angle = start + (end - start) * Double(step) / Double(steps)
                let p = point(angle, center: center, radius: radius)
                if step == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
        }
    }

    private func drawScale(in context: inout GraphicsContext, center: CGPoint, radius: CGFloat, lineWidth: CGFloat) {
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round)

        // Full 0–180° track
        context.stroke(arc(from: 0, to: 180, center: center, radius: radius),
                       with: .color(.secondary.opacity(0.18)),
                       style: style)

        // Travel between closed and open
        let low = Double(min(open, closed))
        let high = Double(max(open, closed))
        context.stroke(arc(from: low, to: high, center: center, radius: radius),
                       with: .linearGradient(Gradient(colors: [ValveColors.closed.opacity(0.55), ValveColors.open.opacity(0.55)]),
                                             startPoint: point(Double(closed), center: center, radius: radius),
                                             endPoint: point(Double(open), center: center, radius: radius)),
                       style: style)

        // Factory positions: thin marks across the track
        for angle in [valve.defaultClosed, valve.defaultOpen] {
            var mark = Path()
            mark.move(to: point(Double(angle), center: center, radius: radius - lineWidth / 2 - 3))
            mark.addLine(to: point(Double(angle), center: center, radius: radius + lineWidth / 2 + 3))
            context.stroke(mark, with: .color(.secondary.opacity(0.7)), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 2]))
        }

        guard !isCompact else { return }

        // Ticks every 10°, longer every 30°, labels at 0 / 90 / 180
        for angle in stride(from: 0, through: 180, by: 10) {
            let major = angle % 30 == 0
            var tick = Path()
            tick.move(to: point(Double(angle), center: center, radius: radius + lineWidth / 2 + 4))
            tick.addLine(to: point(Double(angle), center: center, radius: radius + lineWidth / 2 + (major ? 12 : 8)))
            context.stroke(tick, with: .color(.secondary.opacity(major ? 0.6 : 0.3)), lineWidth: major ? 2 : 1)
        }
        let label = { (angle: Int) in Text("\(angle)°").font(.caption2).foregroundStyle(.secondary) }
        context.draw(label(90), at: point(90, center: center, radius: radius + lineWidth / 2 + 22))
        for angle in [0, 180] {
            let end = point(Double(angle), center: center, radius: radius)
            context.draw(label(angle), at: CGPoint(x: end.x, y: end.y + lineWidth / 2 + 12))
        }
    }

    private func marker(angle: Int, color: Color, emphasized: Bool,
                        center: CGPoint, radius: CGFloat, lineWidth: CGFloat) -> some View {
        let size = lineWidth * (emphasized ? 1.7 : 1.25)
        return Circle()
            .fill(color)
            .overlay(Circle().stroke(.white, lineWidth: isCompact ? 1.5 : 3))
            .shadow(color: color.opacity(emphasized ? 0.6 : 0), radius: 6)
            .frame(width: size, height: size)
            // Pivot the marker around the dial's hub
            .frame(height: radius * 2, alignment: .top)
            .offset(y: -size / 2)
            .rotationEffect(.degrees(Double(angle) - 90))
            .position(x: center.x, y: center.y)
    }
}

// MARK: - One valve

struct ValveCalibrationDetailView: View {
    let calibration: ValveCalibration
    let valveId: Int
    let stationName: String

    private enum Mode: String, CaseIterable, Identifiable {
        case open = "Open Position"
        case closed = "Closed Position"
        var id: String { rawValue }
    }

    @EnvironmentObject var remoteEngine: RemoteEngine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var mode: Mode = .open
    @State private var glassConfirmed = false
    @State private var showGlassWarning = false
    @State private var showManualConfirm = false
    @State private var showResetConfirm = false
    @State private var showLeaveConfirm = false

    private var valve: ValveState? { calibration.valves[valveId] }
    private var isOpen: Bool { calibration.openValveId == valveId }
    private var isUnsaved: Bool { calibration.unsavedIds.contains(valveId) }
    private var isConnected: Bool { remoteEngine.bluetoothEngine.isConnected }
    private var canControl: Bool { calibration.canControl && isConnected }
    private var trayReady: Bool { calibration.isTrayReady(for: valveId) }
    private var trayMoving: Bool { calibration.tray == .moving(to: valveId) }
    private var isManualTray: Bool { calibration.tray == .manual }

    var body: some View {
        ScrollView {
            if let valve {
                VStack(spacing: 16) {
                    header(valve)
                    banners
                    dialCard(valve)

                    Picker("Calibrate", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    // Switching tasks while pouring would hide Done / Cancel
                    .disabled(isOpen)

                    switch mode {
                    case .open: openCard(valve)
                    case .closed: closedCard(valve)
                    }
                }
                .padding()
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            } else {
                ProgressView()
                    .padding(.top, 80)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Valve \(valveId)")
        .navigationBarTitleDisplayMode(.inline)
        // Custom back button so an open valve or unsaved trim is never left
        // behind by accident (also disables the swipe-back gesture)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    leave()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Reset to Factory", systemImage: "arrow.counterclockwise", role: .destructive) {
                        showResetConfirm = true
                    }
                    .disabled(!canControl || isOpen)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .alert("Put a Glass on the Tray", isPresented: $showGlassWarning) {
            Button("Cancel", role: .cancel) {}
            Button("Glass Is on the Tray") {
                glassConfirmed = true
                if trayReady {
                    calibration.open(valveId)
                } else {
                    calibration.moveTray(to: valveId)
                }
            }
        } message: {
            Text("Place an empty glass on the tray. The tray moves under station \(valveId), and calibration pours a little \(stationName) into the glass.")
        }
        // Firmware that can't move the tray: the user is the only check
        .alert("Is the glass under valve \(valveId)?", isPresented: $showManualConfirm) {
            Button("Not Yet", role: .cancel) {}
            Button("Yes, Open Valve") {
                glassConfirmed = true
                calibration.open(valveId)
            }
        } message: {
            Text("This robot can't move the tray for you. Only open the valve with a glass right under station \(valveId) (\(stationName)).")
        }
        .alert("Reset valve \(valveId) to the factory position?", isPresented: $showResetConfirm) {
            Button("Reset and Save", role: .destructive) {
                calibration.resetToFactory(valveId)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let valve {
                Text("Open \(valve.defaultOpen)°, closed \(valve.defaultClosed)°.")
            }
        }
        // An alert, not a confirmation dialog: on wide layouts the dialog
        // becomes a popover that hides its Keep Editing button
        .alert("The closed position isn't saved.", isPresented: $showLeaveConfirm) {
            Button("Save") {
                calibration.save(valveId)
                dismiss()
            }
            Button("Leave Without Saving", role: .destructive) {
                dismiss()
            }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Unsaved changes stay active until the robot restarts.")
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: isOpen)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { calibration.end() }
        }
        .onDisappear {
            if isOpen { calibration.cancelOpen(valveId) }
        }
    }

    // MARK: Header and banners

    private func header(_ valve: ValveState) -> some View {
        HStack(spacing: 14) {
            StationNumber(id: valveId)
            VStack(alignment: .leading, spacing: 2) {
                Text(stationName)
                    .font(.title2.bold())
                Text("Station \(valveId) · Gravity valve")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            SaveBadge(valve: valve, isUnsaved: isUnsaved)
        }
    }

    @ViewBuilder
    private var banners: some View {
        if !isConnected {
            Banner(icon: "antenna.radiowaves.left.and.right.slash", color: .red,
                   text: "Robot not connected. The robot closes all valves when the connection drops.")
        } else if calibration.isBusy {
            BusyBanner(calibration: calibration)
        }

        if let notice = calibration.notice {
            Banner(icon: "info.circle.fill", color: .blue, text: notice) {
                calibration.notice = nil
            }
        }
    }

    // MARK: Dial

    private func dialCard(_ valve: ValveState) -> some View {
        let open = calibration.openAngle(valveId) ?? valve.open
        let closed = calibration.closedAngle(valveId) ?? valve.closed

        return VStack(spacing: 14) {
            ServoDial(valve: valve,
                      openAngle: open,
                      closedAngle: closed,
                      position: isOpen ? open : closed,
                      focus: mode == .open ? .open : .closed)
                .frame(height: 210)

            HStack(spacing: 10) {
                ValveStatePill(isOpen: isOpen)
                TrayPill(tray: calibration.tray, valveId: valveId)
            }

            HStack(spacing: 20) {
                Legend(color: ValveColors.closed, title: "Closed", angle: closed)
                Legend(color: ValveColors.open, title: "Open", angle: open)
                HStack(spacing: 6) {
                    Capsule()
                        .stroke(Color.secondary, style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
                        .frame(width: 2, height: 12)
                    Text("Factory")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.footnote)
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 24).fill(Color(.secondarySystemGroupedBackground)))
    }

    // MARK: Open position

    private func openCard(_ valve: ValveState) -> some View {
        let angle = calibration.openAngle(valveId) ?? valve.open

        return VStack(spacing: 18) {
            StepGuide(steps: ["Glass on the tray",
                              isManualTray ? "Glass under the valve" : "Tray to this valve",
                              "Open & trim until it flows",
                              "Done saves"],
                      current: isOpen ? 2 : (!glassConfirmed ? 0 : (trayReady && !isManualTray ? 2 : 1)))

            TrimControl(trim: angle - valve.defaultOpen,
                        angle: angle,
                        factoryAngle: valve.defaultOpen,
                        color: ValveColors.open,
                        enabled: canControl && isOpen) { delta in
                calibration.nudgeOpen(valveId, by: delta)
            }

            if isOpen {
                Text("Tap + until the liquid starts to flow, then 1–2 more for margin.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if let deadline = calibration.autoCloseAt {
                    AutoCloseBar(deadline: deadline, total: ValveCalibration.autoCloseSeconds)
                }

                // Both close the valve immediately
                HStack(spacing: 12) {
                    Button {
                        calibration.cancelOpen(valveId)
                    } label: {
                        Label("Cancel", systemImage: "xmark")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .tint(.red)

                    Button {
                        calibration.finishOpen(valveId)
                    } label: {
                        Label("Done: Close & Save", systemImage: "checkmark")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .tint(.green)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                primaryClosedAction

                Text(trayReady
                     ? "Opening the valve pours from this station."
                     : "The valve can only open once the robot confirms the tray is under it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 24).fill(Color(.secondarySystemGroupedBackground)))
    }

    /// While the valve is closed: move the tray here first, then open.
    @ViewBuilder
    private var primaryClosedAction: some View {
        if trayMoving {
            Button {} label: {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Moving tray to station \(valveId)…")
                }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(true)
        } else if trayReady {
            Button {
                if isManualTray {
                    // Asked before every open: nothing else knows where the glass is
                    showManualConfirm = true
                } else if glassConfirmed {
                    calibration.open(valveId)
                } else {
                    showGlassWarning = true
                }
            } label: {
                Label("Open Valve", systemImage: "drop.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canControl || calibration.openValveId != nil)
        } else {
            Button {
                if glassConfirmed {
                    calibration.moveTray(to: valveId)
                } else {
                    showGlassWarning = true
                }
            } label: {
                Label("Move Tray to Station \(valveId)", systemImage: "arrow.right.to.line")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
            .controlSize(.large)
            .disabled(!canControl)
        }
    }

    // MARK: Closed position

    private func closedCard(_ valve: ValveState) -> some View {
        let angle = calibration.closedAngle(valveId) ?? valve.closed

        return VStack(spacing: 18) {
            Label("Moves the valve live without pouring. Adjust until it seals without straining the servo.",
                  systemImage: "lock.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            TrimControl(trim: angle - valve.defaultClosed,
                        angle: angle,
                        factoryAngle: valve.defaultClosed,
                        color: ValveColors.closed,
                        enabled: canControl && !isOpen) { delta in
                calibration.nudgeClosed(valveId, by: delta)
            }

            Button {
                calibration.save(valveId)
            } label: {
                Label(isUnsaved ? "Save Closed Position" : "Saved", systemImage: isUnsaved ? "square.and.arrow.down" : "checkmark")
                    .font(.headline)
                    .foregroundStyle(isUnsaved ? .white : .secondary)
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(isUnsaved ? .blue : Color(.tertiarySystemFill))
            .disabled(!canControl || isOpen || !isUnsaved)
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 24).fill(Color(.secondarySystemGroupedBackground)))
    }

    private func leave() {
        if isOpen {
            calibration.cancelOpen(valveId)
        }
        if isUnsaved {
            showLeaveConfirm = true
        } else {
            dismiss()
        }
    }
}

// MARK: - Detail building blocks

/// Big round − / + around the trim value, with the absolute angle below.
private struct TrimControl: View {
    let trim: Int
    let angle: Int
    let factoryAngle: Int
    let color: Color
    let enabled: Bool
    let onNudge: (Int) -> Void

    var body: some View {
        HStack(spacing: 20) {
            nudgeButton(delta: -1, icon: "minus", label: "Decrease by one degree")

            VStack(spacing: 2) {
                Text(formatTrim(trim))
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(enabled ? color : .secondary)
                    .contentTransition(.numericText(value: Double(trim)))
                    .animation(.snappy, value: trim)
                Text("\(angle)° · factory \(factoryAngle)°")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 150)
            .accessibilityElement(children: .combine)

            nudgeButton(delta: 1, icon: "plus", label: "Increase by one degree")
        }
        .sensoryFeedback(.selection, trigger: angle)
    }

    private func nudgeButton(delta: Int, icon: String, label: String) -> some View {
        Button {
            onNudge(delta)
        } label: {
            Image(systemName: icon)
                .font(.title.bold())
                .foregroundStyle(enabled ? color : .secondary)
                .frame(width: 72, height: 72)
                .background(Circle().fill(enabled ? color.opacity(0.15) : Color(.tertiarySystemFill)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

/// "Open: pouring" with a pulsing drop, or "Closed" with a lock.
private struct ValveStatePill: View {
    let isOpen: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isOpen ? "drop.fill" : "lock.fill")
                .symbolEffect(.pulse, isActive: isOpen)
            Text(isOpen ? "Open: pouring" : "Closed")
                .bold()
        }
        .font(.subheadline)
        .foregroundStyle(isOpen ? ValveColors.open : .secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Capsule().fill((isOpen ? ValveColors.open : Color.secondary).opacity(0.15)))
        .animation(.default, value: isOpen)
    }
}

/// Where the tray is relative to this valve.
private struct TrayPill: View {
    let tray: ValveCalibration.TrayPosition
    let valveId: Int

    var body: some View {
        let (icon, text, color): (String, String, Color) = switch tray {
        case .at(let id) where id == valveId: ("checkmark.circle.fill", "Tray here", .green)
        case .moving(let id) where id == valveId: ("arrow.right.circle.fill", "Tray moving…", .orange)
        case .manual: ("hand.raised.fill", "Tray: confirm by eye", .orange)
        default: ("tray", "Tray not here", .secondary)
        }
        HStack(spacing: 8) {
            Image(systemName: icon)
                .symbolEffect(.pulse, isActive: tray == .moving(to: valveId))
            Text(text)
                .bold()
        }
        .font(.subheadline)
        .foregroundStyle(color)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Capsule().fill(color.opacity(0.15)))
        .animation(.default, value: tray)
    }
}

private struct Legend: View {
    let color: Color
    let title: String
    let angle: Int

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(title)
                .foregroundStyle(.secondary)
            Text("\(angle)°")
                .bold()
                .monospacedDigit()
        }
    }
}

/// Numbered steps with the current one highlighted and earlier ones checked.
private struct StepGuide: View {
    let steps: [String]
    let current: Int

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, title in
                VStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(index < current ? Color.green : (index == current ? Color.accentColor : Color(.tertiarySystemFill)))
                            .frame(width: 28, height: 28)
                        if index < current {
                            Image(systemName: "checkmark")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                        } else {
                            Text("\(index + 1)")
                                .font(.caption.bold())
                                .foregroundStyle(index == current ? .white : .secondary)
                        }
                    }
                    Text(title)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(index == current ? .primary : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .animation(.default, value: current)
        .accessibilityElement(children: .combine)
    }
}

/// Shrinking bar until the open valve closes itself.
private struct AutoCloseBar: View {
    let deadline: Date
    let total: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1)) { context in
            // Clamp to 0...total: the deadline can sit a hair past `total` from now.
            let remaining = min(total, max(0, deadline.timeIntervalSince(context.date)))
            let color: Color = remaining < 3 ? .red : .orange
            VStack(alignment: .leading, spacing: 6) {
                Label("Closes automatically in \(Int(remaining.rounded(.up))) s", systemImage: "timer")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(color)
                ProgressView(value: remaining, total: total)
                    .tint(color)
            }
        }
    }
}

private struct Banner: View {
    let icon: String
    let color: Color
    let text: String
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            Text(text)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(color.opacity(0.12)))
    }
}

#Preview("Robot Settings") {
    RobotSettingsView()
        .environmentObject(RemoteEngine(targetPeripheralUUIDString: "94635d24-cf8d-4ff8-9191-de713f39db89"))
}

#Preview("Servo Dial") {
    ServoDial(valve: ValveState(id: 1, open: 150, closed: 47, defaultOpen: 147, defaultClosed: 50, saved: true),
              position: 150,
              focus: .open)
        .frame(height: 210)
        .padding()
}
