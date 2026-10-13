import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            AccountSettings()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
            ClaudeSettings()
                .tabItem { Label("Claude", systemImage: "sparkle") }
            AliasSettings()
                .tabItem { Label("Addresses", systemImage: "at") }
            ReadingSettings()
                .tabItem { Label("Reading & Writing", systemImage: "text.alignleft") }
        }
        .frame(width: 560, height: 460)
    }
}

private struct AccountSettings: View {
    @Environment(MailStore.self) private var store
    @State private var name = ""
    @State private var confirmSignOut = false

    var body: some View {
        Form {
            if let account = store.account {
                Section {
                    LabeledContent("Email", value: account.email)
                    TextField("Display name", text: $name)
                        .onSubmit { store.updateDisplayName(name) }
                        .onChange(of: name) { _, v in store.updateDisplayName(v) }
                }
                Section("Servers") {
                    LabeledContent("Incoming", value: "\(account.imapHost):\(account.imapPort) · \(account.imapSecurity.rawValue)")
                    LabeledContent("Outgoing", value: "\(account.smtpHost):\(account.smtpPort) · \(account.smtpSecurity.rawValue)")
                }
                Section {
                    Button("Sign Out…", role: .destructive) { confirmSignOut = true }
                }
            } else {
                Text("Not signed in.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { name = store.account?.displayName ?? "" }
        .confirmationDialog("Sign out of Letterbox?", isPresented: $confirmSignOut) {
            Button("Sign Out", role: .destructive) { store.signOut() }
        } message: {
            Text("Your password and downloaded mail will be removed from this Mac. Nothing on the server is changed.")
        }
    }
}

private struct AliasSettings: View {
    @Environment(MailStore.self) private var store
    @State private var newAlias = ""

    var body: some View {
        Form {
            Section {
                ForEach(store.addresses) { a in
                    HStack {
                        Image(systemName: a.isPrimary ? "person.crop.circle" : "at").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.email)
                            Text(a.isPrimary ? "Primary" : (a.isManual ? "Added by you" : "Detected from your mail"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !a.isPrimary {
                            Button("Hide") { store.setAlias(a.email, hidden: true) }
                        }
                    }
                }
            } header: {
                Text("Your addresses")
            } footer: {
                Text("Replies are sent from the address a message was delivered to. Choose any of these in the From menu when writing.")
            }
            if !store.hiddenAliases.isEmpty {
                Section("Hidden") {
                    ForEach(store.hiddenAliases) { a in
                        HStack {
                            Text(a.email).foregroundStyle(.secondary)
                            Spacer()
                            Button("Show") { store.setAlias(a.email, hidden: false) }
                        }
                    }
                }
            }
            Section("Add an alias") {
                HStack {
                    TextField("alias@example.com", text: $newAlias)
                        .onSubmit(add)
                    Button("Add", action: add).disabled(!newAlias.contains("@"))
                }
            }
        }
        .formStyle(.grouped)
    }

    private func add() {
        store.addAlias(newAlias)
        newAlias = ""
    }
}

private struct ReadingSettings: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Reading") {
                Toggle("Block remote images until I load them", isOn: $store.blockRemoteContent)
            }
            Section("Sending") {
                Toggle("Save a copy of sent messages to Sent", isOn: $store.saveToSent)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Signature")
                    TextEditor(text: $store.signature)
                        .font(.system(size: 13))
                        .frame(height: 80)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.background))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                }
            }
        }
        .formStyle(.grouped)
    }
}


private struct ClaudeSettings: View {
    @Environment(MailStore.self) private var store
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Toggle("Use Claude to triage, summarize and draft", isOn: $store.aiEnabled)
                Picker("Model", selection: $store.aiModel) {
                    Text("Sonnet — balanced (recommended)").tag("sonnet")
                    Text("Opus — most capable").tag("opus")
                    Text("Haiku — fastest").tag("haiku")
                }
                .disabled(!store.aiEnabled)
            } footer: {
                Text("Letterbox runs your local Claude Code CLI with all tools disabled, so Claude can only read the text Letterbox sends it. Message content is processed under your Claude account.")
            }
            Section("Claude Code CLI") {
                HStack {
                    TextField("Path to claude", text: $store.claudePath)
                    Button("Detect") {
                        store.claudePath = ""
                        store.setupAI()
                    }
                }
                LabeledContent("Status") {
                    switch store.aiStatus {
                    case .ready: Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .missing: Label("Not found", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                    case .off: Text("Off").foregroundStyle(.secondary)
                    case .working(let s): Text(s).foregroundStyle(.secondary)
                    case .failed(let s): Text(s).foregroundStyle(.red).lineLimit(3)
                    case .unknown: Text("Checking…").foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button(testing ? "Testing…" : "Test Connection") { test() }.disabled(testing || !store.aiReady)
                    Button("Re-analyze Inbox") { store.scheduleTriage(force: true) }.disabled(!store.aiReady)
                    Spacer()
                    if let testResult { Text(testResult).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func test() {
        guard let claude = store.claude else { return }
        testing = true
        testResult = nil
        Task {
            var text = ""
            do {
                for try await chunk in claude.stream(prompt: "Reply with exactly: Letterbox is connected.", system: "You are a connectivity check.") { text += chunk }
                testResult = text.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                testResult = error.localizedDescription
            }
            testing = false
        }
    }
}
