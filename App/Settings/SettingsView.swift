import MacSpaceSdk
import MacSpacePlatform
import SwiftUI

/// One page, in this order: General, the module switches, the permissions the active modules need (each listed once), then the
/// options and background tasks of each module that has any. Sections are built directly in this view: wrapping them in custom
/// views inside a ForEach made them render inside the previous card.
struct SettingsView: View {
    @ObservedObject var host: ModuleHost
    @ObservedObject var updates: UpdateController
    /// Bumped to redraw after an option changes or the app becomes active again (permissions may have been granted meanwhile).
    @State private var tick = 0

    private var activeHandles: [ModuleHandle] { host.handles.filter { $0.isEnabled && $0.state != .off } }
    private var moduleOptions: [ModuleHandle] { activeHandles.filter { !$0.manifest.options.isEmpty || !$0.manifest.backgroundTasks.isEmpty } }

    /// Permissions of the active modules, each once, with the modules that use it.
    private var permissions: [(permission: Permission, usedBy: [String])] {
        var order: [Permission] = []
        var users: [Permission: [String]] = [:]
        for handle in activeHandles {
            for permission in handle.manifest.permissions {
                if users[permission] == nil { order.append(permission) }
                users[permission, default: []].append(handle.manifest.name)
            }
        }
        return order.map { ($0, users[$0] ?? []) }
    }

    var body: some View {
        let _ = tick
        Form {
            GeneralSettingsSection(updates: updates)
            Section("Modules") {
                ForEach(host.handles) { handle in
                    ModuleToggleRow(host: host, handle: handle)
                }
                if host.handles.isEmpty { Text("No modules were found.").foregroundStyle(.secondary) }
            }
            if !permissions.isEmpty {
                Section("Permissions") {
                    ForEach(permissions, id: \.permission) { entry in
                        PermissionRow(permission: entry.permission, status: host.permissions.status(of: entry.permission), usedBy: entry.usedBy)
                    }
                }
            }
            ForEach(moduleOptions) { handle in
                Section(handle.manifest.name) {
                    ForEach(handle.manifest.options) { option in
                        optionRow(handle, option)
                    }
                    ForEach(handle.manifest.backgroundTasks) { task in
                        let options = host.settings.optionStore(for: handle.manifest)
                        Toggle(isOn: Binding(get: { options.isBackgroundTaskEnabled(task.id) },
                                             set: { host.setBackgroundTask($0, task.id, module: handle.id); tick += 1 })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.title)
                                if let detail = task.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
            if !host.problems.isEmpty {
                Section("Modules that could not be used") {
                    ForEach(host.problems) { problem in
                        VStack(alignment: .leading) {
                            Text(problem.bundleName)
                            Text(problem.reason).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in tick += 1 }
    }

    @ViewBuilder
    private func optionRow(_ handle: ModuleHandle, _ option: OptionDefinition) -> some View {
        let options = host.settings.optionStore(for: handle.manifest)
        switch option.kind {
        case .toggle:
            Toggle(isOn: Binding(get: { options.bool(option.id) },
                                 set: { host.settings.setOption(.bool($0), option.id, module: handle.id); tick += 1 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                    if let detail = option.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
            }
        case let .choice(choices, _):
            Picker(option.title, selection: Binding(get: { options.string(option.id) },
                                                    set: { host.settings.setOption(.string($0), option.id, module: handle.id); tick += 1 })) {
                ForEach(choices, id: \.id) { Text($0.title).tag($0.id) }
            }
        }
    }
}

private struct ModuleToggleRow: View {
    @ObservedObject var host: ModuleHost
    @ObservedObject var handle: ModuleHandle

    var body: some View {
        let incompatible: String? = { if case let .incompatible(reason) = handle.state { return reason } else { return nil } }()
        Toggle(isOn: Binding(get: { handle.isEnabled }, set: { value in Task { await host.setEnabled(value, module: handle.id) } })) {
            VStack(alignment: .leading, spacing: 2) {
                Label(handle.manifest.name, systemImage: handle.manifest.symbol)
                Text(incompatible ?? handle.manifest.summary).font(.caption).foregroundStyle(incompatible == nil ? Color.secondary : Color.orange)
                if case let .failed(reason) = handle.state { Text(reason).font(.caption).foregroundStyle(.red) }
            }
        }
        .disabled(incompatible != nil)
    }
}

private struct PermissionRow: View {
    let permission: Permission
    let status: PermissionStatus
    var usedBy: [String] = []
    @State private var helperError: String?
    @State private var helperStatus: PermissionStatus?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                Text(permission.detail).font(.caption).foregroundStyle(.secondary)
                if !usedBy.isEmpty { Text("Used by \(usedBy.joined(separator: ", "))").font(.caption2).foregroundStyle(.tertiary) }
                if let helperError { Text(helperError).font(.caption).foregroundStyle(.red) }
            }
            Spacer()
            switch (permission == .privilegedHelper ? helperStatus : nil) ?? status {
            case .granted: Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon)
            case .missing:
                if permission == .fullDiskAccess {
                    Button("Open System Settings") { NSWorkspace.shared.open(LivePermissionChecker.fullDiskAccessSettingsURL) }
                } else if permission == .privilegedHelper {
                    helperButton
                } else {
                    Label("Needed", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
                }
            case .unknown:
                if permission == .privilegedHelper {
                    VStack(alignment: .trailing, spacing: 6) {
                        helperButton
                        Text(PrivilegedHelperInstaller.notFoundReason()).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: 360, alignment: .leading).textSelection(.enabled)
                    }
                } else {
                    Text("Unknown").foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Installs the helper (Launch Services first, so a hand-copied app is found), then sends the user to the one switch that approves it.
    private var helperButton: some View {
        Button(PrivilegedHelperInstaller.status == .requiresApproval ? "Approve in Settings" : "Install helper") {
            helperError = nil
            if PrivilegedHelperInstaller.status != .requiresApproval {
                // Registering reports an error while it waits for the user's approval; that is not a failure.
                do { try PrivilegedHelperInstaller.register() } catch {
                    if PrivilegedHelperInstaller.status != .requiresApproval { helperError = "Could not install the helper: \(error.localizedDescription)" }
                }
            }
            if PrivilegedHelperInstaller.status == .requiresApproval { PrivilegedHelperInstaller.openLoginItemsSettings() }
            helperStatus = PrivilegedHelperInstaller.permissionStatus()
        }
    }
}
