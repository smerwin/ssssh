import SwiftUI

/// Shown the first time a host presents a key we haven't seen before
/// (trust-on-first-use). Presented from the app root so it can interrupt
/// whichever screen triggered the connection.
struct HostKeyConfirmationView: View {
    let pending: PendingHostKeyConfirmation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "key.viewfinder")
                    .font(.system(size: 48))
                    .foregroundStyle(.blue)
                Text("New host: \(pending.host.nickname)")
                    .font(.headline)
                Text("This is the first time connecting to \(pending.host.hostname). Verify the fingerprint out-of-band if you can, then trust it to continue.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text(pending.fingerprint)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding()
                    .background(.quaternary.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding()
            .navigationTitle("Verify Host Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        pending.decide(false)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Trust") {
                        pending.decide(true)
                        dismiss()
                    }
                }
            }
        }
    }
}
