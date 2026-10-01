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
        .modifier(ProminenceModifier(role: action.role))
        .controlSize(compact ? .small : .regular)
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

private struct ProminenceModifier: ViewModifier {
    let role: ActionRole

    func body(content: Content) -> some View {
        if role == .prominent { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) }
    }
}
