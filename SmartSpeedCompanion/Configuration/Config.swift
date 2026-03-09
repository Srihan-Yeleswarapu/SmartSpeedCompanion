// Path: Configuration/Config.swift
import Foundation

enum Config {
    static var hereApiKey: String {
        guard let path = Bundle.main.path(forResource: "Config", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path) as? [String: Any],
              let apiKey = dict["HEREApiKey"] as? String else {
            return ""
        }
        return apiKey
    }
}
