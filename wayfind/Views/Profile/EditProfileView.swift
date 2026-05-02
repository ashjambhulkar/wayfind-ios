import PhotosUI
import SwiftUI
import UIKit

private enum EditProfileLayout {
    static let avatarPreview: CGFloat = 96
    static let rowMinHeight: CGFloat = 56
    static let buttonMinHeight: CGFloat = 44
    static let avatarBorderWidth: CGFloat = 1
    static let cardBorderWidth: CGFloat = 0.5
    static let cardShadowRadius: CGFloat = 10
    static let cardShadowYOffset: CGFloat = 3
    static let avatarShadowRadius: CGFloat = 12
    static let avatarShadowYOffset: CGFloat = 4
    static let jpegQuality: CGFloat = 0.88
}

struct EditProfileView: View {
    var onSaved: (() -> Void)? = nil

    @Environment(DataService.self) private var dataService
    @Environment(AuthViewModel.self) private var authViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var loaded: UserProfileDetail?
    @State private var displayName = ""
    @State private var username = ""
    @State private var bio = ""
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var pickedAvatarJPEG: Data?
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var isDeletingAccount = false
    @State private var showDeleteAccountConfirm = false
    @State private var errorMessage: String?
    @State private var saveError: String?

    private var trimmedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isDirty: Bool {
        guard let loaded, !isLoading else { return false }
        if pickedAvatarJPEG != nil { return true }
        if displayName.trimmingCharacters(in: .whitespacesAndNewlines) != (loaded.displayName ?? "").trimmingCharacters(
            in: .whitespacesAndNewlines
        ) { return true }
        if trimmedUsername != loaded.username.trimmingCharacters(in: .whitespacesAndNewlines) { return true }
        if bio.trimmingCharacters(in: .whitespacesAndNewlines) != (loaded.bio ?? "").trimmingCharacters(
            in: .whitespacesAndNewlines
        ) { return true }
        return false
    }

    private var canSave: Bool {
        AppConfig.useRealBackend && !trimmedUsername.isEmpty && isDirty && !isSaving && !isDeletingAccount && loaded != nil
    }

    var body: some View {
        ScrollView {
            VStack(spacing: AppSpacing.lg) {
                if isLoading {
                    ProfileInfoBanner(
                        message: "Loading your profile...",
                        systemName: "person.crop.circle",
                        tint: AppColors.appPrimary,
                        showsProgress: true
                    )
                }

                if let errorMessage, !errorMessage.isEmpty, !isLoading {
                    ProfileInfoBanner(
                        message: errorMessage,
                        systemName: "exclamationmark.circle.fill",
                        tint: AppColors.appError
                    )
                }

                avatarSection

                identitySection

                accountSection

                if let saveError, !saveError.isEmpty {
                    ProfileInfoBanner(
                        message: saveError,
                        systemName: "exclamationmark.circle.fill",
                        tint: AppColors.appError
                    )
                }
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.vertical, AppSpacing.xl)
        }
        .scrollDismissesKeyboard(.interactively)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppColors.appBackground)
        .navigationTitle("Edit profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") {
                    Task { await saveAsync() }
                }
                .fontWeight(.semibold)
                .disabled(!canSave)
            }
        }
        .task {
            await loadProfile()
        }
        .task(id: photoPickerItem) {
            await loadPickedPhoto()
        }
        .refreshable {
            await loadProfile()
        }
        .disabled(!AppConfig.useRealBackend)
        .confirmationDialog(
            "Delete your account?",
            isPresented: $showDeleteAccountConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Account", role: .destructive) {
                Task { await deleteAccountAsync() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes your profile, trips, uploads, and sign-in account. This cannot be undone.")
        }
    }

    @ViewBuilder
    private var avatarSection: some View {
        ProfileMapSectionCard(title: nil) {
            VStack(spacing: AppSpacing.md) {
                avatarImage

                VStack(spacing: AppSpacing.xs) {
                    Text(displayNamePreview)
                        .font(.cardTitle.weight(.semibold))
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(1)

                    Text(usernamePreview)
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(1)
                }

                if AppConfig.useRealBackend {
                    HStack(spacing: AppSpacing.sm) {
                        PhotosPicker(selection: $photoPickerItem, matching: .images) {
                            Label("Choose photo", systemImage: "photo.on.rectangle.angled")
                                .font(.appBody.weight(.semibold))
                                .foregroundStyle(AppColors.appPrimary)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: EditProfileLayout.buttonMinHeight)
                                .background(AppColors.appPrimaryLight)
                                .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        if pickedAvatarJPEG != nil {
                            Button("Clear") {
                                photoPickerItem = nil
                                pickedAvatarJPEG = nil
                            }
                            .font(.appBody.weight(.semibold))
                            .foregroundStyle(AppColors.appError)
                            .frame(minHeight: EditProfileLayout.buttonMinHeight)
                            .padding(.horizontal, AppSpacing.md)
                            .background(AppColors.appError.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var avatarImage: some View {
        Group {
            if let pickedAvatarJPEG, let uiImage = UIImage(data: pickedAvatarJPEG) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else if let url = loaded?.avatarURL {
                CachedAvatarImage(
                    url: url,
                    showsProgressWhileLoading: true,
                    idle: { Color.clear },
                    onFailure: { avatarPlaceholder }
                )
            } else {
                avatarPlaceholder
            }
        }
        .frame(width: EditProfileLayout.avatarPreview, height: EditProfileLayout.avatarPreview)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(AppColors.appDivider, lineWidth: EditProfileLayout.avatarBorderWidth))
        .shadow(
            color: .black.opacity(0.08),
            radius: EditProfileLayout.avatarShadowRadius,
            x: 0,
            y: EditProfileLayout.avatarShadowYOffset
        )
    }

    private var avatarPlaceholder: some View {
        MapStyleIcon(
            systemName: "person.crop.circle",
            size: .large,
            accent: AppColors.textTertiary,
            backgroundStyle: .surface,
            accessibilityLabel: "Profile photo"
        )
        .frame(width: EditProfileLayout.avatarPreview, height: EditProfileLayout.avatarPreview)
        .background(AppColors.appSurface)
        .clipShape(Circle())
    }

    private var displayNamePreview: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return "Your profile"
    }

    private var usernamePreview: String {
        trimmedUsername.isEmpty ? "Choose a username" : "@\(trimmedUsername)"
    }

    private var identitySection: some View {
        ProfileMapSectionCard(title: "Profile") {
            ProfileMapTextRow(
                title: "Display name",
                subtitle: "This is how friends recognize you in the app.",
                systemName: "person.text.rectangle",
                accessibilityLabel: "Display name"
            ) {
                TextField("Enter display name", text: $displayName)
                    .textContentType(.name)
            }

            ProfileMapDivider()

            ProfileMapTextRow(
                title: "Username",
                subtitle: "Letters, numbers, and underscores work best.",
                systemName: "at",
                accessibilityLabel: "Username"
            ) {
                TextField("Choose a username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
            }

            ProfileMapDivider()

            ProfileMapTextRow(
                title: "Bio",
                subtitle: nil,
                systemName: "text.alignleft",
                accessibilityLabel: "Bio",
                alignment: .top
            ) {
                TextField("A short line about you - optional", text: $bio, axis: .vertical)
                    .lineLimit(3...8)
            }
        }
    }

    private var accountSection: some View {
        ProfileMapSectionCard(title: "Account") {
            Button(role: .destructive) {
                showDeleteAccountConfirm = true
            } label: {
                HStack(alignment: .center, spacing: AppSpacing.md) {
                    MapStyleIcon(
                        systemName: "trash.fill",
                        size: .small,
                        accent: AppColors.appError,
                        backgroundStyle: .soft,
                        accessibilityLabel: "Delete account"
                    )

                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text("Delete account")
                            .font(.appBody.weight(.semibold))
                            .foregroundStyle(AppColors.appError)

                        Text("Permanently remove your profile and app data.")
                            .font(.appCaption)
                            .foregroundStyle(AppColors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)

                    if isDeletingAccount {
                        ProgressView()
                            .tint(AppColors.appError)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.appCaption.weight(.semibold))
                            .foregroundStyle(AppColors.textTertiary)
                    }
                }
                .frame(minHeight: EditProfileLayout.rowMinHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isDeletingAccount)
        }
    }

    @MainActor
    private func loadProfile() async {
        errorMessage = nil
        guard AppConfig.useRealBackend else {
            isLoading = false
            errorMessage = "Profile editing is available when using the live backend."
            return
        }
        isLoading = true
        defer { isLoading = false }

        guard let detail = await dataService.fetchOwnUserProfileDetail() else {
            errorMessage = "Could not load your profile."
            return
        }
        loaded = detail
        displayName = detail.displayName ?? ""
        username = detail.username
        bio = detail.bio ?? ""
    }

    @MainActor
    private func loadPickedPhoto() async {
        guard let photoPickerItem else { return }
        saveError = nil
        do {
            guard let raw = try await photoPickerItem.loadTransferable(type: Data.self) else { return }
            guard
                let jpeg = UIImage(data: raw)?.jpegData(compressionQuality: EditProfileLayout.jpegQuality)
            else {
                saveError = ProfileSaveError.couldNotReadImage.localizedDescription
                return
            }
            pickedAvatarJPEG = jpeg
        } catch {
            saveError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @MainActor
    private func saveAsync() async {
        guard let loaded, canSave else { return }
        isSaving = true
        saveError = nil
        defer { isSaving = false }

        let dnTrim = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayNameValue: String? = dnTrim.isEmpty ? nil : dnTrim
        let bioTrim = bio.trimmingCharacters(in: .whitespacesAndNewlines)
        let bioValue: String? = bioTrim.isEmpty ? nil : bioTrim

        var avatarURL = loaded.avatarURLString
        if let jpeg = pickedAvatarJPEG {
            do {
                avatarURL = try await dataService.uploadProfileAvatar(imageData: jpeg, contentType: "image/jpeg")
            } catch {
                saveError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return
            }
        }

        do {
            try await dataService.updateUserProfile(
                displayName: displayNameValue,
                username: trimmedUsername,
                bio: bioValue,
                preferredAirport: loaded.preferredAirport,
                preferredCurrency: loaded.preferredCurrency,
                avatarURL: avatarURL,
                venmoUsername: loaded.venmoUsername,
                paypalUsername: loaded.paypalUsername
            )
        } catch {
            saveError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }

        let synthetic = UserProfileDetail(
            id: loaded.id,
            username: trimmedUsername,
            displayName: displayNameValue,
            avatarURLString: avatarURL,
            bio: bioValue,
            preferredAirport: loaded.preferredAirport,
            preferredCurrency: loaded.preferredCurrency,
            createdAt: loaded.createdAt,
            venmoUsername: loaded.venmoUsername,
            paypalUsername: loaded.paypalUsername
        )
        authViewModel.currentUserName = ProfileHeroFormatting.primaryLine(
            detail: synthetic,
            email: authViewModel.currentUserEmail
        )
        authViewModel.currentUserAvatarURLString = avatarURL

        pickedAvatarJPEG = nil
        photoPickerItem = nil
        onSaved?()
        dismiss()
    }

    @MainActor
    private func deleteAccountAsync() async {
        guard !isDeletingAccount else { return }
        isDeletingAccount = true
        saveError = nil
        defer { isDeletingAccount = false }

        do {
            try await authViewModel.deleteAccount()
            dismiss()
        } catch {
            saveError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

private struct ProfileMapSectionCard<Content: View>: View {
    let title: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            if let title {
                Text(title)
                    .font(.appCaption.weight(.semibold))
                    .foregroundStyle(AppColors.textSecondary)
                    .textCase(.uppercase)
                    .kerning(0.5)
                    .padding(.horizontal, AppSpacing.xs)
            }

            VStack(spacing: 0) {
                content()
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.vertical, AppSpacing.md)
            .background(AppColors.appSurface)
            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                    .strokeBorder(AppColors.appDivider.opacity(0.85), lineWidth: EditProfileLayout.cardBorderWidth)
            )
            .shadow(
                color: .black.opacity(0.04),
                radius: EditProfileLayout.cardShadowRadius,
                x: 0,
                y: EditProfileLayout.cardShadowYOffset
            )
        }
    }
}

private struct ProfileMapDivider: View {
    var body: some View {
        Divider()
            .background(AppColors.appDivider)
            .padding(.leading, MapStyleIconSize.small.length + AppSpacing.md)
            .padding(.vertical, AppSpacing.xs)
    }
}

private struct ProfileMapTextRow<Content: View>: View {
    let title: String
    let subtitle: String?
    let systemName: String
    let accessibilityLabel: String
    var accent: Color = AppColors.appPrimary
    var alignment: VerticalAlignment = .center
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: alignment, spacing: AppSpacing.md) {
            MapStyleIcon(
                systemName: systemName,
                size: .small,
                accent: accent,
                accessibilityLabel: accessibilityLabel
            )

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(title)
                    .font(.appBody.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)

                content()
                    .font(.appBody)
                    .foregroundStyle(AppColors.textPrimary)
                    .textFieldStyle(.plain)

                if let subtitle {
                    Text(subtitle)
                        .font(.appCaption)
                        .foregroundStyle(AppColors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: EditProfileLayout.rowMinHeight, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct ProfileInfoBanner: View {
    let message: String
    let systemName: String
    let tint: Color
    var showsProgress = false

    var body: some View {
        HStack(alignment: .center, spacing: AppSpacing.md) {
            if showsProgress {
                ProgressView()
                    .tint(tint)
                    .frame(width: MapStyleIconSize.small.length, height: MapStyleIconSize.small.length)
            } else {
                MapStyleIcon(
                    systemName: systemName,
                    size: .small,
                    accent: tint,
                    backgroundStyle: .soft,
                    accessibilityLabel: message
                )
            }

            Text(message)
                .font(.appCaption)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(AppSpacing.md)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                .strokeBorder(tint.opacity(0.18), lineWidth: EditProfileLayout.cardBorderWidth)
        )
    }
}


// =============================================================================

