//
//  simd-extension.swift
//  Video-POC
//

import Foundation
import simd

extension simd_float4x4 {
    var translation: SIMD3<Float> {
        SIMD3<Float>(columns.3.x, columns.3.y, columns.3.z)
    }

    var forward: SIMD3<Float> {
        simd_normalize(SIMD3<Float>(columns.2.x, columns.2.y, columns.2.z))
    }

    var up: SIMD3<Float> {
        simd_normalize(SIMD3<Float>(columns.1.x, columns.1.y, columns.1.z))
    }

    func transformPoint(_ point: SIMD3<Float>) -> SIMD3<Float> {
        let value = self * SIMD4<Float>(point.x, point.y, point.z, 1)
        return SIMD3<Float>(value.x, value.y, value.z)
    }
}
