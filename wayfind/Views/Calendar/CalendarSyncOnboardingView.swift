//
//  CalendarSyncOnboardingView.swift
//  wayfind
//
//  Wave 2.1 — 3-screen onboarding sheet shown the first time a user taps
//  "Sync to Apple Calendar". Sets expectations *before* the system
//  permission dialog so the deny rate stays low (Apple HIG: explain
//  before asking).
//
//  Screens:
//    1. What it does — "We'll add your scheduled places + bookings to a
//       new calendar called 'Wayfind: <trip name>'."
//    2. Privacy — "We don't read your existing calendars. Disable per
//       trip in Trip Settings any time."
//    3. Permission CTA — primary button triggers the system prompt.
//

import EventKit
import SwiftUI

struct CalendarSyncOnboardingView: View {
    let trip: Trip
    let onCompleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var page: Int = 0
    @State private var service: CalendarSyncService = CalendarSyncService()
    @State private var permissionError: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    OnboardingPage(
                        symbol: "calendar.badge.plus",
                        title: "Bring your trip into Calendar",
                        description: "Wayfind will create a new calendar called \"Wayfind: \(trip.title)\" and add every scheduled place and booking. You can hide or delete it in one tap whenever you want."
                    )
                    .tag(0)

                    OnboardingPage(
                        symbol: "lock.shield",
                        title: "Private to your trip",
                        description: "We only write the events for this trip. We don't read your other calendars, and changes you make in Calendar stay there. Sync is per-trip and per-device — flip it off any time in Trip Settings."
                    )
                    .tag(1)

                    OnboardingPage(
                        symbol: "checkmark.circle",
                        title: "Ready when you are",
                        description: "Tap below to grant Calendar access. iOS will ask once. After that, every change you make in Wayfind syncs in seconds."
                    )
                    .tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                VStack(spacing: AppSpacing.sm) {
                    if let permissionError {
                        Text(permissionError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                    Button {
                        if page < 2 {
                            withAnimation { page += 1 }
                        } else {
                            Task { await requestPermission() }
                        }
                    } label: {
                        Text(page < 2 ? "Continue" : "Connect Calendar")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(AppColors.appPrimary, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel(page < 2 ? "Continue" : "Connect Apple Calendar")

                    Button("Maybe later") { dismiss() }
                        .font(.subheadline)
                        .foregroundStyle(AppColors.textSecondary)
                }
                .padding(AppSpacing.lg)
            }
            .navigationTitle("Sync to Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Skip") { dismiss() }
                }
            }
        }
    }

    private func requestPermission() async {
        do {
            _ = try await service.requestAccess()
            dismiss()
            onCompleted()
        } catch {
            permissionError = error.localizedDescription
        }
    }
}

private struct OnboardingPage: View {
    let symbol: String
    let title: String
    let description: String

    var body: some View {
        VStack(spacing: AppSpacing.lg) {
            Spacer(minLength: AppSpacing.xl)
            Image(systemName: symbol)
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(AppColors.appPrimary)
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.primary)
            Text(description)
                .font(.body)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppSpacing.lg)
            Spacer()
        }
        .padding(.bottom, AppSpacing.xl)
    }
}
