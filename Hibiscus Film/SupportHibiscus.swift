import StoreKit
import SwiftUI

struct SupportHibiscus: View {
    let effectsPhoto: CGImage?
    @Environment(AppPurchases.self) private var purchases
    @Environment(\.purchase) private var purchase
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .title) private var emojiSize: CGFloat = 36
    @State private var products: [HibiscusPurchaseProduct: Product] = [:]
    @State private var loading = true
    @State private var notice: LocalizedStringKey?
    @State private var showingSupporterPack = false

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ScrollView {
                    supportContent(rowHeight: min(112, max(76, proxy.size.height * 0.13)))
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                        .padding(.bottom, 20)
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .topLeading)
                }
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Support Hibiscus")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .tint(.primary)
        .sheet(isPresented: $showingSupporterPack) {
            SupporterPackPaywall(photo: effectsPhoto)
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

    private func supportContent(rowHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Help Keep Hibiscus Alive.")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Hibiscus Film, including Supporter Pack, is open source and supported by its community. Your support helps fund our ongoing work.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text("One-time contributions")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Tips support development and do not unlock any features.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 8) {
                    contribution(.biscuit, "Cookie", "🍪", minHeight: rowHeight)
                    contribution(.tea, "A Cup of Tea", "🫖", minHeight: rowHeight)
                    contribution(.matcha, "A Matcha Latte", "🥛", minHeight: rowHeight)
                }
            }

            if !loading && products.isEmpty {
                Text("Contributions are currently unavailable.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("These are symbolic contributions to support Hibiscus development. No actual food, drinks, or physical goods will be purchased or provided in exchange for your contribution.")
                Text("Future Hibiscus products, services, or commercial features may be offered under separate terms, including proprietary licenses.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Button {
                showingSupporterPack = true
            } label: {
                HStack(spacing: 8) {
                    SettingsRow(
                        title: "Looking for the Supporter Pack?",
                        subtitle: "Unlock Recipe Kitchen and additional creative tools."
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .padding(12)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func contribution(_ item: HibiscusPurchaseProduct, _ title: LocalizedStringKey, _ illustration: String,
                              minHeight: CGFloat) -> some View {
        Button {
            guard let product = products[item] else { return }
            Task { handle(await purchases.buy(product) { try await purchase($0) }) }
        } label: {
            HStack(spacing: 14) {
                Text(verbatim: illustration)
                    .font(.system(size: emojiSize))
                    .frame(width: emojiSize + 8)
                    .accessibilityHidden(true)
                Text(title)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if loading {
                    ProgressView().controlSize(.small).accessibilityLabel("Loading price…")
                } else if purchases.purchasing == item {
                    ProgressView().controlSize(.small)
                } else if let price = products[item]?.displayPrice {
                    Text(verbatim: price).monospacedDigit().fixedSize()
                } else if !products.isEmpty {
                    Text("Unavailable").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .font(.headline)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .disabled(loading || products[item] == nil || purchases.busy)
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
