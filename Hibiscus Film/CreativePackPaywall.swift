import StoreKit
import SwiftUI

struct CreativePackPaywall: View {
    @Environment(AppPurchases.self) private var purchases
    @Environment(\.purchase) private var purchase
    @Environment(\.dismiss) private var dismiss
    var photo: CGImage? = nil
    @State private var product: Product?
    @State private var loading = true
    @State private var loadAttempt = 0
    @State private var notice: LocalizedStringKey?
    // Water lily from the original Hibiscus Demo Photos collection.
    private static let demo = UIImage(named: "CreativePackDemo")?.cgImage

    private var isChecking: Bool { purchases.entitlement == .checking && !purchases.canUseCreativePack }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("More room to create.")
                            .font(.title2.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        Text("Explore your own film recipes, experiment with advanced photographic effects, and develop your own visual style.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    if let proofSource = photo ?? Self.demo {
                        CreativeEffectProofs(photo: proofSource)
                            .padding(.horizontal, -22)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        SettingsRow(title: "Recipe Kitchen",
                                    subtitle: "Build from scratch or start from a film stock. Edit response and color curves, grain, and halation with a live Fotufilm preview. Save your recipes and export them as .hspec files.")
                        Divider()
                        SettingsRow(title: "Seven premium Effects",
                                    subtitle: "Save and share Photocopy, Risograph, Fiber Print, ASCII, Engraving, Solarization, and Chromatic Drift.")
                    }
                    Text("Creative Pack is open source. The one-time App Store purchase helps sustain development of Hibiscus Film.")
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
            .navigationTitle("Hibiscus Creative Pack")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .task(id: loadAttempt) {
            guard !purchases.canUseCreativePack else { return }
            loading = true
            let item = HibiscusPurchaseProduct.creativePack
            let prices = try? await Product.products(for: [item.rawValue])
            guard !Task.isCancelled else { return }
            product = prices?.first { $0.id == item.rawValue && $0.type == item.type }
            loading = false
        }
        .alert("Hibiscus Creative Pack", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) { notice = nil }
        } message: {
            if let notice { Text(notice) }
        }
    }

    private var purchaseControls: some View {
        VStack(spacing: 8) {
            if purchases.canUseCreativePack {
                Label("Creative Pack unlocked", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                Button("Done") { dismiss() }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
            } else {
                if let product {
                    Text("\(product.displayPrice) · One-time purchase · No subscription")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button {
                        Task { handle(await purchases.buy(product) { try await purchase($0) }) }
                    } label: {
                        HStack {
                            if purchases.purchasing == .creativePack { ProgressView().controlSize(.small) }
                            Text("Unlock Creative Pack")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .disabled(purchases.busy || isChecking)
                } else if loading {
                    ProgressView("Loading price…")
                } else {
                    Text("Creative Pack is currently unavailable.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Try Again") { loadAttempt += 1 }
                }
                Button {
                    Task { handle(await purchases.restoreCreativePack()) }
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
        case .pending: notice = "Your purchase is pending approval. Creative Pack will unlock once it’s approved."
        case .notFound: notice = "No Creative Pack purchase was found for this Apple Account."
        case .unverified: notice = "The Creative Pack purchase could not be verified."
        case .failed: notice = "The Creative Pack request could not be completed. Please try again."
        }
    }
}

private struct CreativeEffectProofs: View {
    let photo: CGImage
    @State private var images: [PrintEffect: CGImage] = [:]
    @State private var selection = 0
    @State private var loading = true
    private static let engine = HibiscusPrintEngine()
    private static let featured = PrintEffect.allCases.filter(\.requiresCreativePack)
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
