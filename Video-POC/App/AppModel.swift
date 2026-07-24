//
//  AppModel.swift
//  Video-POC
//

import SwiftUI
import Observation

@MainActor
@Observable
final class AppModel {
    let immersiveSpaceID = "ImmersiveSpace"

    enum Feature: String, CaseIterable, Identifiable {
        case temporalEcho
        case spatialSubtitles
        case transparentVideo

        var id: String { rawValue }

        var title: String {
            switch self {
            case .temporalEcho: "Temporal Echo"
            case .spatialSubtitles: "Spatial Subtitles"
            case .transparentVideo: "Transparent Video"
            }
        }

        var systemImage: String {
            switch self {
            case .temporalEcho: "square.stack.3d.up"
            case .spatialSubtitles: "captions.bubble"
            case .transparentVideo: "person.crop.rectangle"
            }
        }

        var summary: String {
            switch self {
            case .temporalEcho:
                "A smooth, hardware-decoded stack of delayed video layers."
            case .spatialSubtitles:
                "Head-relative subtitles with seven selectable SRT languages."
            case .transparentVideo:
                "Chroma-key a separate source into HEVC-with-alpha playback."
            }
        }
    }

    enum ImmersiveSpaceState {
        case closed
        case inTransition
        case open
    }

    var selectedFeature: Feature?
    var immersiveSpaceState = ImmersiveSpaceState.closed
}
