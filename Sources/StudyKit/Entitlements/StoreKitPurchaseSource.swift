#if canImport(StoreKit)
import StoreKit

/// Reads the purchases StoreKit 2 currently honours for this app: verified, not refunded or revoked.
/// Not exercised by package tests; the apps cover it with StoreKit test configurations.
public struct StoreKitPurchaseSource: PurchaseSource {
    public init() {}

    public func currentEntitlements() async -> Set<StudyProduct> {
        var owned: Set<StudyProduct> = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.revocationDate == nil,
                  let product = StudyProduct(rawValue: transaction.productID) else { continue }
            owned.insert(product)
        }
        return owned
    }
}
#endif
