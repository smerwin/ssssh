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
                    TextField("Hostname or IP", text: $hostname)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                    TextField("Port", text: $port)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    TextField("Username", text: $username)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
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
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle(existingHost == nil ? "New Host" : "Edit Host")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
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
