import StoreKit
import SwiftUI

struct SupportHibiscus: View {
    @Environment(AppPurchases.self) private var purchases
    @Environment(\.purchase) private var purchase
    @Environment(\.dismiss) private var dismiss
    @State private var products: [HibiscusPurchaseProduct: Product] = [:]
    @State private var loading = true
    @State private var notice: LocalizedStringKey?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Help Keep Hibiscus Alive.")
                            .font(.title2.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        Text("Hibiscus Film, including Creative Pack, is open source and supported by its community. Your support helps fund bug fixes, compatibility updates, and new features.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("One-time contributions")
                            .font(.subheadline.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        VStack(spacing: 0) {
                            contribution(.biscuit, "A Biscuit", "🍪")
                            Divider().padding(.horizontal, 12)
                            contribution(.tea, "A Tea", "🍵")
                            Divider().padding(.horizontal, 12)
                            contribution(.matcha, "A Matcha Latte", "🥛")
                        }
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                    }

                    if loading {
                        ProgressView("Loading contributions…").font(.footnote)
                    } else if products.isEmpty {
                        Text("Contributions are currently unavailable.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("These are symbolic contributions to support Hibiscus development. No actual food, drinks, or physical goods will be purchased or provided in exchange for your contribution.")
                        Text("Contributions do not unlock features.")
                        Text("Future Hibiscus products, services, or commercial features may be offered under separate terms, including proprietary licenses.")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 20)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Support Hibiscus")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .task {
            loading = true
            let available = (try? await Product.products(for: HibiscusPurchaseProduct.tips.map(\.rawValue))) ?? []
            guard !Task.isCancelled else { return }
            products = Dictionary(uniqueKeysWithValues: available.compactMap { product in
                guard let item = HibiscusPurchaseProduct.matching(id: product.id, type: product.type),
                      HibiscusPurchaseProduct.tips.contains(item) else { return nil }
                return (item, product)
            })
            loading = false
        }
        .alert("Support Hibiscus", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) { notice = nil }
        } message: {
            if let notice { Text(notice) }
        }
    }

    private func contribution(_ item: HibiscusPurchaseProduct, _ title: LocalizedStringKey, _ illustration: String) -> some View {
        Button {
            guard let product = products[item] else { return }
            Task { handle(await purchases.buy(product) { try await purchase($0) }) }
        } label: {
            HStack(spacing: 8) {
                Text(verbatim: illustration)
                    .font(.body)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                Text(title)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if purchases.purchasing == item {
                    ProgressView().controlSize(.small)
                } else if let price = products[item]?.displayPrice {
                    Text(verbatim: price).foregroundStyle(.secondary).fixedSize()
                } else if !loading && !products.isEmpty {
                    Text("Unavailable").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(products[item] == nil || purchases.busy)
    }

    private func handle(_ outcome: AppPurchases.Outcome) {
        switch outcome {
        case .completed: notice = "Thank you for your support."
        case .pending: notice = "Your contribution is pending approval."
        case .unverified: notice = "Your contribution could not be verified."
        case .notFound, .failed: notice = "Your contribution could not be completed."
        case .cancelled: break
        }
    }
}
