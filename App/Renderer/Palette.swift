import MacSpaceSdk
import SwiftUI

/// The app's colors for the tones modules ask for. Pages are drawn on deep colors, so these are light ones that stay apart on them;
/// caution is the action color.
enum Palette {
    static let series: [Color] = [
        Color(red: 1.0, green: 0.86, blue: 0.35),
        Color(red: 0.55, green: 0.93, blue: 1.0),
        .white,
        Color(red: 1.0, green: 0.68, blue: 0.86),
        Color(red: 0.62, green: 1.0, blue: 0.78),
        Color(red: 1.0, green: 0.72, blue: 0.55),
        Color(red: 0.80, green: 0.76, blue: 1.0),
        Color(white: 0.75),
    ]

    static func color(_ tone: Tone) -> Color {
        switch tone {
        case .neutral: return .secondary
        case .accent: return Color(red: 0.25, green: 0.55, blue: 1.0)
        case .positive: return Color(red: 0.15, green: 0.75, blue: 0.45)
        case .caution: return Theme.action
        case .critical: return Color(red: 1.0, green: 0.3, blue: 0.35)
        case let .series(index): return series[((index % series.count) + series.count) % series.count]
        }
    }

    static func color(_ severity: Banner.Severity) -> Color {
        switch severity {
        case .info: return .white
        case .success: return Color(red: 0.6, green: 1.0, blue: 0.75)
        case .warning: return Color(red: 1.0, green: 0.85, blue: 0.35)
        case .critical: return Color(red: 1.0, green: 0.6, blue: 0.6)
        }
    }

    static func symbol(_ severity: Banner.Severity) -> String {
        switch severity {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        }
    }
}
