import SwiftUI

/// The guided "ssh-copy-id" flow: pick a key, authenticate once with a
/// password, and the app appends the public key to the server's
/// `~/.ssh/authorized_keys`, then reconnects with the new key to confirm.
struct CopyKeyToServerView: View {
    let host: SSHHost

    @Environment(KeyStore.self) private var keyStore
    @Environment(HostStore.self) private var hostStore
    @Environment(HostKeyStore.self) private var hostKeyStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedKeyID: UUID?
    @State private var password = ""
    @State private var isWorking = false
    @State private var result: Result<Void, Error>?

    var body: some View {
        NavigationStack {
            Form {
                Section("Key to deploy") {
                    Picker("Key", selection: $selectedKeyID) {
                        ForEach(keyStore.keys) { key in
                            Text(key.label).tag(Optional(key.id))
                        }
                    }
                }
                Section("Authenticate once with a password") {
                    SecureField("Password for \(host.username)@\(host.hostname)", text: $password)
                }
                Section {
                    Button {
                        Task { await copyKey() }
                    } label: {
                        if isWorking {
                            ProgressView()
                        } else {
                            Text("Copy Key to Server")
                        }
                    }
                    .disabled(selectedKeyID == nil || password.isEmpty || isWorking)
                }
                if case .failure(let error) = result {
                    Text(error.localizedDescription).foregroundStyle(.red)
                }
                if case .success = result {
                    Label("Key deployed and verified.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            .navigationTitle("Copy Key to Server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear {
                if selectedKeyID == nil {
                    selectedKeyID = host.keyID ?? keyStore.keys.first?.id
                }
            }
        }
    }

    private func copyKey() async {
        guard let selectedKeyID, let key = keyStore.keys.first(where: { $0.id == selectedKeyID }) else { return }
        isWorking = true
        defer { isWorking = false }

        do {
            let material = try keyStore.privateKeyMaterial(for: key)
            try await SSHCopyID.copyKey(
                publicKeyOpenSSH: key.publicKeyOpenSSH,
                material: material,
                to: host,
                password: password,
                hostKeyStore: hostKeyStore
            )
            try? keyStore.markDeployed(key, to: host.id)
            if host.keyID == nil {
                var updated = host
                updated.keyID = key.id
                try? hostStore.update(updated)
            }
            password = ""
            result = .success(())
        } catch {
            result = .failure(error)
        }
    }
}

#Preview {
    CopyKeyToServerView(host: SSHHost(nickname: "test", hostname: "example.com", username: "me"))
        .environment(KeyStore())
        .environment(HostStore())
        .environment(HostKeyStore())
}
