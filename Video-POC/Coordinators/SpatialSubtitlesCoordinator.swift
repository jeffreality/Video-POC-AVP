//
//  SpatialSubtitlesCoordinator.swift
//  Video-POC
//

import SwiftUI
import Foundation
import Observation
import RealityKit
import AVFoundation
import ARKit
import QuartzCore
import simd

@MainActor
@Observable
final class SpatialSubtitlesCoordinator {
    static let controlsAttachmentID = "spatial-subtitle-controls"
    static let subtitleAttachmentID = "spatial-subtitle-text"

    // MARK: - Observable UI state

    private(set) var isPlaying = true
    private(set) var currentCueText = ""
    private(set) var availableLanguages: [SubtitleLanguage] = []
    private(set) var errorMessage: String?
    var selectedLanguage: SubtitleLanguage = .english

    // MARK: - Scene

    @ObservationIgnored private let root = Entity()
    @ObservationIgnored private let panelRoot = Entity()
    @ObservationIgnored private var videoPlane: ModelEntity?
    @ObservationIgnored private weak var controlsEntity: ViewAttachmentEntity?
    @ObservationIgnored private weak var subtitleEntity: ViewAttachmentEntity?

    // MARK: - Tracking

    @ObservationIgnored private let arSession = ARKitSession()
    @ObservationIgnored private let worldTracking = WorldTrackingProvider()
    @ObservationIgnored private var didPlacePanel = false
    @ObservationIgnored private var smoothedSubtitlePosition: SIMD3<Float>?

    // MARK: - Video and subtitles

    @ObservationIgnored private var player: AVQueuePlayer?
    @ObservationIgnored private var looper: AVPlayerLooper?
    @ObservationIgnored private var cuesByLanguage: [SubtitleLanguage: [SubtitleCue]] = [:]
    @ObservationIgnored private var lastDisplayedCue: SubtitleCue?

    // MARK: - Loop

    @ObservationIgnored private var updateTask: Task<Void, Never>?
    @ObservationIgnored private var isRunning = false

    // MARK: - Placement tuning

    private let videoSize = SIMD2<Float>(0.95, 0.534)
    private let videoDistance: Float = 1.30
    private let subtitleDistance: Float = 0.78
    private let subtitleDrop: Float = 0.17
    private let subtitlePositionSmoothing: Float = 0.24

    func install(into content: RealityViewContent, attachments: RealityViewAttachments) async {
        guard root.parent == nil else {
            attachViewsIfNeeded(attachments)
            return
        }

        content.add(root)
        root.addChild(panelRoot)
        panelRoot.position = [0, 1.25, -1.5]

        let mesh = MeshResource.generateBox(size: [videoSize.x, videoSize.y, 0.001])
        var placeholder = UnlitMaterial()
        placeholder.color = .init(tint: .black)

        let plane = ModelEntity(mesh: mesh, materials: [placeholder])
        plane.name = "spatial-subtitle-video"
        panelRoot.addChild(plane)
        videoPlane = plane

        attachViewsIfNeeded(attachments)
    }

    func updateAttachments(_ attachments: RealityViewAttachments) {
        attachViewsIfNeeded(attachments)
    }

    func start() async {
        guard !isRunning else { return }
        isRunning = true

        do {
            try await arSession.run([worldTracking])
        } catch {
            print("SpatialSubtitles: failed to start ARKitSession: \(error)")
        }

        loadSubtitleFiles()
        configureVideo()
        placeVideoPanelIfPossible()
        player?.play()
        isPlaying = true
        startUpdateLoop()
    }

    func stop() {
        isRunning = false
        updateTask?.cancel()
        updateTask = nil
        player?.pause()
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

    func selectLanguage(_ language: SubtitleLanguage) {
        guard availableLanguages.contains(language) else { return }
        selectedLanguage = language
        lastDisplayedCue = nil
        updateSubtitleText(at: player?.currentTime().seconds ?? 0)
    }

    // MARK: - Setup

    private func attachViewsIfNeeded(_ attachments: RealityViewAttachments) {
        if controlsEntity == nil,
           let controls = attachments.entity(for: Self.controlsAttachmentID) {
            controls.name = Self.controlsAttachmentID
            controls.position = [0, -0.34, -0.018]

            // `panelRoot.look(at:)` points the panel toward the viewer using
            // RealityKit's forward axis, while a SwiftUI attachment's visible
            // face is oriented the opposite way. Rotate just the controls so
            // the buttons and menu face the same direction as the video.
            controls.orientation = simd_quatf(
                angle: .pi,
                axis: SIMD3<Float>(0, 1, 0)
            )

            panelRoot.addChild(controls)
            controlsEntity = controls
        }

        if subtitleEntity == nil,
           let subtitle = attachments.entity(for: Self.subtitleAttachmentID) {
            subtitle.name = Self.subtitleAttachmentID
            subtitle.components.set(BillboardComponent())
            root.addChild(subtitle)
            subtitleEntity = subtitle
        }
    }

    private func configureVideo() {
        guard player == nil else { return }

        guard let url = bundledResourceURL(named: "02b", extension: "mp4") else {
            errorMessage = "02b.mp4 was not found in Resources or the app bundle."
            return
        }

        let templateItem = AVPlayerItem(url: url)
        let queuePlayer = AVQueuePlayer()
        queuePlayer.automaticallyWaitsToMinimizeStalling = false
        let playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: templateItem)

        player = queuePlayer
        looper = playerLooper
        videoPlane?.model?.materials = [VideoMaterial(avPlayer: queuePlayer)]
    }

    private func loadSubtitleFiles() {
        cuesByLanguage.removeAll(keepingCapacity: true)

        for language in SubtitleLanguage.allCases {
            guard let url = subtitleURL(for: language) else { continue }

            do {
                let cues = try SRTParser.parse(url: url)
                if !cues.isEmpty {
                    cuesByLanguage[language] = cues
                }
            } catch {
                print("SpatialSubtitles: unable to parse \(url.lastPathComponent): \(error)")
            }
        }

        availableLanguages = SubtitleLanguage.allCases.filter { cuesByLanguage[$0] != nil }

        if !availableLanguages.contains(selectedLanguage), let first = availableLanguages.first {
            selectedLanguage = first
        }

        if availableLanguages.isEmpty {
            errorMessage = "No 02b.<language>.srt files were found in Resources or the app bundle."
        }
    }

    private func subtitleURL(for language: SubtitleLanguage) -> URL? {
        // The files may be copied as a real Resources directory (blue folder)
        // or flattened into the bundle by an Xcode group (yellow folder).
        let compoundName = "02b.\(language.rawValue)"

        if let url = bundledResourceURL(named: compoundName, extension: "srt") {
            return url
        }

        // Extra fallback for bundles that preserve the language as part of
        // the extension rather than the resource name.
        return bundledResourceURL(named: "02b", extension: "\(language.rawValue).srt")
    }

    private func bundledResourceURL(named name: String, extension fileExtension: String) -> URL? {
        Bundle.main.url(
            forResource: name,
            withExtension: fileExtension,
            subdirectory: "Resources"
        ) ?? Bundle.main.url(forResource: name, withExtension: fileExtension)
    }

    // MARK: - Update loop

    private func startUpdateLoop() {
        updateTask?.cancel()
        updateTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.isRunning {
                self.tick()
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func tick() {
        placeVideoPanelIfPossible()
        updateHeadRelativeSubtitlePlacement()
        updateSubtitleText(at: player?.currentTime().seconds ?? 0)
    }

    private func placeVideoPanelIfPossible() {
        guard !didPlacePanel else { return }
        guard let anchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) else {
            return
        }

        let matrix = anchor.originFromAnchorTransform
        let head = matrix.translation
        let forward = -matrix.forward
        let target = head + forward * videoDistance + matrix.up * 0.02

        panelRoot.position = target
        panelRoot.look(at: head, from: target, relativeTo: nil)
        didPlacePanel = true
    }

    private func updateHeadRelativeSubtitlePlacement() {
        guard let subtitleEntity,
              let anchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) else {
            return
        }

        let matrix = anchor.originFromAnchorTransform
        let desiredPosition = matrix.translation
            + (-matrix.forward * subtitleDistance)
            - (matrix.up * subtitleDrop)

        let nextPosition: SIMD3<Float>
        if let current = smoothedSubtitlePosition {
            nextPosition = simd_mix(
                current,
                desiredPosition,
                SIMD3<Float>(repeating: subtitlePositionSmoothing)
            )
        } else {
            nextPosition = desiredPosition
        }

        smoothedSubtitlePosition = nextPosition
        subtitleEntity.setPosition(nextPosition, relativeTo: nil)
    }

    private func updateSubtitleText(at time: TimeInterval) {
        guard let cues = cuesByLanguage[selectedLanguage] else {
            setDisplayedCue(nil)
            return
        }

        let cue = cue(at: time, in: cues)
        setDisplayedCue(cue)
    }

    private func setDisplayedCue(_ cue: SubtitleCue?) {
        guard cue != lastDisplayedCue else { return }
        lastDisplayedCue = cue
        currentCueText = cue?.text ?? ""
        subtitleEntity?.isEnabled = cue != nil
    }

    private func cue(at time: TimeInterval, in cues: [SubtitleCue]) -> SubtitleCue? {
        var lowerBound = 0
        var upperBound = cues.count

        while lowerBound < upperBound {
            let midpoint = (lowerBound + upperBound) / 2
            if cues[midpoint].startTime <= time {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }

        let candidateIndex = lowerBound - 1
        guard candidateIndex >= 0, candidateIndex < cues.count else { return nil }
        let candidate = cues[candidateIndex]
        return candidate.contains(time) ? candidate : nil
    }
}
