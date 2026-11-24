import StoreKit
import SwiftUI

struct SupporterPackPaywall: View {
    @Environment(AppPurchases.self) private var purchases
    @Environment(\.purchase) private var purchase
    @Environment(\.dismiss) private var dismiss
    var photo: CGImage? = nil
    @State private var product: Product?
    @State private var loading = true
    @State private var loadAttempt = 0
    @State private var notice: LocalizedStringKey?
    // Water lily from the original Hibiscus Demo Photos collection.
    private static let demo = UIImage(named: "SupporterPackDemo")?.cgImage

    private var isChecking: Bool { purchases.entitlement == .checking && !purchases.canUseSupporterPack }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Help Keep Hibiscus Alive.")
                            .font(.title2.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Hibiscus Film is free, open source, and independently developed. Keeping it free takes time, effort, and resources.")
                            Text("By becoming a supporter, you help us maintain Hibiscus, fix bugs, and continue exploring new possibilities in photography.")
                            Text("As a thank-you for your support, unlock Recipe Kitchen and additional photographic effects.")
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
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
                        SettingsRow(title: "Additional Effects",
                                    subtitle: "Save and share Photocopy, Risograph, Fiber Print, ASCII, Engraving, Solarization, and Chromatic Drift.")
                    }
                    Text("This purchase applies only to Hibiscus Film and does not unlock features in other Hibiscus apps.")
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
        .task(id: loadAttempt) {
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
        VStack(spacing: 8) {
            if purchases.canUseSupporterPack {
                Label("Supporter Pack unlocked", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                Button("Done") { dismiss() }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
            } else {
                if let product {
                    Text("\(product.displayPrice) · One purchase. No subscription.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button {
                        Task { handle(await purchases.buy(product) { try await purchase($0) }) }
                    } label: {
                        HStack {
                            if purchases.purchasing == .supporterPack { ProgressView().controlSize(.small) }
                            Text("Become a Supporter")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .disabled(purchases.busy || isChecking)
                } else if loading {
                    ProgressView("Loading price…")
                } else {
                    Text("Supporter Pack is currently unavailable.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Try Again") { loadAttempt += 1 }
                }
                Button {
                    Task { handle(await purchases.restoreSupporterPack()) }
                } label: {
                    HStack {
                        if purchases.restoring { ProgressView().controlSize(.small) }
                        Text("Restore Purchases")
                    }
                    .frame(minHeight: 44)
                }
                .disabled(purchases.busy || isChecking)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .background(.bar)
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
