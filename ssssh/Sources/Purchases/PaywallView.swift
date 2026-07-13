import SwiftUI
import StoreKit

/// Presented when the free tier's one-host/one-key limit is hit. Offers
/// either a one-time lifetime unlock or a monthly subscription -- both
/// grant the same `PurchaseManager.isUnlocked` entitlement.
struct PaywallView: View {
    @Environment(PurchaseManager.self) private var purchaseManager
    @Environment(\.dismiss) private var dismiss

    @State private var purchasingProductID: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Image(systemName: "infinity.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.tint)
                    Text("Unlock Unlimited Hosts & Keys")
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    Text("The free version of ssssh is limited to one host and one key.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if let errorMessage = purchaseManager.purchaseError {
                    Text(errorMessage).foregroundStyle(.red).font(.footnote)
                }

                VStack(spacing: 12) {
                    purchaseButton(
                        for: purchaseManager.lifetimeProduct,
                        fallbackTitle: "Unlock Forever",
                        fallbackPrice: "$9.99",
                        subtitle: "One-time purchase"
                    )
                    purchaseButton(
                        for: purchaseManager.monthlyProduct,
                        fallbackTitle: "Support Development",
                        fallbackPrice: "$0.99/mo",
                        subtitle: "Monthly subscription"
                    )
                }

                Button("Restore Purchases") {
                    Task {
                        await purchaseManager.restorePurchases()
                        if purchaseManager.isUnlocked { dismiss() }
                    }
                }
                .font(.footnote)

                Spacer()
            }
            .padding()
            .navigationTitle("Unlock ssssh")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onChange(of: purchaseManager.isUnlocked) { _, isUnlocked in
                if isUnlocked { dismiss() }
            }
        }
    }

    @ViewBuilder
    private func purchaseButton(
        for product: Product?,
        fallbackTitle: String,
        fallbackPrice: String,
        subtitle: String
    ) -> some View {
        Button {
            guard let product else { return }
            Task {
                purchasingProductID = product.id
                await purchaseManager.purchase(product)
                purchasingProductID = nil
            }
        } label: {
            VStack(spacing: 2) {
                if purchasingProductID == product?.id {
                    ProgressView()
                } else {
                    Text("\(product?.displayName ?? fallbackTitle) — \(product?.displayPrice ?? fallbackPrice)")
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(product == nil || purchasingProductID != nil)
    }
}

#Preview {
    PaywallView()
        .environment(PurchaseManager())
}
