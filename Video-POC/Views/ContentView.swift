//
//  ContentView.swift
//  Video-POC
//

import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Spatial Video POCs")
                .font(.title)
                .fontWeight(.semibold)

            Text("Each experiment runs independently with its own video, assets, and processing path.")
                .foregroundStyle(.secondary)

            ForEach(AppModel.Feature.allCases) { feature in
                featureButton(feature)
            }

            if appModel.immersiveSpaceState == .open {
                Button(role: .destructive) {
                    closeCurrentFeature()
                } label: {
                    Label("Close Current Demo", systemImage: "xmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(28)
        .frame(width: 620)
    }

    private func featureButton(_ feature: AppModel.Feature) -> some View {
        Button {
            open(feature)
        } label: {
            HStack(spacing: 16) {
                Image(systemName: feature.systemImage)
                    .font(.title2)
                    .frame(width: 40)

                VStack(alignment: .leading, spacing: 4) {
                    Text(feature.title)
                        .font(.headline)
                    Text(feature.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                Image(systemName: "arrow.up.right")
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .disabled(appModel.immersiveSpaceState != .closed)
    }

    private func open(_ feature: AppModel.Feature) {
        Task { @MainActor in
            guard appModel.immersiveSpaceState == .closed else { return }

            appModel.selectedFeature = feature
            appModel.immersiveSpaceState = .inTransition

            switch await openImmersiveSpace(id: appModel.immersiveSpaceID) {
            case .opened:
                break
            case .userCancelled, .error:
                appModel.immersiveSpaceState = .closed
                appModel.selectedFeature = nil
            @unknown default:
                appModel.immersiveSpaceState = .closed
                appModel.selectedFeature = nil
            }
        }
    }

    private func closeCurrentFeature() {
        Task { @MainActor in
            guard appModel.immersiveSpaceState == .open else { return }
            appModel.immersiveSpaceState = .inTransition
            await dismissImmersiveSpace()
        }
    }
}

#Preview(windowStyle: .volumetric) {
    ContentView()
        .environment(AppModel())
}
