import AppKit
import MacSpaceSdk
import SwiftUI

/// Runs a module action, asking for confirmation first when the action requires it.
typealias ActionHandler = @MainActor (Action, [String: String]) -> Void

struct ActionButton: View {
    let action: Action
    var compact = false
    let handler: ActionHandler

    var body: some View {
        Button(role: action.role == .destructive ? .destructive : nil) {
            if let confirmation = action.confirmation {
                if ConfirmationAlert.ask(confirmation, destructive: action.role == .destructive) { handler(action, [:]) }
            } else {
                handler(action, [:])
            }
        } label: {
            if let symbol = action.symbol { Label(action.title, systemImage: symbol) } else { Text(action.title) }
        }
        .modifier(ActionButtonLook(role: action.role, compact: compact))
    }
}

/// Asks before an action, in an alert of its own in the middle of the screen. Not a sheet on the window: a sheet dims the window's
/// whole frame, and on this window, clear around its rounded glass, that showed as a grey rectangle with square corners.
@MainActor
enum ConfirmationAlert {
    static func ask(_ confirmation: Confirmation, destructive: Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = confirmation.title
        alert.informativeText = confirmation.message
        alert.addButton(withTitle: confirmation.confirmTitle).hasDestructiveAction = destructive
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
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
