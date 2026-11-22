// SPDX-License-Identifier: MPL-2.0
// From SettingsView.swift in the Hibiscus iOS app.

import SwiftUI

struct SettingsRow: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    var showsExternalLinkIndicator = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if showsExternalLinkIndicator {
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.primary.opacity(0.76))
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }
}
