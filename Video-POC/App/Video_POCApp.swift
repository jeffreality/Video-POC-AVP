//
//  Video_POCApp.swift
//  Video-POC
//
//  Created by Jeffrey Berthiaume on 3/26/26.
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
            TemporalEchoVideoPanelView()
                .environment(appModel)
                .onAppear {
                    print("Immersive space appeared")
                    appModel.immersiveSpaceState = .open
                }
                .onDisappear {
                    print("Immersive space disappeared")
                    appModel.immersiveSpaceState = .closed
                }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
        
    }
}
