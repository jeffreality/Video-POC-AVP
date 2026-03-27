//
//  TemporalEchoVideoPanelView.swift
//  Video-POC
//
//  Created by Jeffrey Berthiaume on 3/27/26.
//

import SwiftUI
import RealityKit

struct TemporalEchoVideoPanelView: View {
    @State private var coordinator = TemporalEchoCoordinator()

    var body: some View {
        RealityView { content in
            await coordinator.install(into: content)
        }
        .task {
            await coordinator.start()
        }
        .onDisappear {
            coordinator.stop()
        }
    }
}
