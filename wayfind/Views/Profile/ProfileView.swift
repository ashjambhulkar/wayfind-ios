import SwiftUI

struct ProfileView: View {
    @Environment(AuthViewModel.self) private var authViewModel
    @Environment(DataService.self) private var dataService
    @Environment(UserPreferencesStore.self) private var userPreferences
    @Environment(TabNavigationCoordinator.self) private var coordinator
    @Environment(ToastManager.self) private var toastManager
    @Environment(\.dismiss) private var dismiss

    @State private var profileDetail: UserProfileDetail?
    @State private var trips: [Trip] = []
    @State private var aggregateStats = ProfileAggregateStats.empty
    @State private var isLoading = false
    @State private var initialLoadComplete = false
    @State private var showEditProfile = false
    @State private var isSavingPreferredCurrency = false
    @State private var legalDocumentToBrowse: LegalDocumentSelection?

    private var spotlight: (trip: Trip, kind: ProfileTripBucketing.SpotlightKind)? {
        ProfileTripBucketing.pickProfileSpotlight(from: trips)
    }

    private var appVersionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        if let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String, build != short {
            return "\(short) (\(build))"
        }
        return short
    }

    private var primaryLine: String {
        ProfileHeroFormatting.primaryLine(detail: profileDetail, email: authViewModel.currentUserEmail)
    }

    private var usernameLine: String? {
        ProfileHeroFormatting.usernameLine(detail: profileDetail)
    }

    private var heroInitials: String {
        ProfileHeroFormatting.initialsForHero(detail: profileDetail, email: authViewModel.currentUserEmail)
    }

    private var joinedLine: String? {
        ProfileHeroFormatting.joinedSubtitle(createdAt: profileDetail?.createdAt)
    }

    private var tripSummaryLine: String {
        ProfileHeroFormatting.tripSummaryLine(
            tripCount: aggregateStats.tripCount,
            upcomingOrActiveCount: aggregateStats.upcomingOrActiveCount
        )
    }

    private var preferredCurrencyMenuLabel: String {
        PreferredCurrencyFormatting.displayLabel(code: profileDetail?.preferredCurrency)
    }

    private var preferredCurrencyRowIsPlaceholder: Bool {
        (profileDetail?.preferredCurrency ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var preferredCurrencyMenuCodes: [String] {
        var codes = MoneyField.commonCurrencies
        let trimmed = (profileDetail?.preferredCurrency ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !trimmed.isEmpty, !codes.contains(trimmed) {
            codes.insert(trimmed, at: 0)
        }
        return codes
    }

    var body: some View {
        ScrollView {
            VStack(spacing: AppSpacing.xl) {
                userCard

                tripSpotlightSection

                statsSection

                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    Text("TRAVEL")
                        .font(.appSmall)
                        .foregroundStyle(AppColors.textTertiary)
                        .textCase(.uppercase)
                        .tracking(1.5)

                    VStack(spacing: 0) {
                        if AppConfig.useRealBackend {
                            HStack(alignment: .center, spacing: AppSpacing.md) {
                                Text("Preferred currency")
                                    .font(.cardTitle)
                                    .foregroundStyle(AppColors.textPrimary)

                                Spacer(minLength: AppSpacing.md)

                                Menu {
                                    Button(PreferredCurrencyFormatting.displayLabel(code: nil)) {
                                        Task { await savePreferredCurrency(nil) }
                                    }
                                    ForEach(preferredCurrencyMenuCodes, id: \.self) { code in
                                        Button(code) {
                                            Task { await savePreferredCurrency(code) }
                                        }
                                    }
                                } label: {
                                    HStack(spacing: AppSpacing.xs) {
                                        if isSavingPreferredCurrency {
                                            ProgressView()
                                                .scaleEffect(0.9)
                                        } else {
                                            Text(preferredCurrencyMenuLabel)
                                                .font(.appCaption.weight(.semibold))
                                                .foregroundStyle(
                                                    preferredCurrencyRowIsPlaceholder
                                                        ? AppColors.textTertiary
                                                        : AppColors.textPrimary
                                                )
                                            Image(systemName: "chevron.up.chevron.down")
                                                .font(.appSmall.weight(.semibold))
                                                .foregroundStyle(AppColors.textSecondary)
                                        }
                                    }
                                    .padding(.horizontal, AppSpacing.sm)
                                    .padding(.vertical, AppSpacing.xs)
                                    .background(AppColors.appBackground)
                                    .clipShape(Capsule())
                                }
                                .disabled(
                                    profileDetail == nil
                                        || !initialLoadComplete
                                        || isSavingPreferredCurrency
                                )
                                .accessibilityLabel("Currency: \(preferredCurrencyMenuLabel)")
                            }
                            .padding(.horizontal, AppSpacing.lg)
                            .padding(.vertical, AppSpacing.md)

                            Divider()
                                .background(AppColors.appDivider)
                        }

                        Button {
                            userPreferences.cycleMapsApp()
                        } label: {
                            HStack {
                                Text("Maps")
                                    .font(.cardTitle)
                                    .foregroundStyle(AppColors.textPrimary)
                                Spacer()
                                Text(userPreferences.mapsAppPreference.menuTitle)
                                    .font(.appBody)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(AppColors.textSecondary)
                            }
                            .padding(.horizontal, AppSpacing.lg)
                            .padding(.vertical, AppSpacing.md)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .background(AppColors.appSurface)
                    .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
                }

                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    Text("APP")
                        .font(.appSmall)
                        .foregroundStyle(AppColors.textTertiary)
                        .textCase(.uppercase)
                        .tracking(1.5)

                    VStack(spacing: 0) {
                        HStack {
                            Text("Sort trips by")
                                .font(.cardTitle)
                                .foregroundStyle(AppColors.textPrimary)
                            Spacer()
                            Picker(
                                "Sort trips by",
                                selection: Binding(
                                    get: { userPreferences.tripSortMode },
                                    set: { userPreferences.tripSortMode = $0 }
                                )
                            ) {
                                ForEach(TripListSortMode.allCases) { option in
                                    Text(option.menuTitle)
                                        .tag(option)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .font(.appBody)
                            .foregroundStyle(AppColors.textPrimary)
                            .tint(AppColors.appPrimary)
                        }
                        .padding(.horizontal, AppSpacing.lg)
                        .padding(.vertical, AppSpacing.md)

                        Divider()
                            .background(AppColors.appDivider)

                        HStack {
                            Text("Appearance")
                                .font(.cardTitle)
                                .foregroundStyle(AppColors.textPrimary)
                            Spacer()
                            Picker(
                                "Appearance",
                                selection: Binding(
                                    get: { userPreferences.appearancePreference },
                                    set: { userPreferences.appearancePreference = $0 }
                                )
                            ) {
                                ForEach(WayfindAppearancePreference.allCases) { option in
                                    Text(option.menuTitle)
                                        .tag(option)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .font(.appBody)
                            .foregroundStyle(AppColors.textPrimary)
                            .tint(AppColors.appPrimary)
                        }
                        .padding(.horizontal, AppSpacing.lg)
                        .padding(.vertical, AppSpacing.md)
                    }
                    .background(AppColors.appSurface)
                    .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
                }

                ProSubscriptionSection()

                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    Text("ABOUT")
                        .font(.appSmall)
                        .foregroundStyle(AppColors.textTertiary)
                        .textCase(.uppercase)
                        .tracking(1.5)

                    VStack(spacing: 0) {
                        HStack {
                            Text("Version")
                                .font(.cardTitle)
                                .foregroundStyle(AppColors.textPrimary)
                            Spacer()
                            Text(appVersionString)
                                .font(.appBody)
                                .foregroundStyle(AppColors.textTertiary)
                        }
                        .padding(.horizontal, AppSpacing.lg)
                        .padding(.vertical, AppSpacing.md)

                        Divider()
                            .background(AppColors.appDivider)

                        legalRow(selection: .privacyPolicy)

                        Divider()
                            .background(AppColors.appDivider)

                        legalRow(selection: .termsOfService)
                    }
                    .background(AppColors.appSurface)
                    .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
                }

                AppButton(title: "Sign Out", style: .destructive) {
                    Task {
                        await authViewModel.signOut()
                    }
                }
            }
            .padding(.horizontal, AppSpacing.lg)
        }
        .background(AppColors.appBackground)
        .navigationTitle("Profile")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if AppConfig.useRealBackend {
                    Button("Edit") {
                        showEditProfile = true
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .navigationDestination(isPresented: $showEditProfile) {
            EditProfileView {
                Task { await reload() }
            }
        }
        .sheet(item: $legalDocumentToBrowse) { selection in
            if let url = selection.url {
                InAppLegalSafariView(url: url) {
                    legalDocumentToBrowse = nil
                }
                .ignoresSafeArea()
            }
        }
        .onAppear {
            Task { await reload() }
        }
        .refreshable { await reload() }
    }

    @ViewBuilder
    private var tripSpotlightSection: some View {
        if initialLoadComplete {
            if let spot = spotlight {
                Button {
                    coordinator.openTrip(spot.trip)
                } label: {
                    tripSpotlightCard(kind: spot.kind, trip: spot.trip)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    dismiss()
                } label: {
                    tripSpotlightEmptyCard()
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func tripSpotlightCard(kind: ProfileTripBucketing.SpotlightKind, trip: Trip) -> some View {
        let title = ProfileTripDisplayFormatting.destinationTitle(destination: trip.destination, tripTitle: trip.title)
        let dates = ProfileTripDisplayFormatting.dateRangeLine(start: trip.startDate, end: trip.endDate)
        let kindLabel = kind == .current ? "Current trip" : "Upcoming trip"
        return VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(kindLabel)
                .font(.appCaption)
                .fontWeight(.semibold)
                .foregroundStyle(AppColors.textSecondary)
                .tracking(0.4)
            Text(title)
                .font(.cardTitle)
                .foregroundStyle(AppColors.textPrimary)
                .lineLimit(2)
            Text(dates)
                .font(.appBody)
                .foregroundStyle(AppColors.textSecondary)
                .lineLimit(2)
            Divider()
                .background(AppColors.appDivider.opacity(0.35))
                .padding(.top, AppSpacing.sm)
            HStack {
                Text("Open trip")
                    .font(.appCaption)
                    .fontWeight(.semibold)
                    .foregroundStyle(AppColors.textTertiary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColors.textTertiary)
            }
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.appPrimaryLight)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                .strokeBorder(AppColors.appPrimary.opacity(0.25), lineWidth: 1)
        )
    }

    private func tripSpotlightEmptyCard() -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text("No upcoming trips")
                .font(.cardTitle)
                .foregroundStyle(AppColors.textPrimary)
            Text("Start planning your next trip")
                .font(.appBody)
                .foregroundStyle(AppColors.textSecondary)
            Divider()
                .background(AppColors.appDivider.opacity(0.35))
                .padding(.top, AppSpacing.sm)
            HStack {
                Text("Browse trips")
                    .font(.appCaption)
                    .fontWeight(.semibold)
                    .foregroundStyle(AppColors.textTertiary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColors.textTertiary)
            }
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.appPrimaryLight)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                .strokeBorder(AppColors.appPrimary.opacity(0.25), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var statsSection: some View {
        if initialLoadComplete {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Text("STATS")
                    .font(.appSmall)
                    .foregroundStyle(AppColors.textTertiary)
                    .textCase(.uppercase)
                    .tracking(1.5)
                HStack(spacing: 0) {
                    statsCell(value: aggregateStats.tripCount, label: "Trips", a11y: "Trips")
                    statsDivider
                    statsCell(value: aggregateStats.upcomingOrActiveCount, label: "Upcoming", a11y: "Upcoming trips")
                    statsDivider
                    statsCell(value: aggregateStats.distinctPlaceCount, label: "Places", a11y: "Places saved on timeline")
                    statsDivider
                    statsCell(value: aggregateStats.importedBookingCount, label: "Imported", a11y: "Bookings imported from email or files")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpacing.lg)
                .background(AppColors.appPrimaryLight)
                .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
                .shadow(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 2)
            }
        }
    }

    private func statsCell(value: Int, label: String, a11y: String) -> some View {
        VStack(alignment: .center, spacing: AppSpacing.xs) {
            Text("\(value)")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(AppColors.textPrimary)
                .accessibilityLabel("\(a11y): \(value)")
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(AppColors.textTertiary)
                .tracking(0.35)
                .multilineTextAlignment(.center)
                .textCase(.uppercase)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, AppSpacing.sm)
    }

    private var statsDivider: some View {
        Rectangle()
            .fill(AppColors.appPrimary.opacity(0.12))
            .frame(width: 1)
            .padding(.vertical, AppSpacing.md)
    }

    private func legalRow(selection: LegalDocumentSelection) -> some View {
        Button {
            legalDocumentToBrowse = selection
        } label: {
            HStack {
                Text(selection.menuTitle)
                    .font(.cardTitle)
                    .foregroundStyle(AppColors.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppSpacing.lg)
            .padding(.vertical, AppSpacing.md)
        }
        .buttonStyle(.plain)
        .disabled(selection.url == nil)
    }

    private func reload() async {
        isLoading = true
        defer {
            isLoading = false
            initialLoadComplete = true
        }
        async let detail = dataService.fetchOwnUserProfileDetail()
        async let tripList = dataService.fetchTrips()
        async let stats = dataService.fetchProfileAggregateStats()
        let (d, t, s) = await (detail, tripList, stats)
        profileDetail = d
        trips = t
        aggregateStats = s
    }

    @MainActor
    private func savePreferredCurrency(_ rawCode: String?) async {
        guard let detail = profileDetail else { return }
        let normalized: String? = rawCode.flatMap { PreferredCurrencyFormatting.normalizeInput($0) }
        let username = detail.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else {
            toastManager.show(ToastData(message: "Profile isn’t ready yet. Try again.", type: .error))
            return
        }

        let current = (detail.preferredCurrency ?? "").uppercased()
        let next = (normalized ?? "").uppercased()
        guard current != next else { return }

        isSavingPreferredCurrency = true
        defer { isSavingPreferredCurrency = false }

        do {
            try await dataService.updateUserProfile(
                displayName: detail.displayName,
                username: username,
                bio: detail.bio,
                preferredAirport: detail.preferredAirport,
                preferredCurrency: normalized,
                avatarURL: detail.avatarURLString,
                venmoUsername: detail.venmoUsername,
                paypalUsername: detail.paypalUsername
            )
            profileDetail = UserProfileDetail(
                id: detail.id,
                username: detail.username,
                displayName: detail.displayName,
                avatarURLString: detail.avatarURLString,
                bio: detail.bio,
                preferredAirport: detail.preferredAirport,
                preferredCurrency: normalized,
                createdAt: detail.createdAt,
                venmoUsername: detail.venmoUsername,
                paypalUsername: detail.paypalUsername
            )
            toastManager.show(ToastData(message: String(localized: "Currency saved"), type: .success))
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            toastManager.show(ToastData(message: message, type: .error))
        }
    }

    private var userCard: some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            avatarView
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                if !initialLoadComplete {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, AppSpacing.md)
                } else {
                    Text(primaryLine)
                        .font(.appBody)
                        .fontWeight(.semibold)
                        .foregroundStyle(AppColors.textPrimary)

                    if let usernameLine {
                        Text(usernameLine)
                            .font(.appCaption)
                            .fontWeight(.medium)
                            .foregroundStyle(AppColors.textSecondary)
                    }

                    if let joinedLine {
                        Text(joinedLine)
                            .font(.appCaption)
                            .foregroundStyle(AppColors.textSecondary)
                    }

                    Text(tripSummaryLine)
                        .font(.appCaption)
                        .fontWeight(.semibold)
                        .foregroundStyle(AppColors.textPrimary)
                        .padding(.top, AppSpacing.xs)

                    if let bio = profileDetail?.bio?.trimmingCharacters(in: .whitespacesAndNewlines), !bio.isEmpty {
                        Text(bio)
                            .font(.appCaption)
                            .foregroundStyle(AppColors.textTertiary)
                            .lineSpacing(3)
                            .lineLimit(4)
                            .padding(.top, AppSpacing.sm)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
    }

    @ViewBuilder
    private var avatarView: some View {
        if let url = profileDetail?.avatarURL {
            CachedAvatarImage(url: url, showsProgressWhileLoading: true) {
                avatarPlaceholder
            }
            .clipShape(Circle())
        } else {
            avatarPlaceholder
        }
    }

    private var avatarPlaceholder: some View {
        Text(heroInitials)
            .font(.appButton)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppColors.appPrimary)
            .clipShape(Circle())
    }
}

private enum LegalDocumentSelection: String, Identifiable {
    case privacyPolicy
    case termsOfService

    var id: String { rawValue }

    var menuTitle: String {
        switch self {
        case .privacyPolicy: "Privacy Policy"
        case .termsOfService: "Terms of Service"
        }
    }

    var url: URL? {
        switch self {
        case .privacyPolicy:
            URL(string: "https://wayfind.city/privacy")
        case .termsOfService:
            URL(string: "https://wayfind.city/terms")
        }
    }
}

#Preview {
    NavigationStack {
        ProfileView()
            .environment(AuthViewModel())
            .environment(DataService())
            .environment(UserPreferencesStore())
            .environment(TabNavigationCoordinator())
            .environment(ToastManager())
    }
}


// =============================================================================

