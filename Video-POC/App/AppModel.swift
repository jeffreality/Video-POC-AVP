//
//  AppModel.swift
//  Video-POC
//
//  Created by Jeffrey Berthiaume on 3/26/26.
//

import SwiftUI
import Observation

@MainActor
@Observable
class AppModel {
    let immersiveSpaceID = "ImmersiveSpace"

    enum ImmersiveSpaceState {
        case closed
        case inTransition
        case open
    }

    var immersiveSpaceState = ImmersiveSpaceState.closed
}
