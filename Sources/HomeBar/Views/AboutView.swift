import SwiftUI
import AppKit

struct AboutView: View {
    @Environment(HomeBarStore.self) private var store

    var body: some View {
        VStack(spacing: 12) {
            if let appIcon = NSImage(named: NSImage.applicationIconName) {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 84, height: 84)
            } else {
                Image(systemName: "house.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.tint)
            }

            VStack(spacing: 2) {
                Text("HomeBar")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(versionString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Text("Home Assistant menu bar controller")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
                .padding(.horizontal, 20)

            VStack(alignment: .leading, spacing: 5) {
                detailRow("Status", store.status.label)
                detailRow("Instance", store.config.effectiveInstanceName)
                detailRow("Base URL", store.config.baseURL.isEmpty ? "—" : store.config.baseURL)
                detailRow("Auth", store.config.usesOnePassword ? "1Password reference" : "Direct token file")
                detailRow("Entities", "\(store.entities.count)")
                detailRow("Data", "~/.homebar/")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)

            HStack(spacing: 8) {
                Button("Open Data Folder") { openDataFolder() }
                Button("Copy Support Info") { copySupportInfo() }
                CheckForUpdatesButton(updater: UpdaterService.shared.updater)
                Spacer()
                Button("Done") { closeWindow() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
        }
        .padding(.vertical, 20)
        .frame(width: 380)
    }

    private var versionString: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "Version \(v) (build \(b))"
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    private func openDataFolder() {
        let url = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".homebar")
        NSWorkspace.shared.open(url)
    }

    private func copySupportInfo() {
        var lines: [String] = []
        lines.append("HomeBar \(versionString)")
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("Status: \(store.status.label)")
        lines.append("Instance: \(store.config.effectiveInstanceName)")
        lines.append("Base URL: \(store.config.baseURL)")
        lines.append("Auth: \(store.config.usesOnePassword ? "1Password reference" : "Direct token")")
        lines.append("Entities: \(store.entities.count)")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    private func closeWindow() {
        AppController.shared.closeAbout()
    }
}
