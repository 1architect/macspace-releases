import MacSpaceSdk
import SwiftUI

/// The app's colors for the tones modules ask for.
enum Palette {
    static let series: [Color] = [.blue, .orange, .purple, .teal, .pink, .indigo, .mint, .brown]

    static func color(_ tone: Tone) -> Color {
        switch tone {
        case .neutral: return .secondary
        case .accent: return .accentColor
        case .positive: return .green
        case .caution: return .orange
        case .critical: return .red
        case let .series(index): return series[((index % series.count) + series.count) % series.count]
        }
    }

    static func color(_ severity: Banner.Severity) -> Color {
        switch severity {
        case .info: return .blue
        case .success: return .green
        case .warning: return .orange
        case .critical: return .red
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
