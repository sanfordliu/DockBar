import SwiftUI

struct WindowPreviewView: View {
    var appID: String
    var displayID: CGDirectDisplayID
    var model: TaskbarModel
    var thumbnails: ThumbnailService

    private var item: AppItem? {
        model.entries(for: displayID).first { $0.id == appID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let item {
                Text(item.name)
                    .font(.headline)
                    .lineLimit(1)
                windowRow(item)
            }
        }
        .padding(PreviewLayout.outerPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onHover { inside in
            if inside {
                PreviewCoordinator.shared.cancelHide()
            } else {
                WindowHighlight.shared.hide()
                PreviewCoordinator.shared.scheduleHide()
            }
        }
    }

    @ViewBuilder
    private func windowRow(_ item: AppItem) -> some View {
        let cards = HStack(spacing: PreviewLayout.cardGap) {
            ForEach(item.windowsOnScreen) { window in
                WindowCard(window: window, item: item, thumbnails: thumbnails)
            }
        }
        let natural = PreviewLayout.width(windowCount: item.windowsOnScreen.count)
        let limit = (ScreenCoordinates.screen(for: displayID)?.frame.width ?? natural) - 24
        if natural > limit {
            ScrollView(.horizontal, showsIndicators: false) {
                cards
            }
        } else {
            cards
        }
    }
}

private struct WindowCard: View {
    var window: WindowInfo
    var item: AppItem
    var thumbnails: ThumbnailService
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                thumbnail
                    .frame(width: PreviewLayout.thumbnailWidth, height: PreviewLayout.thumbnailHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                if hovered {
                    Button {
                        TaskbarModel.shared.close(window)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                }
            }
            Text(label)
                .font(.caption)
                .lineLimit(1)
                .frame(width: PreviewLayout.thumbnailWidth, alignment: .leading)
            if let profile = window.profileName, !profile.isEmpty {
                Text(profile)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: PreviewLayout.thumbnailWidth, alignment: .leading)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(hovered ? 0.12 : 0))
        )
        .onHover { inside in
            hovered = inside
            if inside {
                PreviewCoordinator.shared.cancelHide()
                if !window.isMinimized {
                    WindowHighlight.shared.show(frame: window.frame)
                }
            } else {
                WindowHighlight.shared.hide()
            }
        }
        .onTapGesture {
            TaskbarModel.shared.focus(window)
        }
        .onAppear {
            thumbnails.request(window)
        }
    }

    private var label: String {
        let title = BrowserProfile.pageTitle(window.title, appName: item.name, profile: window.profileName)
        return window.isMinimized ? "\(title) (minimized)" : title
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = thumbnails.image(for: window.windowID) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if window.isMinimized {
            placeholder("minus")
        } else if let message = thumbnails.lastError {
            placeholder("rectangle.dashed", caption: message)
        } else {
            placeholder("macwindow")
        }
    }

    private func placeholder(_ symbol: String, caption: String? = nil) -> some View {
        ZStack {
            Color.primary.opacity(0.08)
            VStack(spacing: 6) {
                Image(nsImage: IconCache.shared.icon(for: item.path))
                    .resizable()
                    .frame(width: 36, height: 36)
                if let caption {
                    Text(caption)
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                } else {
                    Image(systemName: symbol)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
