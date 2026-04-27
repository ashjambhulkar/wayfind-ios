import Foundation

enum AppConfig {
    /// Must match Expo `readAppScheme()` / Supabase redirect allow-list (`wayfind://auth/callback`).
    static let appURLScheme = "wayfind"

    /// Same path as Expo `OAUTH_CALLBACK_PATH` (`services/socialAuth.ts`).
    private static let authCallbackPath = "auth/callback"

    /// Password reset, email confirmation, and OAuth deep links (add to Supabase Auth redirect URLs).
    static var supabaseAuthRedirectURL: URL {
        URL(string: "\(appURLScheme)://\(authCallbackPath)")!
    }

    static let supabaseURL = "https://zmkbdnutedbwkinjukbg.supabase.co"
    static let supabaseAnonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inpta2JkbnV0ZWRid2tpbmp1a2JnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzQzMDUyMzUsImV4cCI6MjA4OTg4MTIzNX0.c6_SU09d2L38Is-oSMHuNAzulnaMA93-ZZaHJkaItA0"
    static let googlePlacesAPIKey = "AIzaSyDPGzUKxDVuPZYKD-FfGVX7eekhX_kdliA"
    static let unsplashAccessKey = "0IsL7-FEKZSxVFvSVNcFo7SJopjjrvtkFV-rbfXYesI"

    /// iOS OAuth client ID (Google Cloud Console). Must match bundle ID `app.wayfind.travel` or replace with your own client.
    static let googleIOSClientID = "1009434603775-8c92mfkampnmj1l7goj6517raaelq0vl.apps.googleusercontent.com"

    /// Web client ID (same project) — required for Supabase to verify Google ID tokens.
    static let googleWebClientID = "1009434603775-9bhraag5uf0orldvvd3i384ij8qr2dcf.apps.googleusercontent.com"

    static var isGoogleSignInConfigured: Bool {
        googleIOSClientID.contains("googleusercontent.com")
            && googleWebClientID.contains("googleusercontent.com")
            && !googleIOSClientID.contains("YOUR_")
            && !googleWebClientID.contains("YOUR_")
    }

    static var useRealBackend: Bool {
        !supabaseURL.contains("YOUR_PROJECT")
    }

    /// Build-time toggle for the AI Stay Area picker autocomplete endpoint.
    /// `true` ⇒ Places API (New) — `places.googleapis.com/v1/places:autocomplete`
    /// with explicit `X-Goog-FieldMask`. `false` ⇒ Legacy `/place/autocomplete/json`.
    /// Both paths bill the same SKU; the new API is future-proof against the
    /// Legacy sunset Google has signaled. See places-cost-and-owned-data plan,
    /// Phase B.5.
    static let useNewPlacesAPIForAutocomplete: Bool = true

    // MARK: - Launch access

    /// Temporary launch switch: while `true`, every signed-in user gets
    /// premium feature access without being treated as a paid subscriber.
    /// Flip to `false` in the release that re-enables paid plans.
    static let grantFreeLaunchPremiumAccess: Bool = true

    // MARK: - RevenueCat (Wave 4.2)

    /// Apple App Store **public** API key from the RevenueCat dashboard
    /// (Project Settings → API Keys → "Public app-specific API keys" →
    /// iOS / App Store row, prefix `appl_…`). This is intentionally a
    /// public key — RevenueCat treats it like an anon Supabase key, the
    /// real auth happens server-side against the App Store receipt.
    /// Replace with your project's value before TestFlight; an empty
    /// string keeps the SDK in no-op mode so dev builds don't crash.
    static let revenueCatPublicAPIKey: String = "appl_YqMSykVMPajgsOXZOwGGFegdZuf"

    /// Whether `Purchases.configure(...)` should be invoked at launch.
    /// Driven entirely by whether we have a non-empty key — guarded so
    /// engineers without a configured key can still build and run the
    /// rest of the app, paywall flows just route through the SDK-less
    /// branch in `EntitlementService`.
    static var isRevenueCatConfigured: Bool {
        !revenueCatPublicAPIKey.isEmpty
    }
}

