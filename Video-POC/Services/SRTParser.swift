//
//  SRTParser.swift
//  Video-POC
//

import Foundation

enum SRTParser {
    static func parse(url: URL) throws -> [SubtitleCue] {
        let raw = try String(contentsOf: url, encoding: .utf8)
        return parse(raw)
    }

    static func parse(_ source: String) -> [SubtitleCue] {
        let normalized = source
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let blocks = normalized.components(separatedBy: "\n\n")
        var cues: [SubtitleCue] = []
        cues.reserveCapacity(blocks.count)

        for block in blocks {
            let lines = block
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)

            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else {
                continue
            }

            let timingParts = lines[timingIndex]
                .components(separatedBy: "-->")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

            guard timingParts.count == 2,
                  let start = parseTimestamp(timingParts[0]),
                  let end = parseTimestamp(timingParts[1]),
                  end > start else {
                continue
            }

            let text = lines
                .dropFirst(timingIndex + 1)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !text.isEmpty else { continue }
            cues.append(SubtitleCue(startTime: start, endTime: end, text: text))
        }

        return cues.sorted { $0.startTime < $1.startTime }
    }

    private static func parseTimestamp(_ source: String) -> TimeInterval? {
        let timestamp = source
            .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? source

        let components = timestamp
            .replacingOccurrences(of: ",", with: ".")
            .split(separator: ":")

        guard components.count == 3,
              let hours = Double(components[0]),
              let minutes = Double(components[1]),
              let seconds = Double(components[2]) else {
            return nil
        }

        return hours * 3600 + minutes * 60 + seconds
    }
}
