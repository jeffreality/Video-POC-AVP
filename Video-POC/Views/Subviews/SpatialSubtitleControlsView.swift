//
//  SpatialSubtitleControlsView.swift
//  Video-POC
//

import SwiftUI

struct SpatialSubtitleControlsView: View {
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    let coordinator: SpatialSubtitlesCoordinator

    var body: some View {
        HStack(spacing: 12) {
            Button {
                coordinator.togglePlayback()
            } label: {
                Image(systemName: coordinator.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(coordinator.isPlaying ? "Pause" : "Play")

            Divider()
                .frame(height: 24)

            Menu {
                ForEach(coordinator.availableLanguages) { language in
                    Button {
                        coordinator.selectLanguage(language)
                    } label: {
                        if language == coordinator.selectedLanguage {
                            Label(language.displayName, systemImage: "checkmark")
                        } else {
                            Text(language.displayName)
                        }
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "globe")
                    Text(coordinator.selectedLanguage.nativeShortName)
                        .fontWeight(.semibold)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
            }
            .menuStyle(.button)

            if let errorMessage = coordinator.errorMessage {
                Divider()
                    .frame(height: 24)
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .frame(maxWidth: 300)
            }

            Divider()
                .frame(height: 24)

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
            .accessibilityLabel("Close Spatial Subtitles")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassBackgroundEffect(in: Capsule())
    }
}

struct HeadRelativeSubtitleView: View {
    let coordinator: SpatialSubtitlesCoordinator

    var body: some View {
        Text(coordinator.currentCueText)
            .font(.system(size: 34, weight: .semibold))
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .padding(.horizontal, 22)
            .padding(.vertical, 13)
            .frame(maxWidth: 760)
            .foregroundStyle(.white)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 16))
            .environment(
                \.layoutDirection,
                coordinator.selectedLanguage.isRightToLeft ? .rightToLeft : .leftToRight
            )
            .opacity(coordinator.currentCueText.isEmpty ? 0 : 1)
            .animation(.easeOut(duration: 0.08), value: coordinator.currentCueText)
    }
}
