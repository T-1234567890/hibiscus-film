import StoreKit
import SwiftUI

struct SupporterPackPaywall: View {
    @Environment(AppPurchases.self) private var purchases
    @Environment(\.purchase) private var purchase
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var photo: CGImage? = nil
    @State private var product: Product?
    @State private var loading = true
    @State private var loadAttempt = 0
    @State private var notice: LocalizedStringKey?
    // Water lily from the original Hibiscus Demo Photos collection.
    private static let demo = UIImage(named: "SupporterPackDemo")?.cgImage

    private var isChecking: Bool { purchases.entitlement == .checking && !purchases.canUseSupporterPack }
    private var showsPurchaseAction: Bool { loading || product != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Help Keep Hibiscus Alive.")
                            .font(.title2.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        Text("Your support keeps Hibiscus Film free and open source. It helps fund our ongoing work.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("One-time purchase. No subscription.")
                            .font(.footnote.weight(.medium))
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    if let proofSource = photo ?? Self.demo {
                        SupporterEffectProofs(photo: proofSource)
                            .padding(.horizontal, -22)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        SettingsRow(title: "Recipe Kitchen",
                                    subtitle: "Create, customize, save, and export original film recipes as .hspec files.")
                        Divider()
                        SettingsRow(title: "Double Exposure",
                                    subtitle: "Blend two camera captures into one photograph.")
                        Divider()
                        SettingsRow(title: "Additional Effects",
                                    subtitle: "Save and share Photocopy, Risograph, Fiber Print, ASCII, Engraving, Solarization, and Chromatic Drift.")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("This purchase applies only to Hibiscus Film and does not unlock features in other Hibiscus apps.")
                        if !purchases.canUseSupporterPack { restoreText }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 22)
                .padding(.top, 10)
                .padding(.bottom, 22)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { purchaseControls }
            .navigationTitle("Supporter Pack")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .task(id: purchases.canUseSupporterPack ? nil : loadAttempt) {
            guard !purchases.canUseSupporterPack else { return }
            loading = true
            let item = HibiscusPurchaseProduct.supporterPack
            let prices = try? await Product.products(for: [item.rawValue])
            guard !Task.isCancelled else { return }
            product = prices?.first { $0.id == item.rawValue && $0.type == item.type }
            loading = false
        }
        .alert("Supporter Pack", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) { notice = nil }
        } message: {
            if let notice { Text(notice) }
        }
    }

    private var purchaseControls: some View {
        Group {
            if purchases.canUseSupporterPack {
                VStack(spacing: 8) {
                    Label("Supporter Pack unlocked", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                    Button("Done") { dismiss() }
                        .controlSize(.large)
                        .hibiscusGlassButtonStyle(tint: .accentColor)
                }
            } else {
                VStack(spacing: 6) {
                    if loading {
                        Text("Loading price…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if product == nil {
                        Text("Supporter Pack is currently unavailable.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        if let product {
                            Task { handle(await purchases.buy(product) { try await purchase($0) }) }
                        } else {
                            loading = true
                            loadAttempt += 1
                        }
                    } label: {
                        purchaseLabel
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .foregroundStyle(showsPurchaseAction ? Color.black : Color.primary)
                            .hibiscusGlass(tint: showsPurchaseAction ? .accentColor : nil,
                                           interactive: !loading && !purchases.busy, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(loading || purchases.busy || (product != nil && isChecking))
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }

    private var purchaseLabel: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Text(showsPurchaseAction ? LocalizedStringKey("Become a Supporter") : "Supporter Pack")
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: stacked ? .center : .leading)
            if loading || purchases.purchasing == .supporterPack {
                ProgressView().controlSize(.small).tint(.black)
            } else if let product {
                Text(verbatim: product.displayPrice).monospacedDigit().fixedSize()
            } else {
                Text("Try Again").font(.subheadline.weight(.semibold))
            }
        }
        .font(.headline)
    }

    @ViewBuilder
    private var restoreText: some View {
        if purchases.restoring {
            ProgressView("Restoring purchases…").controlSize(.small)
        } else {
            Text("Already purchased? [Restore Purchases](hibiscus-film://restore-purchases)")
                .environment(\.openURL, OpenURLAction { url in
                    guard url.absoluteString == "hibiscus-film://restore-purchases", !purchases.busy, !isChecking else {
                        return .discarded
                    }
                    Task { handle(await purchases.restoreSupporterPack()) }
                    return .handled
                })
                .disabled(purchases.busy || isChecking)
        }
    }

    private func handle(_ outcome: AppPurchases.Outcome) {
        switch outcome {
        case .completed, .cancelled: break
        case .pending: notice = "Your purchase is pending approval. Supporter Pack will unlock once it’s approved."
        case .notFound: notice = "No Supporter Pack purchase was found for this Apple Account."
        case .unverified: notice = "The Supporter Pack purchase could not be verified."
        case .failed: notice = "The Supporter Pack request could not be completed. Please try again."
        }
    }
}

private struct SupporterEffectProofs: View {
    let photo: CGImage
    @State private var images: [PrintEffect: CGImage] = [:]
    @State private var selection = 0
    @State private var loading = true
    private static let engine = HibiscusPrintEngine()
    private static let featured = PrintEffect.allCases.filter(\.requiresSupporterPack)
    private var ready: [PrintEffect] { Self.featured.filter { images[$0] != nil } }

    var body: some View {
        VStack(spacing: 2) {
            if loading {
                ProgressView("Rendering effect")
                    .font(.footnote)
                    .frame(maxWidth: .infinity, minHeight: 128)
            } else if !ready.isEmpty {
                PaperCarousel(finishes: ready, thumbnails: images, name: { $0.rawValue },
                              label: "Effect", fallback: UIImage(cgImage: photo),
                              isLocked: { _ in false }, selection: $selection, automaticallyAdvances: true)
                    .frame(height: 128)
                Text(LocalizedStringKey(ready[selection].rawValue))
                    .font(.headline)
                    .accessibilityHidden(true)
            }
        }
        .task(id: ObjectIdentifier(photo)) {
            loading = true
            var proofs: [PrintEffect: CGImage] = [:]
            for effect in Self.featured {
                guard !Task.isCancelled else { return }
                if let proof = try? await Self.engine.preview(photo, effect: effect, inks: effect.defaultPalette, maxDimension: 600) {
                    proofs[effect] = proof
                }
            }
            guard !Task.isCancelled else { return }
            selection = 0
            images = proofs
            loading = false
        }
    }
}
