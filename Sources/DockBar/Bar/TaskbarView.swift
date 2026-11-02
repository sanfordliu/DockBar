import SwiftUI

struct TaskbarView: View {
    var displayID: CGDirectDisplayID
    var model: TaskbarModel

    var body: some View {
        let items = model.entries(for: displayID)
        let floating = model.settings.style == .floating
        Group {
            if floating {
                floatingBar(items)
            } else {
                fullWidthBar(items)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A capsule that hugs the icons, with the same inset on both ends.
    private func floatingBar(_ items: [AppItem]) -> some View {
        let gap = model.barTrailingGap(for: displayID)
        return HStack(spacing: 0) {
            Spacer(minLength: 0)
            iconCluster(items)
            if model.settings.showTrash {
                BarDivider(height: model.settings.effectiveIconSize * 0.7)
                    .offset(x: gap)
                TrashButton()
                    .offset(x: gap)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, BarLayout.edgeInset)
        .padding(.trailing, gap)
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
                if model.showsDivider(after: item, in: items) {
                    BarDivider(height: model.settings.effectiveIconSize * 0.7)
                }
            }
        }
        .overlay(alignment: .leading) {
            if let slotX = dropSlotX(items) {
                DropSlot(width: model.settings.iconStride)
                    .offset(x: slotX)
            }
        }
        .animation(model.dragID == nil ? .spring(duration: 0.22) : nil, value: model.dropVisualIndex)
        .animation(model.dragID == nil ? .spring(duration: 0.28) : nil, value: items.map(\.id))
        .zIndex(model.dragID == nil ? 0 : 2)
    }

    private func dropSlotX(_ items: [AppItem]) -> CGFloat? {
        guard model.dragID == nil, model.dropDisplay == displayID, let visual = model.dropVisualIndex else { return nil }
        let runs = model.iconRuns(in: items)
        var x: CGFloat = 0
        for run in runs.prefix(min(visual, runs.count)) {
            x += run.width
            if run.showsDivider { x += BarLayout.dividerWidth }
        }
        return x
    }
}

private struct DropSlot: View {
    var width: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(0.18))
            .overlay {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.7))
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .allowsHitTesting(false)
    }
}

@MainActor
enum BarLayout {
    static let edgeInset: CGFloat = 10
    static let dividerLine: CGFloat = 1
    static let dividerInset: CGFloat = 8
    static let trashInset: CGFloat = 4
    static var dividerWidth: CGFloat { dividerLine + dividerInset * 2 }

    static func floatingWidth(items: [AppItem], settings: BarSettings, showsFinderDivider: Bool) -> CGFloat {
        let icons = items.isEmpty
            ? settings.iconStride
            : items.reduce(CGFloat(0)) { $0 + settings.buttonWidth(for: $1) }
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
