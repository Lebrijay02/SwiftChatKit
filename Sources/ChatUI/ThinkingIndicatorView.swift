//
//  ThinkingIndicatorView.swift
//  SwiftChatKit
//
//  What the transcript shows while the model is working and has produced
//  nothing yet. Render it on `session.isThinking`, which is already false once
//  text starts streaming — streaming text is its own indicator, and showing
//  both reads as two things happening at once.
//

import SwiftUI

public struct ThinkingIndicatorView: View {

    @Environment(\.chatPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Shown beside the dots. Nil for dots alone.
    public let label: String?

    @State private var phase = 0

    public init(label: String? = "Thinking…") {
        self.label = label
    }

    public var body: some View {
        HStack(spacing: 6) {
            dots
            if let label {
                Text(label)
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryText)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label ?? "Thinking")
        .accessibilityAddTraits(.updatesFrequently)
        .task { await animate() }
    }

    private var dots: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(palette.secondaryText)
                    .frame(width: 5, height: 5)
                    // Reduce Motion gets a steady row rather than a still frame
                    // of a stalled animation, which would read as "hung".
                    .opacity(reduceMotion || index == phase ? 1 : 0.3)
            }
        }
    }

    /// Stepped from `.task` rather than by a repeating `Animation`, so the cycle
    /// stops with the view: this appears and disappears on every turn boundary,
    /// and an animation left running past that keeps the view redrawing forever.
    private func animate() async {
        guard !reduceMotion else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) { phase = (phase + 1) % 3 }
        }
    }
}
