//
//  BubblesBackground.swift
//  MixBot
//

import SwiftUI

/// Decorative rising-bubbles background, rendered in a single Canvas pass
/// so a few dozen bubbles cost almost nothing per frame.
struct BubblesBackground: View {
    var colors: [Color] = [.purple, .pink, .orange, .teal, .indigo, .mint]
    var bubbleCount: Int = 36

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate

                for index in 0..<bubbleCount {
                    let bubble = Bubble(index: index)
                    let travel = size.height + 2 * bubble.radius

                    // Each bubble loops from below the bottom edge to above the top
                    let progress = (t * bubble.speed + bubble.startOffset * travel)
                        .truncatingRemainder(dividingBy: travel)
                    let y = size.height + bubble.radius - progress
                    let x = bubble.xFraction * size.width
                        + sin(t * bubble.wobbleSpeed + bubble.wobblePhase) * bubble.wobbleAmplitude

                    // Fade out as the bubble approaches the top quarter of the screen
                    let fade = min(1, max(0, y / (size.height * 0.25)))

                    let color = colors[index % colors.count]
                    let rect = CGRect(x: x - bubble.radius, y: y - bubble.radius,
                                      width: bubble.radius * 2, height: bubble.radius * 2)

                    context.opacity = bubble.opacity * fade
                    context.fill(
                        Circle().path(in: rect),
                        with: .radialGradient(
                            Gradient(colors: [color.opacity(0.05), color.opacity(0.3)]),
                            center: CGPoint(x: x, y: y),
                            startRadius: 0,
                            endRadius: bubble.radius
                        )
                    )
                    context.stroke(
                        Circle().path(in: rect),
                        with: .color(color.opacity(0.35)),
                        lineWidth: 1
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Bubble parameters derived deterministically from the bubble's index, so
/// every frame recomputes the same bubble without storing any state.
private struct Bubble {
    let xFraction: Double
    let radius: Double
    let speed: Double
    let startOffset: Double
    let wobbleSpeed: Double
    let wobbleAmplitude: Double
    let wobblePhase: Double
    let opacity: Double

    init(index: Int) {
        // Cheap hash: maps (index, salt) to a stable pseudo-random 0..<1 value
        func random(_ salt: Double) -> Double {
            let value = sin(Double(index + 1) * 127.1 + salt * 311.7) * 43758.5453
            return value - value.rounded(.down)
        }

        xFraction = random(1)
        radius = 4 + random(2) * 14           // 4...18 pt
        speed = 18 + random(3) * 30           // 18...48 pt/s upward
        startOffset = random(4)
        wobbleSpeed = 0.6 + random(5) * 1.2
        wobbleAmplitude = 4 + random(6) * 10
        wobblePhase = random(7) * 2 * .pi
        opacity = 0.35 + random(8) * 0.4
    }
}

#Preview {
    BubblesBackground()
        .background(Color(.systemGroupedBackground))
        .ignoresSafeArea()
}
