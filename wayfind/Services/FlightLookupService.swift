import Foundation
import Supabase

struct FlightLookupRequest: Encodable, Hashable, Sendable {
    let carrierIATA: String
    let flightNumber: String
    let departureDate: Date
}

enum FlightLookupFailureReason: String, Decodable, Sendable {
    case invalidCarrierIATA = "invalid_carrier_iata"
    case invalidFlightNumber = "invalid_flight_number"
    case invalidDepartureDate = "invalid_departure_date"
    case invalidJSON = "invalid_json"
    case incompleteProviderSchedule = "incomplete_provider_schedule"
    case missingAPIKey = "missing_api_key"
    case methodNotAllowed = "method_not_allowed"
    case providerReturnedNoSegments = "provider_returned_no_segments"
    case providerUnavailable = "provider_unavailable"
    case noSession = "no_session"
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue) ?? .unknown
    }
}

enum FlightLookupResult: Hashable, Sendable {
    case found(VerifiedFlightLookup)
    case notFound(carrierIATA: String, flightNumber: String, departureDate: Date)
    case failed(FlightLookupFailureReason)
}

struct VerifiedFlightLookup: Decodable, Hashable, Sendable {
    let carrierIATA: String
    let flightNumber: String
    let departureDate: String
    let originAirportIATA: String?
    let destinationAirportIATA: String?
    let scheduledDepartureUTC: Date
    let scheduledArrivalUTC: Date
    let terminalOrigin: String?
    let terminalDestination: String?
    let gateOrigin: String?
    let gateDestination: String?
    let baggageClaim: String?
    let provider: String?

    init(
        carrierIATA: String,
        flightNumber: String,
        departureDate: String,
        originAirportIATA: String?,
        destinationAirportIATA: String?,
        scheduledDepartureUTC: Date,
        scheduledArrivalUTC: Date,
        terminalOrigin: String?,
        terminalDestination: String?,
        gateOrigin: String?,
        gateDestination: String?,
        baggageClaim: String?,
        provider: String?
    ) {
        self.carrierIATA = carrierIATA
        self.flightNumber = flightNumber
        self.departureDate = departureDate
        self.originAirportIATA = originAirportIATA
        self.destinationAirportIATA = destinationAirportIATA
        self.scheduledDepartureUTC = scheduledDepartureUTC
        self.scheduledArrivalUTC = scheduledArrivalUTC
        self.terminalOrigin = terminalOrigin
        self.terminalDestination = terminalDestination
        self.gateOrigin = gateOrigin
        self.gateDestination = gateDestination
        self.baggageClaim = baggageClaim
        self.provider = provider
    }

    private enum CodingKeys: String, CodingKey {
        case carrierIATA = "carrier_iata"
        case flightNumber = "flight_number"
        case departureDate = "departure_date"
        case originAirportIATA = "origin_airport_iata"
        case destinationAirportIATA = "destination_airport_iata"
        case scheduledDepartureUTC = "scheduled_departure_utc"
        case scheduledArrivalUTC = "scheduled_arrival_utc"
        case terminalOrigin = "terminal_origin"
        case terminalDestination = "terminal_destination"
        case gateOrigin = "gate_origin"
        case gateDestination = "gate_destination"
        case baggageClaim = "baggage_claim"
        case provider
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        carrierIATA = try container.decode(String.self, forKey: .carrierIATA)
        flightNumber = try container.decode(String.self, forKey: .flightNumber)
        departureDate = try container.decode(String.self, forKey: .departureDate)
        originAirportIATA = try container.decodeIfPresent(String.self, forKey: .originAirportIATA)
        destinationAirportIATA = try container.decodeIfPresent(String.self, forKey: .destinationAirportIATA)
        terminalOrigin = try container.decodeIfPresent(String.self, forKey: .terminalOrigin)
        terminalDestination = try container.decodeIfPresent(String.self, forKey: .terminalDestination)
        gateOrigin = try container.decodeIfPresent(String.self, forKey: .gateOrigin)
        gateDestination = try container.decodeIfPresent(String.self, forKey: .gateDestination)
        baggageClaim = try container.decodeIfPresent(String.self, forKey: .baggageClaim)
        provider = try container.decodeIfPresent(String.self, forKey: .provider)

        let departureRaw = try container.decode(String.self, forKey: .scheduledDepartureUTC)
        let arrivalRaw = try container.decode(String.self, forKey: .scheduledArrivalUTC)
        scheduledDepartureUTC = try Self.parseProviderDate(
            departureRaw,
            forKey: .scheduledDepartureUTC,
            in: container
        )
        scheduledArrivalUTC = try Self.parseProviderDate(
            arrivalRaw,
            forKey: .scheduledArrivalUTC,
            in: container
        )
    }

    private static func parseProviderDate(
        _ value: String,
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Date {
        let candidates = [
            Self.iso8601WithFractionalSeconds.date(from: value),
            Self.iso8601.date(from: value),
            Self.spaceSeparatedUTC.date(from: value),
            Self.spaceSeparatedUTCWithSeconds.date(from: value)
        ]
        if let date = candidates.compactMap({ $0 }).first {
            return date
        }
        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: container,
            debugDescription: "Unsupported flight timestamp: \(value)"
        )
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let iso8601WithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let spaceSeparatedUTC: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm'Z'"
        return formatter
    }()

    private static let spaceSeparatedUTCWithSeconds: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss'Z'"
        return formatter
    }()
}

enum FlightLookupServiceError: LocalizedError {
    case noSession
    case badResponse

    var errorDescription: String? {
        switch self {
        case .noSession:
            return "Sign in again to look up this flight."
        case .badResponse:
            return "Could not read the flight lookup response."
        }
    }
}

final class FlightLookupService {
    private static let functionName = "lookup-flight"
    static let shared = FlightLookupService()

    private init() {}

    func lookup(_ request: FlightLookupRequest) async -> FlightLookupResult {
        do {
            let response = try await invoke(request)
            switch response.status {
            case "found":
                if let result = response.verifiedFlight {
                    return .found(result)
                }
                return .failed(.unknown)
            case "not_found":
                return .notFound(
                    carrierIATA: response.carrierIATA ?? normalizedCarrier(request.carrierIATA),
                    flightNumber: response.flightNumber ?? normalizedFlightNumber(request.flightNumber, carrierIATA: request.carrierIATA),
                    departureDate: request.departureDate
                )
            case "error":
                return .failed(response.reason ?? .unknown)
            default:
                return .failed(.unknown)
            }
        } catch FlightLookupServiceError.noSession {
            return .failed(.noSession)
        } catch {
            return .failed(.providerUnavailable)
        }
    }

    private func invoke(_ lookupRequest: FlightLookupRequest, alreadyRetried: Bool = false) async throws -> FlightLookupResponse {
        guard let client = AuthSessionService.shared.client else {
            throw FlightLookupServiceError.noSession
        }
        let session = try await client.auth.session

        let url = URL(string: "\(AppConfig.supabaseURL)/functions/v1/\(Self.functionName)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.timeoutInterval = 20
        request.httpBody = try JSONEncoder().encode(EdgeRequest(from: lookupRequest))

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
            if !alreadyRetried {
                _ = try? await client.auth.refreshSession()
                return try await invoke(lookupRequest, alreadyRetried: true)
            }
            throw FlightLookupServiceError.noSession
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(FlightLookupResponse.self, from: data)
    }

    private func normalizedCarrier(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private func normalizedFlightNumber(_ value: String, carrierIATA: String) -> String {
        var normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
        let carrier = normalizedCarrier(carrierIATA)
        if normalized.hasPrefix(carrier) {
            normalized.removeFirst(carrier.count)
        }
        return normalized
    }
}

private struct EdgeRequest: Encodable {
    let carrier_iata: String
    let flight_number: String
    let departure_date: String

    init(from request: FlightLookupRequest) {
        carrier_iata = request.carrierIATA.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        flight_number = request.flightNumber.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        departure_date = Self.formatter.string(from: request.departureDate)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private struct FlightLookupResponse: Decodable {
    let status: String
    let reason: FlightLookupFailureReason?
    let carrierIATA: String?
    let flightNumber: String?
    let verifiedFlight: VerifiedFlightLookup?

    private enum CodingKeys: String, CodingKey {
        case status
        case reason
        case carrierIATA = "carrier_iata"
        case flightNumber = "flight_number"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(String.self, forKey: .status)
        reason = try container.decodeIfPresent(FlightLookupFailureReason.self, forKey: .reason)
        carrierIATA = try container.decodeIfPresent(String.self, forKey: .carrierIATA)
        flightNumber = try container.decodeIfPresent(String.self, forKey: .flightNumber)
        verifiedFlight = status == "found" ? try VerifiedFlightLookup(from: decoder) : nil
    }
}
