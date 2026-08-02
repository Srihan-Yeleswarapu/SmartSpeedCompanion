// RoadNameMatcher.swift
// Shared road-name matcher used to bridge an Apple Maps / CLGeocoder geocoded road
// name (e.g. "West Frye Road") and Esri HPMS `RouteId` strings (e.g. "07 FRYE RD",
// "  S 202                       0 ").
//
// Replaces the previous "spatial-proximity-only" lookup that hit the bug shown in
// https://github.com/.../issues/... where driving on West Frye Rd produced a 65 mph
// answer from S 202 because S 202's bbox engulfed the user. A name match now wins
// decisively regardless of bbox overlap.
//
// SCORE HIERARCHY (highest -> lowest):
//   1.0  : canonical forms equal AND non-empty ("FRYE RD" == "FRYE RD")
//   0.85 : geocoded-name token set is a subset of route-id tokens ("FRYE RD"
//          tokens are a subset of "FRYE RD 07"; the city prefix causes an
//          asymmetric match but the tokens that ARE in the geocoded name are
//          all confirmed present in the route id).
//   0.7  : numeric portion equal AND non-empty ("17" == "17" between "I-17"
//          and "Interstate 17" -- but DISABLED when the road-name contains a
//          strict highway-family keyword that disagrees with the route's
//          alpha prefix, e.g. "US Highway 60" vs "SR-60" pairs reject).
//   0.5  : numeric equal AND name token set contains a generic highway-type
//          keyword ("State Route 17" + "SR-17" without strict family rule).
//   0.0  : no match.
//
// Mirrors `speed_limit_compare._route_numeric_part` + `_tier2_numeric_match_allowed`
// 1:1 so the Python web server (`website/server.py`) returns the same score for
// the same inputs. Keep these tables identical across both implementations.

import Foundation

public struct RoadNameMatcher: Sendable {
    public static let SUFFIX_ALIASES: [String: String] = [
        "ROAD":     "RD",
        "AVENUE":   "AVE",
        "BOULEVARD":"BLVD",
        "HIGHWAY":  "HWY",
        "FREEWAY":  "FWY",
        "EXPRESSWAY":"EXPY",
        "DRIVE":    "DR",
        "LANE":     "LN",
        "COURT":    "CT",
        "STREET":   "ST",
        "PLACE":    "PL",
        "PARKWAY":  "PKWY",
        "TERRACE":  "TER",
        "CIRCLE":   "CIR",
    ]

    public static let DIRECTION_PREFIXES: Set<String> = [
        "W", "WEST", "E", "EAST", "N", "NORTH", "S", "SOUTH",
        "NW", "NORTHWEST", "NE", "NORTHEAST", "SW", "SOUTHWEST", "SE", "SOUTHEAST",
    ]

    /// Strict highway-family keywords that require the route's alpha prefix to match.
    /// "US Highway 60" + "SR-60" must NOT pair (different highway families).
    public static let STRICT_FAMILY_KEYWORDS: [String: String] = [
        "INTERSTATE":          "I",
        "INTERSTATE HIGHWAY":  "I",
        "US":                  "US",
        "UNITED STATES":       "US",
        "US HIGHWAY":          "US",
        "US ROUTE":            "US",
    ]

    /// Generic highway-type keywords that work with any non-I, non-US prefix.
    public static let GENERIC_TYPE_KEYWORDS: Set<String> = [
        "STATE ROUTE", "STATE HIGHWAY", "ROUTE", "HIGHWAY",
        "FREEWAY", "EXPRESSWAY", "TURNPIKE", "PARKWAY",
    ]

    /// Score the name match between a reverse-geocoded road name (from
    /// CLGeocoder.placemark.thoroughfare, MKLocalSearch result, or
    /// Nominatim) and a SQLite `RouteId` (or `SRNumber`).
    /// Returns 0.0 if either input is empty/nil.
    public static func score(geocodedName: String?, sqliteRouteId: String?) -> Double {
        guard let rawGIN = geocodedName, let rawSID = sqliteRouteId else { return 0.0 }
        let geocodedNorm = normalize(rawGIN)
        let routeNorm = normalize(rawSID)
        guard !geocodedNorm.isEmpty, !routeNorm.isEmpty else { return 0.0 }

        // 1. Exact canonical match.
        if geocodedNorm == routeNorm { return 1.0 }

        let geocodedTokens = Set(geocodedNorm.split(separator: " ").map(String.init))
        let routeTokens = Set(routeNorm.split(separator: " ").map(String.init))

        // 2. Token-subset match: every normalized geocoded token appears in route.
        if !geocodedTokens.isEmpty && geocodedTokens.isSubset(of: routeTokens) {
            return 0.85
        }

        // 3. Numeric-only match (with safety gate: I/US families cannot pair).
        let geocodedDigits = numericPortion(rawGIN)
        let routeDigits = numericPortion(rawSID)
        if !geocodedDigits.isEmpty, geocodedDigits == routeDigits {
            let providerPrefix = alphaPrefix(rawSID.uppercased())
            let nameTokensOriginal = rawGIN.uppercased().split(separator: " ").map(String.init)

            // Negative family check: if name mentions strict-family keyword,
            // provider MUST be in that family. Otherwise reject.
            for (kw, family) in STRICT_FAMILY_KEYWORDS {
                if nameTokensOriginal.contains(kw), providerPrefix != family {
                    return 0.0
                }
            }
            // Positive strict: name + provider both in same harsh family.
            for (kw, family) in STRICT_FAMILY_KEYWORDS {
                if nameTokensOriginal.contains(kw), providerPrefix == family {
                    return 0.7
                }
            }
            // Positive generic: generic type keyword AND provider prefix set +
            // provider is NOT I/US (which would have been caught above).
            let hasGeneric = nameTokensOriginal.contains { token in
                GENERIC_TYPE_KEYWORDS.contains(token)
            }
            if hasGeneric, !providerPrefix.isEmpty, providerPrefix != "I", providerPrefix != "US" {
                return 0.5
            }
        }
        return 0.0
    }

    /// Normalize a road identifier for equality / token-subset comparison.
    /// Removes zero-padded direction/terminus markers (" 0"),
    /// strips a leading numeric prefix + space ("07 FRYE RD" -> "FRYE RD"),
    /// strips leading directional prefix ("WEST FRYE RD" -> "FRYE RD"),
    /// converts compound highway identifiers ("I 010" -> "I-10"),
    /// strips trailing direction suffixes ("I-10 W" -> "I-10"),
    /// and expands common suffix aliases.
    public static func normalize(_ raw: String) -> String {
        var s = raw.uppercased().trimmingCharacters(in: .whitespaces)
        // Collapse runs of spaces.
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        // Drop trailing " 0" terminus marker that the AZ HPMS file attaches.
        if s.hasSuffix(" 0") { s = String(s.dropLast(2)).trimmingCharacters(in: .whitespaces) }
        // Strip leading numeric prefix (e.g. "07 FRYE RD" -> "FRYE RD").
        let parts = s.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var idx = 0
        if idx < parts.count, Int(parts[idx]) != nil {
            idx += 1
        }
        // Strip a single leading directional prefix.
        if idx < parts.count, DIRECTION_PREFIXES.contains(parts[idx]) {
            idx += 1
        }

        // Work with a mutable copy of parts for all remaining transformations.
        var working = parts

        // --- Compound highway conversion: "I 010" -> "I-10" ---
        // The AZ HPMS RouteId stores interstates as "  I 010" (single-letter
        // prefix + space + zero-padded number), while CLGeocoder returns
        // "I-10" (letter-hyphen-number). Normalizing the HPMS form lets
        // canonical (1.0) and token-subset (0.85) matches fire instead of
        // falling through to numeric-only matching.
        if idx + 1 < working.count,
           working[idx].count == 1,
           working[idx].first?.isLetter == true,
           working[idx + 1].first?.isNumber == true {
            let rawSecond = working[idx + 1]
            var numberOnly = rawSecond.prefix(while: { $0.isNumber })
            while numberOnly.hasPrefix("0") {
                numberOnly = numberOnly.dropFirst()
            }
            if numberOnly.isEmpty { numberOnly = "0" }
            let suffix = rawSecond.drop(while: { $0.isNumber })
            working[idx] = "\(working[idx])-\(numberOnly)\(suffix)"
            working.remove(at: idx + 1)
        }

        // --- Concatenated highway form: "I010" -> "I-10" (no space or hyphen) ---
        // Some RouteId variants omit the space between letter prefix and number.
        if idx < working.count,
           let firstChar = working[idx].first,
           firstChar.isLetter,
           working[idx].dropFirst().first?.isNumber == true {
            let letter = String(firstChar)
            let restStr = String(working[idx].dropFirst())
            var numberOnly = restStr.prefix(while: { $0.isNumber })
            while numberOnly.hasPrefix("0") {
                numberOnly = numberOnly.dropFirst()
            }
            if numberOnly.isEmpty { numberOnly = "0" }
            let suffix = restStr.drop(while: { $0.isNumber })
            working[idx] = "\(letter)-\(numberOnly)\(suffix)"
        }

        // --- Strip trailing direction suffix (e.g., "I-10 W" -> "I-10") ---
        // Common CLGeocoder output appends a cardinal suffix.
        while idx < working.count, DIRECTION_PREFIXES.contains(working.last ?? "") {
            working.removeLast()
        }

        // --- Apply suffix aliases (e.g., "STREET" -> "ST") ---
        if let last = working.last, let expansion = SUFFIX_ALIASES[last] {
            working[working.count - 1] = expansion
        }
        return working[idx...].joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Numeric portion of a road identifier (e.g. "17" from "I-17" or "SR-17").
    /// Strips leading zeros so "010" from AZ HPMS "I 010" normalizes to "10"
    /// and matches "10" from CLGeocoder's "I-10".
    public static func numericPortion(_ raw: String) -> String {
        var digits = ""
        var seenDigit = false
        for ch in raw.uppercased() {
            if ch.isNumber { digits.append(ch); seenDigit = true }
            else if seenDigit { break }
        }
        // Strip leading zeros so AZ HPMS zero-padded numbers ("010" for I-10)
        // are numerically comparable to standard representations ("10").
        let stripped = digits.drop { $0 == "0" }
        return stripped.isEmpty ? (digits.isEmpty ? "" : "0") : String(stripped)
    }

    /// Alpha prefix of a road identifier (e.g. "I" from "I-17", "US" from "US-60",
    /// "" from "17"). Returns uppercased.
    ///
    /// Handles the HPMS convention where "U" (single letter) represents a
    /// US highway: normalizes "U" → "US" so that CLGeocoder's "US 60" can
    /// match the DB's "U 060" via the strict-family numeric match (0.7).
    public static func alphaPrefix(_ raw: String) -> String {
        let upper = raw.uppercased()
        var letters = ""
        for ch in upper {
            if ch.isLetter { letters.append(ch) }
            else if ch.isNumber { break }
            else { continue }
        }
        // HPMS stores US highways with a single-letter "U" prefix ("U 060").
        // Treat it as "US" for family matching against CLGeocoder's "US 60".
        if letters == "U" { return "US" }
        return letters
    }
}
