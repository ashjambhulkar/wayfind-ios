import Foundation

enum AppConfig {
    static let supabaseURL = "https://YOUR_PROJECT.supabase.co"
    static let supabaseAnonKey = "https://YOUR_PROJECT.supabase.co/auth/v1/token?grant_type=password"
    static let googlePlacesAPIKey = "your-google-places-api-key"
    static let unsplashAccessKey = "your-unsplash-access-key"

    static var useRealBackend: Bool {
        !supabaseURL.contains("YOUR_PROJECT")
    }
}