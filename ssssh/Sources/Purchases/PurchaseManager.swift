import Foundation
import StoreKit
import Observation

/// Tracks whether the unlimited-hosts-and-keys unlock has been purchased,
/// either as a one-time non-consumable or an auto-renewable monthly
/// subscription -- either grants the same entitlement. Free-tier limits are
/// enforced by callers (see `HostListView`, `KeyListView`) checking
/// `isUnlocked`.
@MainActor
@Observable
final class PurchaseManager {
    static let lifetimeProductID = "com.smerwin.ssssh.unlimited"
    static let monthlyProductID = "com.smerwin.ssssh.monthly"

    private(set) var isUnlocked = false
    private(set) var lifetimeProduct: Product?
    private(set) var monthlyProduct: Product?
    private(set) var purchaseError: String?

    @ObservationIgnored
    private nonisolated(unsafe) var updatesTask: Task<Void, Never>?

    init() {
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(update)
            }
        }
        Task { [weak self] in
            await self?.loadProducts()
            await self?.refreshEntitlements()
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    func loadProducts() async {
        do {
            let products = try await Product.products(for: [Self.lifetimeProductID, Self.monthlyProductID])
            lifetimeProduct = products.first { $0.id == Self.lifetimeProductID }
            monthlyProduct = products.first { $0.id == Self.monthlyProductID }
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    func refreshEntitlements() async {
        var unlocked = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if Self.isKnownProductID(transaction.productID) {
                unlocked = true
            }
        }
        isUnlocked = unlocked
    }

    func purchase(_ product: Product) async {
        purchaseError = nil
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                await handle(verification)
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    func restorePurchases() async {
        purchaseError = nil
        do {
            try await AppStore.sync()
            await refreshEntitlements()
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else { return }
        guard Self.isKnownProductID(transaction.productID) else { return }
        await transaction.finish()
        await refreshEntitlements()
    }

    private static func isKnownProductID(_ productID: String) -> Bool {
        productID == lifetimeProductID || productID == monthlyProductID
    }
}
