//
//  TemporalEchoCoordinator.swift
//  Video-POC
//

import SwiftUI
import RealityKit
import AVFoundation
import ARKit
import QuartzCore
import simd

/// A temporal-echo prototype that uses independent, hardware-decoded AVPlayers
/// rather than rebuilding RealityKit textures for every layer on every frame.
///
/// The previous implementation created hundreds of TextureResource objects per
/// second. This version keeps one VideoMaterial per layer and periodically
/// corrects timing drift between delayed players.
@MainActor
final class TemporalEchoCoordinator {
    // MARK: - Tuning

    private let echoDelays: [Double] = [0.09, 0.17, 0.27, 0.40, 0.57, 0.78, 1.04]
    private let planeSize = SIMD2<Float>(0.90, 0.506)
    private let panelDistance: Float = 1.15
    private let panelVerticalOffset: Float = 0.02
    private let headSpreadScale: Float = 0.25
    private let velocitySpreadScale: Float = 0.035
    private let microJitterAmplitude: Float = 0.004
    private let baseLayerDepth: Float = 0.028
    private let scaleBloatPerLayer: Float = 0.004
    private let smoothing: Float = 0.13
    private let synchronizationInterval: CFTimeInterval = 0.45
    private let driftCorrectionThreshold: Double = 0.065

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

    private var mainPlayer: AVQueuePlayer?
    private var mainLooper: AVPlayerLooper?
    private var echoPlayers: [AVQueuePlayer] = []
    private var echoLoopers: [AVPlayerLooper] = []
    private var videoDuration: Double = 0
    private var lastSynchronizationTime: CFTimeInterval = 0

    // MARK: - Loop

    private var renderTask: Task<Void, Never>?
    private var isRunning = false

    // MARK: - Install

    func install(into content: RealityViewContent) async {
        guard root.parent == nil else { return }

        content.add(root)
        root.addChild(panelRoot)

        // Visible fallback for Simulator or a temporarily unavailable device anchor.
        panelRoot.position = [0, 1.25, -1.4]

        let front = makeVideoPlane(name: "current")
        front.position = [0, 0, -0.012]
        panelRoot.addChild(front)
        currentPlane = front

        echoPlanes = echoDelays.indices.map { index in
            let plane = makeVideoPlane(name: "echo_\(index)")
            plane.position = [0, 0, baseLayerDepth * Float(index + 1)]
            plane.components.set(OpacityComponent(opacity: echoOpacity(for: index)))
            panelRoot.addChild(plane)
            return plane
        }
    }

    // MARK: - Start / Stop

    func start() async {
        guard !isRunning else { return }
        isRunning = true

        do {
            try await arSession.run([worldTracking])
        } catch {
            print("TemporalEcho: failed to start ARKitSession: \(error)")
        }

        do {
            try await configureVideo()
            placePanelInFrontOfUserIfPossible()
            synchronizePlayers(force: true)
            playAll()
            startRenderLoop()
        } catch {
            print("TemporalEcho: \(error.localizedDescription)")
        }
    }

    func stop() {
        isRunning = false
        renderTask?.cancel()
        renderTask = nil
        mainPlayer?.pause()
        echoPlayers.forEach { $0.pause() }
    }

    // MARK: - Video setup

    private func configureVideo() async throws {
        guard mainPlayer == nil else { return }

        guard let url = bundledResourceURL(named: "mockthru", extension: "mp4") else {
            throw TemporalEchoError.missingVideo
        }

        let asset = AVURLAsset(url: url)
        videoDuration = try await asset.load(.duration).seconds
        guard videoDuration.isFinite, videoDuration > 0 else {
            throw TemporalEchoError.invalidDuration
        }

        let mainPair = makeLoopingPlayer(url: url, muted: false)
        mainPlayer = mainPair.player
        mainLooper = mainPair.looper

        echoPlayers.removeAll(keepingCapacity: true)
        echoLoopers.removeAll(keepingCapacity: true)

        for _ in echoDelays {
            let pair = makeLoopingPlayer(url: url, muted: true)
            echoPlayers.append(pair.player)
            echoLoopers.append(pair.looper)
        }

        if let mainPlayer, let currentPlane {
            currentPlane.model?.materials = [VideoMaterial(avPlayer: mainPlayer)]
            currentPlane.components.set(OpacityComponent(opacity: 1))
        }

        for (index, plane) in echoPlanes.enumerated() where index < echoPlayers.count {
            plane.model?.materials = [VideoMaterial(avPlayer: echoPlayers[index])]
        }
    }

    private func bundledResourceURL(named name: String, extension fileExtension: String) -> URL? {
        Bundle.main.url(
            forResource: name,
            withExtension: fileExtension,
            subdirectory: "Resources"
        ) ?? Bundle.main.url(forResource: name, withExtension: fileExtension)
    }

    private func makeLoopingPlayer(url: URL, muted: Bool) -> (player: AVQueuePlayer, looper: AVPlayerLooper) {
        let templateItem = AVPlayerItem(url: url)
        templateItem.preferredForwardBufferDuration = 0.35

        let player = AVQueuePlayer()
        player.isMuted = muted
        player.automaticallyWaitsToMinimizeStalling = false

        let looper = AVPlayerLooper(player: player, templateItem: templateItem)
        return (player, looper)
    }

    private func playAll() {
        mainPlayer?.playImmediately(atRate: 1)
        echoPlayers.forEach { $0.playImmediately(atRate: 1) }
    }

    private func synchronizePlayers(force: Bool = false) {
        guard let mainPlayer, videoDuration > 0 else { return }

        let now = CACurrentMediaTime()
        guard force || now - lastSynchronizationTime >= synchronizationInterval else { return }
        lastSynchronizationTime = now

        let mainTime = normalized(mainPlayer.currentTime().seconds)

        for (index, player) in echoPlayers.enumerated() where index < echoDelays.count {
            let target = wrapped(mainTime - echoDelays[index])
            let actual = normalized(player.currentTime().seconds)
            let drift = circularDistance(actual, target)

            if force || drift > driftCorrectionThreshold {
                let time = CMTime(seconds: target, preferredTimescale: 600)
                player.seek(
                    to: time,
                    toleranceBefore: CMTime(seconds: 0.015, preferredTimescale: 600),
                    toleranceAfter: CMTime(seconds: 0.015, preferredTimescale: 600)
                )
            }

            if mainPlayer.rate > 0, player.rate == 0 {
                player.playImmediately(atRate: mainPlayer.rate)
            }
        }
    }

    private func normalized(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        return wrapped(seconds)
    }

    private func wrapped(_ seconds: Double) -> Double {
        guard videoDuration > 0 else { return max(0, seconds) }
        let remainder = seconds.truncatingRemainder(dividingBy: videoDuration)
        return remainder >= 0 ? remainder : remainder + videoDuration
    }

    private func circularDistance(_ a: Double, _ b: Double) -> Double {
        let direct = abs(a - b)
        return min(direct, max(0, videoDuration - direct))
    }

    // MARK: - Scene creation

    private func makeVideoPlane(name: String) -> ModelEntity {
        let mesh = MeshResource.generateBox(size: [planeSize.x, planeSize.y, 0.001])
        var placeholder = UnlitMaterial()
        placeholder.color = .init(tint: .black)

        let entity = ModelEntity(mesh: mesh, materials: [placeholder])
        entity.name = name
        return entity
    }

    private func placePanelInFrontOfUserIfPossible() {
        guard !didPlacePanel else { return }
        guard let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) else {
            return
        }

        let deviceMatrix = deviceAnchor.originFromAnchorTransform
        let head = deviceMatrix.translation
        let forward = -deviceMatrix.forward
        let target = head + forward * panelDistance + SIMD3<Float>(0, panelVerticalOffset, 0)

        panelRoot.position = target
        panelRoot.look(at: head, from: target, relativeTo: nil)
        didPlacePanel = true
    }

    // MARK: - Update loop

    private func startRenderLoop() {
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.isRunning {
                self.tick()
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func tick() {
        placePanelInFrontOfUserIfPossible()
        updateHeadDrivenSpread()
        updateEchoTransforms()
        synchronizePlayers()
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

        if lastHeadSampleTime == 0 {
            lastHeadSampleTime = now
            lastHeadLocal = local2
            return
        }

        let dt = max(now - lastHeadSampleTime, 1.0 / 90.0)
        let velocity = (local2 - lastHeadLocal) / Float(dt)
        let target = (local2 * headSpreadScale) + (velocity * velocitySpreadScale)
        smoothedSpread = simd_mix(smoothedSpread, target, SIMD2<Float>(repeating: smoothing))

        lastHeadLocal = local2
        lastHeadSampleTime = now
    }

    private func updateEchoTransforms() {
        let time = Float(CACurrentMediaTime())

        for (index, plane) in echoPlanes.enumerated() {
            let layer = Float(index + 1)
            let age = layer / Float(max(echoPlanes.count, 1))
            let easedAge = age * age
            let spread = smoothedSpread * (0.30 + easedAge * 1.75)
            let jitter = microJitter(for: index, time: time) * microJitterAmplitude * (0.5 + age)

            plane.position = [
                spread.x + jitter.x,
                -spread.y + jitter.y,
                baseLayerDepth * layer
            ]

            let scale = 1 + scaleBloatPerLayer * layer
            plane.scale = [scale, scale, 1]
            plane.components.set(OpacityComponent(opacity: echoOpacity(for: index)))
        }
    }

    private func microJitter(for index: Int, time: Float) -> SIMD2<Float> {
        let seed = Float(index + 1)
        return [
            sin(time * (0.85 + seed * 0.07) + seed * 0.73),
            cos(time * (0.92 + seed * 0.06) + seed * 1.17)
        ]
    }

    private func echoOpacity(for index: Int) -> Float {
        let normalizedIndex = Float(index + 1) / Float(max(echoDelays.count, 1))
        return max(0.035, 0.30 * pow(1 - normalizedIndex, 1.15))
    }
}

private enum TemporalEchoError: LocalizedError {
    case missingVideo
    case invalidDuration

    var errorDescription: String? {
        switch self {
        case .missingVideo:
            "mockthru.mp4 was not found in Resources or the app bundle."
        case .invalidDuration:
            "mockthru.mp4 does not report a usable duration."
        }
    }
}
