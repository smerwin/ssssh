import SwiftUI

struct KeyListView: View {
    @Environment(KeyStore.self) private var keyStore
    @State private var isPresentingGenerator = false

    var body: some View {
        NavigationStack {
            List {
                if keyStore.keys.isEmpty {
                    ContentUnavailableView(
                        "No Keys Yet",
                        systemImage: "key",
                        description: Text("Generate a key to get started.")
                    )
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
                }
                .onDelete { offsets in
                    for index in offsets {
                        try? keyStore.delete(keyStore.keys[index])
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
                        isPresentingGenerator = true
                    } label: {
                        Label("New Key", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $isPresentingGenerator) {
                GenerateKeyView()
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

    var body: some View {
        NavigationStack {
            Form {
                Section("Label") {
                    TextField("e.g. personal", text: $label)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
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
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Generate") {
                        do {
                            _ = try keyStore.generateKey(label: label, algorithm: algorithm)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

#Preview {
    KeyListView()
        .environment(KeyStore())
}
