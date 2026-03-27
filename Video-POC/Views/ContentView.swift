//
//  ContentView.swift
//  Video-POC
//
//  Created by Jeffrey Berthiaume on 3/26/26.
//

import SwiftUI
import RealityKit
import RealityKitContent

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        VStack(spacing: 16) {
            Text("Temporal Echo Video")
                .font(.title2)

            Button("Open Video") {
                Task {
                    guard appModel.immersiveSpaceState == .closed else { return }
                    appModel.immersiveSpaceState = .inTransition

                    let result = await openImmersiveSpace(id: appModel.immersiveSpaceID)
                    print("openImmersiveSpace result:", result)
                    
                    switch result {
                    case .opened:
                        break
                    case .userCancelled, .error:
                        appModel.immersiveSpaceState = .closed
                    @unknown default:
                        appModel.immersiveSpaceState = .closed
                    }
                }
            }

            Button("Close Video") {
                Task {
                    guard appModel.immersiveSpaceState == .open else { return }
                    appModel.immersiveSpaceState = .inTransition
                    await dismissImmersiveSpace()
                    appModel.immersiveSpaceState = .closed
                }
            }
        }
        .padding()
    }
}

#Preview(windowStyle: .volumetric) {
    ContentView()
        .environment(AppModel())
}
