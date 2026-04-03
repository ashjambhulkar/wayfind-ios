import Foundation

enum AppConfig {
    static let supabaseURL = "https://zmkbdnutedbwkinjukbg.supabase.co"
    static let supabaseAnonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inpta2JkbnV0ZWRid2tpbmp1a2JnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzQzMDUyMzUsImV4cCI6MjA4OTg4MTIzNX0.c6_SU09d2L38Is-oSMHuNAzulnaMA93-ZZaHJkaItA0"
    static let googlePlacesAPIKey = "AIzaSyDPGzUKxDVuPZYKD-FfGVX7eekhX_kdliA"
    static let unsplashAccessKey = "0IsL7-FEKZSxVFvSVNcFo7SJopjjrvtkFV-rbfXYesI"

    static var useRealBackend: Bool {
        !supabaseURL.contains("YOUR_PROJECT")
    }
}