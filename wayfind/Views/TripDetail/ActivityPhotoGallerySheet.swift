import SwiftUI

/// Full-screen paged gallery for activity attachments (view-only).
struct ActivityPhotoGallerySheet: View {
    let activityId: UUID
    let tripId: UUID
    let activityTitle: String

    @Environment(\.dismiss) private var dismiss
    @Environment(DataService.self) private var dataService

    @State private var service: ActivityAttachmentService?
    @State private var pageIndex: Int = 0

    private var imageAttachments: [ActivityAttachment] {
        (service?.attachments ?? []).filter(\.isImage)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if let service, service.isLoading && imageAttachments.isEmpty {
                    ProgressView()
                        .tint(.white)
                } else if imageAttachments.isEmpty {
                    ContentUnavailableView(
                        "No photos",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text("Photos for this stop are unavailable.")
                    )
                    .foregroundStyle(.white.opacity(0.85))
                } else {
                    TabView(selection: $pageIndex) {
                        ForEach(Array(imageAttachments.enumerated()), id: \.element.id) { index, attachment in
                            ActivityGalleryPage(attachment: attachment)
                                .tag(index)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: imageAttachments.count > 1 ? .automatic : .never))
                }
            }
            .navigationTitle(activityTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Close"))
                }
                if imageAttachments.count > 1 {
                    ToolbarItem(placement: .primaryAction) {
                        Text("\(pageIndex + 1) / \(imageAttachments.count)")
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .accessibilityLabel(
                                String(localized: "Photo \(pageIndex + 1) of \(imageAttachments.count)")
                            )
                    }
                }
            }
            .task {
                if service == nil {
                    let new = ActivityAttachmentService(
                        activityId: activityId,
                        tripId: tripId,
                        dataService: dataService
                    )
                    service = new
                    await new.reload()
                }
            }
            .onChange(of: imageAttachments.count) { _, count in
                if pageIndex >= count {
                    pageIndex = max(0, count - 1)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Page

private struct ActivityGalleryPage: View {
    let attachment: ActivityAttachment

    var body: some View {
        Group {
            if let url = attachment.signedURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .tint(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .failure:
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.white.opacity(0.5))
                    @unknown default:
                        EmptyView()
                    }
                }
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .padding(.bottom, 8)
    }
}
