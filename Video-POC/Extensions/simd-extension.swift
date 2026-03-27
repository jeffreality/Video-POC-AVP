//
//  simd-extension.swift
//  Video-POC
//
//  Created by Jeffrey Berthiaume on 3/27/26.
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

    func transformPoint(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let v = self * SIMD4<Float>(p.x, p.y, p.z, 1)
        return SIMD3<Float>(v.x, v.y, v.z)
    }
}
