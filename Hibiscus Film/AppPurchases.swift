import StoreKit
import SwiftUI

nonisolated enum HibiscusPurchaseProduct: String, CaseIterable {
    case supporterPack = "hibiscus.creativepack.unlock"
    case biscuit = "hibiscus.tip.biscuit"
    case tea = "hibiscus.tip.tea"
    case matcha = "hibiscus.tip.matcha"

    static let tips: [Self] = [.biscuit, .tea, .matcha]

    var type: Product.ProductType { self == .supporterPack ? .nonConsumable : .consumable }

    static func matching(id: String, type: Product.ProductType) -> Self? {
        guard let item = Self(rawValue: id), item.type == type else { return nil }
        return item
    }
}

nonisolated enum SupporterPackEntitlement: Equatable {
    case checking, locked, unlocked
}

@Observable
final class AppPurchases {
    enum Outcome: Equatable {
        case completed, pending, cancelled, notFound, unverified, failed
    }

    private(set) var entitlement = SupporterPackEntitlement.checking
    private(set) var purchasing: HibiscusPurchaseProduct?
    private(set) var restoring = false
    @ObservationIgnored private var entitlementRevision = 0

    var busy: Bool { purchasing != nil || restoring }
    var canUseSupporterPack: Bool { entitlement == .unlocked }

    func observeTransactions() async {
        async let initialRefresh: Void = refreshSupporterPack()
        for await update in Transaction.updates {
            guard case .verified(let transaction) = update,
                  let item = HibiscusPurchaseProduct.matching(id: transaction.productID, type: transaction.productType) else { continue }
            if item == .supporterPack { await refreshSupporterPack() }
            await transaction.finish()
        }
        await initialRefresh
    }

    func buy(_ product: Product, perform: (Product) async throws -> Product.PurchaseResult) async -> Outcome {
        guard !busy,
              let item = HibiscusPurchaseProduct.matching(id: product.id, type: product.type) else { return .failed }
        purchasing = item
        defer { purchasing = nil }
        do {
            switch try await perform(product) {
            case .success(let result):
                guard case .verified(let transaction) = result,
                      transaction.productID == item.rawValue, transaction.productType == item.type else { return .unverified }
                if item == .supporterPack {
                    if transaction.revocationDate == nil {
                        entitlementRevision += 1
                        entitlement = .unlocked
                    } else {
                        await refreshSupporterPack()
                    }
                }
                await transaction.finish()
                return transaction.revocationDate == nil ? .completed : .failed
            case .pending: return .pending
            case .userCancelled: return .cancelled
            @unknown default: return .failed
            }
        } catch StoreKitError.userCancelled {
            return .cancelled
        } catch {
            return .failed
        }
    }

    func restoreSupporterPack() async -> Outcome {
        guard !busy else { return .failed }
        restoring = true
        defer { restoring = false }
        do {
            try await AppStore.sync()
            await refreshSupporterPack()
            return entitlement == .unlocked ? .completed : .notFound
        } catch StoreKitError.userCancelled {
            return .cancelled
        } catch {
            return .failed
        }
    }

    private func refreshSupporterPack() async {
        entitlementRevision += 1
        let revision = entitlementRevision
        var refreshed = SupporterPackEntitlement.locked
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == HibiscusPurchaseProduct.supporterPack.rawValue,
               transaction.productType == .nonConsumable,
               transaction.revocationDate == nil {
                refreshed = .unlocked
                break
            }
        }
        // A verified purchase can complete while this snapshot is in flight.
        guard !Task.isCancelled, revision == entitlementRevision else { return }
        entitlement = refreshed
    }
}
