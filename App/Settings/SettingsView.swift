import MacSpaceSdk
import MacSpacePlatform
import SwiftUI

/// One page, in this order: General, Design, the module switches, the permissions the active modules need (each listed once), then
/// the options and background tasks of each module that has any. A system grouped form, as the module pages are: it keeps its look
/// whatever the palette and glass settings. Descriptions are tooltips. Sections are built directly in this view: wrapping them in
/// custom views inside a ForEach made them render inside the previous card.
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
        Form {
            GeneralSettingsSection(updates: updates)
            AutoCleanSection(cleaner: host.autoCleaner, host: host)
            CleanupHistorySection()
            DesignSettingsSection()
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
                        Toggle(task.title, isOn: Binding(get: { options.isBackgroundTaskEnabled(task.id) },
                                                         set: { host.setBackgroundTask($0, task.id, module: handle.id); tick += 1 }))
                            .help(task.detail ?? "")
                    }
                }
            }
            if !host.problems.isEmpty {
                Section("Modules that could not be used") {
                    ForEach(host.problems) { problem in
                        LabeledContent(problem.bundleName) { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
                            .help(problem.reason)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .modifier(PageScrollArea(hasFooter: false))
        .environment(\.colorScheme, design.colorScheme)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // A profile approved in System Settings meanwhile shows at once.
            ConfigurationProfiles.shared.refresh()
            tick += 1
        }
        // The profile check reads in the background; the page is redrawn once it has an answer.
        .task {
            await Task.detached { ConfigurationProfiles.shared.refreshNow() }.value
            tick += 1
        }
    }

    @ViewBuilder
    private func optionRow(_ handle: ModuleHandle, _ option: OptionDefinition) -> some View {
        let options = host.settings.optionStore(for: handle.manifest)
        switch option.kind {
        case .toggle:
            Toggle(option.title, isOn: Binding(get: { options.bool(option.id) },
                                               set: { host.settings.setOption(.bool($0), option.id, module: handle.id); tick += 1 }))
                .help(option.detail ?? "")
        case let .choice(choices, _):
            Picker(option.title, selection: Binding(get: { options.string(option.id) },
                                                    set: { host.settings.setOption(.string($0), option.id, module: handle.id); tick += 1 })) {
                ForEach(choices, id: \.id) { Text($0.title).tag($0.id) }
            }
            .help(option.detail ?? "")
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
                if let incompatible { Text(incompatible).font(.caption).foregroundStyle(.orange) }
                if case let .failed(reason) = handle.state { Text(reason).font(.caption).foregroundStyle(.red) }
            }
        }
        .help(handle.manifest.summary)
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
                if let helperError { Text(helperError).font(.caption).foregroundStyle(.red) }
            }
            .help(Tooltip.join(permission.detail, usedBy.isEmpty ? nil : "Used by \(usedBy.joined(separator: ", ")).") ?? "")
            Spacer()
            switch (permission == .privilegedHelper ? helperStatus : nil) ?? status {
            case .granted: Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon)
            case .missing:
                if permission == .fullDiskAccess {
                    Button("Open System Settings") { NSWorkspace.shared.open(LivePermissionChecker.fullDiskAccessSettingsURL) }
                } else if permission == .privilegedHelper {
                    helperButton
                } else if permission == .configurationProfile {
                    // None installed: nothing is wrong until a policy is switched off, which opens the profile to approve.
                    Text("Not installed").foregroundStyle(.secondary)
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
