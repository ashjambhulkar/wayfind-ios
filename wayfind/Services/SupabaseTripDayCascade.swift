import Foundation
import Supabase

/// Mirrors Expo `cascadeTripDaysForNewRange` (`services/tripDayCascade.ts`) for native trip date changes.
enum SupabaseTripDayCascade {
    struct TripDayRow: Decodable, Sendable {
        let id: UUID
        let trip_id: UUID
        let user_id: UUID
        let date: String
        let day_number: Int
        let label: String?
        let notes: String?
        let timezone: String?
    }

    private struct ActivityDayCountRow: Decodable, Sendable {
        let day_id: UUID
    }

    private struct TripDayInsert: Encodable, Sendable {
        let trip_id: UUID
        let user_id: UUID
        let date: String
        let day_number: Int
        let label: String?
        let notes: String?
        let timezone: String?
    }

    private struct TripDayDateUpdate: Encodable, Sendable {
        let date: String
        let updated_at: String
    }

    private struct TripDayNumberUpdate: Encodable, Sendable {
        let day_number: Int
        let updated_at: String
    }

    static func cascadeTripDaysForNewRange(
        client: SupabaseClient,
        tripId: UUID,
        userId: UUID,
        startDate: Date,
        endDate: Date,
        calendar: Calendar = .current
    ) async throws {
        let startISO = SupabaseModelMapping.calendarDateOnlyString(from: startDate, calendar: calendar)
        let desired = SupabaseModelMapping.enumerateCalendarDateOnlyStrings(from: startDate, through: endDate, calendar: calendar)
        guard !desired.isEmpty else {
            throw SupabaseManagerError.invalidDateRange
        }

        let ideasDate = SupabaseModelMapping.addCalendarDaysString(startISO, offsetDays: -1, calendar: calendar)

        let existingDays: [TripDayRow] = try await client
            .from("trip_days")
            .select()
            .eq("trip_id", value: tripId.uuidString)
            .execute()
            .value

        var ideasDay = existingDays.first { $0.day_number == 0 }
        let nowIso = ISO8601DateFormatter().string(from: Date())

        if let ideas = ideasDay, ideas.date != ideasDate {
            try await client
                .from("trip_days")
                .update(TripDayDateUpdate(date: ideasDate, updated_at: nowIso))
                .eq("id", value: ideas.id.uuidString)
                .execute()
            ideasDay = TripDayRow(
                id: ideas.id,
                trip_id: ideas.trip_id,
                user_id: ideas.user_id,
                date: ideasDate,
                day_number: ideas.day_number,
                label: ideas.label,
                notes: ideas.notes,
                timezone: ideas.timezone
            )
        } else if ideasDay == nil {
            let insert = TripDayInsert(
                trip_id: tripId,
                user_id: userId,
                date: ideasDate,
                day_number: 0,
                label: "Ideas",
                notes: nil,
                timezone: nil
            )
            try await client.from("trip_days").insert(insert).execute()
        }

        let scheduled = sortScheduledByDate(existingDays.filter { $0.day_number > 0 })
        var byDate = Dictionary(uniqueKeysWithValues: scheduled.map { ($0.date, $0) })
        let desiredSet = Set(desired)

        let activityRows: [ActivityDayCountRow] = try await client
            .from("trip_activities")
            .select("day_id")
            .eq("trip_id", value: tripId.uuidString)
            .execute()
            .value

        var countByDay = [UUID: Int]()
        for row in activityRows {
            countByDay[row.day_id, default: 0] += 1
        }

        for day in scheduled where !desiredSet.contains(day.date) {
            let count = countByDay[day.id] ?? 0
            if count > 0 {
                throw SupabaseManagerError.cannotShrinkTripDayHasActivities(date: day.date)
            }
            try await client
                .from("trip_days")
                .delete()
                .eq("id", value: day.id.uuidString)
                .execute()
            byDate.removeValue(forKey: day.date)
        }

        for date in desired where byDate[date] == nil {
            let insert = TripDayInsert(
                trip_id: tripId,
                user_id: userId,
                date: date,
                day_number: 9999,
                label: nil,
                notes: nil,
                timezone: nil
            )
            try await client.from("trip_days").insert(insert).execute()
        }

        let refreshed: [TripDayRow] = try await client
            .from("trip_days")
            .select()
            .eq("trip_id", value: tripId.uuidString)
            .gt("day_number", value: -1)
            .order("date", ascending: true)
            .execute()
            .value

        let toRenumber = sortScheduledByDate(refreshed.filter { $0.day_number > 0 })
        for (index, day) in toRenumber.enumerated() {
            let nextNum = index + 1
            if day.day_number == nextNum { continue }
            try await client
                .from("trip_days")
                .update(TripDayNumberUpdate(day_number: nextNum, updated_at: nowIso))
                .eq("id", value: day.id.uuidString)
                .execute()
        }
    }

    private static func sortScheduledByDate(_ days: [TripDayRow]) -> [TripDayRow] {
        days.sorted { a, b in
            if a.date != b.date { return a.date < b.date }
            return a.id.uuidString < b.id.uuidString
        }
    }
}
