import MacSpaceSdk
import MacSpacePlatform
import SwiftUI

/// Modules on/off, then each module's options, background tasks and the permissions it needs.
struct SettingsView: View {
    @ObservedObject var host: ModuleHost
    @ObservedObject var updates: UpdateController

    var body: some View {
        Form {
            GeneralSettingsSection(updates: updates)
            Section("Modules") {
                ForEach(host.handles) { handle in
                    ModuleToggleRow(host: host, handle: handle)
                }
                if host.handles.isEmpty { Text("No modules were found.").foregroundStyle(.secondary) }
            }
            ForEach(host.handles.filter { $0.isEnabled && $0.state != .off }) { handle in
                ModuleSettingsSection(host: host, handle: handle)
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

private struct ModuleSettingsSection: View {
    @ObservedObject var host: ModuleHost
    @ObservedObject var handle: ModuleHandle
    @State private var refresh = 0

    var body: some View {
        let manifest = handle.manifest
        let options = host.settings.optionStore(for: manifest)
        if !manifest.options.isEmpty || !manifest.backgroundTasks.isEmpty || !manifest.permissions.isEmpty {
            Section(manifest.name) {
                ForEach(manifest.options) { option in
                    optionRow(option, options: options)
                }
                ForEach(manifest.backgroundTasks) { task in
                    Toggle(isOn: Binding(get: { options.isBackgroundTaskEnabled(task.id) },
                                         set: { host.setBackgroundTask($0, task.id, module: handle.id); refresh += 1 })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(task.title)
                            if let detail = task.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                ForEach(manifest.permissions, id: \.self) { permission in
                    PermissionRow(permission: permission, status: host.permissions.status(of: permission))
                }
            }
            .id(refresh)
        }
    }

    @ViewBuilder
    private func optionRow(_ option: OptionDefinition, options: any OptionStore) -> some View {
        switch option.kind {
        case .toggle:
            Toggle(isOn: Binding(get: { options.bool(option.id) },
                                 set: { host.settings.setOption(.bool($0), option.id, module: handle.id); refresh += 1 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                    if let detail = option.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
            }
        case let .choice(choices, _):
            Picker(option.title, selection: Binding(get: { options.string(option.id) },
                                                    set: { host.settings.setOption(.string($0), option.id, module: handle.id); refresh += 1 })) {
                ForEach(choices, id: \.id) { Text($0.title).tag($0.id) }
            }
        }
    }
}

private struct PermissionRow: View {
    let permission: Permission
    let status: PermissionStatus
    @State private var helperError: String?
    @State private var helperStatus: PermissionStatus?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                Text(permission.detail).font(.caption).foregroundStyle(.secondary)
                if let helperError { Text(helperError).font(.caption).foregroundStyle(.red) }
            }
            Spacer()
            switch (permission == .privilegedHelper ? helperStatus : nil) ?? status {
            case .granted: Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon)
            case .missing:
                if permission == .fullDiskAccess {
                    Button("Open System Settings") { NSWorkspace.shared.open(LivePermissionChecker.fullDiskAccessSettingsURL) }
                } else if permission == .privilegedHelper {
                    Button(PrivilegedHelperInstaller.status == .requiresApproval ? "Approve in Settings" : "Install helper") {
                        helperError = nil
                        if PrivilegedHelperInstaller.status != .requiresApproval {
                            do { try PrivilegedHelperInstaller.register() } catch { helperError = "Could not install the helper: \(error.localizedDescription)" }
                        }
                        if PrivilegedHelperInstaller.status == .requiresApproval { PrivilegedHelperInstaller.openLoginItemsSettings() }
                        helperStatus = PrivilegedHelperInstaller.permissionStatus()
                    }
                } else {
                    Label("Needed", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
                }
            case .unknown: Text("Unknown").foregroundStyle(.secondary)
            }
        }
    }
}
