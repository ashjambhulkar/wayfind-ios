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
}

