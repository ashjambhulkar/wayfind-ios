import SwiftUI
import UIKit

/// Loads an activity attachment image through `ActivityAttachmentImageCache`,
/// keyed by the stable attachment UUID so signed-URL rotation never causes
/// re-downloads. When the image is in the memory tier, it renders on the very
/// first body call with no placeholder flash.
struct CachedAttachmentImage<Placeholder: View>: View {
    let attachmentId: UUID
    let url: URL
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var displayImage: UIImage?
    @State private var loadFailed = false

    init(
        attachmentId: UUID,
        url: URL,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.attachmentId = attachmentId
        self.url = url
        self.placeholder = placeholder
        // Synchronous memory read so cached images appear on first render.
        self._displayImage = State(
            initialValue: ActivityAttachmentImageCache.shared.cachedImage(for: attachmentId)
        )
    }

    var body: some View {
        Group {
            if let displayImage {
                Image(uiImage: displayImage)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: attachmentId) {
            guard displayImage == nil else { return }
            await load()
        }
    }

    @MainActor
    private func load() async {
        if let cached = await ActivityAttachmentImageCache.shared.image(for: attachmentId) {
            if !Task.isCancelled { displayImage = cached }
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            guard let image = UIImage(data: data) else {
                throw URLError(.cannotDecodeContentData)
            }
            ActivityAttachmentImageCache.shared.store(data: data, for: attachmentId)
            if !Task.isCancelled {
                displayImage = image
            }
        } catch is CancellationError {
            return
        } catch {
            if !Task.isCancelled {
                loadFailed = true
            }
        }
    }
}
