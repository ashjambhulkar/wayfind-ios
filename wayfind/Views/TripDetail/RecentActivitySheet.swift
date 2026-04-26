//
//  RecentActivitySheet.swift
//  wayfind
//
//  Phase 4 — Recent activity feed for one trip. Presented from the
//  trip-detail toolbar Menu (secondary surface, intentionally not the
//  toolbar avatar stack — that slot is reserved for Members which is the
//  primary collaboration entry point).
//
//  UX choices, per the plan:
//  • Sheet detents: `.medium` (default) and `.large` so the user can
//    scan a few entries quickly or expand for deep history without
//    losing context.
//  • Sticky day-bucket section headers (Today / Yesterday / date) so
//    long histories stay scannable while scrolling.
//  • SkeletonView placeholder rows during the initial load — never a
//    bare spinner, never a layout pop on first paint.
//  • Pull-to-refresh in addition to realtime, because cellular drops
//    happen and the sheet is the canonical source of truth.
//  • Empty state: gentle clock-arrow symbol at 20% opacity + reassuring
//    copy. No CTA — there is nothing for the user to do here.
//
//  Reduce Motion: the only animations in this sheet are sheet detent
//  transitions (system-handled, already respects Reduce Motion) and the
//  SkeletonView shimmer (already gated). Nothing extra to do here.
//

import SwiftUI

struct RecentActivitySheet: View {
    let trip: Trip

    @State private var store = ActivityFeedStore()
    @State private var photosSheetTarget: ActivityPhotosSheetTarget?
    @Environment(\.dismiss) private var dismiss
    @Environment(DataService.self) private var dataService
    @Environment(CollaborationStore.self) private var collaborationStore

    var body: some View {
        NavigationStack {
            sheetBody
                .background(AppColors.appBackground)
                .navigationTitle("Recent activity")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                            .foregroundStyle(AppColors.appPrimary)
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .tint(AppColors.appPrimary)
        .sheet(item: $photosSheetTarget) { target in
            ActivityPhotosSheet(
                activityId: target.activityId,
                tripId: trip.id,
                activityTitle: target.title,
                canEditAttachments: collaborationStore.canEdit
            )
            .environment(dataService)
            .onDisappear {
                Task { await store.refreshAttachmentStacksOnly() }
            }
        }
        .onAppear {
            store.bind(to: trip.id)
        }
        .onDisappear {
            store.unbind()
        }
    }

    @ViewBuilder
    private var sheetBody: some View {
        switch (store.loadState, store.entries.isEmpty) {
        case (.loading, true), (.idle, true):
            loadingPlaceholder
        case (.failed(let message), true):
            failedState(message: message)
        case (_, true):
            emptyState
        default:
            entriesList
        }
    }

    // MARK: - List

    private var entriesList: some View {
        let groups = Self.groupByDay(store.entries)
        return List {
            ForEach(groups, id: \.bucket) { group in
                Section {
                    ForEach(group.entries) { entry in
                        ActivityFeedRow(
                            entry: entry,
                            photoStack: store.photoStack(for: entry),
                            onOpenPhotos: { openPhotos(for: entry) }
                        )
                        .listRowBackground(AppColors.appSurface)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if collaborationStore.canEdit, entry.tripActivityAttachmentTargetId != nil {
                                Button {
                                    openPhotos(for: entry)
                                } label: {
                                    Label("Photos", systemImage: "photo.on.rectangle.angled")
                                }
                                .tint(AppColors.appPrimary)
                            }
                        }
                    }
                } header: {
                    Text(group.label)
                        .font(.appCaption.weight(.semibold))
                        .foregroundStyle(AppColors.textSecondary)
                        .accessibilityAddTraits(.isHeader)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(AppColors.appBackground)
        .refreshable {
            await store.refresh()
        }
    }

    private func openPhotos(for entry: ActivityLogEntry) {
        guard let aid = entry.tripActivityAttachmentTargetId else { return }
        let trimmed = entry.entityName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = trimmed.isEmpty ? String(localized: "Stop") : trimmed
        photosSheetTarget = ActivityPhotosSheetTarget(activityId: aid, title: title)
    }

    // MARK: - Placeholders / states

    private var loadingPlaceholder: some View {
        // Mirror the shape of a real row so the layout doesn't pop when
        // the data lands. Six rows roughly fills the .medium detent.
        ScrollView {
            VStack(spacing: AppSpacing.sm) {
                ForEach(0..<6, id: \.self) { _ in
                    HStack(alignment: .top, spacing: AppSpacing.md) {
                        SkeletonView(cornerRadius: 16, height: 32)
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: AppSpacing.xs) {
                            SkeletonView(cornerRadius: 6, height: 14)
                                .frame(maxWidth: 220)
                            SkeletonView(cornerRadius: 6, height: 12)
                                .frame(maxWidth: 100)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, AppSpacing.sm)
                    .padding(.horizontal, AppSpacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                            .fill(AppColors.appSurface)
                    )
                }
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.top, AppSpacing.lg)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading recent activity")
    }

    private var emptyState: some View {
        VStack(spacing: AppSpacing.lg) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(AppColors.appPrimary.opacity(0.20))
            Text("Activity will show up here")
                .font(.appBody)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("Edits, additions, and joins from your trip mates land in this list as they happen.")
                .font(.appCaption)
                .foregroundStyle(AppColors.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppSpacing.xl)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No recent activity yet")
    }

    private func failedState(message: String) -> some View {
        VStack(spacing: AppSpacing.lg) {
            Spacer()
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(AppColors.textTertiary)
            Text(message)
                .font(.appBody)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppSpacing.xl)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await store.refresh() }
            } label: {
                Text("Try again")
                    .font(.appBody.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.vertical, AppSpacing.sm + 2)
                    .background(
                        Capsule().fill(AppColors.appPrimary)
                    )
            }
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Grouping

    /// Group entries into day-buckets in `entries` order — the service
    /// already sorts most-recent-first so this preserves that order
    /// inside each bucket.
    private static func groupByDay(_ entries: [ActivityLogEntry]) -> [DayGroup] {
        var seen: [Date: Int] = [:]
        var groups: [DayGroup] = []
        for entry in entries {
            let bucket = entry.dayBucketKey()
            if let idx = seen[bucket] {
                groups[idx].entries.append(entry)
            } else {
                seen[bucket] = groups.count
                groups.append(DayGroup(
                    bucket: bucket,
                    label: entry.dayBucketLabel(),
                    entries: [entry]
                ))
            }
        }
        return groups
    }

    private struct DayGroup {
        let bucket: Date
        let label: String
        var entries: [ActivityLogEntry]
    }
}

// MARK: - Row

private struct ActivityFeedRow: View {
    let entry: ActivityLogEntry
    let photoStack: [ActivityFeedPhotoStackItem]
    let onOpenPhotos: () -> Void

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private var showsPhotoChrome: Bool {
        entry.tripActivityAttachmentTargetId != nil && !photoStack.isEmpty
    }

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            AvatarView(
                displayName: entry.actorDisplayName,
                imageURL: nil,
                stableID: entry.userId.uuidString,
                size: 32
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs) {
                    Image(systemName: entry.action.systemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary.opacity(0.6))
                        .frame(width: 16, alignment: .leading)
                    Text(entry.description)
                        .font(.appBody)
                        .foregroundStyle(AppColors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(Self.relativeFormatter.localizedString(for: entry.createdAt, relativeTo: Date()))
                    .font(.appCaption)
                    .foregroundStyle(AppColors.textTertiary)
                    .padding(.leading, 16 + AppSpacing.xs)
            }
            Spacer(minLength: AppSpacing.sm)

            if showsPhotoChrome {
                ActivityFeedPhotoStackView(items: photoStack, onTap: onOpenPhotos)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabelText)
    }

    private var accessibilityLabelText: String {
        var base = "\(entry.description), \(Self.relativeFormatter.localizedString(for: entry.createdAt, relativeTo: Date()))"
        if showsPhotoChrome {
            base += ", \(photoStack.count) photos"
        }
        return base
    }
}


// =============================================================================
