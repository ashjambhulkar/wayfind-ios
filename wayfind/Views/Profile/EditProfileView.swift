import PhotosUI
import SwiftUI
import UIKit

private enum EditProfileLayout {
    static let airportMaxLen = 24
    static let avatarPreview: CGFloat = 96
    static let jpegQuality: CGFloat = 0.88
}

struct EditProfileView: View {
    @Environment(DataService.self) private var dataService
    @Environment(AuthViewModel.self) private var authViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var loaded: UserProfileDetail?
    @State private var displayName = ""
    @State private var username = ""
    @State private var bio = ""
    @State private var preferredAirport = ""
    @State private var preferredCurrency = ""
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var pickedAvatarJPEG: Data?
    @State private var isLoading = true
    @State private var isSaving = false
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
        let ap = preferredAirport.trimmingCharacters(in: .whitespacesAndNewlines)
        if ap != (loaded.preferredAirport ?? "").trimmingCharacters(in: .whitespacesAndNewlines) { return true }
        let nextCur = (PreferredCurrencyFormatting.normalizeInput(preferredCurrency) ?? "").uppercased()
        let prevCur = (loaded.preferredCurrency ?? "").uppercased()
        if nextCur != prevCur { return true }
        return false
    }

    private var canSave: Bool {
        AppConfig.useRealBackend && !trimmedUsername.isEmpty && isDirty && !isSaving && loaded != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppSpacing.xl)
                }

                if let errorMessage, !errorMessage.isEmpty, !isLoading {
                    Text(errorMessage)
                        .font(.appCaption)
                        .foregroundStyle(AppColors.appError)
                }

                avatarSection

                labeledField(title: "Display name", hint: "This is how friends recognize you in the app.") {
                    TextField("Enter display name", text: $displayName)
                        .textContentType(.name)
                }

                labeledField(title: "Username", hint: "Letters, numbers, and underscores work best.") {
                    TextField("Choose a username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                }

                labeledField(title: "Bio", hint: nil) {
                    TextField("A short line about you — optional", text: $bio, axis: .vertical)
                        .lineLimit(3...8)
                }

                labeledField(title: "Home airport", hint: "Used as a default when planning.") {
                    TextField("e.g. SFO", text: $preferredAirport)
                        .textInputAutocapitalization(.characters)
                        .onChange(of: preferredAirport) { _, newValue in
                            let upper = newValue.uppercased()
                            if upper.count > EditProfileLayout.airportMaxLen {
                                preferredAirport = String(upper.prefix(EditProfileLayout.airportMaxLen))
                            } else if upper != newValue {
                                preferredAirport = upper
                            }
                        }
                }

                currencySection

                if let saveError, !saveError.isEmpty {
                    Text(saveError)
                        .font(.appCaption)
                        .foregroundStyle(AppColors.appError)
                }
            }
            .padding(AppSpacing.xl)
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
    }

    @ViewBuilder
    private var avatarSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Photo")
                .font(.appCaption)
                .foregroundStyle(AppColors.textSecondary)

            Group {
                if let pickedAvatarJPEG, let uiImage = UIImage(data: pickedAvatarJPEG) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                } else if let url = loaded?.avatarURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .empty:
                            ProgressView()
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                        case .failure:
                            avatarPlaceholder
                        @unknown default:
                            EmptyView()
                        }
                    }
                } else {
                    avatarPlaceholder
                }
            }
            .frame(width: EditProfileLayout.avatarPreview, height: EditProfileLayout.avatarPreview)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(AppColors.appDivider, lineWidth: 1))

            if AppConfig.useRealBackend {
                HStack(spacing: AppSpacing.md) {
                    PhotosPicker(selection: $photoPickerItem, matching: .images) {
                        Label("Choose photo", systemImage: "photo.on.rectangle.angled")
                            .font(.appBody)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(AppColors.appSurface)
                            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                                    .strokeBorder(AppColors.appDivider, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)

                    if pickedAvatarJPEG != nil {
                        Button("Clear") {
                            photoPickerItem = nil
                            pickedAvatarJPEG = nil
                        }
                        .font(.appBody)
                        .foregroundStyle(AppColors.appPrimary)
                    }
                }
            }
        }
    }

    private var avatarPlaceholder: some View {
        Circle()
            .fill(AppColors.appSurface)
            .overlay {
                Image(systemName: "person.crop.circle")
                    .font(.largeTitle)
                    .foregroundStyle(AppColors.textTertiary)
            }
    }

    private var currencySection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("Preferred currency")
                .font(.appCaption)
                .foregroundStyle(AppColors.textSecondary)
            TextField("ISO code, e.g. USD", text: $preferredCurrency)
                .font(.appBody)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .padding(.horizontal, AppSpacing.md)
                .frame(height: 48)
                .background(AppColors.appSurface)
                .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                        .strokeBorder(AppColors.appDivider, lineWidth: 1)
                )
                .onChange(of: preferredCurrency) { _, newValue in
                    let upper = newValue.uppercased().filter(\.isLetter)
                    let capped = String(upper.prefix(PreferredCurrencyFormatting.codeMaxLength))
                    if capped != newValue {
                        preferredCurrency = capped
                    }
                }
            Menu {
                ForEach(Array(PreferredCurrencyFormatting.presetCycle.enumerated()), id: \.offset) { _, code in
                    Button(PreferredCurrencyFormatting.displayLabel(code: code)) {
                        preferredCurrency = code ?? ""
                    }
                }
            } label: {
                Text("Presets")
                    .font(.appBody)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(AppColors.appSurface)
                    .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                            .strokeBorder(AppColors.appDivider, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            Text("Used as defaults when planning; you can still set currency per trip.")
                .font(.appCaption)
                .foregroundStyle(AppColors.textTertiary)
        }
    }

    private func labeledField(title: String, hint: String?, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(title)
                .font(.appCaption)
                .foregroundStyle(AppColors.textSecondary)
            content()
                .font(.appBody)
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, AppSpacing.sm)
                .frame(minHeight: 48, alignment: .leading)
                .background(AppColors.appSurface)
                .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                        .strokeBorder(AppColors.appDivider, lineWidth: 1)
                )
            if let hint {
                Text(hint)
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textTertiary)
            }
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
        preferredAirport = detail.preferredAirport ?? ""
        preferredCurrency = detail.preferredCurrency ?? ""
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
        let airportTrim = preferredAirport.trimmingCharacters(in: .whitespacesAndNewlines)
        let airportValue: String? = airportTrim.isEmpty
            ? nil
            : String(airportTrim.uppercased().prefix(EditProfileLayout.airportMaxLen))
        let currencyValue = PreferredCurrencyFormatting.normalizeInput(preferredCurrency)

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
                preferredAirport: airportValue,
                preferredCurrency: currencyValue,
                avatarURL: avatarURL
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
            preferredAirport: airportValue,
            preferredCurrency: currencyValue,
            createdAt: loaded.createdAt
        )
        authViewModel.currentUserName = ProfileHeroFormatting.primaryLine(
            detail: synthetic,
            email: authViewModel.currentUserEmail
        )

        pickedAvatarJPEG = nil
        photoPickerItem = nil
        dismiss()
    }
}
