//
//  TransparentVideoControlsView.swift
//  Video-POC
//

import SwiftUI

struct TransparentVideoControlsView: View {
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    let coordinator: TransparentVideoCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    coordinator.togglePlayback()
                } label: {
                    Image(systemName: coordinator.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.bordered)
                .disabled(!coordinator.hasPlayableVideo)

                VStack(alignment: .leading, spacing: 3) {
                    Text(coordinator.status.label)
                        .font(.headline)
                        .lineLimit(1)

                    Text("Source: \(TransparentVideoCoordinator.sourceResourceName).mp4")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .layoutPriority(1)

                Spacer(minLength: 8)

                Button("Process Again") {
                    coordinator.reprocess()
                }
                .buttonStyle(.borderedProminent)
                .disabled(coordinator.status == .preparing)
                .fixedSize(horizontal: true, vertical: false)

                Divider()
                    .frame(height: 28)

                Button(role: .destructive) {
                    coordinator.stop()
                    Task {
                        await dismissImmersiveSpace()
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close Transparent Video")
            }

            if coordinator.status == .preparing {
                ProgressView(value: coordinator.processingProgress) {
                    Text("Processing chroma key")
                        .font(.caption)
                } currentValueLabel: {
                    Text(coordinator.processingProgress, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit())
                }
                .frame(maxWidth: .infinity)
            }

            Divider()

            settingSlider(
                title: "Tolerance",
                value: Binding(
                    get: { coordinator.threshold },
                    set: { coordinator.threshold = $0 }
                ),
                range: 0.03...0.53
            )

            settingSlider(
                title: "Edge softness",
                value: Binding(
                    get: { coordinator.softness },
                    set: { coordinator.softness = $0 }
                ),
                range: 0.01...0.49
            )

            settingSlider(
                title: "Green spill",
                value: Binding(
                    get: { coordinator.spillSuppression },
                    set: { coordinator.spillSuppression = $0 }
                ),
                range: 0...1
            )
        }
        .padding(18)
        .frame(width: 620)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 24))
    }

    private func settingSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.caption)
                .frame(width: 100, alignment: .leading)

            Slider(value: value, in: range)

            Text(value.wrappedValue, format: .number.precision(.fractionLength(2)))
                .font(.caption.monospacedDigit())
                .frame(width: 38, alignment: .trailing)
        }
    }
}
