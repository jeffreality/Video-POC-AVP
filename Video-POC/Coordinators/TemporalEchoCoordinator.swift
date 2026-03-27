//
//  TemporalEchoCoordinator.swift
//  Video-POC
//
//  Created by Jeffrey Berthiaume on 3/26/26.
//

import SwiftUI
import RealityKit
import AVFoundation
import ARKit
import CoreImage
import QuartzCore
import simd

/// Prototype for a Vision Pro "temporal echo" video effect.

/// What it does:
/// - Plays the live/current video on a front plane.
/// - Captures earlier video frames and places them on planes behind the front plane.
/// - Uses the user's head pose to spread those older frames in XY, so the echoes drift
///   as the viewer changes angle.
/// - Adds a tiny time-varying micro-jitter so the stack feels more alive and less like
///   perfect stair-steps.

@MainActor
final class TemporalEchoCoordinator {
    // MARK: - Tuning

    private let echoCount = 12
    private let historyStep = 2
    private let captureFPS: Double = 24
    private let planeSize = SIMD2<Float>(0.8, 0.45)
    private let panelDistance: Float = 1.0
    private let panelVerticalOffset: Float = 0.0
    private let headSpreadScale: Float = 0.28
    private let velocitySpreadScale: Float = 0.06
    private let microJitterAmplitude: Float = 0.008
    private let depthSpreadScale: Float = 1.35
    private let scaleBloatPerLayer: Float = 0.002
    private let smoothing: Float = 0.16
    private let currentLayerOffset: Float = -0.01
    private let baseLayerDepth: Float = 0.03

    // MARK: - Scene

    private let root = Entity()
    private let panelRoot = Entity()
    private var currentPlane: ModelEntity?
    private var echoPlanes: [ModelEntity] = []

    // MARK: - Tracking

    private let arSession = ARKitSession()
    private let worldTracking = WorldTrackingProvider()
    private var didPlacePanel = false
    private var lastHeadSampleTime: CFTimeInterval = 0
    private var lastHeadLocal = SIMD2<Float>(repeating: 0)
    private var smoothedSpread = SIMD2<Float>(repeating: 0)

    // MARK: - Video

    private let ciContext = CIContext(options: nil)
    private var player: AVPlayer?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var historyImages: [CGImage] = []
    private var lastCapturePTS: Double = -1

    // MARK: - Loop

    private var renderTask: Task<Void, Never>?
    private var isRunning = false

    // MARK: - Install

    private let fallbackPanelPosition = SIMD3<Float>(0, 1.15, -1.0)

    func install(into content: RealityViewContent) async {
        guard root.parent == nil else { return }

        content.add(root)
        root.addChild(panelRoot)

        // Fallback visible placement for Simulator / failed device-anchor lookup
        panelRoot.position = [0, 1.25, -1.4]

        let front = makeVideoPlane(name: "current")
        front.position = [0, 0, currentLayerOffset]
        front.components.set(OpacityComponent(opacity: 1.0))
        panelRoot.addChild(front)
        currentPlane = front

        echoPlanes = (0..<echoCount).map { i in
            let plane = makeVideoPlane(name: "echo_\(i)")
            let z = baseLayerDepth * Float(i + 1)
            plane.position = [0, 0, z]
            plane.components.set(OpacityComponent(opacity: 0.0))
            panelRoot.addChild(plane)
            return plane
        }

        print("TemporalEcho: installed panel root at fallback position \(panelRoot.position)")
    }

    // MARK: - Start / Stop

    func start() async {
        guard !isRunning else { return }
        isRunning = true

        do {
            try await arSession.run([worldTracking])
            print("ARKitSession running")
        } catch {
            print("TemporalEcho: failed to start ARKitSession: \(error)")
        }

        configureVideo()
        print("TemporalEcho: player exists?", player != nil)
        applyLiveVideoToCurrentPlane()
        print("TemporalEcho: applied live video material")
        placePanelInFrontOfUserIfPossible()
        startRenderLoop()
        player?.play()
    }

    func stop() {
        isRunning = false
        renderTask?.cancel()
        renderTask = nil
        player?.pause()
    }

    // MARK: - Setup

    private func configureVideo() {
        guard player == nil else { return }

        guard let url = Bundle.main.url(forResource: "mockthru", withExtension: "mp4") else {
            print("TemporalEcho: mockthru.mp4 was not found in the app bundle.")
            return
        }

        print("TemporalEcho: found video at \(url)")

        let item = AVPlayerItem(url: url)
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
        item.add(output)

        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause

        self.player = player
        self.videoOutput = output
    }

    private func makeVideoPlane(name: String) -> ModelEntity {
        let mesh = MeshResource.generateBox(size: [planeSize.x, planeSize.y, 0.001])

        var material = UnlitMaterial()
        material.color = .init(tint: name == "current" ? .red : .blue.withAlphaComponent(0.25))

        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.name = name
        return entity
    }
    
    private func applyLiveVideoToCurrentPlane() {
        guard let player, let currentPlane else { return }
        currentPlane.model?.materials = [VideoMaterial(avPlayer: player)]
        currentPlane.components.set(OpacityComponent(opacity: 1.0))
    }

    private func placePanelInFrontOfUserIfPossible() {
        guard !didPlacePanel else { return }

        guard let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) else {
            print("TemporalEcho: device anchor unavailable, keeping fallback panel position")
            return
        }

        let deviceMatrix = deviceAnchor.originFromAnchorTransform
        let head = deviceMatrix.translation
        let forward = -deviceMatrix.forward
        let targetPosition = head + forward * panelDistance + SIMD3<Float>(0, panelVerticalOffset, 0)

        panelRoot.position = targetPosition
        panelRoot.look(at: head, from: targetPosition, relativeTo: nil)
        didPlacePanel = true

        print("TemporalEcho: placed panel from device anchor at \(targetPosition)")
    }

    // MARK: - Loop

    private func startRenderLoop() {
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.tick()
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func tick() async {
        placePanelInFrontOfUserIfPossible()
        updateHeadDrivenSpread()
        handleLoopIfNeeded()
        await captureFrameIfNeeded()
        updateEchoTransforms()
    }

    private func handleLoopIfNeeded() {
        guard let player, let item = player.currentItem else { return }

        let duration = item.duration.seconds
        guard duration.isFinite, duration > 0 else { return }

        let current = player.currentTime().seconds
        if current >= duration - 0.03 {
            historyImages.removeAll(keepingCapacity: true)
            lastCapturePTS = -1
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            player.play()
        }
    }

    private func updateHeadDrivenSpread() {
        guard didPlacePanel else { return }
        guard let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) else {
            return
        }

        let now = CACurrentMediaTime()
        let headWorld = deviceAnchor.originFromAnchorTransform.translation
        let panelWorld = panelRoot.transformMatrix(relativeTo: nil)
        let headLocal = panelWorld.inverse.transformPoint(headWorld)
        let local2 = SIMD2<Float>(headLocal.x, headLocal.y)

        let dt = max(now - lastHeadSampleTime, 1.0 / 90.0)
        let velocity = (local2 - lastHeadLocal) / Float(dt)
        let target = (local2 * headSpreadScale) + (velocity * velocitySpreadScale)
        smoothedSpread = simd_mix(smoothedSpread, target, SIMD2<Float>(repeating: smoothing))

        lastHeadLocal = local2
        lastHeadSampleTime = now
    }

    private func updateEchoTransforms() {
        let t = Float(CACurrentMediaTime())

        for (index, plane) in echoPlanes.enumerated() {
            let layer = Float(index + 1)
            let age = layer / Float(max(echoCount, 1))
            let depthFactor = pow(age, depthSpreadScale)
            let jitter = microJitter(for: index, time: t) * (microJitterAmplitude * (0.65 + depthFactor))
            let spread = smoothedSpread * (0.25 + depthFactor * 1.8)

            plane.position = [
                spread.x + jitter.x,
                -spread.y + jitter.y,
                baseLayerDepth * layer
            ]

            let scale = 1.0 + (scaleBloatPerLayer * layer)
            plane.scale = [scale, scale, 1.0]
            plane.components.set(OpacityComponent(opacity: echoOpacity(for: index)))
        }
    }

    private func microJitter(for index: Int, time: Float) -> SIMD2<Float> {
        let seed = Float(index + 1)
        let x = sin(time * (1.2 + seed * 0.11) + seed * 0.73)
        let y = cos(time * (1.4 + seed * 0.09) + seed * 1.17)
        return SIMD2<Float>(x, y)
    }

    private func echoOpacity(for index: Int) -> Float {
        let x = Float(index + 1) / Float(max(echoCount, 1))
        return max(0.05, 0.28 * pow(1.0 - x, 1.1))
    }

    // MARK: - Frame capture

    private func captureFrameIfNeeded() async {
        guard let videoOutput, let currentPlane else { return }

        let hostTime = CACurrentMediaTime()
        let itemTime = videoOutput.itemTime(forHostTime: hostTime)
        let ptsSeconds = itemTime.seconds

        guard ptsSeconds.isFinite else { return }
        guard ptsSeconds >= 0 else { return }
        guard (lastCapturePTS < 0) || (ptsSeconds - lastCapturePTS >= (1.0 / captureFPS)) else { return }
        guard videoOutput.hasNewPixelBuffer(forItemTime: itemTime) else { return }
        guard let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) else {
            return
        }
        guard let image = makeCGImage(from: pixelBuffer) else { return }

        if lastCapturePTS >= 0, ptsSeconds < lastCapturePTS {
            historyImages.removeAll(keepingCapacity: true)
            lastCapturePTS = -1
        }

        lastCapturePTS = ptsSeconds
        historyImages.insert(image, at: 0)

        let maxFrames = echoCount * historyStep + 1
        if historyImages.count > maxFrames {
            historyImages.removeLast(historyImages.count - maxFrames)
        }

        await apply(image, to: currentPlane)

        guard !echoPlanes.isEmpty else { return }
        for (i, plane) in echoPlanes.enumerated() {
            let sampleIndex = min((i + 1) * historyStep, historyImages.count - 1)
            guard sampleIndex >= 0, sampleIndex < historyImages.count else { continue }
            await apply(historyImages[sampleIndex], to: plane)
        }
    }

    private func makeCGImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let rect = ciImage.extent.integral
        return ciContext.createCGImage(ciImage, from: rect)
    }

    private func apply(_ image: CGImage, to entity: ModelEntity) async {
        do {
            let texture = try await TextureResource(
                image: image,
                withName: nil,
                options: .init(semantic: .color)
            )
            var material = UnlitMaterial()
            material.color = .init(texture: .init(texture))
            entity.model?.materials = [material]
        } catch {
            print("TemporalEcho: failed to create texture: \(error)")
        }
    }
}
