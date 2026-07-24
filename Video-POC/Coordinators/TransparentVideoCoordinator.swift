//
//  TransparentVideoCoordinator.swift
//  Video-POC
//

import SwiftUI
import Foundation
import Observation
import RealityKit
import AVFoundation
import ARKit
import QuartzCore

@MainActor
@Observable
final class TransparentVideoCoordinator {
    static let controlsAttachmentID = "transparent-video-controls"

    enum Status: Equatable {
        case idle
        case preparing
        case ready
        case failed(String)

        var label: String {
            switch self {
            case .idle: "Waiting to prepare"
            case .preparing: "Creating transparent video"
            case .ready: "Transparent video ready"
            case .failed(let message): message
            }
        }
    }

    // Change this one value to match the independent green-screen test asset.
    static let sourceResourceName = "Green-Screen-Sample"

    private(set) var status: Status = .idle
    private(set) var processingProgress: Double = 0
    private(set) var isPlaying = false
    private(set) var hasPlayableVideo = false

    var threshold: Double = 0.28
    var softness: Double = 0.25
    var spillSuppression: Double = 1.0

    @ObservationIgnored private let root = Entity()
    @ObservationIgnored private let panelRoot = Entity()
    @ObservationIgnored private var videoPlane: ModelEntity?
    @ObservationIgnored private weak var controlsEntity: ViewAttachmentEntity?

    @ObservationIgnored private let arSession = ARKitSession()
    @ObservationIgnored private let worldTracking = WorldTrackingProvider()
    @ObservationIgnored private var didPlacePanel = false

    @ObservationIgnored private let processor = ChromaKeyVideoProcessor()
    @ObservationIgnored private var processingTask: Task<Void, Never>?
    @ObservationIgnored private var placementTask: Task<Void, Never>?
    @ObservationIgnored private var player: AVQueuePlayer?
    @ObservationIgnored private var looper: AVPlayerLooper?

    private let planeSize = SIMD2<Float>(0.82, 0.52)
    private let panelDistance: Float = 1.15

    func install(into content: RealityViewContent, attachments: RealityViewAttachments) async {
        guard root.parent == nil else {
            attachControlsIfNeeded(attachments)
            return
        }

        content.add(root)
        root.addChild(panelRoot)
        panelRoot.position = [0, 1.2, -1.35]

        let mesh = MeshResource.generatePlane(width: planeSize.x, height: planeSize.y)
        var placeholder = UnlitMaterial()
        placeholder.color = .init(tint: .clear)

        let plane = ModelEntity(mesh: mesh, materials: [placeholder])
        plane.name = "transparent-video-plane"

        // `panelRoot.look(at:)` points the panel toward the viewer using
        // RealityKit's forward axis, but `generatePlane` has only one visible
        // front face. Turn that front face toward the viewer. Without this,
        // AVPlayer still plays (including audio) while the video surface is
        // removed by back-face culling.
        plane.orientation = simd_quatf(
            angle: .pi,
            axis: SIMD3<Float>(0, 1, 0)
        )

        panelRoot.addChild(plane)
        videoPlane = plane

        attachControlsIfNeeded(attachments)
    }

    func updateAttachments(_ attachments: RealityViewAttachments) {
        attachControlsIfNeeded(attachments)
    }

    func start() async {
        do {
            try await arSession.run([worldTracking])
        } catch {
            print("TransparentVideo: failed to start ARKitSession: \(error)")
        }

        startPlacementLoop()
        prepareVideo(force: false)
    }

    func stop() {
        processingTask?.cancel()
        processingTask = nil
        placementTask?.cancel()
        placementTask = nil
        player?.pause()
        isPlaying = false
    }

    func togglePlayback() {
        guard let player else { return }

        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    func reprocess() {
        prepareVideo(force: true)
    }

    private func attachControlsIfNeeded(_ attachments: RealityViewAttachments) {
        guard controlsEntity == nil,
              let controls = attachments.entity(for: Self.controlsAttachmentID) else {
            return
        }

        controls.name = Self.controlsAttachmentID
        controls.position = [0, -0.38, -0.018]

        // A SwiftUI attachment's visible face points opposite the local face
        // produced by `panelRoot.look(at:)`. Flip the attachment around its
        // vertical axis so the full chroma-key control panel faces the viewer.
        controls.orientation = simd_quatf(
            angle: .pi,
            axis: SIMD3<Float>(0, 1, 0)
        )

        panelRoot.addChild(controls)
        controlsEntity = controls
    }


    private func startPlacementLoop() {
        placementTask?.cancel()
        placementTask = Task { [weak self] in
            while let self, !Task.isCancelled, !self.didPlacePanel {
                self.placePanelIfPossible()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func placePanelIfPossible() {
        guard !didPlacePanel,
              let anchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) else {
            return
        }

        let matrix = anchor.originFromAnchorTransform
        let head = matrix.translation
        let target = head + (-matrix.forward * panelDistance)

        panelRoot.position = target
        panelRoot.look(at: head, from: target, relativeTo: nil)
        didPlacePanel = true
    }

    private func prepareVideo(force: Bool) {
        processingTask?.cancel()

        // Keep the last successfully prepared movie alive while a replacement is
        // rendering. Deleting or detaching it up front makes RealityKit show a
        // black plane and silences audio for the entire conversion.
        let hadPlayableVideo = player != nil
        if !hadPlayableVideo {
            isPlaying = false
        }

        processingTask = Task { [weak self] in
            guard let self else { return }

            do {
                guard let sourceURL = self.sourceVideoURL() else {
                    throw TransparentVideoError.missingSource
                }

                let outputURL = try self.cachedOutputURL(sourceURL: sourceURL)

                if force || !FileManager.default.fileExists(atPath: outputURL.path) {
                    self.status = .preparing
                    self.processingProgress = 0

                    let settings = ChromaKeySettings(
                        keyColor: [0, 1, 0],
                        threshold: Float(self.threshold),
                        softness: Float(self.softness),
                        spillSuppression: Float(self.spillSuppression)
                    )

                    try await self.processor.process(
                        sourceURL: sourceURL,
                        outputURL: outputURL,
                        settings: settings
                    ) { [weak self] progress in
                        self?.processingProgress = progress
                    }
                }

                guard !Task.isCancelled else { return }
                self.configurePlayback(url: outputURL)
                self.status = .ready
                self.processingProgress = 1
                self.player?.play()
                self.isPlaying = true
            } catch is CancellationError {
                return
            } catch {
                self.status = .failed(error.localizedDescription)
                self.processingProgress = 0
                print("TransparentVideo: \(error)")
            }
        }
    }

    private func configurePlayback(url: URL) {
        let oldPlayer = player

        let asset = AVURLAsset(url: url)
        let templateItem = AVPlayerItem(asset: asset)
        let queuePlayer = AVQueuePlayer()
        queuePlayer.automaticallyWaitsToMinimizeStalling = true
        queuePlayer.actionAtItemEnd = .none
        let playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: templateItem)

        var material = VideoMaterial(avPlayer: queuePlayer)

        // Be defensive about procedural-plane winding. VideoMaterial normally
        // culls back-facing triangles; disabling culling guarantees the movie
        // remains visible even if the parent transform changes later.
        material.faceCulling = .none

        // Fully transparent pixels should not write an invisible rectangle into
        // RealityKit's depth buffer and hide objects behind the keyed subject.
        material.writesDepth = false

        // Swap the material and player only after the new item has been created.
        // The previous movie can continue displaying throughout reprocessing.
        videoPlane?.model?.materials = [material]
        player = queuePlayer
        looper = playerLooper
        hasPlayableVideo = true
        oldPlayer?.pause()
    }

    private func sourceVideoURL() -> URL? {
        bundledResourceURL(named: Self.sourceResourceName, extension: "mp4")
            ?? bundledResourceURL(named: Self.sourceResourceName, extension: "mov")
    }

    private func bundledResourceURL(named name: String, extension fileExtension: String) -> URL? {
        Bundle.main.url(
            forResource: name,
            withExtension: fileExtension,
            subdirectory: "Resources"
        ) ?? Bundle.main.url(forResource: name, withExtension: fileExtension)
    }

    private func cachedOutputURL(sourceURL: URL) throws -> URL {
        let cacheDirectory = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let values = try? sourceURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let sourceSize = values?.fileSize ?? 0
        let modified = Int(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)

        let signature = String(
            format: "pipeline3-%d-%d-t%03d-s%03d-p%03d",
            sourceSize,
            modified,
            Int(threshold * 1000),
            Int(softness * 1000),
            Int(spillSuppression * 1000)
        )

        return cacheDirectory
            .appendingPathComponent("\(Self.sourceResourceName)-\(signature)")
            .appendingPathExtension("mov")
    }
}

private enum TransparentVideoError: LocalizedError {
    case missingSource

    var errorDescription: String? {
        switch self {
        case .missingSource:
            "Add Green-Screen-Sample.mp4 to Resources and make sure it has Video-POC target membership."
        }
    }
}
