import SwiftUI
import UIKit

enum HarnessTheme {
    enum Spacing {
        static let xSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let xLarge: CGFloat = 20
        static let xxLarge: CGFloat = 24
    }

    enum Radius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let card: CGFloat = 18
        static let floating: CGFloat = 22
    }

    static let pageBackground = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let secondarySurface = Color(uiColor: .tertiarySystemGroupedBackground)
    static let subtleFill = Color(uiColor: .tertiarySystemFill)
    static let separator = Color(uiColor: .separator).opacity(0.32)
}

struct HarnessIconTile: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: HarnessTheme.Radius.small, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct HarnessStatusPill: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, HarnessTheme.Spacing.small)
            .padding(.vertical, HarnessTheme.Spacing.xSmall)
            .background(tint.opacity(0.11), in: Capsule())
            .fixedSize(horizontal: true, vertical: false)
    }
}

extension View {
    func harnessCompactListChrome() -> some View {
        listStyle(.plain)
            .listSectionSpacing(.compact)
            .environment(\.defaultMinListRowHeight, 44)
            .scrollContentBackground(.hidden)
            .background(HarnessTheme.pageBackground)
    }

    func harnessCardSurface(
        padding: CGFloat = HarnessTheme.Spacing.large,
        radius: CGFloat = HarnessTheme.Radius.card
    ) -> some View {
        self
            .padding(padding)
            .background(HarnessTheme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(HarnessTheme.separator, lineWidth: 0.5)
            }
    }

    func harnessFloatingSurface(radius: CGFloat = HarnessTheme.Radius.floating) -> some View {
        self
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(HarnessTheme.separator, lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
    }

    func harnessCardListRow(horizontalInset: CGFloat = HarnessTheme.Spacing.large) -> some View {
        listRowInsets(
            EdgeInsets(
                top: HarnessTheme.Spacing.xSmall,
                leading: horizontalInset,
                bottom: HarnessTheme.Spacing.xSmall,
                trailing: horizontalInset
            )
        )
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}
