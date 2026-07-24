//
//  Video_POCApp.swift
//  Video-POC
//

import SwiftUI

@main
struct Video_POCApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
        }
        .windowStyle(.volumetric)

        ImmersiveSpace(id: appModel.immersiveSpaceID) {
            ActiveFeatureView()
                .environment(appModel)
                .onAppear {
                    appModel.immersiveSpaceState = .open
                }
                .onDisappear {
                    appModel.immersiveSpaceState = .closed
                    appModel.selectedFeature = nil
                }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}

private struct ActiveFeatureView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Group {
            switch appModel.selectedFeature {
            case .temporalEcho:
                TemporalEchoVideoPanelView()
            case .spatialSubtitles:
                SpatialSubtitlesVideoPanelView()
            case .transparentVideo:
                TransparentVideoPanelView()
            case nil:
                EmptyView()
            }
        }
    }
}
