import MacSpaceSdk
import MacSpacePlatform
import SwiftUI

/// One page, in this order: General (with the look, and a row opening the permissions the active modules need), Cleanup (automatic
/// cleanup and its history), Notifications, the module switches, then the options and background tasks of each module that has
/// any. A system grouped form, as the module pages are: it keeps its look whatever the palette and glass settings. Only the rows
/// whose title is not enough have an (i) (`InfoButton`). Sections are built directly in this view: wrapping them in
/// custom views inside a ForEach made them render inside the previous card.
struct SettingsView: View {
    @ObservedObject var host: ModuleHost
    @ObservedObject var updates: UpdateController
    @Environment(\.design) private var design
    /// Bumped to redraw after an option changes or the app becomes active again (permissions may have been granted meanwhile).
    @State private var tick = 0

    private var activeHandles: [ModuleHandle] { host.handles.filter { $0.isEnabled && $0.state != .off } }
    private var moduleOptions: [ModuleHandle] { activeHandles.filter { !$0.manifest.options.isEmpty || !$0.manifest.backgroundTasks.isEmpty } }

    var body: some View {
        let _ = tick
        Form {
            GeneralSettingsSection(host: host, updates: updates)
            CleanupSection(cleaner: host.autoCleaner, host: host)
            NotificationSettingsSection()
            Section("Modules") {
                ForEach(host.handles) { handle in
                    ModuleToggleRow(host: host, handle: handle)
                }
                if host.handles.isEmpty { Text("No modules were found.").foregroundStyle(.secondary) }
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
                    }
                }
            }
            if !host.problems.isEmpty {
                Section("Modules that could not be used") {
                    ForEach(host.problems) { problem in
                        LabeledContent {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(DesignSettings.shared.design.action)
                        } label: {
                            InfoTitle(title: problem.bundleName, info: problem.reason)
                        }
                    }
                }
            }
            PageBottomRoom()
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .modifier(PageScrollArea(hasFooter: false))
        .environment(\.colorScheme, design.colorScheme)
        // Settings is drawn on the slate tile's color.
        .environment(\.pageGround, design.palette(.slate).base)
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
        case let .choice(choices, _):
            Picker(option.title, selection: Binding(get: { options.string(option.id) },
                                                    set: { host.settings.setOption(.string($0), option.id, module: handle.id); tick += 1 })) {
                ForEach(choices, id: \.id) { Text($0.title).tag($0.id) }
            }
        }
    }
}

/// The permissions the active modules need, each listed once with the modules that use it; opened from General.
struct PermissionsPage: View {
    @ObservedObject var host: ModuleHost
    @Environment(\.design) private var design
    @State private var tick = 0

    /// Permissions of the active modules, each once, with the modules that use it.
    static func permissions(_ host: ModuleHost) -> [(permission: Permission, usedBy: [String])] {
        var order: [Permission] = []
        var users: [Permission: [String]] = [:]
        for handle in host.handles where handle.isEnabled && handle.state != .off {
            for permission in handle.manifest.permissions {
                if users[permission] == nil { order.append(permission) }
                users[permission, default: []].append(handle.manifest.name)
            }
        }
        return order.map { ($0, users[$0] ?? []) }
    }

    var body: some View {
        let _ = tick
        let permissions = Self.permissions(host)
        Form {
            Section {
                if permissions.isEmpty { Text("No module needs a permission.").foregroundStyle(.secondary) }
                ForEach(permissions, id: \.permission) { entry in
                    PermissionRow(permission: entry.permission, status: host.permissions.status(of: entry.permission))
                }
            }
            PageBottomRoom()
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .modifier(PageScrollArea(hasFooter: false))
        .environment(\.colorScheme, design.colorScheme)
        // Settings is drawn on the slate tile's color.
        .environment(\.pageGround, design.palette(.slate).base)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            ConfigurationProfiles.shared.refresh()
            tick += 1
        }
        .task {
            await Task.detached { ConfigurationProfiles.shared.refreshNow() }.value
            tick += 1
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
                Text(handle.manifest.name)
                if let incompatible { Text(incompatible).font(.caption).foregroundStyle(DesignSettings.shared.design.action) }
                if case let .failed(reason) = handle.state { Text(reason).font(.caption).foregroundStyle(DesignSettings.shared.design.action) }
            }
        }
        .disabled(incompatible != nil)
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
                InfoTitle(title: permission.title, info: permission.detail)
                if let helperError { Text(helperError).font(.caption).foregroundStyle(DesignSettings.shared.design.action) }
            }
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
                    Label("Needed", systemImage: "exclamationmark.circle.fill").foregroundStyle(DesignSettings.shared.design.action)
                }
            case .unknown:
                if permission == .privilegedHelper {
                    HStack(spacing: 8) {
                        InfoButton(text: PrivilegedHelperInstaller.notFoundReason())
                        helperButton
                    }
                } else {
                    Text("Unknown").foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Installs the helper (Launch Services first, so a hand-copied app is found), then sends the user to the one switch that approves it.
    private var helperButton: some View {
        Button(PrivilegedHelperInstaller.status == .requiresApproval ? String(localized: "Approve in Settings") : String(localized: "Install helper")) {
            helperError = nil
            if PrivilegedHelperInstaller.status != .requiresApproval {
                // Registering reports an error while it waits for the user's approval; that is not a failure.
                do { try PrivilegedHelperInstaller.register() } catch {
                    if PrivilegedHelperInstaller.status != .requiresApproval { helperError = String(localized: "Could not install the helper: \(error.localizedDescription)") }
                }
            }
            if PrivilegedHelperInstaller.status == .requiresApproval { PrivilegedHelperInstaller.openLoginItemsSettings() }
            helperStatus = PrivilegedHelperInstaller.permissionStatus()
        }
    }
}
