import Foundation

/// The weather for the Dock's widget, from Open-Meteo: free, without a key or an account.
///
/// Apple's WeatherKit needs a paid developer account. Open-Meteo is asked only once the person
/// turns the widget on and names a town; the town is looked up once, and after that only its
/// coordinates are sent, at most every half hour.
public enum Weather {
    public struct Place: Codable, Equatable, Sendable {
        public let name: String
        public let latitude: Double
        public let longitude: Double

        public init(name: String, latitude: Double, longitude: Double) {
            self.name = name
            self.latitude = latitude
            self.longitude = longitude
        }
    }

    public struct Now: Equatable, Sendable {
        public let temperature: Double
        public let code: Int
        public let isDay: Bool
        public let high: Double?
        public let low: Double?
    }

    public static func searchURL(for town: String, language: String) -> URL? {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")
        components?.queryItems = [
            URLQueryItem(name: "name", value: town),
            URLQueryItem(name: "count", value: "1"),
            URLQueryItem(name: "language", value: language),
        ]
        return components?.url
    }

    public static func place(fromSearch json: Data) -> Place? {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let first = (object["results"] as? [[String: Any]])?.first,
              let name = first["name"] as? String,
              let latitude = (first["latitude"] as? NSNumber)?.doubleValue,
              let longitude = (first["longitude"] as? NSNumber)?.doubleValue
        else { return nil }
        return Place(name: name, latitude: latitude, longitude: longitude)
    }

    public static func forecastURL(for place: Place) -> URL? {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), place.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), place.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "forecast_days", value: "1"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        return components?.url
    }

    public static func now(fromForecast json: Data) -> Now? {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let current = object["current"] as? [String: Any],
              let temperature = (current["temperature_2m"] as? NSNumber)?.doubleValue,
              let code = (current["weather_code"] as? NSNumber)?.intValue
        else { return nil }
        let daily = object["daily"] as? [String: Any]
        return Now(
            temperature: temperature,
            code: code,
            isDay: (current["is_day"] as? NSNumber)?.intValue != 0,
            high: ((daily?["temperature_2m_max"] as? [Any])?.first as? NSNumber)?.doubleValue,
            low: ((daily?["temperature_2m_min"] as? [Any])?.first as? NSNumber)?.doubleValue
        )
    }

    /// The SF Symbol for a WMO weather code.
    public static func symbol(for code: Int, isDay: Bool) -> String {
        switch code {
        case 0: isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51 ... 57: "cloud.drizzle.fill"
        case 61 ... 67, 80 ... 82: "cloud.rain.fill"
        case 71 ... 77, 85, 86: "cloud.snow.fill"
        case 95 ... 99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }
}
