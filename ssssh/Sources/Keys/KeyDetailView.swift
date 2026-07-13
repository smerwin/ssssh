import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins

struct KeyDetailView: View {
    let key: SSHKey
    @Environment(KeyStore.self) private var keyStore
    @State private var didCopy = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let qrImage = Self.qrCode(for: key.publicKeyOpenSSH) {
                    Image(uiImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 240)
                        .padding()
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Text(key.publicKeyOpenSSH)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding()
                    .background(.quaternary.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal)

                HStack(spacing: 16) {
                    Button {
                        UIPasteboard.general.string = key.publicKeyOpenSSH
                        didCopy = true
                    } label: {
                        Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.bordered)

                    ShareLink(item: key.publicKeyOpenSSH) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                }

                if !key.deployedHostIDs.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Deployed to \(key.deployedHostIDs.count) host(s)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(key.label)
        .navigationBarTitleDisplayMode(.inline)
    }

    private static func qrCode(for string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else { return nil }
        let transform = CGAffineTransform(scaleX: 8, y: 8)
        let scaled = outputImage.transformed(by: transform)
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

#Preview {
    NavigationStack {
        KeyDetailView(key: SSHKey(
            id: UUID(),
            label: "personal",
            algorithm: .ed25519,
            createdAt: .now,
            publicKeyOpenSSH: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILfakefakefakefakefakefakefakefakefakefake personal",
            deployedHostIDs: []
        ))
        .environment(KeyStore())
    }
}
