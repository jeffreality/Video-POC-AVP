//
//  TransparentVideoPanelView.swift
//  Video-POC
//

import SwiftUI
import RealityKit

struct TransparentVideoPanelView: View {
    @State private var coordinator = TransparentVideoCoordinator()

    var body: some View {
        RealityView { content, attachments in
            await coordinator.install(into: content, attachments: attachments)
        } update: { _, attachments in
            coordinator.updateAttachments(attachments)
        } attachments: {
            Attachment(id: TransparentVideoCoordinator.controlsAttachmentID) {
                TransparentVideoControlsView(coordinator: coordinator)
            }
        }
        .task {
            await coordinator.start()
        }
        .onDisappear {
            coordinator.stop()
        }
    }
}
