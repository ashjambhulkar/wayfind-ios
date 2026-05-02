//
//  CachedAvatarImage.swift
//  wayfind
//
//  Loads a remote avatar image through `AvatarRemoteImageCache` so reopening
//  Profile, Edit Profile, or member lists does not repeat full downloads.
//

import SwiftUI
import UIKit

struct CachedAvatarImage: View {
    let url: URL
    /// When true, overlays a small `ProgressView` on the idle placeholder until bytes resolve.
    var showsProgressWhileLoading: Bool = false
    private let idlePlaceholder: () -> AnyView
    private let failurePlaceholder: () -> AnyView

    @State private var displayImage: UIImage?
    @State private var loadFailed = false

    /// Same view for loading (under the optional progress overlay) and for failure.
    init<P: View>(
        url: URL,
        showsProgressWhileLoading: Bool = false,
        @ViewBuilder placeholder: @escaping () -> P
    ) {
        self.url = url
        self.showsProgressWhileLoading = showsProgressWhileLoading
        self.idlePlaceholder = { AnyView(placeholder()) }
        self.failurePlaceholder = { AnyView(placeholder()) }
    }

    /// Separate idle vs failure chrome (e.g. spinner-only loading vs icon fallback on error).
    init<I: View, F: View>(
        url: URL,
        showsProgressWhileLoading: Bool = false,
        @ViewBuilder idle: @escaping () -> I,
        onFailure: @escaping () -> F
    ) {
        self.url = url
        self.showsProgressWhileLoading = showsProgressWhileLoading
        self.idlePlaceholder = { AnyView(idle()) }
        self.failurePlaceholder = { AnyView(onFailure()) }
    }

    var body: some View {
        Group {
            if let displayImage {
                Image(uiImage: displayImage)
                    .resizable()
                    .scaledToFill()
            } else if loadFailed {
                failurePlaceholder()
            } else {
                ZStack {
                    idlePlaceholder()
                    if showsProgressWhileLoading {
                        ProgressView()
                            .scaleEffect(0.85)
                    }
                }
            }
        }
        .onChange(of: url.absoluteString) { _, _ in
            displayImage = nil
            loadFailed = false
        }
        .task(id: url.absoluteString) {
            await load()
        }
    }

    @MainActor
    private func load() async {
        loadFailed = false
        if let cached = await AvatarRemoteImageCache.shared.image(for: url) {
            if !Task.isCancelled {
                displayImage = cached
            }
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
            await AvatarRemoteImageCache.shared.store(data: data, for: url)
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
