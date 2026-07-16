import Foundation
import CoreLocation
import SQLite3

/// A thread-safe actor service that queries Arizona speed limit data.
/// Updated for Swift 6 Concurrency and Xcode 16 compatibility.
public actor ArizonaSpeedLimitService {
    public static let shared = ArizonaSpeedLimitService()
    
    private var db: OpaquePointer?
    private var isLoaded = false

    private var circularCache: [RoadSegment] = []
    private var lastCacheCenter: CLLocationCoordinate2D?
    private let cacheRadiusDegrees = 0.03 // Approx 2 miles
    private let triggerDistanceMeters = 1609.0 // 1 mile
    
    // Grid precision: 0.02 degrees is roughly 2.2km per cell.
    // Larger cells mean fewer DB queries per drive and better route pre-cache coverage.
    private let gridPrecision = 0.02
    private var spatialCache: [String: [RoadSegment]] = [:]
    private var lastSegmentId: String?
    
    private init() {}
    
    deinit {
        if let db = db {
            sqlite3_close_v2(db)
        }
    }

    // MARK: - Data Models
    
    struct RoadSegment: Sendable {
        let minx: Double
        let maxx: Double
        let miny: Double
        let maxy: Double
        let limit: Int
        let routeId: String?

        var area: Double {
            return (maxx - minx) * (maxy - miny)
        }

        /// Point-to-bounding-box edge distance in meters. Used as the SPATIAL
        /// GATE (`maxSnappingDistance`) so points physically inside the bbox
        /// always pass without forcing us to parse the actual polyline.
        /// DO NOT use this for scoring: a coord inside a 36km × 5km freeway
        /// bbox would return 0, which would let a freeway out-score a tight
        /// cross-street 15m away.
        func distance(to coord: CLLocationCoordinate2D) -> CLLocationDistance {
            let dx = max(0.0, minx - coord.longitude, coord.longitude - maxx)
            let dy = max(0.0, miny - coord.latitude, coord.latitude - maxy)

            if dx == 0 && dy == 0 { return 0 }

            // Geographic to meters approximation
            let latDist = dy * 111111.0
            let lonDist = dx * 111111.0 * cos(coord.latitude * .pi / 180.0)
            return sqrt(latDist * latDist + lonDist * lonDist)
        }

        /// Offset (meters) from the bbox's inferred centerline. Used as the
        /// SCORING PENALTY so a coord inside a giant freeway bbox that's
        /// actually a few hundred meters off the freeway reports a centerline
        /// offset rather than 0.
        ///
        /// Math: high-aspect-ratio bboxes (e.g., S 202 Santan Freeway:
        /// dx=0.325°, dy=0.049° → aspectRatio ≈ 6.6) are modeled as corridors
        /// whose centerline lies along the major axis. Square or nearly-square
        /// bboxes are treated as 2-D areas, so a coord inside them returns 0
        /// (matching the legacy behavior to keep small-area roads unchanged).
        /// Continuous across the bbox edge: clamped at `h/2` or `w/2` so we
        /// don't double-count the edge distance.
        func centerlineOffset(to coord: CLLocationCoordinate2D) -> CLLocationDistance {
            let w = maxx - minx
            let h = maxy - miny
            let cx = minx + w / 2.0
            let cy = miny + h / 2.0

            var inDx = 0.0
            var inDy = 0.0

            if w > h && w > 0 {
                // Horizontal-dominant corridor. Centerline is `lat = cy`.
                // Aspect-ratio factor: 1.0 for a perfect line, 0.0 for square.
                let factor = 1.0 - (h / w)
                inDy = min(abs(coord.latitude - cy), h / 2.0) * factor
            } else if h > w && h > 0 {
                // Vertical-dominant corridor. Centerline is `lon = cx`.
                let factor = 1.0 - (w / h)
                inDx = min(abs(coord.longitude - cx), w / 2.0) * factor
            }
            // Square / nearly-square bbox: factor ≈ 0 → no penalty. Preserves
            // legacy "coord inside tight local-road bbox = distance 0" behavior,
            // because those roads are exactly the ones whose snap is correct.

            let latDist = inDy * 111111.0
            let lonDist = inDx * 111111.0 * cos(coord.latitude * .pi / 180.0)
            return sqrt(latDist * latDist + lonDist * lonDist)
        }
    }

    // MARK: - Public API
    
    /// Opens the SQLite-based geodatabase at the specified file path.
    public func loadDatabase(at path: String) -> Bool {
        guard !isLoaded else { return true }
        
        let result = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        if result == SQLITE_OK {
            isLoaded = true
            DebugLogger.shared.log("DB OPENED: \(URL(fileURLWithPath: path).lastPathComponent)")
            print("[AZ Data] Geodatabase OPENED at \(path)")
            return true
        } else {
            let errmsg = db != nil ? String(cString: sqlite3_errmsg(db)!) : "Unknown error"
            DebugLogger.shared.log("DB OPEN FAILED: \(errmsg)")
            print("[AZ Data] FAILED to open geodatabase: \(result) - \(errmsg)")
            return false
        }
    }
    
    /// Opens the geodatabase from the app bundle.
    public func loadDataIfNeeded() {
        guard !isLoaded else { return }
        
        // First try the prioritized name
        let possibleNames = [
            ("ArizonaSpeedLimits", "sqlite"),
            ("ArizonaSpeedLimits", "db"),
            ("HPMS_2024_Data_-2111065798425599378", "geodatabase")
        ]
        
        DebugLogger.shared.log("Searching for DB...")
        
        for (name, ext) in possibleNames {
            if let url = Bundle.main.url(forResource: name, withExtension: ext) {
                DebugLogger.shared.log("Found DB candidate: \(name).\(ext)")
                if loadDatabase(at: url.path) {
                    return
                }
            }
        }
        
        // Search entire bundle one level deep
        let bundleURL = Bundle.main.bundleURL
        DebugLogger.shared.log("Scanning bundle: \(bundleURL.lastPathComponent)")
        
        if let contents = try? FileManager.default.contentsOfDirectory(at: bundleURL, includingPropertiesForKeys: nil) {
            let fileList = contents.map { $0.lastPathComponent }.joined(separator: ", ")
            DebugLogger.shared.log("Bundle Files: \(fileList)")
            
            for url in contents {
                // If it's a directory, list its contents too
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    if let subContents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                        let subList = subContents.map { $0.lastPathComponent }.joined(separator: ", ")
                        DebugLogger.shared.log("Inside \(url.lastPathComponent): \(subList)")
                        
                        for subUrl in subContents {
                            let ext = subUrl.pathExtension.lowercased()
                            if ["sqlite", "db", "geodatabase", "gpkg"].contains(ext) {
                                DebugLogger.shared.log("Found \(ext) in subfolder: \(subUrl.lastPathComponent)")
                                if loadDatabase(at: subUrl.path) {
                                    return
                                }
                            }
                        }
                    }
                }
                
                let ext = url.pathExtension.lowercased()
                if ["sqlite", "db", "geodatabase", "gpkg"].contains(ext) {
                    DebugLogger.shared.log("Found \(ext) file: \(url.lastPathComponent)")
                    if loadDatabase(at: url.path) {
                        return
                    }
                }
            }
        }
        
        DebugLogger.shared.log("DB NOT FOUND in initial scan - trying recursive search...")
        
        // Final recursive attempt
        if let enumerator = FileManager.default.enumerator(at: bundleURL, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator {
                if ["sqlite", "db", "geodatabase", "gpkg"].contains(url.pathExtension.lowercased()) {
                    if loadDatabase(at: url.path) {
                        return
                    }
                }
            }
        }
        
        DebugLogger.shared.log("FATAL: DB NOT FOUND anywhere.")
        print("[AZ Data] No supported geodatabase file found in bundle.")
        isLoaded = true // Stop trying
    }

    /// Finds the legal speed limit for a given coordinate.
    /// Added heading awareness to prevent snapping to cross-streets or nearby parallel roads.
    /// `roadName` (NEW) is the reverse-geocoded road name from RoadGeocoder. When
    /// non-nil, the scoring uses RoadNameMatcher against each candidate's
    /// `RouteId`/`SRNumber` and applies a large negative offset to any matching
    /// candidate, so the user-on-West-Frye-Road case no longer snares the
    /// nearest big-bbox freeway segment. Pass `nil` to disable.
    public func updateSpeedLimit(at coordinate: CLLocationCoordinate2D, heading: Double? = nil, currentSpeedMph: Double? = nil, roadName: String? = nil, expandedSearch: Bool = false) async throws -> Int {
        if !isLoaded {
            loadDataIfNeeded()
        }
        if db == nil {
            throw URLError(.resourceUnavailable)
        }

        // Trigger recache if first run or if moved > 1 mile from previous cache center
        let shouldRefresh = lastCacheCenter == nil || 
                           coordinate.distance(from: lastCacheCenter!) > triggerDistanceMeters
        
        if shouldRefresh {
            refreshCircularCache(at: coordinate)
        }

        let segments = circularCache // Use the high-speed memory cache
        
        var closestLimit: Int?
        var closestRouteId: String?
        var minScore: Double = Double.infinity        // --- PRECISION SNAPPING ---
        // Tightening snapping radius significantly to prevent jumping to nearby overpasses.
        // Surface streets are rarely more than 15-20m from the center line.
        let maxSnappingDistance: CLLocationDistance = expandedSearch ? 60.0 : 20.0

        // Scoring constants.
        //   SCORE_BASE_OFFSET: an additive floor on `(distance)` so that heading
        //     / velocity / hysteresis multipliers (× 0.15 .. × 40) retain enough
        //     leverage to push the actual road above any cross-street that
        //     happens to lie inside a huge infrastructure bbox. With 1.0 (the
        //     old value) a single hitch point where the user is *truly* on the
        //     freeway but the cross-street lies inside its corridor would have
        //     flipped the answer — 25.0 raises the floor so that hitch is
        //     correctly resolved by the heading/velocity multipliers.
        //   CORRIDOR_PENALTY: uses RoadSegment.centerlineOffset(to:) to add the
        //     perpendicular distance from the inferred centerline as a flat
        //     score penalty. Replaces the old `area * 50.0` tie-breaker, which
        //     was not strong enough to demote a freeway whose bbox already
        //     contains the user's coord.
        //   NAME_MATCH_BONUS_MAGNITUDE: when a reverse-geocoded road name is
        //     available, RoadNameMatcher.score returns 0.0..1.0; we translate
        //     that into `-magnitude * score` as an additive offset. 10000 is
        //     chosen so any positive match (>= 0.5) decisively outscores any
        //     pure-spatial candidate, even a 2-km ~plus-cross-street score.
        let SCORE_BASE_OFFSET: Double = 25.0
        let NAME_MATCH_BONUS_MAGNITUDE: Double = 10000.0
        // Mirrored to website/server.py for byte-for-byte parity.
        // NAME_MATCH_SPATIAL_GATE_M (200 m) is the wider gate used when we
        // are doing the name-first pass. It deliberately exceeds the legacy
        // 20 m SNAP_RADIUS_M so imperfect ESRI geodatabase bboxes don't
        // accidentally exclude the user's actual road.
        // NAME_MATCH_THRESHOLD (0.5) is the minimum RoadNameMatcher.score
        // for a candidate to qualify -- covers the matchScore hierarchy
        // exactly (canonical, subset, numeric + strict-family, numeric +
        // generic-type) and excludes 0.0 (no match).
        let NAME_MATCH_SPATIAL_GATE_M: Double = 200.0
        let NAME_MATCH_THRESHOLD: Double = 0.5
        // Defense-in-depth: if the user is on a residential street but no
        // road_name came back from reverse-geocode, a corridor (aspect > 3)
        // whose centerlineOffset exceeds AMBIGUOUS_CORRIDOR_OFFSET_M
        // (250 m) is treated as ambiguous. Its score gets a massive penalty
        // (AMBIGUOUS_CORRIDOR_PENALTY) so a tight local-road candidate wins
        // even when the ambiguous corridor is technically "closer" (dist=0
        // because of mega-bbox engulfment). Mirrors Python server.py.
        let AMBIGUOUS_CORRIDOR_ASPECT_RATIO: Double = 3.0
        let AMBIGUOUS_CORRIDOR_OFFSET_M: Double = 250.0
        let AMBIGUOUS_CORRIDOR_PENALTY: Double = 2000.0
        let PASS2_LOCAL_ROAD_RADIUS_M: Double = 1000.0

        // ---- PASS 1: name-first across the cache, wide gate ----
        // When a reverse-geocoded road name is available, gate candidates by
        // NAME_MATCH_SPATIAL_GATE_M (200 m, wider than the legacy 20 m
        // spatial gate) and require at least NAME_MATCH_THRESHOLD (0.5) from
        // RoadNameMatcher. The best name-matching candidate wins. If NONE
        // qualifies (the user's known road has no SQL coverage near here),
        // we DELIBERATELY reject SQLite entirely so the orchestrator falls
        // through to live ArcGIS / Overpass. Falling back to pure-spatial in
        // this case would let a freeway mega-bbox like S 202 vault to the
        // top, which is the bug the user just hit ("on Arizona Ave but gets
        // 65 mph from S 202 because S 202's corridor overlaps me").
        if let providedRoadName = roadName {
            var nameBestLimit: Int? = nil
            var nameBestRouteId: String? = nil
            var nameMinScore: Double = .infinity
            for segment in segments {
                guard segment.limit > 0 else { continue }
                let dx = segment.maxx - segment.minx
                let dy = segment.maxy - segment.miny
                if sqrt(dx*dx + dy*dy) > 1.0 { continue }
                let distance = segment.distance(to: coordinate)
                guard distance <= NAME_MATCH_SPATIAL_GATE_M else { continue }
                let nameMatch = RoadNameMatcher.score(
                    geocodedName: providedRoadName,
                    sqliteRouteId: segment.routeId
                )
                guard nameMatch >= NAME_MATCH_THRESHOLD else { continue }
                // Pre-hysteresis score (we still apply the bias last).
                var score = (distance + SCORE_BASE_OFFSET)
                score += segment.centerlineOffset(to: coordinate)
                score -= NAME_MATCH_BONUS_MAGNITUDE * nameMatch
                let hysteresis: Double
                if let lastId = self.lastSegmentId, segment.routeId == lastId {
                    hysteresis = 0.15
                } else {
                    hysteresis = 1.0
                }
                score *= hysteresis
                if score < nameMinScore {
                    nameMinScore = score
                    nameBestLimit = segment.limit
                    nameBestRouteId = segment.routeId
                }
            }
            if let matched = nameBestLimit, matched > 0 {
                self.lastSegmentId = nameBestRouteId
                DebugLogger.shared.log("AZ Data: name-first hit \(matched) on \(nameBestRouteId ?? "unknown road") (geocoded '\(providedRoadName)')")
                return matched
            }
            // ---- PASS 1.5: bearing-dominant spatial salvage ----
            // Why this exists (TestFlight 2.1.4 feedback from
            // srihan.yeleswarapu@gmail.com): "E Riggs Rd is 45 mph and it
            // found 25 mph." E Riggs Rd is an east-west arterial in the
            // Phoenix east valley. CLGeocoder correctly resolves the road
            // name to "E Riggs Rd", but the SQLite `RouteId` for the
            // segment is stored without the directional prefix (e.g.
            // "07 RIGGS RD"), and `RoadNameMatcher.normalize(_:)` strips
            // the alpha prefix AND the directional prefix on its way to a
            // canonical form. After normalization both sides read as
            // "RIGGS RD" -- which should match -- but if there's any
            // whitespace / zero-padding drift the canonical compare fails
            // AND Pass 1's `RoadNameMatcher.score(...)` rounds to < 0.5.
            // Before Pass 1.5, the fallback was: throw URLError and let
            // the orchestrator walk live providers. ArcGIS / Overpass
            // also miss E Riggs Rd (municipal arterials aren't in HPMS),
            // and SQLite was rejected on each retry, so the lower-speed
            // 25 mph cross-street would win by default.
            //
            // Pass 1.5 runs ONLY when `roadName` is provided. It does a
            // strict physical-physical match: the candidate's bbox must
            // be directional (mostly N-S or mostly E-W), it must be
            // within 30 m of the user, AND the user's heading must
            // align with the candidate's dominant axis within 30°.
            // Tight gates block the S 202 mega-bbox case from regressing:
            // a freeway 65 m from the user with the wrong heading do
            // NOT pick up, but the right road RIGHT under the user does.
            if let currentHeading = heading {
                var salvageLimit: Int? = nil
                var salvageRouteId: String? = nil
                var salvageMinScore: Double = .infinity
                for segment in segments {
                    guard segment.limit > 0 else { continue }
                    let dx = segment.maxx - segment.minx
                    let dy = segment.maxy - segment.miny
                    if sqrt(dx*dx + dy*dy) > 1.0 { continue }
                    let distance = segment.distance(to: coordinate)
                    // 30 m gate -- wider than Pass 2's legacy 20 m but
                    // still tight enough that a freeway 65 m away can't
                    // pickup. The previous 20 m gate was the reason many
                    // legit local-road answers required expandedSearch.
                    guard distance <= 30.0 else { continue }
                    let isNorthSouth = dy > (dx * 1.5)
                    let isEastWest   = dx > (dy * 1.5)
                    guard isNorthSouth || isEastWest else { continue }
                    let roadHeading = isNorthSouth ? 0.0 : 90.0
                    let raw = abs(currentHeading.truncatingRemainder(dividingBy: 180) - roadHeading)
                    let normalizedDiff = min(raw, 180 - raw)
                    // Require the user's heading to actually match the
                    // road's dominant axis. 30° is generous enough to
                    // cover a slight misalignment at intersections but
                    // tight enough that a 45 mph E-W road can NOT pickup
                    // from a driver who reports a 90° off-axis heading
                    // (e.g. they're actually on a N-S cross-street).
                    guard normalizedDiff < 30 else { continue }
                    var score = (distance + SCORE_BASE_OFFSET)
                    // Reward the bearing match HARD so the residual
                    // spatial sub-score has no chance of vaulting a
                    // bigger-but-mismatched bbox over our candidate.
                    if normalizedDiff < 10 {
                        score += 100.0  // excellent alignment bonus
                    } else {
                        score += 30.0   // acceptable alignment
                    }
                    if score < salvageMinScore {
                        salvageMinScore = score
                        salvageLimit = segment.limit
                        salvageRouteId = segment.routeId
                    }
                }
                if let salvaged = salvageLimit, salvaged > 0 {
                    self.lastSegmentId = salvageRouteId
                    DebugLogger.shared.log("AZ Data: Pass 1.5 salvaged \(salvaged) on \(salvageRouteId ?? "unknown road") via bearing alignment (geocoded '\(providedRoadName)' had no name match)")
                    return salvaged
                }
            }
            // No name-matching candidate within the 200 m gate AND no
            // bearing-aligned corridor within 30 m -> REJECT SQLite so
            // the SpeedLimitService orchestrator falls through to
            // ArcGIS + Overpass. This preserves the original safety net
            // for cases where the user's road truly has no SQL coverage
            // (and Pass 1.5's tight bearing gate rightly stayed silent)
            // but lets the local-DB answer win for the E Riggs Rd case
            // where the SQLite has the data and the user is clearly on
            // the road, just with a name normalization drift.
            DebugLogger.shared.log("AZ Data: no SQL coverage for geocoded '\(providedRoadName)' within \(Int(NAME_MATCH_SPATIAL_GATE_M)) m and no bearing-aligned corridor within 30 m -> REJECT SQLite")
            throw URLError(.resourceUnavailable)
        }

        // ---- PASS 2: spatial-only fallback (no reverse-geocoded name) ----
        // Same defense-in-depth as Python: ambiguous mega-bbox corridors
        // (high aspect ratio + centerline offset > 250 m) get a +2000 score
        // penalty so a tight local road wins regardless of dist=0 engulfment.
        for segment in segments {
            guard segment.limit > 0 else { continue }
            let dx = segment.maxx - segment.minx
            let dy = segment.maxy - segment.miny
            if sqrt(dx*dx + dy*dy) > 1.0 { continue }
            let distance = segment.distance(to: coordinate)
            let offset = segment.centerlineOffset(to: coordinate)
            let minDim = min(dx, dy)
            let maxDim = max(dx, dy)
            let isCorridor = minDim > 0.0 &&
                maxDim > AMBIGUOUS_CORRIDOR_ASPECT_RATIO * minDim
            let isAmbiguous = isCorridor && offset > AMBIGUOUS_CORRIDOR_OFFSET_M
            // Gate: ambiguous corridors see the legacy 20 m snap gate; other
            // candidates see the wider 1000 m gate so local roads can beat
            // engulfing mega-bbox corridors.
            let effectiveRadius = isAmbiguous
                ? maxSnappingDistance
                : PASS2_LOCAL_ROAD_RADIUS_M
            guard distance <= effectiveRadius else { continue }

            var scoreMultiplier: Double = 1.0
            if let carHeading = heading {
                let isNorthSouth = dy > (dx * 1.5)
                let isEastWest = dx > (dy * 1.5)
                let isHighlyDirectional = isNorthSouth || isEastWest
                if isHighlyDirectional {
                    let roadHeading = isNorthSouth ? 0.0 : 90.0
                    let diff = abs(carHeading.truncatingRemainder(dividingBy: 180) - roadHeading)
                    let normalizedDiff = min(diff, 180 - diff)
                    if normalizedDiff > 40 { scoreMultiplier *= 40.0 }
                    else if normalizedDiff > 20 { scoreMultiplier *= 5.0 }
                }
            }
            if let currentSpdMph = currentSpeedMph {
                let speedDiff = abs(Double(segment.limit) - currentSpdMph)
                if speedDiff > 30 { scoreMultiplier *= 25.0 }
                else if speedDiff > 15 { scoreMultiplier *= 6.0 }
                else if speedDiff < 5 { scoreMultiplier *= 0.7 }
            }

            var score = (distance + SCORE_BASE_OFFSET) * scoreMultiplier
            score += offset
            if isAmbiguous { score += AMBIGUOUS_CORRIDOR_PENALTY }
            // No name bonus: this is the no-roadName path.
            if let lastId = self.lastSegmentId, segment.routeId == lastId {
                score *= 0.15
            }
            if score < minScore {
                minScore = score
                closestLimit = segment.limit
                closestRouteId = segment.routeId
            }
        }
        
        if let limit = closestLimit, limit > 0 { 
            self.lastSegmentId = closestRouteId
            DebugLogger.shared.log("AZ Data: Found limit \(limit) on \(closestRouteId ?? "unknown road")")
            return limit 
        }
        
        DebugLogger.shared.log("AZ Data: No segment found within \(Int(maxSnappingDistance))m of [\(coordinate.latitude), \(coordinate.longitude)]")
        throw URLError(.resourceUnavailable)
    }

    // MARK: - Private Logic
    
    private func getSegmentsForGrid(lat: Double, lon: Double) -> [RoadSegment] {
        // Use floor() for stable, non-overlapping tile boundaries.
        // round() caused the same real-world point to map to different keys depending
        // on minor floating-point drift, breaking the cache hit rate.
        let latK = floor(lat / gridPrecision) * gridPrecision
        let lonK = floor(lon / gridPrecision) * gridPrecision
        let key = String(format: "%.4f_%.4f", latK, lonK)
        
        if let cached = spatialCache[key] {
            return cached
        }
        
        let segments = queryDatabase(lat: latK, lon: lonK)
        DebugLogger.shared.log("CACHE MISS: Loaded \(segments.count) road segments for grid \(key)")
        spatialCache[key] = segments
        return segments
    }

    // Helper method gridKey removed - logic moved inline for clarity


    private func queryDatabase(lat: Double, lon: Double) -> [RoadSegment] {
        guard let db = db else { return [] }
        let searchBuffer = gridPrecision
        var segments: [RoadSegment] = []
        
        let sql = """
            SELECT a.SpeedLimit, b.minx, b.maxx, b.miny, b.maxy, a.RouteId
            FROM SpeedLimit_2024 a
            JOIN st_spindex__SpeedLimit_2024_SHAPE b ON a.OBJECTID = b.pkid
            WHERE ? <= b.maxx AND ? >= b.minx
              AND ? <= b.maxy AND ? >= b.miny
        """
        
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_double(stmt, 1, lon - searchBuffer)
            sqlite3_bind_double(stmt, 2, lon + searchBuffer)
            sqlite3_bind_double(stmt, 3, lat - searchBuffer)
            sqlite3_bind_double(stmt, 4, lat + searchBuffer)
            
            while sqlite3_step(stmt) == SQLITE_ROW {
                let limit = Int(sqlite3_column_int(stmt, 0))
                let minx = sqlite3_column_double(stmt, 1)
                let maxx = sqlite3_column_double(stmt, 2)
                let miny = sqlite3_column_double(stmt, 3)
                let maxy = sqlite3_column_double(stmt, 4)
                let routeId = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
                
                segments.append(RoadSegment(minx: minx, maxx: maxx, miny: miny, maxy: maxy, limit: limit, routeId: routeId))
            }
            sqlite3_finalize(stmt)
        } else {
            let errmsg = String(cString: sqlite3_errmsg(db)!)
            DebugLogger.shared.log("DB QUERY ERR: \(errmsg)")
            print("[AZ Data] Query preparation failed: \(errmsg)")
            sqlite3_finalize(stmt)
        }
        
        if segments.isEmpty {
            DebugLogger.shared.log("DB: Zero matches in grid cell. Check if you are in Arizona.")
        }
        
        return segments
    }

    // MARK: - Phase 2 -- SQLite-first fast pre-check

    /// Returns true if any AZ-speed-limit segment is registered within ~1 km of
    /// `coordinate`, without committing to a snap. Used by SpeedLimitService as a
    /// cheap gate to prefer the local SQLite over network providers when the
    /// driver is in well-known corridor territory.
    ///
    /// Refreshing the 2-mile circular cache normally if we've moved more than a
    /// mile since last fill. Cheap: walks the in-memory circularCache (a few
    /// hundred segments at most); no DB query on the hit path.
    public func hasNearbyCoverage(
        at coordinate: CLLocationCoordinate2D,
        heading: Double? = nil
    ) -> Bool {
        if !isLoaded { loadDataIfNeeded() }
        guard db != nil else { return false }

        let shouldRefresh = lastCacheCenter == nil ||
            coordinate.distance(from: lastCacheCenter!) > triggerDistanceMeters
        if shouldRefresh {
            refreshCircularCache(at: coordinate)
        }

        // Any segment within 1 km of the coord, with a sensible area cap (drop
        // generic county-wide polygons), counts. Heading is intentionally ignored
        // here -- the goal is "is there a known corridor nearby?", not a snap.
        let corridorRadius: CLLocationDistance = 1000.0
        for segment in circularCache where segment.limit > 0 {
            let dx = segment.maxx - segment.minx
            let dy = segment.maxy - segment.miny
            let diagonalDegrees = sqrt(dx * dx + dy * dy)
            if diagonalDegrees > 1.0 { continue }  // skip huge county polygons
            if segment.distance(to: coordinate) <= corridorRadius {
                return true
            }
        }
        return false
    }

    // MARK : Circular Cache

    private func refreshCircularCache(at center: CLLocationCoordinate2D) {
        guard let db = db else { return }
        var segments: [RoadSegment] = []
        
        let sql = """
            SELECT a.SpeedLimit, b.minx, b.maxx, b.miny, b.maxy, a.RouteId
            FROM SpeedLimit_2024 a
            JOIN st_spindex__SpeedLimit_2024_SHAPE b ON a.OBJECTID = b.pkid
            WHERE ? <= b.maxx AND ? >= b.minx
              AND ? <= b.maxy AND ? >= b.miny
        """
        
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            // Bind a box covering the 2-mile radius
            sqlite3_bind_double(stmt, 1, center.longitude - cacheRadiusDegrees)
            sqlite3_bind_double(stmt, 2, center.longitude + cacheRadiusDegrees)
            sqlite3_bind_double(stmt, 3, center.latitude - cacheRadiusDegrees)
            sqlite3_bind_double(stmt, 4, center.latitude + cacheRadiusDegrees)
            
            while sqlite3_step(stmt) == SQLITE_ROW {
                segments.append(RoadSegment(
                    minx: sqlite3_column_double(stmt, 1),
                    maxx: sqlite3_column_double(stmt, 2),
                    miny: sqlite3_column_double(stmt, 3),
                    maxy: sqlite3_column_double(stmt, 4),
                    limit: Int(sqlite3_column_int(stmt, 0)),
                    routeId: sqlite3_column_text(stmt, 5).map { String(cString: $0) }
                ))
            }
            sqlite3_finalize(stmt)
        }
        
        self.circularCache = segments
        self.lastCacheCenter = center
        DebugLogger.shared.log("Cache: Refreshed 2-mile radius with \(segments.count) segments.")
    }

    private func boundingBox(for center: CLLocationCoordinate2D, radius: Double) -> (minx: Double, maxx: Double, miny: Double, maxy: Double) {
        return (
            center.longitude - radius,
            center.longitude + radius,
            center.latitude - radius,
            center.latitude + radius
        )
    }

    private func intersects(_ segment: RoadSegment, _ bounds: (minx: Double, maxx: Double, miny: Double, maxy: Double)) -> Bool {
        return segment.maxx >= bounds.minx && segment.minx <= bounds.maxx &&
               segment.maxy >= bounds.miny && segment.miny <= bounds.maxy
    }

    // Distance logic moved into RoadSegment struct.

    
    // parseWKBLineString is removed as Esri geodatabases use proprietary 
    // Compressed Geometry. We use spatial index bounding boxes instead natively.

    /// Clears the spatial cache.
    public func clearCache() {
        spatialCache.removeAll()
    }
    
    /// Pre-caches speed limits along a planned route.
    public func preCacheRoute(coordinates: [CLLocationCoordinate2D]) async {
        for coord in coordinates {
            // We search in 3x3 grid around each point to ensure coverage
            let searchOffsets = [-gridPrecision, 0.0, gridPrecision]
            for latOff in searchOffsets {
                for lonOff in searchOffsets {
                    _ = getSegmentsForGrid(lat: coord.latitude + latOff, 
                                         lon: coord.longitude + lonOff)
                }
            }
        }
    }
}

// MARK: - Extensions
extension CLLocationCoordinate2D {
    func distance(from other: CLLocationCoordinate2D) -> CLLocationDistance {
        let locA = CLLocation(latitude: self.latitude, longitude: self.longitude)
        let locB = CLLocation(latitude: other.latitude, longitude: other.longitude)
        return locA.distance(from: locB)
    }
}