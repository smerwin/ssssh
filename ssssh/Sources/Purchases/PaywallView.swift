import SwiftUI
import StoreKit

/// Presented when the free tier's one-host/one-key limit is hit. Offers
/// either a one-time lifetime unlock or a monthly subscription -- both
/// grant the same `PurchaseManager.isUnlocked` entitlement.
struct PaywallView: View {
    @Environment(PurchaseManager.self) private var purchaseManager
    @Environment(\.dismiss) private var dismiss

    @State private var purchasingProductID: String?

    /// Shown only until `Product.products(for:)` loads the real StoreKit
    /// price; kept as one constant so the button and the renewal
    /// disclaimer below can't drift out of sync with each other.
    private static let monthlyFallbackPrice = "$0.99"

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
                        fallbackPrice: "\(Self.monthlyFallbackPrice)/mo",
                        subtitle: "Monthly subscription"
                    )
                }
                .tint(.blue)

                VStack(spacing: 4) {
                    Text("Support Development renews monthly at \(purchaseManager.monthlyProduct?.displayPrice ?? Self.monthlyFallbackPrice) until canceled. Manage or cancel anytime in Settings > Apple Account > Subscriptions.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 16) {
                        Link("Terms of Use", destination: LegalLinks.termsOfUse)
                        Link("Privacy Policy", destination: LegalLinks.privacyPolicy)
                    }
                    .font(.caption2)
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
            .onAppear { purchaseManager.clearStaleError() }
            .task {
                // `PurchaseManager.init()` only calls `loadProducts()`
                // once. If that attempt failed (e.g. no network at cold
                // launch), both buttons below are stuck showing "Loading…"
                // forever with no retry -- reopening the paywall later,
                // once connectivity is back, is this view's only chance to
                // recover without a full app relaunch.
                if purchaseManager.lifetimeProduct == nil && purchaseManager.monthlyProduct == nil {
                    await purchaseManager.loadProducts()
                }
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
                if let product, purchasingProductID == product.id {
                    ProgressView()
                } else if product == nil {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading \(fallbackTitle)…")
                            .font(.headline)
                    }
                    .foregroundStyle(.secondary)
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
