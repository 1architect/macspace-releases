import MacSpaceSdk
import MacSpacePlatform
import SwiftUI

/// One page, in this order: General, Design, the module switches, the permissions the active modules need (each listed once), then
/// the options and background tasks of each module that has any. Built from the same groups and rows as the module pages, so headers,
/// colors and switches are the same everywhere.
struct SettingsView: View {
    @ObservedObject var host: ModuleHost
    @ObservedObject var updates: UpdateController
    @Environment(\.design) private var design
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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GeneralSettingsSection(updates: updates)
                DesignSettingsSection()
                FormBlock(title: "Modules") {
                    ForEach(Array(host.handles.enumerated()), id: \.element.id) { index, handle in
                        if index > 0 { FormDivider() }
                        ModuleToggleRow(host: host, handle: handle)
                    }
                    if host.handles.isEmpty { FormRow { Text("No modules were found.").foregroundStyle(.secondary) } }
                }
                if !permissions.isEmpty {
                    FormBlock(title: "Permissions") {
                        ForEach(Array(permissions.enumerated()), id: \.element.permission) { index, entry in
                            if index > 0 { FormDivider() }
                            PermissionRow(permission: entry.permission, status: host.permissions.status(of: entry.permission), usedBy: entry.usedBy)
                        }
                    }
                }
                ForEach(moduleOptions) { handle in
                    FormBlock(title: handle.manifest.name) {
                        ForEach(Array(handle.manifest.options.enumerated()), id: \.element.id) { index, option in
                            if index > 0 { FormDivider() }
                            optionRow(handle, option)
                        }
                        ForEach(Array(handle.manifest.backgroundTasks.enumerated()), id: \.element.id) { index, task in
                            if index > 0 || !handle.manifest.options.isEmpty { FormDivider() }
                            let options = host.settings.optionStore(for: handle.manifest)
                            FormToggleRow(title: task.title, help: task.detail,
                                          isOn: Binding(get: { options.isBackgroundTaskEnabled(task.id) },
                                                        set: { host.setBackgroundTask($0, task.id, module: handle.id); tick += 1 }))
                        }
                    }
                }
                if !host.problems.isEmpty {
                    FormBlock(title: "Modules that could not be used") {
                        ForEach(Array(host.problems.enumerated()), id: \.element.id) { index, problem in
                            if index > 0 { FormDivider() }
                            FormRow(help: problem.reason) {
                                Text(problem.bundleName)
                                Spacer()
                                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
            .padding(.top, PageInsets.top)
            .padding(.horizontal, PageInsets.side)
            .padding(.bottom, PageInsets.bottom(hasFooter: false))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .scrollEdgeEffectHidden(true, for: .all)
        .mask(PageFade(hasFooter: false))
        .environment(\.colorScheme, design.colorScheme)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in tick += 1 }
    }

    @ViewBuilder
    private func optionRow(_ handle: ModuleHandle, _ option: OptionDefinition) -> some View {
        let options = host.settings.optionStore(for: handle.manifest)
        switch option.kind {
        case .toggle:
            FormToggleRow(title: option.title, help: option.detail,
                          isOn: Binding(get: { options.bool(option.id) },
                                        set: { host.settings.setOption(.bool($0), option.id, module: handle.id); tick += 1 }))
        case let .choice(choices, _):
            FormRow(help: option.detail) {
                Text(option.title)
                Spacer(minLength: 8)
                Picker(option.title, selection: Binding(get: { options.string(option.id) },
                                                        set: { host.settings.setOption(.string($0), option.id, module: handle.id); tick += 1 })) {
                    ForEach(choices, id: \.id) { Text($0.title).tag($0.id) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}

private struct ModuleToggleRow: View {
    @ObservedObject var host: ModuleHost
    @ObservedObject var handle: ModuleHandle

    var body: some View {
        let incompatible: String? = { if case let .incompatible(reason) = handle.state { return reason } else { return nil } }()
        var status: [(text: String, color: Color)] = []
        if let incompatible { status.append((incompatible, .orange)) }
        if case let .failed(reason) = handle.state { status.append((reason, .red)) }
        return FormToggleRow(title: handle.manifest.name, symbol: handle.manifest.symbol, help: handle.manifest.summary, status: status,
                             isOn: Binding(get: { handle.isEnabled }, set: { value in Task { await host.setEnabled(value, module: handle.id) } }))
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
        FormRow(help: Tooltip.join(permission.detail, usedBy.isEmpty ? nil : "Used by \(usedBy.joined(separator: ", ")).")) {
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                if let helperError { Text(helperError).font(.caption).foregroundStyle(.red) }
            }
            Spacer(minLength: 8)
            switch (permission == .privilegedHelper ? helperStatus : nil) ?? status {
            case .granted:
                Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon)
            case .missing:
                if permission == .fullDiskAccess {
                    ActionPill(title: "Open System Settings") { NSWorkspace.shared.open(LivePermissionChecker.fullDiskAccessSettingsURL) }
                } else if permission == .privilegedHelper {
                    helperButton
                } else {
                    Label("Needed", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
                }
            case .unknown:
                if permission == .privilegedHelper {
                    helperButton.help(PrivilegedHelperInstaller.notFoundReason())
                } else {
                    Text("Unknown").foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Installs the helper (Launch Services first, so a hand-copied app is found), then sends the user to the one switch that approves it.
    private var helperButton: some View {
        ActionPill(title: PrivilegedHelperInstaller.status == .requiresApproval ? "Approve in Settings" : "Install helper") {
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

/// A row button in the pages' style, for Settings actions that are not module actions.
struct ActionPill: View {
    let title: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(PillButtonStyle(prominent: false, compact: true))
            .disabled(!enabled)
    }
}
