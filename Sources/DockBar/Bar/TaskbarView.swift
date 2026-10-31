import SwiftUI

struct TaskbarView: View {
    var displayID: CGDirectDisplayID
    var model: TaskbarModel

    var body: some View {
        let items = model.entries(for: displayID)
        let floating = model.settings.style == .floating
        let radius: CGFloat = floating ? model.settings.barHeight / 2 : 0
        Group {
            if floating {
                floatingBar(items)
            } else {
                fullWidthBar(items)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.black.opacity(0.12))
        }
        .glassEffect(
            floating ? .regular.interactive() : .regular,
            in: RoundedRectangle(cornerRadius: radius, style: .continuous)
        )
    }

    /// A capsule that hugs the icons, with the same inset on both ends.
    private func floatingBar(_ items: [AppItem]) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            iconCluster(items)
            if model.settings.showTrash {
                BarDivider(height: model.settings.effectiveIconSize * 0.7)
                TrashButton()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, BarLayout.edgeInset)
    }

    private func fullWidthBar(_ items: [AppItem]) -> some View {
        HStack(spacing: 0) {
            if model.settings.alignment == .center {
                if model.settings.showTrash {
                    Color.clear.frame(width: model.settings.trashSlot)
                }
                Spacer(minLength: 0)
            }
            iconCluster(items)
            Spacer(minLength: 0)
            if model.settings.showTrash {
                BarDivider(height: model.settings.effectiveIconSize * 0.7)
                TrashButton()
                    .padding(.trailing, 10)
            }
        }
        .padding(.leading, model.settings.alignment == .leading ? 8 : 0)
        .padding(.trailing, model.settings.showTrash ? 0 : 10)
    }

    private func iconCluster(_ items: [AppItem]) -> some View {
        HStack(spacing: 0) {
            if items.isEmpty {
                Text("DockBar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            }
            ForEach(items) { item in
                AppIconButton(item: item, displayID: displayID, model: model)
                if item.isPinned && model.settings.showFinder && item.bundleID == TaskbarModel.finderBundleID {
                    BarDivider(height: model.settings.effectiveIconSize * 0.7)
                }
            }
        }
        .animation(model.dragID == nil ? .spring(duration: 0.28) : nil, value: items.map(\.id))
    }
}

@MainActor
enum BarLayout {
    static let edgeInset: CGFloat = 10
    static let dividerLine: CGFloat = 1
    static let dividerInset: CGFloat = 8
    static let trashInset: CGFloat = 4
    static var dividerWidth: CGFloat { dividerLine + dividerInset * 2 }

    static func floatingWidth(itemCount: Int, settings: BarSettings, showsFinderDivider: Bool) -> CGFloat {
        let icons = CGFloat(max(itemCount, 1)) * settings.iconStride
        let finder = showsFinderDivider ? dividerWidth : 0
        let trash = settings.showTrash ? dividerWidth + settings.effectiveIconSize + trashInset * 2 : 0
        return icons + finder + trash + edgeInset * 2
    }
}

private struct BarDivider: View {
    var height: CGFloat

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.18))
            .frame(width: BarLayout.dividerLine, height: height)
            .padding(.horizontal, BarLayout.dividerInset)
    }
}
