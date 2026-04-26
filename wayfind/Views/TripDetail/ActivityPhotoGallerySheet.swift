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
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    if imageAttachments.count > 1 {
                        Text("\(pageIndex + 1) / \(imageAttachments.count)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.backward")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.white.opacity(0.14))
                            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Back"))
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
