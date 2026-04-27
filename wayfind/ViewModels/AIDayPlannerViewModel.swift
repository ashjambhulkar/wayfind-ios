import Foundation
import Observation

enum AIPlannerState: Equatable {
    case idle
    case loading
    case preview
    case applying
    case applied
    case empty
    case error(String)
    /// Wave 4.2 — server returned `free_limit_reached` (HTTP 429). The
    /// wizard renders an upgrade nudge instead of the generic error
    /// banner so the user understands the path forward is "go Pro",
    /// not "try again later".
    case quotaExhausted
}

@Observable
@MainActor
final class AIDayPlannerViewModel {

    // MARK: - Trip context (set from owning view)
    var trip: Trip
    private(set) var scheduledDays: [ItineraryDay] = []
    private(set) var isDaysLoading: Bool = false

    /// Cached snapshot used to compute `exclude_places` (dedupes across days).
    private var placesByDayId: [UUID: [Place]] = [:]

    // MARK: - Stay area (lodging anchor — required by edge function)

    /// Free-text label shown to the user (e.g. "Le Marais, Paris"). Pre-filled
    /// from `trip.destination` and overwritten by the picker sheet.
    var stayAreaLabel: String

    /// Google `place_id` for the stay area. The edge function rejects requests
    /// when this is missing — UI must keep "Generate" disabled until set.
    var stayAreaPlaceId: String?

    // MARK: - User preferences (bound to UI controls)
    var selectedDay: ItineraryDay? {
        didSet {
            if oldValue?.id != selectedDay?.id {
                cancelGenerate()
                if plannerState != .idle { reset() }
            }
        }
    }
    var pace: PlanPace = .balanced
    var explorationScope: ExplorationScope = .city_wide
    var timeStart: String = "09:00"
    var timeEnd: String = "21:00"
    var includeMeals: Bool = true
    var selectedInterests: Set<String> = []

    // MARK: - State
    var plannerState: AIPlannerState = .idle
    var previewCards: [ActivityPreviewCard] = []
    var previewOps: [ItineraryOp] = []
    var previewSummary: String = ""
    var previewStoryTitle: String? = nil
    var previewStorySubtitle: String? = nil
    var previewStoryArc: [String] = []
    /// IANA timezone reported by the edge function for the destination.
    /// Used to render `starts_at` in destination wall-clock instead of device-local time.
    var previewDisplayTimezone: TimeZone?
    /// Number of activities that were committed in the last successful apply.
    /// Surfaced in the success banner ("Added 6 stops").
    var appliedOpsCount: Int = 0

    private var generateTask: Task<Void, Never>?

    var isLoading: Bool { plannerState == .loading }
    var isApplying: Bool { plannerState == .applying }
    var hasPreview: Bool { plannerState == .preview && !previewCards.isEmpty }
    var isApplied: Bool { plannerState == .applied }
    var isEmpty: Bool { plannerState == .empty }
    /// Wave 4.2 — true iff the server told us the free user has burned
    /// their monthly quota. The bottom bar uses this to swap "Try Again"
    /// for "Upgrade to Pro".
    var isQuotaExhausted: Bool { plannerState == .quotaExhausted }

    var errorMessage: String? {
        if case .error(let msg) = plannerState { return msg }
        return nil
    }

    // MARK: - Pro / quota badge (Wave 4.2)

    /// Mirrors effective premium access at the moment the wizard reads
    /// it. Launch access and paid subscriptions both show unlimited in
    /// the client UI.
    var isProUser: Bool { EntitlementService.shared.hasPremiumAccess }

    /// String to render in the wizard's quota badge. Pro users get
    /// "Unlimited"; Free users get "X of N free remaining" with the
    /// limit pulled from EntitlementService so a server-side cap
    /// change (Wave 4.4b moves 7 → 3) lights up without an app
    /// release.
    var quotaBadgeText: String {
        if isProUser { return "Unlimited" }
        let limit = EntitlementService.shared.aiFreeMonthlyLimit
        let remaining = EntitlementService.shared.aiRemainingForFree
        return "\(remaining) of \(limit) free remaining"
    }

    var canGenerate: Bool {
        let trimmedLabel = stayAreaLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasPlaceId = (stayAreaPlaceId?.isEmpty == false)
        return selectedDay != nil
            && !trimmedLabel.isEmpty
            && hasPlaceId
            && !isLoading
            && !isApplying
    }

    /// True when neither the trip nor the picker has provided a Google `place_id`
    /// — the UI surfaces this as a guiding note in the stay-area row.
    var needsStayAreaPlaceId: Bool {
        stayAreaPlaceId == nil || stayAreaPlaceId?.isEmpty == true
    }

    // MARK: - Available interests
    let availableInterests: [String] = [
        "history", "art", "food", "nature", "architecture",
        "shopping", "nightlife", "museums", "local_culture", "photography"
    ]

    func interestDisplayName(_ interest: String) -> String {
        interest.replacingOccurrences(of: "_", with: " ").capitalized
    }

    // MARK: - Init

    init(trip: Trip) {
        self.trip = trip
        self.stayAreaLabel = trip.destination
        self.stayAreaPlaceId = trip.destinationPlaceId
    }

    // MARK: - Stay area mutation

    /// Trims the label, swaps the place_id, and resets any stale preview so the
    /// user can't accidentally apply the previous area's plan against the new one.
    func setStayArea(label: String, placeId: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedId = placeId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmedId.isEmpty else { return }
        stayAreaLabel = trimmed
        stayAreaPlaceId = trimmedId
        cancelGenerate()
        if plannerState != .idle { reset() }
    }

    // MARK: - Load days

    func loadDays(from dataService: DataService) async {
        isDaysLoading = true
        defer { isDaysLoading = false }
        let (days, places) = await dataService.fetchTripTimeline(for: trip.id)
        scheduledDays = days.filter { !$0.isWishlist }.sorted { $0.dayNumber < $1.dayNumber }
        placesByDayId = places
        if selectedDay == nil {
            selectedDay = scheduledDays.first
        }
    }

    // MARK: - Generate

    func generate() async {
        guard let day = selectedDay else { return }
        // Don't fall back to trip.startDate here — sending Day 1's date with
        // Day N's UUID would fail the server's plan_day_day_match gate
        // ("day_id or date does not match a trip day in range").
        guard let dayDate = day.date else {
            plannerState = .error("This day is missing a date. Pull to refresh and try again.")
            return
        }
        guard let placeId = stayAreaPlaceId, !placeId.isEmpty else {
            plannerState = .error("Pick a neighborhood or lodging area before generating a plan.")
            return
        }
        let trimmedLabel = stayAreaLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty else {
            plannerState = .error("Stay area can't be empty.")
            return
        }

        cancelGenerate()
        plannerState = .loading
        previewCards = []
        previewOps = []
        previewStoryTitle = nil
        previewStorySubtitle = nil
        previewStoryArc = []
        previewDisplayTimezone = nil

        let stopCounts = stopRange(for: pace)
        let exclude = mergeExcludePlaceNames(currentDayId: day.id)
        let params = PlanDayParams(
            dayId: day.id,
            date: dayDate,
            destination: trip.destination,
            interests: Array(selectedInterests),
            pace: pace,
            stopCountMin: stopCounts.min,
            stopCountMax: stopCounts.max,
            timeStart: timeStart,
            timeEnd: timeEnd,
            includeMeals: includeMeals,
            stayAreaLabel: trimmedLabel,
            stayAreaPlaceId: placeId,
            explorationScope: explorationScope,
            travelStyle: nil,
            excludePlaces: exclude
        )

        let tripId = trip.id
        let task = Task { [weak self] in
            do {
                let service = ItineraryAIService()
                let response = try await service.planDay(tripId: tripId, params: params)

                try Task.checkCancellation()
                await self?.applyPlanResponse(response)
                // Wave 4.2 — successful generation consumed one AI call
                // server-side. Refresh the cached count so the wizard
                // badge ("X of 3 free remaining") decrements without
                // waiting for the next mount.
                await EntitlementService.shared.refreshAIUsage()
            } catch is CancellationError {
                // No-op: a newer generate() superseded this task.
            } catch ItineraryAIError.quotaExceeded {
                // Wave 4.2 — drop into the dedicated "out of free
                // generations" state so the bottom bar can swap "Try
                // Again" for "Upgrade to Pro" instead of letting the
                // generic error banner stand. Also reconcile the local
                // count to the cap so the badge stops lying.
                await self?.setStateIfActive(.quotaExhausted)
                await EntitlementService.shared.refreshAIUsage()
            } catch ItineraryAIError.dailySafetyCapReached {
                // Wave 4.4b — distinct from the free monthly cap. This
                // is a hard ceiling that applies to Pro users too,
                // so we present an error message rather than the
                // upgrade paywall (no remediation = no pretending the
                // user can pay their way out of this one).
                await self?.setStateIfActive(
                    .error(ItineraryAIError.dailySafetyCapReached.errorDescription
                        ?? "Daily safety cap reached.")
                )
            } catch let err as ItineraryAIError {
                await self?.setStateIfActive(.error(err.errorDescription ?? "Unknown error"))
            } catch {
                if Task.isCancelled { return }
                await self?.setStateIfActive(.error(error.localizedDescription))
            }
        }
        generateTask = task
        await task.value
    }

    /// Applies a successful preview response onto the VM. Splits into its own
    /// MainActor method so the cancel-aware Task body stays simple.
    private func applyPlanResponse(_ response: PlanDayPreviewResponse) {
        let insertOps = (response.itinerary_ops ?? []).filter { $0.action == "insert" }
        let cards = insertOps.compactMap { op -> ActivityPreviewCard? in
            guard let row = op.row else { return nil }
            return ActivityPreviewCard(from: row)
        }

        previewSummary = response.summary
        previewStoryTitle = response.story_title
        previewStorySubtitle = response.story_subtitle
        previewStoryArc = response.story_arc ?? []
        previewDisplayTimezone = response.display_timezone.flatMap { TimeZone(identifier: $0) }

        if cards.isEmpty {
            previewCards = []
            previewOps = []
            plannerState = .empty
            return
        }

        previewCards = cards
        previewOps = response.itinerary_ops ?? []
        plannerState = .preview
    }

    /// Guard so a cancelled Task can't set state on a fresh generate cycle.
    private func setStateIfActive(_ newState: AIPlannerState) {
        if Task.isCancelled { return }
        plannerState = newState
    }

    /// Cancels any in-flight `generate()` Task. Safe to call repeatedly.
    func cancelGenerate() {
        generateTask?.cancel()
        generateTask = nil
    }

    // MARK: - Apply

    func applyPreview() async {
        guard case .preview = plannerState else { return }
        guard !previewOps.isEmpty else { return }

        plannerState = .applying
        do {
            let service = ItineraryAIService()
            try await service.applyOps(tripId: trip.id, ops: previewOps)
            appliedOpsCount = previewOps.filter { $0.action == "insert" }.count
            plannerState = .applied
            NotificationCenter.default.post(
                name: .tripActivitiesDidChange,
                object: nil,
                userInfo: [TripActivitiesNotificationKeys.tripId: trip.id]
            )
        } catch let err as ItineraryAIError {
            plannerState = .error(err.errorDescription ?? "Apply failed")
        } catch {
            plannerState = .error(error.localizedDescription)
        }
    }

    // MARK: - Reset

    func reset() {
        cancelGenerate()
        plannerState = .idle
        previewCards = []
        previewOps = []
        previewSummary = ""
        previewStoryTitle = nil
        previewStorySubtitle = nil
        previewStoryArc = []
        previewDisplayTimezone = nil
        appliedOpsCount = 0
    }

    // MARK: - Exclude-places dedup
    //
    // Mirrors Expo `mergeExcludePlaceNamesForItineraryAi(userList, fromOtherDays, MAX)`:
    // dedupes by lower-cased trim, preserving first-seen casing, capped to avoid
    // oversized request bodies (server tolerates ~60).

    private static let maxExcludePlaces = 60

    private func mergeExcludePlaceNames(currentDayId: UUID) -> [String] {
        var seen = Set<String>()
        var out: [String] = []

        func push(_ rawName: String) {
            let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.lowercased()
            guard !trimmed.isEmpty,
                  !seen.contains(key),
                  out.count < Self.maxExcludePlaces else { return }
            seen.insert(key)
            out.append(trimmed)
        }

        if let same = placesByDayId[currentDayId] {
            for place in same { push(place.name) }
        }
        let otherDayIds = placesByDayId.keys.filter { $0 != currentDayId }
        for dayId in otherDayIds {
            guard let list = placesByDayId[dayId] else { continue }
            for place in list { push(place.name) }
        }
        return out
    }

    // MARK: - Helpers

    private func stopRange(for pace: PlanPace) -> (min: Int, max: Int) {
        switch pace {
        case .relaxed: return (2, 4)
        case .balanced: return (4, 6)
        case .packed: return (6, 9)
        }
    }

    func dayLabel(for day: ItineraryDay) -> String {
        guard let date = day.date else { return "Day \(day.dayNumber)" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        return "Day \(day.dayNumber) · \(formatter.string(from: date))"
    }

    /// Formats a UTC ISO8601 `starts_at` in the destination's IANA timezone
    /// (e.g. `Europe/Paris`) so wall-clock matches the trip city, not the device.
    /// Falls back to the device timezone when the response didn't include one.
    func formattedTime(_ isoString: String?) -> String? {
        formattedTime(isoString, in: previewDisplayTimezone)
    }

    func formattedTime(_ isoString: String?, in tz: TimeZone?) -> String? {
        guard let isoString else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = iso.date(from: isoString)
        if date == nil {
            let fallback = ISO8601DateFormatter()
            fallback.formatOptions = [.withInternetDateTime]
            date = fallback.date(from: isoString)
        }
        guard let date else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        fmt.amSymbol = "AM"
        fmt.pmSymbol = "PM"
        fmt.timeZone = tz ?? .current
        return fmt.string(from: date)
    }
}


// =============================================================================
