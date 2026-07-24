//
//  ChromaKeySettings.swift
//  Video-POC
//

import Foundation
import simd

struct ChromaKeySettings: Sendable, Equatable {
    var keyColor = SIMD3<Float>(0.0, 1.0, 0.0)
    var threshold: Float = 0.28
    var softness: Float = 0.25
    var spillSuppression: Float = 1.0
}
