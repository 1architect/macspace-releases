import MacSpaceSdk
import SwiftUI

/// Runs a module action, asking for confirmation first when the action requires it.
typealias ActionHandler = @MainActor (Action, [String: String]) -> Void

struct ActionButton: View {
    let action: Action
    var compact = false
    let handler: ActionHandler
    @State private var confirming = false

    var body: some View {
        Button(role: action.role == .destructive ? .destructive : nil) {
            if action.confirmation != nil { confirming = true } else { handler(action, [:]) }
        } label: {
            if let symbol = action.symbol { Label(action.title, systemImage: symbol) } else { Text(action.title) }
        }
        .modifier(ActionButtonLook(role: action.role, compact: compact))
        .confirmationDialog(action.confirmation?.title ?? "", isPresented: $confirming, titleVisibility: .visible) {
            if let confirmation = action.confirmation {
                Button(confirmation.confirmTitle, role: action.role == .destructive ? .destructive : nil) { handler(action, [:]) }
                Button("Cancel", role: .cancel) {}
            }
        } message: {
            Text(action.confirmation?.message ?? "")
        }
    }
}

/// Buttons in rows are the system's, as in Settings; the page's main action is the pill.
private struct ActionButtonLook: ViewModifier {
    let role: ActionRole
    let compact: Bool

    func body(content: Content) -> some View {
        if compact {
            content.buttonStyle(.bordered).controlSize(.small)
        } else {
            content.buttonStyle(PillButtonStyle(prominent: role == .prominent, destructive: role == .destructive))
        }
    }
}
