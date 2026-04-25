//
//  TripDocumentsView.swift
//  wayfind
//
//  Wave 1.4 — production trip documents screen. Replaces the placeholder.
//
//  Layout — phone:
//      Native navigation search
//      [Scrollable category chips row]
//      Grid (2-col) of document tiles
//      Floating "+" FAB anchored bottom-trailing.
//
//  Layout — iPad regular width:
//      Same shell but the grid widens to 3 columns and the FAB stays
//      bottom-trailing. We rely on `LazyVGrid` adaptive layout instead
//      of branching on `horizontalSizeClass` for a single source of truth.
//
//  Pro-gating (Wave 4.5):
//      • Free users: HARD-capped at `perUserSoftLimit` (5) docs they
//        themselves uploaded for this trip. The +/FAB is disabled at
//        the cap and tapping the cap pill presents the paywall.
//      • Pro users: only the per-trip ceiling (25) applies — the
//        per-user check is skipped server-side and client-side.
//      • Hitting the trip ceiling (25) is a hard error for both tiers
//        — Pro doesn't unlock more storage, just removes the per-user
//        cap. Copy in `TripDocumentError.ceilingReached` says so.
//      • Every gate trip logs `pro_gate_attempted` with `is_pro:false`
//        through `PaywallPresenter`, which centralises both the
//        analytics shape and the placement-specific paywall offering.
//

import Auth
import PhotosUI
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct TripDocumentsView: View {
    let trip: Trip

    @Environment(DataService.self) private var dataService

    @State private var service: TripDocumentsService?
    @State private var currentUserId: UUID?
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showingDocumentPicker: Bool = false
    @State private var showingCategorySheet: Bool = false
    @State private var pendingMimeType: String?
    @State private var pendingBytes: Data?
    @State private var pendingFileName: String?
    @State private var pendingTitle: String = ""
    @State private var pendingCategory: DocumentCategory = .other
    @State private var pendingUploads: [PendingAttachmentUpload] = []
    @State private var previewURL: URL?
    @State private var error: String?

    private let columns: [GridItem] = [
        GridItem(.adaptive(minimum: 150, maximum: 260), spacing: AppSpacing.md)
    ]

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            content
            fab
        }
        .navigationTitle("Documents")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .searchable(
            text: documentSearchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search documents"
        )
        .background(AppColors.appBackground.ignoresSafeArea())
        .task {
            await ensureSession()
            if service == nil, let uid = currentUserId {
                let new = TripDocumentsService(
                    tripId: trip.id,
                    currentUserId: uid,
                    dataService: dataService
                )
                service = new
                await new.reload()
            }
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await handlePhotos(items: items) }
        }
        .sheet(isPresented: $showingDocumentPicker) {
            DocumentPicker(
                allowedTypes: [.pdf, .jpeg, .png, .heic, .webP, .image],
                onPicked: { url in Task { await handleDocument(url: url) } }
            )
        }
        .sheet(isPresented: $showingCategorySheet) {
            categoryPickerSheet
        }
        .sheet(item: previewURLBinding) { wrapped in
            QuickLookPreview(url: wrapped.url)
        }
        .alert(
            "Couldn't add document",
            isPresented: Binding(
                get: { error != nil },
                set: { if !$0 { error = nil } }
            )
        ) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let service {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppSpacing.md, pinnedViews: [.sectionHeaders]) {
                    Section {
                        if !pendingUploads.isEmpty {
                            VStack(spacing: AppSpacing.sm) {
                                ForEach(pendingUploads) { up in
                                    DocUploadRow(upload: up, onClear: { clearUpload(id: up.id) })
                                }
                            }
                            .padding(.horizontal, AppSpacing.md)
                        }

                        if shouldShowFreeUserCapPill {
                            // Wave 4.5 — flipped from soft pill to a
                            // tappable hard-gate banner. The button
                            // presents the paywall through
                            // PaywallPresenter so analytics + offering
                            // selection stay consistent with every
                            // other gate.
                            Button {
                                PaywallPresenter.shared.present(
                                    .documents,
                                    dataService: dataService,
                                    metadata: [
                                        "trip_id": trip.id.uuidString,
                                        "user_doc_count": "\(service.quotaSnapshot.perUserUploadCount)",
                                        "trigger": "documents_cap_pill",
                                    ]
                                )
                            } label: {
                                ProGateSoftPill(
                                    message: "Free plan limit reached (\(TripDocumentsService.perUserSoftLimit) per trip). Tap to upgrade for unlimited."
                                )
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, AppSpacing.md)
                        }

                        if service.documents.isEmpty && !service.isLoading {
                            emptyState
                                .padding(.top, AppSpacing.xxxl)
                        } else if service.isLoading && service.documents.isEmpty {
                            LazyVGrid(columns: columns, spacing: AppSpacing.md) {
                                ForEach(0..<6, id: \.self) { _ in
                                    SkeletonView(cornerRadius: AppCornerRadius.medium, height: 180)
                                }
                            }
                            .padding(.horizontal, AppSpacing.md)
                        } else {
                            LazyVGrid(columns: columns, spacing: AppSpacing.md) {
                                ForEach(service.filteredDocuments) { doc in
                                    DocTile(
                                        document: doc,
                                        onTap: { Task { await openPreview(for: doc) } },
                                        onDelete: { Task { await service.delete(documentId: doc.id) } }
                                    )
                                }
                            }
                            .padding(.horizontal, AppSpacing.md)
                        }
                    } header: {
                        categoryChipsHeader(service: service)
                    }
                }
                .padding(.bottom, 96) // FAB clearance
            }
            .refreshable { await service.reload() }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var documentSearchText: Binding<String> {
        Binding(
            get: { service?.searchText ?? "" },
            set: { service?.searchText = $0 }
        )
    }

    @ViewBuilder
    private func categoryChipsHeader(service: TripDocumentsService) -> some View {
        VStack(spacing: AppSpacing.sm) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppSpacing.xs) {
                    CategoryChip(
                        label: "All",
                        symbol: "square.grid.2x2",
                        isSelected: service.selectedCategory == nil,
                        action: { service.selectedCategory = nil }
                    )
                    ForEach(DocumentCategory.allCases) { cat in
                        CategoryChip(
                            label: cat.displayLabel,
                            symbol: cat.sfSymbol,
                            isSelected: service.selectedCategory == cat,
                            action: {
                                service.selectedCategory = service.selectedCategory == cat ? nil : cat
                            }
                        )
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.top, AppSpacing.sm)
        .padding(.bottom, AppSpacing.sm)
        .background(AppColors.appBackground)
    }

    private var emptyState: some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(AppColors.appPrimary.opacity(0.7))
                .accessibilityHidden(true)
            Text("No documents yet")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.primary)
            Text("Boarding passes, hotel confirmations, visas, insurance — keep them all in one place for this trip.")
                .font(.subheadline)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppSpacing.xl)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - FAB

    @ViewBuilder
    private var fab: some View {
        // Wave 4.5 — three states for the FAB:
        //   1. Trip ceiling hit (Pro & Free)  → disabled, no menu.
        //   2. Free user at per-user cap      → tappable but routes
        //      directly to the paywall instead of the upload menu, so
        //      the user understands *why* they can't add more.
        //   3. Otherwise                      → normal Menu with
        //      Photos / Files options.
        if service?.quotaSnapshot.hitsHardCeiling == true {
            fabButton(label: "Add document")
                .disabled(true)
        } else if isFreeUserAtCap {
            Button {
                PaywallPresenter.shared.present(
                    .documents,
                    dataService: dataService,
                    metadata: [
                        "trip_id": trip.id.uuidString,
                        "user_doc_count": "\(service?.quotaSnapshot.perUserUploadCount ?? 0)",
                        "trigger": "documents_fab",
                    ]
                )
            } label: {
                fabButton(label: "Upgrade to add more documents")
            }
            .padding(.trailing, AppSpacing.lg)
            .padding(.bottom, AppSpacing.lg)
        } else {
            Menu {
                PhotosPicker(
                    selection: $photoItems,
                    maxSelectionCount: max(0, TripDocumentsService.tripCeiling - (service?.documents.count ?? 0)),
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    Label("Photo from Library", systemImage: "photo.on.rectangle.angled")
                }
                Button {
                    showingDocumentPicker = true
                } label: {
                    Label("File from Files app", systemImage: "doc.badge.plus")
                }
            } label: {
                fabButton(label: "Add document")
            }
            .padding(.trailing, AppSpacing.lg)
            .padding(.bottom, AppSpacing.lg)
        }
    }

    private func fabButton(label: String) -> some View {
        Image(systemName: "plus")
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 56, height: 56)
            .background(AppColors.appPrimary, in: Circle())
            .shadow(color: AppColors.appPrimary.opacity(0.35), radius: 12, y: 4)
            .accessibilityLabel(label)
    }

    // MARK: - Category sheet (after picking a file)

    private var categoryPickerSheet: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Optional title", text: $pendingTitle)
                }
                Section("Category") {
                    Picker("Category", selection: $pendingCategory) {
                        ForEach(DocumentCategory.allCases) { cat in
                            Label(cat.displayLabel, systemImage: cat.sfSymbol).tag(cat)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                if let fileName = pendingFileName {
                    Section("File") {
                        Text(fileName)
                            .font(.appCaption)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                }
            }
            .navigationTitle("Add Document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        clearPending()
                        showingCategorySheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task { await commitPending() }
                    }
                    .disabled(pendingBytes == nil)
                }
            }
        }
    }

    // MARK: - Helpers

    /// Wave 4.5 — Pro users have no per-user cap (just the trip
    /// ceiling), so we only surface the upgrade banner / paywall to
    /// free users. We re-read `EntitlementService.shared.isPro` on
    /// every render via the @Observable machinery so flipping Pro
    /// mid-session updates the gate without a re-mount.
    private var isFreeUserAtCap: Bool {
        guard let service else { return false }
        if EntitlementService.shared.isPro { return false }
        return service.quotaSnapshot.hitsPerUserSoftLimit
            && !service.quotaSnapshot.hitsHardCeiling
    }

    /// Cap pill shows whenever the upload affordance has been removed
    /// for the free-user-cap reason — i.e. same condition as
    /// `isFreeUserAtCap`. Trip-ceiling case shows the standard error
    /// alert via `TripDocumentError.ceilingReached` instead, so we
    /// don't need a second pill for it.
    private var shouldShowFreeUserCapPill: Bool {
        isFreeUserAtCap
    }

    private var previewURLBinding: Binding<PreviewURLWrapper?> {
        Binding(
            get: { previewURL.map { PreviewURLWrapper(url: $0) } },
            set: { previewURL = $0?.url }
        )
    }

    private func ensureSession() async {
        if currentUserId != nil { return }
        if let session = await AuthSessionService.shared.currentSession() {
            currentUserId = session.user.id
        }
    }

    private func clearUpload(id: UUID) {
        pendingUploads.removeAll { $0.id == id }
    }

    private func clearPending() {
        pendingBytes = nil
        pendingMimeType = nil
        pendingFileName = nil
        pendingTitle = ""
        pendingCategory = .other
    }

    private func handlePhotos(items: [PhotosPickerItem]) async {
        defer { photoItems = [] }
        guard let item = items.first else { return }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            let processed = try await ImageProcessor.process(data: data)
            stagePending(
                bytes: processed.data,
                mimeType: processed.mimeType,
                fileName: processed.fileName
            )
        } catch let err as ImageProcessorError {
            error = err.errorDescription
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func handleDocument(url: URL) async {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let utType = UTType(filenameExtension: url.pathExtension) ?? .data
            let mime = AttachmentValidator.mimeType(for: utType) ?? "application/octet-stream"
            let bytesToUpload: Data
            let mimeToUpload: String
            let name: String
            if mime.hasPrefix("image/") && mime != "image/jpeg" {
                let processed = try await ImageProcessor.process(
                    data: data,
                    sourceFileName: url.lastPathComponent
                )
                bytesToUpload = processed.data
                mimeToUpload = processed.mimeType
                name = processed.fileName
            } else {
                bytesToUpload = data
                mimeToUpload = mime
                name = url.lastPathComponent
            }
            stagePending(bytes: bytesToUpload, mimeType: mimeToUpload, fileName: name)
        } catch let err as AttachmentValidator.ValidationError {
            error = err.errorDescription
        } catch let err as ImageProcessorError {
            error = err.errorDescription
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func stagePending(bytes: Data, mimeType: String, fileName: String) {
        pendingBytes = bytes
        pendingMimeType = mimeType
        pendingFileName = fileName
        pendingTitle = (fileName as NSString).deletingPathExtension
        pendingCategory = inferCategory(fromName: fileName)
        showingCategorySheet = true
    }

    private func inferCategory(fromName name: String) -> DocumentCategory {
        let l = name.lowercased()
        if l.contains("visa") { return .visa }
        if l.contains("insur") { return .insurance }
        if l.contains("hotel") || l.contains("airbnb") { return .lodging }
        if l.contains("flight") || l.contains("boarding") || l.contains("itinerary") { return .flight }
        if l.contains("train") || l.contains("rail") || l.contains("bus") { return .transport }
        if l.contains("ticket") { return .tickets }
        return .other
    }

    private func commitPending() async {
        guard let service else { return }
        guard let bytes = pendingBytes,
              let mime = pendingMimeType,
              let name = pendingFileName else { return }
        showingCategorySheet = false
        do {
            let pending = try await service.upload(
                bytes: bytes,
                mimeType: mime,
                fileName: name,
                title: pendingTitle.isEmpty ? nil : pendingTitle,
                category: pendingCategory
            )
            pendingUploads.append(pending)
            clearPending()
        } catch let err as TripDocumentError {
            error = err.errorDescription
            clearPending()
        } catch let err as AttachmentValidator.ValidationError {
            error = err.errorDescription
            clearPending()
        } catch {
            self.error = error.localizedDescription
            clearPending()
        }
    }

    private func openPreview(for document: TripDocument) async {
        // `??` evaluates the right-hand side as an autoclosure which
        // can't carry `async`. Resolve the lazy fallback explicitly.
        let signed: URL?
        if let cached = document.signedURL {
            signed = cached
        } else {
            signed = await refreshURL(for: document)
        }
        guard let signed else {
            error = "Couldn't generate a preview link."
            return
        }
        do {
            let local = try await downloadToTemp(url: signed, suggestedName: document.fileName)
            await MainActor.run { previewURL = local }
        } catch {
            self.error = "Couldn't download the document."
        }
    }

    private func refreshURL(for document: TripDocument) async -> URL? {
        await service?.resolveSignedURLs()
        return service?.documents.first(where: { $0.id == document.id })?.signedURL
    }

    private func downloadToTemp(url: URL, suggestedName: String) async throws -> URL {
        let (data, _) = try await URLSession.shared.data(from: url)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("trip-docs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent(suggestedName)
        try? FileManager.default.removeItem(at: target)
        try data.write(to: target, options: .atomic)
        return target
    }
}

// MARK: - Subviews

private struct PreviewURLWrapper: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct CategoryChip: View {
    let label: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.caption2.weight(.semibold))
                Text(label)
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, 8)
            .background(
                isSelected ? AppColors.appPrimary : AppColors.appSurface,
                in: Capsule()
            )
            .foregroundStyle(isSelected ? .white : AppColors.textPrimary)
            .overlay(
                Capsule().strokeBorder(
                    isSelected ? Color.clear : AppColors.appDivider,
                    lineWidth: 1
                )
            )
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct DocTile: View {
    let document: TripDocument
    let onTap: () -> Void
    let onDelete: () -> Void

    @State private var thumbnail: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    AppColors.appSurface
                    VStack(spacing: 6) {
                        Image(systemName: document.category?.sfSymbol ?? (document.isPDF ? "doc.richtext" : "doc"))
                            .font(.system(size: 28))
                            .foregroundStyle(AppColors.appPrimary.opacity(0.7))
                        Text(document.isPDF ? "PDF" : "FILE")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(AppColors.textSecondary)
                    }
                }
            }
            .frame(height: 140)
            .frame(maxWidth: .infinity)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium))
            .overlay(
                RoundedRectangle(cornerRadius: AppCornerRadius.medium)
                    .strokeBorder(AppColors.appDivider, lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(document.displayTitle)
                    .font(.appCaption.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 4) {
                    if let cat = document.category {
                        Text(cat.displayLabel)
                    }
                    if document.byteSize > 0 {
                        Text("·")
                        Text(document.sizeLabel)
                    }
                }
                .font(.caption2)
                .foregroundStyle(AppColors.textSecondary)
            }
            .padding(.horizontal, 4)
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .contextMenu {
            Button {
                onTap()
            } label: {
                Label("Preview", systemImage: "eye")
            }
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(document.displayTitle), \(document.category?.displayLabel ?? "uncategorized"), \(document.sizeLabel)")
        .accessibilityAddTraits(.isButton)
        .task(id: document.signedURL?.absoluteString) {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        guard thumbnail == nil, let url = document.signedURL else { return }
        if document.isImage {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let img = UIImage(data: data) {
                    await MainActor.run { thumbnail = img }
                }
            } catch {}
        } else if document.isPDF {
            let img = await PDFThumbnailService.shared.thumbnail(
                for: document.storagePath,
                remoteURL: url,
                targetSize: CGSize(width: 320, height: 320)
            )
            await MainActor.run { thumbnail = img }
        }
    }
}

private struct DocUploadRow: View {
    let upload: PendingAttachmentUpload
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            statusIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(upload.displayName)
                    .font(.appCaption.weight(.medium))
                    .lineLimit(1)
                statusText
                    .font(.caption2)
                    .foregroundStyle(AppColors.textSecondary)
            }
            Spacer()
            if isTerminal {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppColors.textSecondary)
                }
                .accessibilityLabel("Dismiss upload")
            }
        }
        .padding(AppSpacing.sm)
        .background(AppColors.appSurface, in: RoundedRectangle(cornerRadius: AppCornerRadius.small))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch upload.status {
        case .waiting, .committing, .finalizing: ProgressView()
        case .uploading(let p): ProgressView(value: p).progressViewStyle(.linear).frame(width: 60)
        case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch upload.status {
        case .waiting: Text("Queued")
        case .committing: Text("Preparing")
        case .uploading(let p): Text("Uploading \(Int(p * 100))%")
        case .finalizing: Text("Finishing")
        case .completed: Text("Added")
        case .failed(let m, _): Text(m)
        }
    }

    private var isTerminal: Bool {
        switch upload.status {
        case .completed, .failed: return true
        default: return false
        }
    }
}

private struct ProGateSoftPill: View {
    let message: String

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: "sparkles")
                .foregroundStyle(.white)
                .padding(8)
                .background(AppColors.appPrimary, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("Heads-up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColors.appPrimary)
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(AppColors.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(AppSpacing.sm)
        .background(
            AppColors.appPrimary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: AppCornerRadius.medium)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppCornerRadius.medium)
                .strokeBorder(AppColors.appPrimary.opacity(0.25), lineWidth: 1)
        )
    }
}
