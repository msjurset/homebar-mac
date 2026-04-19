import SwiftUI

struct SettingsView: View {
    @Environment(HomeBarStore.self) private var store

    @State private var baseURL: String = ""
    @State private var input: String = ""
    @State private var instanceName: String = ""
    @State private var testMessage: String?
    @State private var testIsError: Bool = false
    @State private var isTesting: Bool = false
    @State private var isSaving: Bool = false
    @State private var saveError: String?

    var body: some View {
        Form {
            Section("Home Assistant") {
                TextField("Base URL", text: $baseURL, prompt: Text("http://ha:8123"))
                    .textContentType(.URL)
                TextField("Instance Name", text: $instanceName, prompt: Text(ProcessInfo.processInfo.hostName))
                Text("Used to route `homebar_speak` events when multiple Macs run HomeBar. Set `event_data.target` in your HA automation to this name to aim an announcement at this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if inputIsReference {
                    TextField("Token", text: $input, prompt: tokenPrompt)
                } else {
                    SecureField("Token", text: $input, prompt: tokenPrompt)
                }

                Text(helpText)
                    .font(.caption)
                    .foregroundStyle(helpColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                HStack {
                    Button("Test Connection") { Task { await runTest() } }
                        .disabled(isTesting || isSaving || !canTest)
                    if isTesting || isSaving { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Save") { Task { await save() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isSaving || !canTest)
                }
                if let msg = testMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(testIsError ? Color.red : Color.green)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let err = saveError {
                    Text("Save failed: \(err)")
                        .font(.caption)
                        .foregroundStyle(Color.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { load() }
    }

    private var sanitizedInput: String {
        input.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r\"'"))
    }

    private var inputIsReference: Bool {
        sanitizedInput.hasPrefix("op://")
    }

    private var tokenPrompt: Text {
        Text("long-lived token or op://vault/item/field")
    }

    private var canTest: Bool {
        !baseURL.isEmpty && !sanitizedInput.isEmpty
    }

    private var helpText: String {
        if inputIsReference {
            return OnePassword.isInstalled()
                ? "1Password reference detected. Resolved via `op read` on every connect — triggers Touch ID if 1Password CLI integration is enabled."
                : "1Password reference detected, but the op CLI isn't installed. Run `brew install 1password-cli` and enable \u{201C}Connect with 1Password CLI\u{201D} in 1Password settings."
        } else {
            return "Long-lived token is stored at ~/.homebar/token (0600). Or paste a 1Password reference like op://Private/HomeAssistant/credential to resolve at runtime."
        }
    }

    private var helpColor: Color {
        if inputIsReference && !OnePassword.isInstalled() { return .orange }
        return .secondary
    }

    private func load() {
        baseURL = store.config.baseURL
        instanceName = store.config.instanceName ?? ""
        if let ref = store.config.tokenRef, !ref.isEmpty {
            input = ref
        } else {
            input = Keychain.getToken() ?? ""
        }
    }

    private func runTest() async {
        isTesting = true
        testMessage = nil
        defer { isTesting = false }
        let result = await store.testConnection(baseURL: baseURL, tokenOrRef: sanitizedInput)
        switch result {
        case .success(let count):
            testMessage = "Connected. \(count) entities visible."
            testIsError = false
        case .failure(let err):
            testMessage = err.localizedDescription
            testIsError = true
        }
    }

    private func save() async {
        isSaving = true
        saveError = nil
        defer { isSaving = false }

        let trimmedInstance = instanceName.trimmingCharacters(in: .whitespacesAndNewlines)
        var newConfig = HAConfig(
            baseURL: baseURL,
            watchEntities: store.config.watchEntities,
            tokenRef: nil,
            instanceName: trimmedInstance.isEmpty ? nil : trimmedInstance
        )

        if inputIsReference {
            newConfig.tokenRef = sanitizedInput
            // Clear any stale direct token so the op path is unambiguous.
            Keychain.deleteToken()
        } else {
            store.saveToken(sanitizedInput)
        }

        await store.saveConfig(newConfig)
        await store.connect()

        switch store.status {
        case .connected:
            AppController.shared.closeSettings()
        case .failed(let msg):
            saveError = msg
        case .connecting, .disconnected:
            saveError = "Unexpected state after save: \(store.status.label)"
        }
    }
}
