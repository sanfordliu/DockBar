import SwiftUI

struct TaskbarView: View {
    var displayID: CGDirectDisplayID
    var model: TaskbarModel

    var body: some View {
        let items = model.entries(for: displayID)
        let radius: CGFloat = model.settings.style == .floating ? 22 : 0
        HStack(spacing: 0) {
            if model.settings.alignment == .center {
                if model.settings.showTrash {
                    Color.clear.frame(width: model.settings.trashSlot)
                }
                Spacer(minLength: 0)
            }
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
            Spacer(minLength: 0)
            if model.settings.showTrash {
                BarDivider(height: model.settings.effectiveIconSize * 0.7)
                TrashButton()
                    .padding(.trailing, 10)
            }
        }
        .padding(.leading, model.settings.alignment == .leading ? 8 : 0)
        .padding(.trailing, model.settings.showTrash ? 0 : 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.black.opacity(0.12))
        }
        .glassEffect(
            model.settings.style == .floating ? .regular.interactive() : .regular,
            in: RoundedRectangle(cornerRadius: radius, style: .continuous)
        )
    }
}

private struct BarDivider: View {
    var height: CGFloat

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.18))
            .frame(width: 1, height: height)
            .padding(.horizontal, 8)
    }
}
