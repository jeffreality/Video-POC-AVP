//
//  SubtitleModels.swift
//  Video-POC
//

import Foundation

struct SubtitleCue: Sendable, Equatable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String

    func contains(_ time: TimeInterval) -> Bool {
        time >= startTime && time < endTime
    }
}

enum SubtitleLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case arabic = "ar"
    case german = "de"
    case french = "fr"
    case japanese = "ja"
    case korean = "ko"
    case chinese = "zh"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .english: "English"
        case .arabic: "العربية"
        case .german: "Deutsch"
        case .french: "Français"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .chinese: "中文"
        }
    }

    var nativeShortName: String {
        switch self {
        case .english: "EN"
        case .arabic: "AR"
        case .german: "DE"
        case .french: "FR"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .chinese: "中文"
        }
    }

    var isRightToLeft: Bool {
        self == .arabic
    }
}
