import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var settings: Settings
    let permissions: Permissions
    let loginItem: LoginItem

    var body: some View {
        Form {
            if !permissions.isTrusted {
                Section {
                    Label("Quit on Close needs Accessibility access to see when windows close.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Open Accessibility Settings…") { permissions.openSystemSettings() }
                }
            }

            Section {
                Toggle("Quit apps when their last window closes", isOn: $settings.isEnabled)
                Picker("Apply to", selection: $settings.mode) {
                    Text("All apps except the list below").tag(QuitMode.allExcept)
                    Text("Only the apps in the list below").tag(QuitMode.onlyListed)
                }
                Stepper(value: $settings.closeDelay, in: 1...30) {
                    Text("Wait \(settings.closeDelay) second\(settings.closeDelay == 1 ? "" : "s") before quitting")
                }
            }

            Section(settings.mode == .allExcept ? "Never quit" : "Quit only") {
                if settings.apps.isEmpty {
                    Text("No apps added.").foregroundStyle(.secondary)
                }
                ForEach(settings.apps, id: \.self) { bundleID in
                    AppRow(bundleID: bundleID) { settings.remove(bundleID) }
                }
                Button("Add App…", action: addApp)
            }

            Section {
                Toggle("Launch at login", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }))
                if loginItem.status == .requiresApproval {
                    Text("Approve it in System Settings → General → Login Items.").font(.caption).foregroundStyle(.secondary)
                }
                if let error = loginItem.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Toggle("Show menu bar icon", isOn: $settings.showMenuBarIcon)
                if !settings.showMenuBarIcon {
                    Text("Open the app again to get back to these settings.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose Apps"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let bundleID = Bundle(url: url)?.bundleIdentifier {
                settings.add(bundleID)
            }
        }
    }

}

private struct AppRow: View {
    let bundleID: String
    let onRemove: () -> Void

    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        HStack {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 20, height: 20)
            }
            VStack(alignment: .leading) {
                Text(url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID)
                if url == nil {
                    Text("Not installed").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("Remove")
        }
    }
}
