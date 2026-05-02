import Foundation

struct FlightAirline: Identifiable, Hashable, Sendable {
    var id: String { iataCode }
    let name: String
    let iataCode: String
}

enum FlightAirlineCatalog {
    static let airlines: [FlightAirline] = [
        FlightAirline(name: "American Airlines", iataCode: "AA"),
        FlightAirline(name: "Delta Air Lines", iataCode: "DL"),
        FlightAirline(name: "United Airlines", iataCode: "UA"),
        FlightAirline(name: "Southwest Airlines", iataCode: "WN"),
        FlightAirline(name: "JetBlue", iataCode: "B6"),
        FlightAirline(name: "Alaska Airlines", iataCode: "AS"),
        FlightAirline(name: "Air Canada", iataCode: "AC"),
        FlightAirline(name: "British Airways", iataCode: "BA"),
        FlightAirline(name: "Air France", iataCode: "AF"),
        FlightAirline(name: "KLM Royal Dutch Airlines", iataCode: "KL"),
        FlightAirline(name: "Lufthansa", iataCode: "LH"),
        FlightAirline(name: "Iberia", iataCode: "IB"),
        FlightAirline(name: "Aer Lingus", iataCode: "EI"),
        FlightAirline(name: "Virgin Atlantic", iataCode: "VS"),
        FlightAirline(name: "Emirates", iataCode: "EK"),
        FlightAirline(name: "Qatar Airways", iataCode: "QR"),
        FlightAirline(name: "Etihad Airways", iataCode: "EY"),
        FlightAirline(name: "Turkish Airlines", iataCode: "TK"),
        FlightAirline(name: "Singapore Airlines", iataCode: "SQ"),
        FlightAirline(name: "Cathay Pacific", iataCode: "CX"),
        FlightAirline(name: "Qantas", iataCode: "QF"),
        FlightAirline(name: "Air New Zealand", iataCode: "NZ"),
        FlightAirline(name: "Japan Airlines", iataCode: "JL"),
        FlightAirline(name: "ANA", iataCode: "NH"),
        FlightAirline(name: "Korean Air", iataCode: "KE"),
        FlightAirline(name: "Air India", iataCode: "AI"),
        FlightAirline(name: "IndiGo", iataCode: "6E"),
        FlightAirline(name: "Vistara", iataCode: "UK"),
        FlightAirline(name: "Ryanair", iataCode: "FR"),
        FlightAirline(name: "easyJet", iataCode: "U2"),
        FlightAirline(name: "Wizz Air", iataCode: "W6"),
        FlightAirline(name: "SAS", iataCode: "SK"),
        FlightAirline(name: "Swiss", iataCode: "LX"),
        FlightAirline(name: "Austrian Airlines", iataCode: "OS"),
        FlightAirline(name: "TAP Air Portugal", iataCode: "TP"),
        FlightAirline(name: "ITA Airways", iataCode: "AZ"),
        FlightAirline(name: "Finnair", iataCode: "AY"),
        FlightAirline(name: "LOT Polish Airlines", iataCode: "LO"),
        FlightAirline(name: "Aeromexico", iataCode: "AM"),
        FlightAirline(name: "LATAM Airlines", iataCode: "LA"),
        FlightAirline(name: "Avianca", iataCode: "AV"),
        FlightAirline(name: "Copa Airlines", iataCode: "CM"),
    ]

    static func search(_ query: String) -> [FlightAirline] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Array(airlines.prefix(6)) }

        let lower = trimmed.lowercased()
        let upper = trimmed.uppercased()
        return airlines
            .filter { airline in
                airline.name.lowercased().contains(lower)
                    || airline.iataCode.contains(upper)
            }
            .sorted { lhs, rhs in
                if lhs.iataCode == upper { return true }
                if rhs.iataCode == upper { return false }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    static func airline(matchingCode code: String?) -> FlightAirline? {
        guard let code else { return nil }
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return airlines.first { $0.iataCode == normalized }
    }

    static func airline(matchingName name: String?) -> FlightAirline? {
        guard let name else { return nil }
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return airlines.first { $0.name.compare(normalized, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }
}
