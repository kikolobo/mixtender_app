//
//  ServingGlassView.swift
//  MixBot
//
//  Playful serving-progress view: a glass that fills layer by layer with a
//  distinct color per ingredient, driven by the live weight coming from the
//  robot's scale. The active ingredient is highlighted by the pour stream
//  color, the header label, and a glowing chip in the legend below.
//

import SwiftUI

struct ServingGlassView: View {
    let items: [ListItem]
    let totalQty: Int
    var onToggle: ((Int) -> Void)? = nil

    @State private var celebrationStart: Date?

    // Same palette as DrinkDetailView/menu, cycled per ingredient, so the
    // layer colors match the "Your Mix" bar the user just configured
    private static let accents: [Color] = [.purple, .pink, .orange, .teal, .indigo, .mint]

    private func color(for index: Int) -> Color {
        Self.accents[index % Self.accents.count]
    }

    // MARK: - Progress math

    // Percent shares normalized so layer heights always sum to a full glass
    private var shares: [Double] {
        let total = items.reduce(0.0) { $0 + $1.ingredient.percent }
        guard total > 0 else {
            return items.map { _ in 1.0 / Double(max(items.count, 1)) }
        }
        return items.map { $0.ingredient.percent / total }
    }

    private func fillFraction(_ index: Int) -> Double {
        let item = items[index]
        if item.completed || item.failed { return 1 }
        guard item.working else { return 0 }
        let targetGrams = shares[index] * Double(totalQty)
        guard targetGrams > 0 else { return 0 }
        return min(Double(item.weight) / targetGrams, 1)
    }

    // Animation key: heights change whenever any of these change
    private var fillFractions: [Double] {
        items.indices.map { fillFraction($0) }
    }

    private var activeIndex: Int? {
        items.firstIndex { $0.working && !$0.completed && !$0.failed }
    }

    private var completedCount: Int { items.filter(\.completed).count }
    private var failedCount: Int { items.filter(\.failed).count }
    private var allFinished: Bool {
        !items.isEmpty && items.allSatisfy { $0.completed || $0.failed }
    }
    private var celebrating: Bool {
        !items.isEmpty && items.allSatisfy(\.completed)
    }

    var body: some View {
        VStack(spacing: 18) {
            header

            glass
                .aspectRatio(0.75, contentMode: .fit)
                .frame(maxWidth: 280)
                .frame(maxHeight: .infinity)
                .modifier(ShakeEffect(animatableData: CGFloat(failedCount)))
                .animation(.default, value: failedCount)

            legend
        }
        .overlay {
            if let start = celebrationStart {
                ConfettiView(startDate: start)
            }
        }
        .sensoryFeedback(.success, trigger: completedCount)
        .sensoryFeedback(.error, trigger: failedCount)
        .onChange(of: celebrating) {
            if celebrating && celebrationStart == nil {
                celebrationStart = Date()
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        Group {
            if let index = activeIndex {
                Label("Pouring \(items[index].ingredient.name)…", systemImage: "drop.fill")
                    .foregroundStyle(color(for: index))
            } else if celebrating {
                Text("Cheers! 🎉")
            } else if allFinished {
                Label("Finished with a hiccup", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                Label("Getting ready…", systemImage: "hourglass")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.title3.bold())
        .animation(.default, value: activeIndex)
    }

    // MARK: - Glass

    private var glass: some View {
        GeometryReader { geo in
            // Leave a little headroom so a full drink doesn't touch the rim
            let maxLiquidHeight = geo.size.height * 0.9
            let heights = items.indices.map { shares[$0] * fillFraction($0) * maxLiquidHeight }
            let liquidHeight = heights.reduce(0, +)

            ZStack(alignment: .bottom) {
                // Faint interior so the empty glass reads as glass
                GlassShape()
                    .fill(Color(.secondarySystemGroupedBackground).opacity(0.6))

                ZStack(alignment: .bottom) {
                    // Liquid layers, bottom-up in serving order
                    ForEach(items.indices, id: \.self) { index in
                        let below = heights[..<index].reduce(0, +)
                        layerFill(for: index)
                            .frame(height: heights[index])
                            .padding(.bottom, below)
                    }

                    // Bubbles rising inside the liquid only
                    BubblesBackground(colors: [.white], bubbleCount: 10)
                        .frame(height: max(liquidHeight, 0))
                        .opacity(liquidHeight > 20 ? 0.5 : 0)

                    // Wavy surface riding on top of the liquid
                    if liquidHeight > 6, let topIndex = topLayerIndex {
                        SurfaceWave(color: color(for: topIndex),
                                    lively: activeIndex != nil)
                            .frame(height: 14)
                            .padding(.bottom, liquidHeight - 7)
                    }

                    // Pour stream from the rim down to the surface, in the
                    // active ingredient's color
                    if let index = activeIndex {
                        PourStreamView(color: color(for: index))
                            .frame(width: 14, height: max(geo.size.height - liquidHeight, 0))
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                }
                .animation(.easeOut(duration: 0.45), value: fillFractions)
                .clipShape(GlassShape())

                GlassShape()
                    .stroke(Color.secondary.opacity(0.55), lineWidth: 3)
            }
        }
    }

    // The highest layer that has any liquid in it, for the surface color
    private var topLayerIndex: Int? {
        items.indices.last { fillFraction($0) > 0 }
    }

    @ViewBuilder
    private func layerFill(for index: Int) -> some View {
        if items[index].failed {
            // Ghost layer: the liquid that should be there but isn't
            LinearGradient(colors: [Color(.systemGray3).opacity(0.5),
                                    Color(.systemGray4).opacity(0.5)],
                           startPoint: .top, endPoint: .bottom)
        } else {
            let base = color(for: index)
            LinearGradient(colors: [base.opacity(0.95), base.opacity(0.7)],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    // MARK: - Legend

    private var legend: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
            ForEach(items.indices, id: \.self) { index in
                IngredientChip(item: items[index],
                               color: color(for: index),
                               isActive: index == activeIndex)
                    .onTapGesture { onToggle?(index) }
            }
        }
    }
}

// MARK: - Legend chip

private struct IngredientChip: View {
    let item: ListItem
    let color: Color
    let isActive: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            Text(item.ingredient.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(String(format: "%.0f g", item.weight))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Image(systemName: item.imageName)
                .font(.caption)
                .foregroundStyle(item.completed ? .green : (item.failed ? .red : (isActive ? color : .gray)))
                .symbolEffect(.pulse, isActive: isActive)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Capsule().fill(Color(.secondarySystemGroupedBackground)))
        .overlay(Capsule().stroke(isActive ? color : .clear, lineWidth: 2))
        .scaleEffect(isActive ? 1.04 : 1)
        .animation(.spring(duration: 0.3), value: isActive)
    }
}

// MARK: - Glass silhouette

/// Simple tumbler: full-width rim tapering to a narrower, rounded base.
struct GlassShape: Shape {
    func path(in rect: CGRect) -> Path {
        let inset = rect.width * 0.13
        let corner = min(rect.width * 0.09, 20)

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + inset, y: rect.maxY - corner))
        path.addQuadCurve(to: CGPoint(x: rect.minX + inset + corner, y: rect.maxY),
                          control: CGPoint(x: rect.minX + inset, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - inset - corner, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - inset, y: rect.maxY - corner),
                          control: CGPoint(x: rect.maxX - inset, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Animated pieces

/// Gently undulating liquid surface, drawn as a filled sine ribbon.
private struct SurfaceWave: View {
    var color: Color
    var lively: Bool

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let amplitude = size.height * (lively ? 0.32 : 0.12)
                let midY = size.height / 2

                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height))
                path.addLine(to: CGPoint(x: 0, y: midY))
                for x in stride(from: 0.0, through: size.width, by: 3) {
                    let y = midY + sin(x / size.width * .pi * 4 + t * 3) * amplitude
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()

                context.fill(path, with: .color(color))

                // Bright crest line so the surface catches the light
                var crest = Path()
                for x in stride(from: 0.0, through: size.width, by: 3) {
                    let y = midY + sin(x / size.width * .pi * 4 + t * 3) * amplitude
                    if x == 0 { crest.move(to: CGPoint(x: x, y: y)) }
                    else { crest.addLine(to: CGPoint(x: x, y: y)) }
                }
                context.stroke(crest, with: .color(.white.opacity(0.4)), lineWidth: 1.5)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Falling stream of the active ingredient, with droplet highlights
/// sliding down so the pour visibly flows.
private struct PourStreamView: View {
    var color: Color

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let sway = sin(t * 5) * 1.5
                let streamRect = CGRect(x: size.width / 2 - 4 + sway, y: 0,
                                        width: 8, height: size.height)

                context.fill(
                    Path(roundedRect: streamRect, cornerRadius: 4),
                    with: .linearGradient(
                        Gradient(colors: [color.opacity(0.9), color.opacity(0.55)]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: 0, y: size.height)
                    )
                )

                // Droplet highlights travelling down the stream
                let spacing = max(size.height / 4, 1)
                for index in 0..<4 {
                    let y = (t * 260 + Double(index) * spacing)
                        .truncatingRemainder(dividingBy: max(size.height, 1))
                    let drop = CGRect(x: size.width / 2 - 1.5 + sway, y: y,
                                      width: 3, height: 11)
                    context.fill(Path(ellipseIn: drop), with: .color(.white.opacity(0.5)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// One-shot confetti burst; particles derive from the index like
/// BubblesBackground so no per-particle state is stored.
private struct ConfettiView: View {
    let startDate: Date
    private let colors: [Color] = [.purple, .pink, .orange, .teal, .indigo, .mint, .yellow]

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSince(startDate)
                guard t >= 0, t < 4 else { return }

                for index in 0..<70 {
                    func random(_ salt: Double) -> Double {
                        let value = sin(Double(index + 1) * 127.1 + salt * 311.7) * 43758.5453
                        return value - value.rounded(.down)
                    }

                    let delay = random(1) * 0.8
                    let age = t - delay
                    guard age > 0 else { continue }

                    let x = random(2) * size.width + sin(age * (2 + random(3) * 3)) * 22
                    let y = age * (130 + random(4) * 170) - 20
                    guard y < size.height else { continue }

                    let width = 6 + random(6) * 6
                    var piece = context
                    piece.translateBy(x: x, y: y)
                    piece.rotate(by: .radians(age * (3 + random(5) * 5)))
                    piece.opacity = min(1, max(0, 4 - t))
                    piece.fill(
                        Path(CGRect(x: -width / 2, y: -width / 4, width: width, height: width / 2)),
                        with: .color(colors[index % colors.count])
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Horizontal wiggle used when a pour step fails.
private struct ShakeEffect: GeometryEffect {
    var travel: CGFloat = 8
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(
            CGAffineTransform(translationX: travel * sin(animatableData * .pi * 6), y: 0)
        )
    }
}

#Preview("Mid-pour") {
    ServingGlassView(
        items: [
            ListItem(ingredient: Ingredient(name: "Tequila", stationId: 1, percent: 40),
                     completed: true, working: false, weight: 120),
            ListItem(ingredient: Ingredient(name: "Triple Sec", stationId: 2, percent: 30),
                     completed: false, working: true, weight: 45),
            ListItem(ingredient: Ingredient(name: "Lime Juice", stationId: 3, percent: 30),
                     completed: false, working: false, weight: 0)
        ],
        totalQty: 300
    )
    .padding()
    .background(Color(.systemGroupedBackground))
}
