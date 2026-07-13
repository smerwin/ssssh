import SwiftUI

struct KeyListView: View {
    @State private var keyStore = KeyStore()
    @State private var isPresentingGenerator = false
    @State private var newKeyLabel = ""

    var body: some View {
        NavigationStack {
            List {
                if keyStore.keys.isEmpty {
                    ContentUnavailableView(
                        "No Keys Yet",
                        systemImage: "key",
                        description: Text("Generate an Ed25519 key to get started.")
                    )
                }
                ForEach(keyStore.keys) { key in
                    VStack(alignment: .leading) {
                        Text(key.label).font(.headline)
                        Text(key.algorithm.displayName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Keys")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isPresentingGenerator = true
                    } label: {
                        Label("New Key", systemImage: "plus")
                    }
                }
            }
            .alert("New Key", isPresented: $isPresentingGenerator) {
                TextField("Label (e.g. personal)", text: $newKeyLabel)
                Button("Generate") {
                    try? keyStore.generateKey(label: newKeyLabel)
                    newKeyLabel = ""
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

#Preview {
    KeyListView()
}
