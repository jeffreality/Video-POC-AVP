//
//  ChromaKeyVideoProcessor.swift
//  Video-POC
//

import Foundation
@preconcurrency import AVFoundation
@preconcurrency import CoreImage
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import simd

/// Converts a normal green-screen movie into a separate HEVC-with-alpha movie.
///
/// This implementation deliberately avoids `AVVideoComposition`'s unavailable
/// Core Image initializer on visionOS. It decodes frames with `AVAssetReader`,
/// applies a reusable `CIColorCubeWithColorSpace` filter, and writes the keyed
/// BGRA frames as HEVC with alpha using `AVAssetWriter`.
struct ChromaKeyVideoProcessor: Sendable {
    func process(
        sourceURL: URL,
        outputURL: URL,
        settings: ChromaKeySettings,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        guard #available(visionOS 26.0, *) else {
            throw ChromaKeyProcessorError.requiresVisionOS26
        }

        try await ModernChromaKeyVideoProcessor().process(
            sourceURL: sourceURL,
            outputURL: outputURL,
            settings: settings,
            progress: progress
        )
    }
}

@available(visionOS 26.0, *)
private struct ModernChromaKeyVideoProcessor: Sendable {
    func process(
        sourceURL: URL,
        outputURL: URL,
        settings: ChromaKeySettings,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ChromaKeyProcessorError.noVideoTrack
        }

        let duration = try await asset.load(.duration)
        let durationSeconds = max(duration.seconds, 0.001)
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)

        let width = max(Int(abs(naturalSize.width).rounded()), 2)
        let height = max(Int(abs(naturalSize.height).rounded()), 2)

        // Never write directly to the cache URL that playback considers
        // complete. A process termination during export can otherwise leave a
        // corrupt movie that is mistaken for a valid cached result next launch.
        let stagingURL = outputURL
            .deletingPathExtension()
            .appendingPathExtension("partial-\(UUID().uuidString).mov")

        try? FileManager.default.removeItem(at: stagingURL)

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: stagingURL, fileType: .mov)

        let readerVideoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )

        let videoProvider = reader.outputProvider(for: readerVideoOutput)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]

        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw ChromaKeyProcessorError.hevcAlphaUnsupported
        }

        let writerVideoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: videoSettings
        )
        writerVideoInput.transform = preferredTransform

        // The receiver-based API attaches this input to the writer. The output
        // buffers are allocated below because Core Image needs mutable buffers.
        let videoReceiver = writer.inputPixelBufferReceiver(
            for: writerVideoInput,
            pixelBufferAttributes: nil
        )

        let audioPipeline = try await makeAudioPipeline(
            asset: asset,
            reader: reader,
            writer: writer
        )

        let cubeData = Self.makeChromaKeyCube(settings: settings)

        do {
            // `start()` prepares the writer, but it does not begin its media
            // timeline. Every receiver append must happen after an explicit
            // writing session has started or AVFoundation raises an Objective-C
            // exception that cannot be caught by Swift.
            try writer.start()
            writer.startSession(atSourceTime: .zero)
            try reader.start()

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await Self.processVideoFrames(
                        provider: videoProvider,
                        receiver: videoReceiver,
                        width: width,
                        height: height,
                        cubeData: cubeData,
                        durationSeconds: durationSeconds,
                        progress: progress
                    )
                }

                if let audioPipeline {
                    group.addTask {
                        try await Self.copyAudio(
                            provider: audioPipeline.provider,
                            receiver: audioPipeline.receiver
                        )
                    }
                }

                try await group.waitForAll()
            }

            await writer.finishWriting()

            guard writer.status == .completed else {
                throw writer.error ?? ChromaKeyProcessorError.exportFailed
            }

            try await Self.validateOutput(at: stagingURL, expectsAudio: audioPipeline != nil)
            try Self.publish(stagingURL: stagingURL, outputURL: outputURL)
            await progress(1)
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: stagingURL)

            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }

            throw error
        }
    }

    private static func validateOutput(at url: URL, expectsAudio: Bool) async throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) > 1_024 else {
            throw ChromaKeyProcessorError.invalidOutput
        }

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let isPlayable = try await asset.load(.isPlayable)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        guard isPlayable,
              duration.isNumeric,
              duration.seconds > 0.05,
              !videoTracks.isEmpty,
              !expectsAudio || !audioTracks.isEmpty else {
            throw ChromaKeyProcessorError.invalidOutput
        }
    }

    private static func publish(stagingURL: URL, outputURL: URL) throws {
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: outputURL.path) {
            _ = try fileManager.replaceItemAt(
                outputURL,
                withItemAt: stagingURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: stagingURL, to: outputURL)
        }
    }

    private struct AudioPipeline: @unchecked Sendable {
        let provider: AVAssetReaderOutput.Provider<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>
        let receiver: AVAssetWriterInput.SampleBufferReceiver
    }

    private func makeAudioPipeline(
        asset: AVAsset,
        reader: AVAssetReader,
        writer: AVAssetWriter
    ) async throws -> AudioPipeline? {
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            return nil
        }

        let formatDescriptions = try await audioTrack.load(.formatDescriptions)
        guard let sourceFormatHint = formatDescriptions.first else {
            return nil
        }

        let readerAudioOutput = AVAssetReaderTrackOutput(
            track: audioTrack,
            outputSettings: nil
        )
        let provider = reader.outputProvider(for: readerAudioOutput)

        // A nil output-settings dictionary passes the compressed audio through
        // unchanged instead of needlessly re-encoding it.
        let writerAudioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: nil,
            sourceFormatHint: sourceFormatHint
        )
        let receiver = writer.inputReceiver(for: writerAudioInput)

        return AudioPipeline(provider: provider, receiver: receiver)
    }

    private static func processVideoFrames(
        provider: AVAssetReaderOutput.Provider<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>,
        receiver: AVAssetWriterInput.PixelBufferReceiver,
        width: Int,
        height: Int,
        cubeData: Data,
        durationSeconds: Double,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        let context = CIContext(options: [
            .cacheIntermediates: false
        ])
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)

        guard let filter = CIFilter(name: "CIColorCubeWithColorSpace") else {
            throw ChromaKeyProcessorError.filterCreationFailed
        }

        filter.setValue(NSNumber(value: Self.cubeDimension), forKey: "inputCubeDimension")
        filter.setValue(cubeData, forKey: "inputCubeData")
        filter.setValue(colorSpace, forKey: "inputColorSpace")

        var lastReportedProgress = -1.0

        while let dynamicSample = try await provider.next() {
            try Task.checkCancellation()

            guard let sourceSample = CMReadySampleBuffer<CVReadOnlyPixelBuffer>(dynamicSample) else {
                throw ChromaKeyProcessorError.invalidVideoFrame
            }

            let outputPixelBuffer = try Self.makePixelBuffer(width: width, height: height)

            try sourceSample.content.withUnsafeBuffer { sourcePixelBuffer in
                let sourceImage = CIImage(cvPixelBuffer: sourcePixelBuffer)
                filter.setValue(sourceImage, forKey: kCIInputImageKey)

                guard let keyedImage = filter.outputImage else {
                    throw ChromaKeyProcessorError.filterFailed
                }

                context.render(
                    keyedImage.cropped(to: sourceImage.extent),
                    to: outputPixelBuffer,
                    bounds: sourceImage.extent,
                    colorSpace: colorSpace
                )
            }

            let readOnlyOutput = CVReadOnlyPixelBuffer(unsafeBuffer: outputPixelBuffer)
            try await receiver.append(
                readOnlyOutput,
                with: sourceSample.presentationTimeStamp
            )

            let current = min(
                max(sourceSample.presentationTimeStamp.seconds / durationSeconds, 0),
                1
            )

            // UI updates at roughly one-percent increments; frame-by-frame main
            // actor hops make long conversions unnecessarily expensive.
            if current - lastReportedProgress >= 0.01 {
                lastReportedProgress = current
                await progress(current)
            }
        }

        receiver.finish()
    }

    private static func copyAudio(
        provider: AVAssetReaderOutput.Provider<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>,
        receiver: AVAssetWriterInput.SampleBufferReceiver
    ) async throws {
        while let sample = try await provider.next() {
            try Task.checkCancellation()
            try await receiver.append(sample)
        }

        receiver.finish()
    }

    private static func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]

        let result = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )

        guard result == kCVReturnSuccess, let pixelBuffer else {
            throw ChromaKeyProcessorError.pixelBufferCreationFailed(result)
        }

        return pixelBuffer
    }

    private static let cubeDimension = 64

    /// Builds a premultiplied-alpha 3D lookup table. Core Image's color-cube
    /// filter interpolates this table on the GPU for every decoded frame.
    private static func makeChromaKeyCube(settings: ChromaKeySettings) -> Data {
        let dimension = cubeDimension
        let maximumIndex = Float(dimension - 1)
        let keyChroma = normalizedChroma(for: settings.keyColor)
        let threshold = max(settings.threshold, 0)
        let softness = max(settings.softness, 0.0001)
        let spill = min(max(settings.spillSuppression, 0), 1)

        var values = [Float](
            repeating: 0,
            count: dimension * dimension * dimension * 4
        )
        var index = 0

        for blueIndex in 0..<dimension {
            let blue = Float(blueIndex) / maximumIndex

            for greenIndex in 0..<dimension {
                let green = Float(greenIndex) / maximumIndex

                for redIndex in 0..<dimension {
                    let red = Float(redIndex) / maximumIndex
                    var rgb = SIMD3<Float>(red, green, blue)

                    let luminance = simd_dot(
                        rgb,
                        SIMD3<Float>(0.2126, 0.7152, 0.0722)
                    )

                    // Compare normalized chromaticity rather than raw YCbCr.
                    // Raw chroma scales with brightness, so a darker patch of the
                    // same green can look far away from the key color and survive
                    // unchanged. Normalization makes bright and dark green-screen
                    // pixels map to the same key neighborhood.
                    let distanceFromKey = simd_distance(
                        normalizedChroma(for: rgb),
                        keyChroma
                    )

                    let alpha: Float
                    if luminance < 0.02 {
                        // Preserve genuinely black subject detail. Chromaticity is
                        // unstable when all three channels are nearly zero.
                        alpha = 1
                    } else {
                        alpha = smoothstep(
                            edge0: threshold,
                            edge1: threshold + softness,
                            value: distanceFromKey
                        )
                    }

                    // Green-spill suppression is intentionally independent from
                    // alpha so partially transparent edge pixels remain neutral.
                    let greenDominance = max(rgb.y - max(rgb.x, rgb.z), 0)
                    rgb.y = max(
                        0,
                        rgb.y - greenDominance * (1 - alpha) * spill
                    )

                    values[index] = rgb.x * alpha
                    values[index + 1] = rgb.y * alpha
                    values[index + 2] = rgb.z * alpha
                    values[index + 3] = alpha
                    index += 4
                }
            }
        }

        return values.withUnsafeBytes { Data($0) }
    }

    private static func normalizedChroma(for rgb: SIMD3<Float>) -> SIMD2<Float> {
        let total = max(rgb.x + rgb.y + rgb.z, 0.0001)
        return SIMD2<Float>(rgb.x / total, rgb.z / total)
    }

    private static func smoothstep(
        edge0: Float,
        edge1: Float,
        value: Float
    ) -> Float {
        let normalized = min(max((value - edge0) / (edge1 - edge0), 0), 1)
        return normalized * normalized * (3 - 2 * normalized)
    }
}

private enum ChromaKeyProcessorError: LocalizedError {
    case requiresVisionOS26
    case noVideoTrack
    case hevcAlphaUnsupported
    case filterCreationFailed
    case invalidVideoFrame
    case filterFailed
    case pixelBufferCreationFailed(CVReturn)
    case invalidOutput
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .requiresVisionOS26:
            "Transparent-video preparation requires visionOS 26 or later."
        case .noVideoTrack:
            "The selected chroma-key source has no video track."
        case .hevcAlphaUnsupported:
            "This device cannot encode the source as HEVC with alpha."
        case .filterCreationFailed:
            "The built-in Core Image chroma-key filter could not be created."
        case .invalidVideoFrame:
            "A decoded video frame did not contain a readable pixel buffer."
        case .filterFailed:
            "The chroma-key filter failed to create an output frame."
        case .pixelBufferCreationFailed(let code):
            "A transparent output frame could not be allocated (Core Video error \(code))."
        case .invalidOutput:
            "The processed movie did not contain a playable video track. The previous successful version was preserved."
        case .exportFailed:
            "The transparent-video export failed."
        }
    }
}
