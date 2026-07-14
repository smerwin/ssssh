import SwiftUI
import UniformTypeIdentifiers

struct KeyListView: View {
    @Environment(KeyStore.self) private var keyStore
    @Environment(PurchaseManager.self) private var purchaseManager
    @State private var isPresentingGenerator = false
    @State private var isPresentingImporter = false
    @State private var isPresentingPaywall = false
    @State private var keyPendingDeletion: SSHKey?

    var body: some View {
        NavigationStack {
            List {
                if keyStore.keys.isEmpty {
                    ContentUnavailableView {
                        Label("No Keys Yet", systemImage: "key")
                    } description: {
                        Text("Generate a key to get started, or import an existing Ed25519 key.")
                    } actions: {
                        Button("Generate Key") { isPresentingGenerator = true }
                        Button("Import Key") { isPresentingImporter = true }
                    }
                }
                ForEach(keyStore.keys) { key in
                    NavigationLink(value: key) {
                        VStack(alignment: .leading) {
                            Text(key.label).font(.headline)
                            Text(key.algorithm.displayName)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            keyPendingDeletion = key
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle("Keys")
            .navigationDestination(for: SSHKey.self) { key in
                KeyDetailView(key: key)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            presentIfUnlocked { isPresentingGenerator = true }
                        } label: {
                            Label("Generate Key", systemImage: "plus")
                        }
                        Button {
                            presentIfUnlocked { isPresentingImporter = true }
                        } label: {
                            Label("Import Key", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Label("New Key", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $isPresentingGenerator) {
                GenerateKeyView()
            }
            .sheet(isPresented: $isPresentingImporter) {
                ImportKeyView()
            }
            .sheet(isPresented: $isPresentingPaywall) {
                PaywallView()
            }
            // .alert instead of .confirmationDialog: a confirmationDialog
            // renders as a popover with a tail pointing at its (here,
            // ambiguous) anchor on iPad, and only gets a Cancel button for
            // free if no button you supply has role .cancel. .alert is a
            // plain centered modal on every device -- no tail -- and needs
            // an explicit Cancel button either way, which keeps that
            // behavior obvious rather than incidental.
            .alert(
                "Delete Key",
                isPresented: Binding(
                    get: { keyPendingDeletion != nil },
                    set: { if !$0 { keyPendingDeletion = nil } }
                ),
                presenting: keyPendingDeletion
            ) { key in
                Button("Cancel", role: .cancel) {
                    keyPendingDeletion = nil
                }
                Button("Delete", role: .destructive) {
                    try? keyStore.delete(key)
                    keyPendingDeletion = nil
                }
            } message: { key in
                if key.deployedHostIDs.isEmpty {
                    Text("\"\(key.label)\" will be permanently deleted with no backup. This cannot be undone.")
                } else {
                    Text("\"\(key.label)\" is deployed to \(key.deployedHostIDs.count) host(s) and will be permanently deleted with no backup. This cannot be undone.")
                }
            }
        }
    }

    private func presentIfUnlocked(_ present: () -> Void) {
        if purchaseManager.isUnlocked || keyStore.keys.isEmpty {
            present()
        } else {
            isPresentingPaywall = true
        }
    }
}

private struct GenerateKeyView: View {
    @Environment(KeyStore.self) private var keyStore
    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var algorithm: SSHKeyAlgorithm = .ed25519
    @State private var errorMessage: String?
    @FocusState private var isLabelFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Label") {
                    TextField("e.g. personal", text: $label)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .focused($isLabelFocused)
                        .submitLabel(.done)
                        .onSubmit { generate() }
                }
                Section("Algorithm") {
                    Picker(selection: $algorithm) {
                        ForEach([SSHKeyAlgorithm.ed25519, .ecdsaP256, .ecdsaP384], id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.inline)
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle("New Key")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Generate") { generate() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func generate() {
        guard !label.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            _ = try keyStore.generateKey(label: label, algorithm: algorithm)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// File-picker only, deliberately -- no paste field. A pasted private key
/// sits on the system pasteboard, which any app can read and which syncs
/// to a user's other devices via Universal Clipboard; a picked file's
/// bytes go straight from disk into this view's memory and then into the
/// Keychain, with no intermediate shared state. See CLAUDE.md for why
/// only Ed25519 import is offered.
private struct ImportKeyView: View {
    @Environment(KeyStore.self) private var keyStore
    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var passphrase = ""
    @State private var pickedFileName: String?
    @State private var pickedFileContents: Data?
    @State private var isPresentingFilePicker = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Private Key File") {
                    Button {
                        isPresentingFilePicker = true
                    } label: {
                        HStack {
                            Text(pickedFileName ?? "Choose File")
                                .foregroundStyle(pickedFileName == nil ? .secondary : .primary)
                            Spacer()
                            if pickedFileName != nil {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            }
                        }
                    }
                }
                Section("Label") {
                    TextField("e.g. personal", text: $label)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                }
                Section {
                    SecureField("Only if this key is passphrase-protected", text: $passphrase)
                } header: {
                    Text("Passphrase")
                } footer: {
                    Text("ssssh can only import Ed25519 keys right now -- the format ssh-keygen uses by default.")
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle("Import Key")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { importKey() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(pickedFileContents == nil || label.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .fileImporter(isPresented: $isPresentingFilePicker, allowedContentTypes: [.item]) { result in
                handlePickedFile(result)
            }
        }
    }

    private func handlePickedFile(_ result: Result<URL, Error>) {
        errorMessage = nil
        guard case .success(let url) = result else { return }

        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer { if didStartAccessing { url.stopAccessingSecurityScopedResource() } }

        do {
            pickedFileContents = try Data(contentsOf: url)
            pickedFileName = url.lastPathComponent
            if label.isEmpty {
                label = url.deletingPathExtension().lastPathComponent
            }
        } catch {
            pickedFileContents = nil
            pickedFileName = nil
            errorMessage = "Couldn't read that file."
        }
    }

    private func importKey() {
        guard let pickedFileContents else { return }
        guard !label.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            _ = try keyStore.importKey(label: label, fileContents: pickedFileContents, passphrase: passphrase)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    KeyListView()
        .environment(KeyStore())
        .environment(PurchaseManager())
}
