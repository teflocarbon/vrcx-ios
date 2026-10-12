import SwiftUI

/// The first thing you see: connect to your relay (recommended), or sign
/// in to VRChat directly
struct SignInView: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 12) {
                        Image("Glyph")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 88, height: 88)
                            .clipShape(.rect(cornerRadius: 20, style: .continuous))
                        Text("Portal")
                            .font(.largeTitle.weight(.bold))
                        Text("Your VRChat friends, where they are, and your invites, on the go.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 40)

                    if let problem = session.problem {
                        Text(problem)
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                    }

                    VStack(spacing: 12) {
                        NavigationLink {
                            RelaySignInView()
                        } label: {
                            ChoiceCard(
                                symbol: "server.rack",
                                title: "Connect to Your Relay",
                                detail: "Recommended. Your relay holds your VRChat session, sends push notifications and keeps history. Your password never reaches this phone.",
                                badge: "Recommended"
                            )
                        }
                        NavigationLink {
                            VRChatSignInView()
                        } label: {
                            ChoiceCard(
                                symbol: "globe",
                                title: "Sign In to VRChat",
                                detail: "No relay needed. Portal talks to VRChat itself while it's open; no push notifications or history from while it was closed."
                            )
                        }
                    }
                    .buttonStyle(.plain)

                    Text("Portal is unofficial, and isn't made or endorsed by VRChat or the VRCX team.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct ChoiceCard: View {
    let symbol: String
    let title: String
    let detail: String
    var badge: String?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.headline)
                    if let badge {
                        Badge(badge, color: .accentColor)
                    }
                }
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 22, interactive: true)
        .contentShape(.rect)
    }
}

/// A relay's address and a login made on its admin page
struct RelaySignInView: View {
    @Environment(SessionStore.self) private var session
    @AppStorage("lastRelayAddress") private var address = ""
    @State private var login = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var capabilities: RelayCapabilities?
    @FocusState private var field: Field?

    enum Field {
        case address, login, password
    }

    var body: some View {
        Form {
            Section {
                TextField("relay.example.ts.net", text: $address)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($field, equals: .address)
                    .submitLabel(.next)
                    .onSubmit { field = .login }
            } header: {
                Text("Address")
            } footer: {
                if let capabilities {
                    Text(capabilitiesText(capabilities))
                } else {
                    Text("Your relay's HTTPS address, such as its tailscale serve name. Keep Tailscale on to reach it away from home.")
                }
            }

            Section {
                TextField("Login", text: $login)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($field, equals: .login)
                    .submitLabel(.next)
                    .onSubmit { field = .password }
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($field, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { Task { await signIn() } }
            } header: {
                Text("Relay Login")
            } footer: {
                Text("Make a login for this phone on your relay's admin page. It isn't your VRChat password.")
            }

            if let error {
                Section {
                    ErrorRow(message: error)
                }
            }

            Section {
                Button {
                    Task { await signIn() }
                } label: {
                    HStack {
                        Text("Connect")
                        Spacer()
                        if busy { ProgressView() }
                    }
                }
                .disabled(busy || address.isEmpty || login.isEmpty || password.isEmpty)
            }
        }
        .navigationTitle("Your Relay")
        .task(id: address) {
            // Ask the relay what it offers once typing settles
            try? await Task.sleep(for: .milliseconds(600))
            guard let origin = Connection.relayOrigin(from: address) else {
                capabilities = nil
                return
            }
            capabilities = await RelayProbe.capabilities(origin)
        }
    }

    private func capabilitiesText(_ capabilities: RelayCapabilities) -> String {
        var parts = ["Found a VRCX relay."]
        if capabilities.features.push { parts.append("It can send push notifications.") }
        if capabilities.features.events { parts.append("It keeps history.") }
        return parts.joined(separator: " ")
    }

    private func signIn() async {
        field = nil
        busy = true
        defer { busy = false }
        do {
            try await session.signIn(relay: address, login: login, password: password)
            password = ""
            error = nil
        } catch {
            self.error = error.userMessage
        }
    }
}

/// VRChat's own sign-in, then its second factor if it asks for one
struct VRChatSignInView: View {
    @Environment(SessionStore.self) private var session
    @State private var username = ""
    @State private var password = ""
    @State private var code = ""
    @State private var method = "totp"
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            if let methods = session.twoFactorMethods {
                twoFactor(methods)
            } else {
                Section {
                    TextField("Username or Email", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .onSubmit { Task { await signIn() } }
                } footer: {
                    Text("Your password is sent to VRChat once and never kept. Portal keeps only the session, in this phone's Keychain.")
                }
                if let error {
                    Section { ErrorRow(message: error) }
                }
                Section {
                    Button {
                        Task { await signIn() }
                    } label: {
                        HStack {
                            Text("Sign In")
                            Spacer()
                            if busy { ProgressView() }
                        }
                    }
                    .disabled(busy || username.isEmpty || password.isEmpty)
                }
            }
        }
        .navigationTitle("VRChat")
        .onDisappear {
            if session.phase == .signedOut { session.cancelTwoFactor() }
        }
    }

    @ViewBuilder
    private func twoFactor(_ methods: [String]) -> some View {
        Section {
            TextField(method == "otp" ? "Recovery Code" : "6-Digit Code", text: $code)
                .textContentType(.oneTimeCode)
                .keyboardType(method == "otp" ? .asciiCapable : .numberPad)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.title3.monospacedDigit())
                .focused($focused)
                .onAppear {
                    focused = true
                    if !methods.contains(method) { method = methods.first ?? "totp" }
                }
                .onChange(of: code) { _, value in
                    if method != "otp", value.filter(\.isNumber).count == 6 { Task { await verify() } }
                }
        } header: {
            Text(prompt)
        } footer: {
            if methods.count > 1 || methods.contains("totp") {
                Picker("Use", selection: $method) {
                    if methods.contains("totp") { Text("Authenticator App").tag("totp") }
                    if methods.contains("emailOtp") { Text("Email Code").tag("emailOtp") }
                    Text("Recovery Code").tag("otp")
                }
                .pickerStyle(.menu)
            }
        }
        if let error {
            Section { ErrorRow(message: error) }
        }
        Section {
            Button {
                Task { await verify() }
            } label: {
                HStack {
                    Text("Verify")
                    Spacer()
                    if busy { ProgressView() }
                }
            }
            .disabled(busy || code.isEmpty)
            Button("Start Again", role: .cancel) {
                session.cancelTwoFactor()
                code = ""
                error = nil
            }
        }
    }

    private var prompt: String {
        switch method {
        case "emailOtp": "Enter the code VRChat emailed you"
        case "otp": "Enter one of your recovery codes"
        default: "Enter the code from your authenticator app"
        }
    }

    private func signIn() async {
        busy = true
        defer { busy = false }
        do {
            try await session.signIn(vrchat: username, password: password)
            password = ""
            error = nil
            if let methods = session.twoFactorMethods {
                method = methods.contains("totp") ? "totp" : methods.first ?? "totp"
            }
        } catch {
            self.error = error.userMessage
        }
    }

    private func verify() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await session.verify(code: code, method: method)
            error = nil
        } catch {
            self.error = error.userMessage
            code = ""
        }
    }
}
