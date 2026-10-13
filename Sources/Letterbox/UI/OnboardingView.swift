import SwiftUI

struct OnboardingView: View {
    @Environment(MailStore.self) private var store
    @State private var email = ""
    @State private var password = ""
    @State private var name = NSFullUserName()
    @State private var provider: MailProvider = .custom
    @State private var providerPinned = false
    @State private var account = Account(email: "", displayName: "")
    @State private var showServers = false
    @State private var working = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var canSubmit: Bool {
        email.contains("@") && !password.isEmpty && !working && !account.imapHost.isEmpty && !account.smtpHost.isEmpty
    }

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            MaybeScroll {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    providerGrid
                    form
                    if showServers || provider.id == "custom" { serverForm }
                    if let error { errorView(error) }
                    footer
                }
                .frame(width: 460)
                .padding(.vertical, 56)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            focused = true
            if Snapshot.isActive {
                name = "Alex Rivera"
                email = "alex@example.com"
            }
            account.displayName = name
        }
        .onChange(of: email) { _, new in emailChanged(new) }
        .animation(.snappy(duration: 0.2), value: provider)
        .animation(.snappy(duration: 0.2), value: error)
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            Text("Welcome to Letterbox")
                .font(Theme.serif(30, .regular))
                .foregroundStyle(Theme.text)
            Text("A quiet, fast mail client for any IMAP account — organized by Claude.")
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.text2)
        }
    }

    private var providerGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Provider").microLabel()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                ForEach(MailProvider.all) { p in
                    Button {
                        providerPinned = true
                        select(p)
                    } label: {
                        Text(p.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(provider == p ? Theme.onInk : Theme.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(provider == p ? Theme.ink : Theme.raised))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(provider == p ? .clear : Theme.hairline))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 0) {
                row("Email") {
                    TextField("you@example.com", text: $email)
                        .textContentType(.username)
                        .focused($focused)
                }
                Rectangle().fill(Theme.hairline).frame(height: 1)
                if provider.usesSeparateUsername || showServers {
                    row("Username") {
                        TextField(provider.usesSeparateUsername ? "From Proton Bridge" : "Same as email", text: $account.username)
                    }
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                }
                row(provider.passwordLabel) {
                    SecureField("Required", text: $password).textContentType(.password)
                }
                Rectangle().fill(Theme.hairline).frame(height: 1)
                row("Your name") {
                    TextField("Shown to people you email", text: $name)
                }
            }
            .textFieldStyle(.plain)
            .panel(radius: 12)
            .onSubmit(submit)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(Theme.text3)
                Text(provider.help).font(.system(size: 12)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                if let url = provider.helpURL {
                    Link("Open ↗", destination: url).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
                }
            }
        }
    }

    private var serverForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Servers").microLabel()
            VStack(spacing: 0) {
                serverRow("Incoming (IMAP)", placeholder: "imap.example.com", host: $account.imapHost, port: $account.imapPort, security: $account.imapSecurity)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                serverRow("Outgoing (SMTP)", placeholder: "smtp.example.com", host: $account.smtpHost, port: $account.smtpPort, security: $account.smtpSecurity)
            }
            .panel(radius: 12)
            Toggle("Server saves sent mail automatically", isOn: $account.serverSavesSent)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text2)
                .toggleStyle(.checkbox)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                if provider.id != "custom" {
                    Button(showServers ? "Hide server settings" : "Server settings") { showServers.toggle() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.text2)
                }
                Spacer()
                Button(action: submit) {
                    HStack(spacing: 8) {
                        if working { ProgressView().controlSize(.small) }
                        Text(working ? "Connecting…" : "Sign in")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.onInk)
                    .padding(.horizontal, 22)
                    .frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.ink).opacity(canSubmit ? 1 : 0.35))
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
                .keyboardShortcut(.defaultAction)
            }
            Text("Your password is stored in the macOS Keychain and sent only to your mail server. Claude features run through your own Claude Code CLI.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func errorView(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.urgent)
            Text(message).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12.5))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(radius: 10, fill: Theme.sunken)
    }

    // MARK: Rows

    private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.system(size: 12.5)).foregroundStyle(Theme.text2).frame(width: 118, alignment: .leading)
            content().font(.system(size: 13))
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    private func serverRow(_ label: String, placeholder: String, host: Binding<String>, port: Binding<UInt16>, security: Binding<ConnectionSecurity>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.text3)
            HStack(spacing: 8) {
                TextField(placeholder, text: host).textFieldStyle(.roundedBorder)
                TextField("Port", value: port, format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 64)
                Picker("", selection: security) {
                    ForEach(ConnectionSecurity.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 112)
            }
            .font(.system(size: 12.5))
        }
        .padding(14)
    }

    // MARK: Logic

    private func emailChanged(_ value: String) {
        guard !providerPinned else { return }
        if let p = MailProvider.detect(email: value) {
            select(p)
        } else if value.contains("@") {
            if provider.id != "custom" { select(.custom) }
            let guess = MailProvider.guess(email: value)
            account.imapHost = guess.imap
            account.smtpHost = guess.smtp
        }
    }

    private func select(_ p: MailProvider) {
        provider = p
        let username = account.username
        p.apply(to: &account)
        account.username = username
        if p.id == "custom" && email.contains("@") && account.imapHost.isEmpty {
            let guess = MailProvider.guess(email: email)
            account.imapHost = guess.imap
            account.smtpHost = guess.smtp
        }
    }

    private func submit() {
        guard canSubmit else { return }
        working = true
        error = nil
        var a = account
        a.email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        a.displayName = name.trimmingCharacters(in: .whitespaces)
        a.imapHost = a.imapHost.trimmingCharacters(in: .whitespaces)
        a.smtpHost = a.smtpHost.trimmingCharacters(in: .whitespaces)
        a.username = a.username.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                try await store.signIn(account: a, password: password)
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}
