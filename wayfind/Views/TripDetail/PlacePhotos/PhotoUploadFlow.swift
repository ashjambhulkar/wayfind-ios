//
//  PhotoUploadFlow.swift
//  wayfind
//
//  Phase F.6 — Surfaces the user-photo upload journey on top of
//  PlaceDetailSheet's photo carousel:
//
//   1. First-time onboarding modal with the license-grant sentence.
//      Stored in `@AppStorage("hasSeenPhotoUploadOnboarding")` so we
//      only show it once per device.
//   2. Native PhotosPicker for selection. Reads EXIF GPS when present
//      (soft signal for moderation).
//   3. Hands the bytes to `PlacePhotoUploadService` which owns the
//      pre-screen → upload → moderate state machine.
//   4. Renders a transient progress strip + final outcome toast.
//

import CoreLocation
import ImageIO
import PhotosUI
import SwiftUI

struct PhotoUploadFlowView: View {
    let cityPlaceId: UUID
    let placeName: String
    var onUploadFinished: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(DataService.self) private var dataService
    @AppStorage("hasSeenPhotoUploadOnboarding")
    private var hasSeenOnboarding: Bool = false

    @State private var pickerItem: PhotosPickerItem?
    @State private var showOnboarding: Bool = false
    @State private var pendingUpload: PendingUpload?
    @State private var inlineError: String?
    @State private var uploadService: PlacePhotoUploadService?
    @State private var appealSheetPhoto: AppealTarget?

    private struct AppealTarget: Identifiable {
        let id: UUID
        let reason: String?
        let detail: String?
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                heroIllustration
                copyBlock
                if !FeatureFlagsService.shared.userPhotosEnabled {
                    // Phase G.2 — `flag_user_photos` kill-switch.
                    // Surface a calm, non-error message instead of
                    // hiding the whole sheet so users who tapped the
                    // upload affordance from a different surface
                    // (e.g. an old deep link) still understand why.
                    photosDisabledNotice
                } else if let pending = pendingUpload {
                    statusStrip(for: pending)
                } else {
                    PhotosPicker(
                        selection: $pickerItem,
                        matching: .images,
                        photoLibrary: .shared()
                    ) {
                        primaryButtonLabel
                    }
                    .buttonStyle(.plain)
                    .disabled(uploadService == nil)
                }
                if let inlineError {
                    Text(inlineError)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppColors.appError)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                Spacer()
                guidelinesFooter
            }
            .padding(.top, 16)
            .navigationTitle("Add a photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showOnboarding) {
                PhotoUploadOnboardingSheet {
                    hasSeenOnboarding = true
                    showOnboarding = false
                }
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
            .sheet(item: $appealSheetPhoto) { target in
                PhotoAppealSheet(
                    photoId: target.id,
                    originalReason: target.reason,
                    originalDetail: target.detail
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
        .task {
            if uploadService == nil {
                uploadService = PlacePhotoUploadService(dataService: dataService)
            }
        }
        .onChange(of: pickerItem) { _, newValue in
            guard newValue != nil else { return }
            if !hasSeenOnboarding {
                showOnboarding = true
            }
            handlePickedPhoto()
        }
    }

    // MARK: – Picked photo handler

    private func handlePickedPhoto() {
        guard let item = pickerItem, let service = uploadService else { return }
        inlineError = nil
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    inlineError = "Couldn't read that photo. Try a different one."
                    return
                }
                let exif = Self.extractExifLatLng(from: data)
                let pending = await service.upload(
                    imageData: data,
                    cityPlaceId: cityPlaceId,
                    placeName: placeName,
                    exifLat: exif?.lat,
                    exifLng: exif?.lng
                )
                self.pendingUpload = pending
            } catch {
                inlineError = error.localizedDescription
            }
        }
    }

    // MARK: – Subviews

    private var heroIllustration: some View {
        ZStack {
            Circle()
                .fill(AppColors.appPrimaryLight)
                .frame(width: 96, height: 96)
            Image(systemName: "camera.macro")
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(AppColors.appPrimary)
        }
        .padding(.top, 8)
    }

    private var photosDisabledNotice: some View {
        VStack(spacing: 10) {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(AppColors.appWarning)
                .accessibilityHidden(true)
            Text("Photo uploads are paused")
                .font(.system(size: 15, weight: .semibold))
            Text("We've temporarily turned off new uploads while we work on improvements. Please check back later.")
                .font(.system(size: 13))
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .padding(.vertical, 8)
        // Phase G.4 — VoiceOver should hear this as one calm
        // message, not three separate elements ("pause icon",
        // "Photo uploads are paused", body text).
        .accessibilityElement(children: .combine)
    }

    private var copyBlock: some View {
        VStack(spacing: 8) {
            Text("Help others discover \(placeName)")
                .font(.system(size: 20, weight: .semibold))
                .multilineTextAlignment(.center)
            Text("Photos are reviewed before publishing. Don't post photos with identifiable faces or content that violates our guidelines.")
                .font(.system(size: 14))
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    private var primaryButtonLabel: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 14, weight: .semibold))
                .accessibilityHidden(true)
            Text("Choose a photo")
                .font(.system(size: 15, weight: .semibold))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 50)
        .foregroundStyle(.white)
        .background(AppColors.appPrimary)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
        .padding(.horizontal, 24)
        .accessibilityLabel(Text("Choose a photo"))
        .accessibilityHint(Text("Opens your photo library to pick an image to upload"))
    }

    @ViewBuilder
    private func statusStrip(for pending: PendingUpload) -> some View {
        VStack(spacing: 10) {
            switch pending.status {
            case .prescreening:
                rowIndicator(text: "Checking photo…", systemImage: "wand.and.stars")
            case .uploading(let progress):
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(AppColors.appPrimary)
                    .padding(.horizontal, 24)
                Text("Uploading…").font(.system(size: 12)).foregroundStyle(AppColors.textTertiary)
            case .awaitingModeration:
                rowIndicator(text: "Reviewing your photo…", systemImage: "eye")
            case .approved(let url):
                approvedBlock(url: url)
            case .pendingReview(let reason):
                pendingReviewBlock(reason: reason)
            case .rejected(let reason, let detail):
                rejectedBlock(
                    reason: reason,
                    detail: detail,
                    photoId: pending.serverPhotoId
                )
            case .failed(let message):
                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppColors.appError)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
    }

    private func rowIndicator(text: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Image(systemName: systemImage)
                .foregroundStyle(AppColors.textTertiary)
                .accessibilityHidden(true)
            Text(text).font(.system(size: 14, weight: .medium))
                .foregroundStyle(AppColors.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func approvedBlock(url: URL) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 32))
                .foregroundStyle(AppColors.appSuccess)
                .accessibilityHidden(true)
            Text("Live now")
                .font(.system(size: 18, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Thanks for sharing — your photo is up.")
                .font(.system(size: 13))
                .foregroundStyle(AppColors.textSecondary)
            Button("Done") {
                onUploadFinished()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .tint(AppColors.appPrimary)
        }
    }

    private func pendingReviewBlock(reason: String?) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.badge.checkmark")
                .font(.system(size: 32))
                .foregroundStyle(AppColors.appWarning)
                .accessibilityHidden(true)
            Text("Awaiting review")
                .font(.system(size: 18, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text(reason == "identifiable_face"
                 ? "We'll publish this once a moderator confirms there are no identifiable faces."
                 : "Our team will take a look. You'll get a notification once it's reviewed.")
                .font(.system(size: 13))
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("OK") { dismiss() }
                .buttonStyle(.bordered)
        }
    }

    private func rejectedBlock(reason: String, detail: String?, photoId: UUID?) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(AppColors.appError)
                .accessibilityHidden(true)
            Text("Couldn't accept this photo")
                .font(.system(size: 18, weight: .semibold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            HStack(spacing: 10) {
                Button("Try a different photo") {
                    pendingUpload = nil
                    pickerItem = nil
                }
                .buttonStyle(.bordered)
                if let photoId {
                    Button("Appeal decision") {
                        appealSheetPhoto = AppealTarget(
                            id: photoId,
                            reason: reason,
                            detail: detail
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppColors.appPrimary)
                }
            }
        }
    }

    private var guidelinesFooter: some View {
        Text("By uploading you grant us a worldwide, non-exclusive license to use, display, and distribute your photo on Wayfind.")
            .font(.system(size: 11))
            .foregroundStyle(AppColors.textTertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .padding(.bottom, 18)
    }

    // MARK: – EXIF extraction

    /// Returns the embedded GPS lat/lng when the user has explicitly
    /// included location metadata via the iOS share sheet ("Include
    /// Location"). PHPicker strips these defaults to false in iOS 14+,
    /// so this is a *soft* signal — see Section 7.2 of the plan.
    private static func extractExifLatLng(from data: Data) -> (lat: Double, lng: Double)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
              let lng = gps[kCGImagePropertyGPSLongitude] as? Double,
              let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String,
              let lngRef = gps[kCGImagePropertyGPSLongitudeRef] as? String
        else { return nil }
        let signedLat = latRef == "S" ? -lat : lat
        let signedLng = lngRef == "W" ? -lng : lng
        return (signedLat, signedLng)
    }
}

// MARK: – Onboarding sheet (shown once)

private struct PhotoUploadOnboardingSheet: View {
    var onContinue: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Capsule()
                .fill(AppColors.appDivider)
                .frame(width: 36, height: 4)
                .padding(.top, 8)
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 30))
                .foregroundStyle(AppColors.appPrimary)
                .padding(.top, 8)
            Text("Before you upload")
                .font(.system(size: 22, weight: .semibold))
            VStack(alignment: .leading, spacing: 14) {
                bullet(
                    "person.crop.circle.badge.xmark",
                    "Don't post photos with identifiable faces of people who haven't consented."
                )
                bullet(
                    "shield.lefthalf.filled",
                    "Reviewed by our team. Inappropriate content is rejected and may lock the account."
                )
                bullet(
                    "photo.on.rectangle",
                    "By uploading you grant Wayfind a worldwide, non-exclusive license to display the photo."
                )
            }
            .padding(.horizontal, 24)
            Spacer()
            Button {
                onContinue()
            } label: {
                Text("I understand — Continue")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .foregroundStyle(.white)
                    .background(AppColors.appPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
                    .padding(.horizontal, 24)
            }
            .padding(.bottom, 18)
        }
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(AppColors.appPrimary)
                .frame(width: 22)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(AppColors.textSecondary)
        }
    }
}
