import SwiftUI

struct KeyListView: View {
    @Environment(KeyStore.self) private var keyStore
    @Environment(PurchaseManager.self) private var purchaseManager
    @State private var isPresentingGenerator = false
    @State private var isPresentingPaywall = false
    @State private var keyPendingDeletion: SSHKey?

    var body: some View {
        NavigationStack {
            List {
                if keyStore.keys.isEmpty {
                    ContentUnavailableView {
                        Label("No Keys Yet", systemImage: "key")
                    } description: {
                        Text("Generate a key to get started.")
                    } actions: {
                        Button("Generate Key") { isPresentingGenerator = true }
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
                    Button {
                        if purchaseManager.isUnlocked || keyStore.keys.isEmpty {
                            isPresentingGenerator = true
                        } else {
                            isPresentingPaywall = true
                        }
                    } label: {
                        Label("New Key", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $isPresentingGenerator) {
                GenerateKeyView()
            }
            .sheet(isPresented: $isPresentingPaywall) {
                PaywallView()
            }
            .confirmationDialog(
                "Delete Key",
                isPresented: Binding(
                    get: { keyPendingDeletion != nil },
                    set: { if !$0 { keyPendingDeletion = nil } }
                ),
                titleVisibility: .visible,
                presenting: keyPendingDeletion
            ) { key in
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

#Preview {
    KeyListView()
        .environment(KeyStore())
        .environment(PurchaseManager())
}
