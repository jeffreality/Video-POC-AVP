//
//  SpatialSubtitlesVideoPanelView.swift
//  Video-POC
//

import SwiftUI
import RealityKit

struct SpatialSubtitlesVideoPanelView: View {
    @State private var coordinator = SpatialSubtitlesCoordinator()

    var body: some View {
        RealityView { content, attachments in
            await coordinator.install(into: content, attachments: attachments)
        } update: { _, attachments in
            coordinator.updateAttachments(attachments)
        } attachments: {
            Attachment(id: SpatialSubtitlesCoordinator.controlsAttachmentID) {
                SpatialSubtitleControlsView(coordinator: coordinator)
            }

            Attachment(id: SpatialSubtitlesCoordinator.subtitleAttachmentID) {
                HeadRelativeSubtitleView(coordinator: coordinator)
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
