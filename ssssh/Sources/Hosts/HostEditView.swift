import SwiftUI

/// Add/edit sheet for a host profile. Pass `existingHost` to edit in place;
/// omit it to create a new one.
struct HostEditView: View {
    let existingHost: SSHHost?

    @Environment(HostStore.self) private var hostStore
    @Environment(KeyStore.self) private var keyStore
    @Environment(\.dismiss) private var dismiss

    @State private var nickname = ""
    @State private var hostname = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var keyID: UUID?
    @State private var startupCommand = ""
    @State private var errorMessage: String?

    private enum Field: Hashable {
        case nickname, hostname, port, username, startupCommand
    }
    @FocusState private var focusedField: Field?

    init(existingHost: SSHHost? = nil) {
        self.existingHost = existingHost
        if let existingHost {
            _nickname = State(initialValue: existingHost.nickname)
            _hostname = State(initialValue: existingHost.hostname)
            _port = State(initialValue: String(existingHost.port))
            _username = State(initialValue: existingHost.username)
            _keyID = State(initialValue: existingHost.keyID)
            _startupCommand = State(initialValue: existingHost.startupCommand ?? "")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Host") {
                    TextField("Nickname (e.g. home server)", text: $nickname)
                        .focused($focusedField, equals: .nickname)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .hostname }
                    TextField("Hostname or IP", text: $hostname)
                        .noAutoCapitalization()
                        #if os(iOS)
                        .keyboardType(.URL)
                        #endif
                        .focused($focusedField, equals: .hostname)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .port }
                    TextField("Port", text: $port)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                        .focused($focusedField, equals: .port)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .username }
                    TextField("Username", text: $username)
                        .noAutoCapitalization()
                        .focused($focusedField, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .startupCommand }
                }
                Section("Authentication") {
                    Picker("Key", selection: $keyID) {
                        Text("None").tag(UUID?.none)
                        ForEach(keyStore.keys) { key in
                            Text(key.label).tag(Optional(key.id))
                        }
                    }
                }
                Section("Startup command") {
                    TextField("Optional, e.g. tmux attach || tmux new", text: $startupCommand)
                        .noAutoCapitalization()
                        .focused($focusedField, equals: .startupCommand)
                        .submitLabel(.done)
                        .onSubmit { save() }
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle(existingHost == nil ? "New Host" : "Edit Host")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(nickname.trimmingCharacters(in: .whitespaces).isEmpty || hostname.trimmingCharacters(in: .whitespaces).isEmpty || username.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        guard let portNumber = Int(port), (1...65535).contains(portNumber) else {
            errorMessage = "Port must be a number between 1 and 65535."
            return
        }
        do {
            if var host = existingHost {
                host.nickname = nickname
                host.hostname = hostname
                host.port = portNumber
                host.username = username
                host.keyID = keyID
                host.startupCommand = startupCommand.isEmpty ? nil : startupCommand
                try hostStore.update(host)
            } else {
                let host = SSHHost(
                    nickname: nickname,
                    hostname: hostname,
                    port: portNumber,
                    username: username,
                    keyID: keyID,
                    startupCommand: startupCommand.isEmpty ? nil : startupCommand
                )
                try hostStore.add(host)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    HostEditView()
        .environment(HostStore())
        .environment(KeyStore())
}
