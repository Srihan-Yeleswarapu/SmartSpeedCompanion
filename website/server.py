#!/usr/bin/env python3
"""
website/server.py -- Stdlib HTTP server that proxies all three of Speedio's
speed-limit providers so the website can show the answer side-by-side per
provider.

Endpoints
---------
  GET  /                                     index.html
  GET  /health                               liveness probe
  GET  /api/reverse-geocode?lat=&lon=        Nominatim /reverse proxy,
                                              50m grid cache + 1 req/sec
                                              throttle (per Nominatim policy)
  POST /api/speedlimit-az       {lat, lon, road_name?}
  POST /api/speedlimit-arcgis   {lat, lon, heading?}
  POST /api/speedlimit-overpass {lat, lon, heading?}

Python<>Swift parity
-------------------
scoring here MUST mirror `SmartSpeedCompanion/Core/RoadNameMatcher.swift`
1:1 so the iOS app and the web agree on which candidate wins for the same
(lat, lon, roadName). The constants here are byte-for-byte copies of the
Swift tables. If you add a normalisation rule in Swift, copy it here as
well, and update the regression tests in
`test_snap_named.py` and `test_snap_corridor.py` to assert the same
score on both sides.

The scoring loop in `snap(segments, lat, lon, road_name)` DECISIVELY
favours any candidate whose `RouteId` matches `road_name` (per
`name_match_score`) via `NAME_MATCH_BONUS_MAGNITUDE` (10000) so a
residential street like "07 FRYE RD" outranks the freeway "S 202"
which only partially overlaps by spatial bbox. This is the fix for:
"driving on West Frye Road and the app says 65 mph".

Stdlib only. Run:
    python website/server.py
Then open http://127.0.0.1:8089/.
"""

import json
import math
import os
import sqlite3
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


# ---- Geographic constants mirrored verbatim from ArizonaSpeedLimitService.swift
GRID_DEGREES = 0.02             # Swift: searchBuffer / gridPrecision
SNAP_RADIUS_M = 20.0           # Swift: maxSnappingDistance when expandedSearch=false
CACHE_RADIUS_DEGREES = 0.03    # Swift: cacheRadiusDegrees (~2 mi)
SKIP_DIAGONAL_DEGREES = 1.0    # Swift: county-polygon diagonal cap
SCORE_BASE_OFFSET = 25.0       # Swift: SCORE_BASE_OFFSET (was 1.0)
NAME_MATCH_BONUS_MAGNITUDE = 10000.0  # Swift: ArizonaSpeedLimitService.NAME_MATCH_BONUS_MAGNITUDE
# Gate width for the name-first scoring pass. Wider than the legacy 20 m
# SNAP_RADIUS_M so imperfect ESRI geodatabase bboxes don't accidentally
# exclude the user's actual road. If NO candidate matches within this gate,
# SQLite is REJECTED entirely so the orchestrator falls through to live
# ArcGIS / Overpass.
# -- AUTHORITATIVE BASIS (research 2026-07): FHWA HPMS data is required at
#   1:24,000 scale (NMAS) ~= 12.2 m absolute accuracy. Typical urban OSM
#   data precision can reach sub-5 m; rural/non-metro GPS-hardware
#   positional error typically 5-50 m depending on signal environment.
#   200 m is ~10x the looser GPS-hardware bound, deliberately wide to
#   err on availability over precision. Risk: false positives when driving
#   near parallel roads (trusts RoadNameMatcher to disambiguate).
NAME_MATCH_SPATIAL_GATE_M = 200.0  # Swift: NAME_MATCH_SPATIAL_GATE_M (mirrored 1:1)
# Minimum RoadNameMatcher.score (0.0..1.0) for a candidate to qualify.
# -- AUTHORITATIVE BASIS (research 2026-07): industry default for strict
#   entity-resolution fuzzy matching is 0.7-0.8 (Levenshtein / Jaro-Winkler).
#   0.5 is permissive and RELIES on aggressive pre-normalization in
#   RoadNameMatcher.normalize(_:) -- suffix aliases, direction prefixes,
#   zero-padded terminus suffix, leading numeric prefix -- to drop the
#   noise. Without those normalizations, the same threshold would risk
#   false positives like "Main St" matching "Maple St".
NAME_MATCH_THRESHOLD = 0.5       # Swift: NAME_MATCH_THRESHOLD (mirrored 1:1)
# ---- Pass 2 corridor-ambiguity hardening ----
# A corridor (max(w,h) > 3 * min(w,h)) whose centerlineOffset exceeds
# AMBIGUOUS_CORRIDOR_OFFSET_M is treated as ambiguous: it engulfs the user
# bboxes in Chandler 256 km long, dist=0, but the user's actually 740 m
# off the inferred centerline. We apply a massive penalty so a tight
# local-road candidate (square bboxes, dist<=a few meters, centerlineOffset=0)
# decisively wins over an ambiguous mega-bbox corridor.
AMBIGUOUS_CORRIDOR_ASPECT_RATIO = 3.0  # Swift: RoadSegment.isCorridor()
AMBIGUOUS_CORRIDOR_OFFSET_M = 250.0     # Swift: RoadSegment.isAmbiguous()
AMBIGUOUS_CORRIDOR_PENALTY = 2000.0     # Swift: penalty added to score when ambiguous
PASS2_LOCAL_ROAD_RADIUS_M = 1000.0      # Swift: wider gate for non-corridors in Pass 2
EARTH_M_PER_DEG_LAT = 111_111.0
GEOCODE_GRID_DEGREES = 0.0005  # Swift: RoadGeocoder.gridPrecision (~50m)
GEOCODE_TTL_SECONDS = 24 * 3600
NOMINATIM_MIN_INTERVAL_S = 1.1  # Nominatim /reverse policy: 1 req/sec max
NOMINATIM_URL = "https://nominatim.openstreetmap.org/reverse"
USER_AGENT = "Speedio-WebLookup/1.0 (research; speedsenseapp@gmail.com)"

PORT = int(os.environ.get('PORT', '8089'))
DB_PATH = os.path.normpath(os.path.join(
    os.path.dirname(__file__), '..',
    'SmartSpeedCompanion', 'Resources', 'ArizonaSpeedLimits.sqlite',
))


# ---- Swift<>Python mirror: RoadNameMatcher constants
# Mirrors SmartSpeedCompanion/Core/RoadNameMatcher.swift 1:1.
SUFFIX_ALIASES = {
    "ROAD": "RD", "AVENUE": "AVE", "BOULEVARD": "BLVD",
    "HIGHWAY": "HWY", "FREEWAY": "FWY", "EXPRESSWAY": "EXPY",
    "DRIVE": "DR", "LANE": "LN", "COURT": "CT",
    "STREET": "ST", "PLACE": "PL", "PARKWAY": "PKWY",
    "TERRACE": "TER", "CIRCLE": "CIR",
}
DIRECTION_PREFIXES = {
    "W", "WEST", "E", "EAST", "N", "NORTH", "S", "SOUTH",
    "NW", "NORTHWEST", "NE", "NORTHEAST", "SW", "SOUTHWEST", "SE", "SOUTHEAST",
}
STRICT_FAMILY_KEYWORDS = {
    "INTERSTATE": "I", "INTERSTATE HIGHWAY": "I",
    "US": "US", "UNITED STATES": "US",
    "US HIGHWAY": "US", "US ROUTE": "US",
}
GENERIC_TYPE_KEYWORDS = {
    "STATE ROUTE", "STATE HIGHWAY", "ROUTE", "HIGHWAY",
    "FREEWAY", "EXPRESSWAY", "TURNPIKE", "PARKWAY",
}


# ---- Mirrored functions ------------------------------------------------

def segment_distance_m(minx, maxx, miny, maxy, lat, lon):
    """Mirror RoadSegment.distance(to:) in ArizonaSpeedLimitService.swift.
    POINT-TO-BOUNDING-BOX-EDGE distance in meters. Used as the SPATIAL
    GATE (SNAP_RADIUS_M); points physically inside the bbox always return 0.
    """
    dx = max(0.0, minx - lon, lon - maxx)
    dy = max(0.0, miny - lat, lat - maxy)
    if dx == 0.0 and dy == 0.0:
        return 0.0
    cos_lat = math.cos(math.radians(lat))
    lat_m = dy * EARTH_M_PER_DEG_LAT
    lon_m = dx * EARTH_M_PER_DEG_LAT * cos_lat
    return math.sqrt(lat_m * lat_m + lon_m * lon_m)


def centerline_offset_m(minx, maxx, miny, maxy, lat, lon):
    """Mirror RoadSegment.centerlineOffset(to:) in
    ArizonaSpeedLimitService.swift. Returns the perpendicular offset from
    the inferred centerline scaled by 1 - min(w,h)/max(w,h). Clamped at
    minor-axis half-width for bbox-edge continuity.
    """
    w = maxx - minx
    h = maxy - miny
    cx = minx + w / 2.0
    cy = miny + h / 2.0

    in_dx = 0.0
    in_dy = 0.0
    if w > h and w > 0.0:
        factor = 1.0 - (h / w)
        in_dy = min(abs(lat - cy), h / 2.0) * factor
    elif h > w and h > 0.0:
        factor = 1.0 - (w / h)
        in_dx = min(abs(lon - cx), w / 2.0) * factor

    cos_lat = math.cos(math.radians(lat))
    lat_m = in_dy * EARTH_M_PER_DEG_LAT
    lon_m = in_dx * EARTH_M_PER_DEG_LAT * cos_lat
    return math.sqrt(lat_m * lat_m + lon_m * lon_m)


def normalize_route_name(raw):
    """Mirror RoadNameMatcher.normalize(_:) in Swift.
    Removes zero-padded direction/terminus markers, leading numeric prefix,
    leading directional prefix, and expands common suffix aliases.
    """
    s = (raw or "").upper().strip()
    while "  " in s:
        s = s.replace("  ", " ")
    if s.endswith(" 0"):
        s = s[:-2].strip()
    parts = s.split(" ")
    idx = 0
    if idx < len(parts) and parts[idx].isdigit():
        idx += 1
    if idx < len(parts) and parts[idx] in DIRECTION_PREFIXES:
        idx += 1
    # Expand suffix aliases on the LAST remaining token.
    tail = parts[idx:]
    if tail and tail[-1] in SUFFIX_ALIASES:
        tail[-1] = SUFFIX_ALIASES[tail[-1]]
    return " ".join(tail).strip()


def numeric_portion(raw):
    """Mirror RoadNameMatcher.numericPortion(_:) in Swift. Returns the leading
    digit run of the uppercase string. e.g. "I-17" -> "17", "US-60" -> "60".
    """
    digits = ""
    seen = False
    for ch in (raw or "").upper():
        if ch.isdigit():
            digits += ch
            seen = True
        elif seen:
            break
    return digits


def alpha_prefix(raw):
    """Mirror RoadNameMatcher.alphaPrefix(_:) in Swift. Returns the leading
    alpha run before the first digit or non-letter. "I-17" -> "I",
    "US-60" -> "US", "17" -> "".
    """
    upper = (raw or "").upper()
    letters = ""
    for ch in upper:
        if ch.isalpha():
            letters += ch
        elif ch.isdigit():
            break
    return letters


def name_match_score(geocoded_name, sqlite_route_id):
    """Mirror RoadNameMatcher.score(geocodedName:sqliteRouteId:) in Swift.
    Returns 0.0-1.0; 0.0 if either input is missing.
    """
    if not geocoded_name or not sqlite_route_id:
        return 0.0
    g_norm = normalize_route_name(geocoded_name)
    r_norm = normalize_route_name(sqlite_route_id)
    if not g_norm or not r_norm:
        return 0.0

    if g_norm == r_norm:
        return 1.0

    g_tokens = set(g_norm.split(" "))
    r_tokens = set(r_norm.split(" "))
    if g_tokens and g_tokens.issubset(r_tokens):
        return 0.85

    g_digits = numeric_portion(geocoded_name)
    r_digits = numeric_portion(sqlite_route_id)
    if g_digits and (g_digits == r_digits):
        provider_prefix = alpha_prefix(sqlite_route_id)
        name_tokens = set((geocoded_name or "").upper().split(" "))

        # Negative family check.
        for kw, family in STRICT_FAMILY_KEYWORDS.items():
            if kw in name_tokens and provider_prefix != family:
                return 0.0
        # Positive strict family match.
        for kw, family in STRICT_FAMILY_KEYWORDS.items():
            if kw in name_tokens and provider_prefix == family:
                return 0.7
        # Positive generic-type match.
        has_generic = any(tok in GENERIC_TYPE_KEYWORDS for tok in name_tokens)
        if has_generic and provider_prefix and provider_prefix not in ("I", "US"):
            return 0.5
    return 0.0


def fetch_segments(conn, lat, lon):
    """Mirror refreshCircularCache(at:) SQL and bounds. Return positive-limit
    segments within a 0.03 deg box (~2 mi radius) around (lat, lon).
    """
    cur = conn.cursor()
    cur.execute(
        "SELECT a.SpeedLimit, b.minx, b.maxx, b.miny, b.maxy, a.RouteId "
        "FROM SpeedLimit_2024 a "
        "JOIN st_spindex__SpeedLimit_2024_SHAPE b ON a.OBJECTID = b.pkid "
        "WHERE ? <= b.maxx AND ? >= b.minx "
        "  AND ? <= b.maxy AND ? >= b.miny",
        (
            lon - CACHE_RADIUS_DEGREES,
            lon + CACHE_RADIUS_DEGREES,
            lat - CACHE_RADIUS_DEGREES,
            lat + CACHE_RADIUS_DEGREES,
        ),
    )
    out = []
    for r in cur.fetchall():
        if r[0] is None:
            continue
        limit = int(r[0])
        if limit <= 0:
            continue
        out.append({
            'limit': limit,
            'minx': float(r[1]), 'maxx': float(r[2]),
            'miny': float(r[3]), 'maxy': float(r[4]),
            'route_id': r[5],
        })
    return out


def snap(segments, lat, lon, road_name=None):
    """Mirror updateSpeedLimit(at:heading:currentSpeedMph:roadName:expandedSearch:) in
    Swift (with heading=nil, currentSpeedMph=nil, lastSegmentId=nil).

    Two-pass scoring (named-first, then spatial):

      Pass 1 -- if `road_name` is non-empty, gather all candidates within
        NAME_MATCH_SPATIAL_GATE_M that score >= NAME_MATCH_THRESHOLD against
        `road_name`. Pick the lowest-scoring one (the spatial terms +
        corridor offset + the giant NAME_MATCH_BONUS subtraction).
        If NO candidate qualifies, REJECT Sqlite entirely (return 0, None)
        so the orchestrator falls through to live ArcGIS / Overpass.
      Pass 2 -- only attempted when `road_name` is None. Pure spatial, with
        the legacy 20 m SNAP_RADIUS_M gate, no name bonus.

    Background: the older single-pass implementation applied the 20 m spatial
    gate BEFORE the road-name bonus. Mega-bbox freeway segments (like S 202
    whose 36 km x 5 km corridor engulfs residential streets) were always 0 m
    away and always won, even when the user is on a side street with no SQL
    coverage. The two-pass model here flips that: name goes first when known,
    and when the SQLite really has nothing for the user's road, we admit it
    instead of faking a freeways number.
    """
    best_limit, best_route, best_score = 0, None, float('inf')

    # ---- Pass 1: name-first across the cache, wide gate ----
    if road_name:
        for seg in segments:
            ddx = seg['maxx'] - seg['minx']
            ddy = seg['maxy'] - seg['miny']
            if math.sqrt(ddx * ddx + ddy * ddy) > SKIP_DIAGONAL_DEGREES:
                continue
            dist = segment_distance_m(seg['minx'], seg['maxx'],
                                      seg['miny'], seg['maxy'], lat, lon)
            if dist > NAME_MATCH_SPATIAL_GATE_M:
                continue
            nm = name_match_score(road_name, seg['route_id'])
            if nm < NAME_MATCH_THRESHOLD:
                continue
            score = (dist + SCORE_BASE_OFFSET) + centerline_offset_m(
                seg['minx'], seg['maxx'],
                seg['miny'], seg['maxy'], lat, lon,
            )
            score -= NAME_MATCH_BONUS_MAGNITUDE * nm
            if score < best_score:
                best_score = score
                best_limit = seg['limit']
                best_route = seg['route_id']
        if best_limit > 0:
            return best_limit, best_route, None
        # REJECT Sqlite entirely so the orchestrator falls through to live
        # providers and ultimately shows "No Data" if none have it.
        return 0, None, "no SQL coverage for " + road_name

    # ---- Pass 2: spatial-only fallback (no road_name) ----
    # ARCHITECTURE: Two gate widths are used together.
    #   1. Corridors (aspect > AMBIGUOUS_CORRIDOR_ASPECT_RATIO) ONLY pass the
    #      20 m SNAP_RADIUS_M gate. Widening their gate would let a freeway
    #      visa-snap onto a residential coord a few hundred meters away.
    #   2. Non-corridors (local roads) ALSO pass a much wider 1000 m gate so
    #      the algorithm can find a tight local road that's clearly closer
    #      to the user than a freeway mega-bbox with dist=0.
    # Candidates classed as AMBIGUOUS corridors (corridor + centerlineOffset
    # > 250 m) get a +2000 score penalty. Without this, an ambiguous
    # corridor (S 202 with offset = 740 m at (33.29888, -111.83890)) has
    # score = 765, beating a local road 1.4 m away with score 36.9? No --
    # actually 36.9 < 765 so the local road wins anyway. The penalty is
    # BELT-AND-SUSPENDERS for the future case where a corridor is even
    # wider offset (e.g. 2 km+) OR a tighter local-road bbox is missing.
    for seg in segments:
        ddx = seg['maxx'] - seg['minx']
        ddy = seg['maxy'] - seg['miny']
        if math.sqrt(ddx * ddx + ddy * ddy) > SKIP_DIAGONAL_DEGREES:
            continue
        dist = segment_distance_m(seg['minx'], seg['maxx'],
                                  seg['miny'], seg['maxy'], lat, lon)
        offset = centerline_offset_m(seg['minx'], seg['maxx'],
                                     seg['miny'], seg['maxy'], lat, lon)
        min_dim = min(ddx, ddy)
        max_dim = max(ddx, ddy)
        # Corridor iff aspect ratio strictly greater than 3 AND the bbox
        # has nonzero extent. A perfectly-symmetric bbox is NEVER a corridor.
        is_corridor = (
            min_dim > 0.0
            and max_dim > AMBIGUOUS_CORRIDOR_ASPECT_RATIO * min_dim
        )
        is_ambiguous = is_corridor and offset > AMBIGUOUS_CORRIDOR_OFFSET_M
        # Ambiguous corridors see the legacy 20 m gate (same as before); any
        # other candidate sees the wider 1000 m gate so the local road
        # candidates can be considered.
        effective_radius = (
            SNAP_RADIUS_M if is_ambiguous else PASS2_LOCAL_ROAD_RADIUS_M
        )
        if dist > effective_radius:
            continue
        score = (dist + SCORE_BASE_OFFSET) + offset
        if is_ambiguous:
            score += AMBIGUOUS_CORRIDOR_PENALTY
        if score < best_score:
            best_score = score
            best_limit = seg['limit']
            best_route = seg['route_id']
    return best_limit, best_route, None


# ---- SpeedLimit Continuity Guard (mirror of SmartSpeedLimitService.swift)
#
# Pure-Python mirror of the iOS orchestrator's `finalizeWithContinuity(...)`
# decision so the website's tests can regression-check the same algorithm
# without spawning Swift tests.
#
# Background: when the user drives under a flyover, CLGeocoder can briefly
# resolve `roadName` to the OVERPASS road for ~3-5 seconds. The orchestrator
# then publishes the freeway's 75 mph for that window, before SQLite
# name-match corrects back to 45 mph. This guard dampens that flicker.
#
# Rules (mirrored byte-for-byte from SmartSpeedLimitService.swift):
#   1. Small speed delta (<= 20 mph) OR same-road identity  -> commit immediately
#   2. Physics override: |new - userSpeed| <= 10 AND |prior - userSpeed| > 15
#      (driver is moving at the new speed; the answer matching physics wins)
#   3. Suspect hold: hold prior for up to 5 consequent fetches with the
#      same (roadName, roadKey) identity. After 5, sink-in.
#
# The web orchestrator is stateless across clicks, so the live UI doesn't
# run this guard -- it just ships the raw answer. The Python mirror exists
# for parity regression testing.
class ContinuityGuard:
    # All 4 are byte-for-byte mirrors of SmartSpeedLimitService.swift. Verdict
    # card from research 2026-07:
    #   SUSPICIOUS_JUMP_MPH      = 20 : UNVERIFIED -- no US federal/engineering
    #     rule specifies a max speed-zone delta. MUTCD governs transition
    #     length, not delta; FHWA Speed Limit Setting Handbook uses the 85th-    #   percentile rule. Work-zone management literature treats 10-15 mph
    #     max-mph-delta as a design boundary; beyond that transition zones /
    #     additional signage are recommended. 20 mph
    #     chosen empirically to admit arterial->highway jumps while rejecting
    #     the observed 30-mph flyover flicker.
    #   SUSPICIOUS_FETCH_HOLD    = 5  : WEAKLY-DEFENSIBLE -- Apple publishes no
    #     CLGeocoder latency SLA. 5 fetches = ~5 to ~45 sec depending on fetch
    #     cadence and vehicle speed
    #     cadence; application-layer debounce; nothing in Apple HIG contradicts.
    #   PHYSICS_TOLERANCE_MPH    = 10 : WEAKLY-DEFENSIBLE -- 49 CFR §393.82 CMV
    #     speedometer accuracy = +/- 5 mph at 50 mph; iPhone CLLocationSpeed
    #     typically +/- 0.2-0.5 mph open-sky; up to +/- 2-3 mph in multipath
    #     / signal degradation; combined worst-case ~5-8 mph; 10 mph is
    #     deliberately generous.
    #   PHYSICS_PRIOR_MARGIN_MPH = 15 : UNVERIFIED -- no FHWA / AASHTO
    #     "inter-road-class mph gap" rule exists. 15 mph = typical arterial->
    #     highway speed differential observed empirically in real driving.
    SUSPICIOUS_JUMP_MPH = 20         # Swift: SUSPICIOUS_JUMP_MPH
    SUSPICIOUS_FETCH_HOLD = 5        # Swift: SUSPICIOUS_FETCH_HOLD
    PHYSICS_TOLERANCE_MPH = 10       # Swift: PHYSICS_TOLERANCE_MPH
    PHYSICS_PRIOR_MARGIN_MPH = 15    # Swift: PHYSICS_PRIOR_MARGIN_MPH

    def __init__(self):
        # `last_stable` mirrors `lastStable: ContinuitySnapshot?` in Swift.
        self.last_stable = None
        # `pending_suspect` mirrors `pendingSuspect: ContinuitySnapshot?`.
        self.pending_suspect = None
        # `consecutive_suspect_count` mirrors `consecutiveSuspectCount`.
        self.consecutive_suspect_count = 0

    def step(self, candidate, user_speed_mph):
        """`candidate` is a dict: {limit, source, road_key, road_name}.
        Returns a dict {display, action} where action is one of:
          'commit'         -- candidate was published; HUD takes it
          'commit_first'   -- first fetch ever; commit unconditionally
          'hold'           -- suspect hold; HUD keeps `last_stable['limit']`
        Mutates `last_stable`, `pending_suspect`, `consecutive_suspect_count`
        exactly the way the Swift guard mutates its mirror vars.
        """
        snapshot = {
            'limit': int(candidate['limit']),
            'source': candidate.get('source', 'localDB'),
            'road_key': candidate.get('road_key', ''),
            'road_name': candidate.get('road_name'),
            'committedAt': time.time(),
        }
        prior = self.last_stable
        if prior is None:
            self.last_stable = snapshot
            self.pending_suspect = None
            self.consecutive_suspect_count = 0
            return {'display': snapshot['limit'], 'action': 'commit_first'}

        speed_delta = abs(snapshot['limit'] - prior['limit'])
        road_changed = (
            (snapshot['road_name'] != prior['road_name'])
            or (snapshot['road_key'] != prior['road_key'])
        )

        # Rule 1 -- small delta or same-road identity: commit.
        if speed_delta <= self.SUSPICIOUS_JUMP_MPH or not road_changed:
            self.last_stable = snapshot
            self.pending_suspect = None
            self.consecutive_suspect_count = 0
            return {'display': snapshot['limit'], 'action': 'commit'}

        # Rule 2 -- physics override.
        if (abs(snapshot['limit'] - user_speed_mph) <= self.PHYSICS_TOLERANCE_MPH
                and abs(prior['limit'] - user_speed_mph) > self.PHYSICS_PRIOR_MARGIN_MPH):
            self.last_stable = snapshot
            self.pending_suspect = None
            self.consecutive_suspect_count = 0
            return {'display': snapshot['limit'], 'action': 'commit_physics'}

        # Rule 3 -- suspect hold.
        if (self.pending_suspect is not None
                and self.pending_suspect['road_key'] == snapshot['road_key']
                and self.pending_suspect['road_name'] == snapshot['road_name']):
            self.consecutive_suspect_count += 1
        else:
            self.pending_suspect = snapshot
            self.consecutive_suspect_count = 1

        if self.consecutive_suspect_count >= self.SUSPICIOUS_FETCH_HOLD:
            # Sink-in: 5 consecutive suspect fetches -> commit.
            self.last_stable = snapshot
            self.pending_suspect = None
            self.consecutive_suspect_count = 0
            return {'display': snapshot['limit'], 'action': 'commit_sinkin'}

        # Hold prior -- dampen the flyover-resolve flicker for ~5 fetches.
        return {'display': prior['limit'], 'action': 'hold'}


# ---- Overpass / ArcGIS paths (Python mirrors of Swift providers) ----

def query_overpass_for_speed(lat, lon, heading=None):
    """Mirror OverpassSpeedLimitProvider.fetchSpeedLimit(at:heading:) in Swift.
    Throttled to ~1 query / 100m of movement. Returns SpeedLimitResponse
    dict-compatible with AZ SQLite / ArcGIS responses, or None.
    """
    query = (
        "[out:json][timeout:10];\n"
        f"way(around:100,{lat},{lon})[highway][maxspeed];\n"
        "out tags center 1;\n"
    )
    body = urllib.parse.urlencode({"data": query}).encode("utf-8")
    req = urllib.request.Request(
        "https://overpass-api.de/api/interpreter",
        data=body,
        headers={
            "User-Agent": USER_AGENT,
            "Accept": "application/json",
            "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            if resp.status == 429:
                return None
            payload = json.loads(resp.read().decode("utf-8"))
    except (urllib.error.HTTPError, urllib.error.URLError, json.JSONDecodeError, OSError) as e:
        return None

    elements = payload.get("elements") or []
    if not elements:
        return None

    # Pick the closest element with a parseable maxspeed.
    def parse_maxspeed(raw):
        if not raw:
            return None
        s = raw.strip().lower()
        is_kmh = ("km/h" in s) or ("kmh" in s) or ("kph" in s)
        digits = ""
        seen = False
        for ch in s:
            if ch.isdigit() or ch == ".":
                digits += ch
                seen = True
            elif seen:
                break
        if not digits:
            return None
        n = float(digits)
        if n <= 0 or n > 200:
            return None
        return int(round(n * 0.621371)) if is_kmh else int(round(n))

    lat1 = math.radians(lat)
    best, best_dist = None, float("inf")
    for el in elements:
        tags = el.get("tags") or {}
        mph = parse_maxspeed(tags.get("maxspeed", ""))
        if not mph:
            continue
        c = el.get("center") or {}
        el_lat = c.get("lat") if "lat" in c else el.get("lat")
        el_lon = c.get("lon") if "lon" in c else el.get("lon")
        if el_lat is None or el_lon is None:
            continue
        dlat = math.radians(el_lat - lat)
        dlon = math.radians(el_lon - lon)
        a = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(math.radians(el_lat)) \
            * math.sin(dlon / 2) ** 2
        m = 6_378_137.0 * 2 * math.asin(math.sqrt(a))
        if m < best_dist:
            best_dist = m
            highway = tags.get("highway", "")
            detail = f"OSM way {el.get('id')} ({highway})" if highway else f"OSM way {el.get('id')}"
            best = {
                "speedLimitMph": mph,
                "roadKey": f"way{el.get('id')}",
                "providerName": "Overpass",
                "detail": detail,
            }
    return best


def query_arcgis_for_speed(lat, lon, heading=None):
    """Direct port of ArcGISHPMSSpeedLimitProvider.fetchSpeedLimit(at:heading:)
    to Python. Returns None on miss; full SpeedLimitResponse-shaped dict on hit.
    """
    base = (
        "https://services6.arcgis.com/clPWQMwZfdWn4MQZ/arcgis/rest/services/"
        "HPMS_2024_Data/FeatureServer/48/query"
    )
    geom = json.dumps({"x": lon, "y": lat})
    params = {
        "f": "json",
        "geometry": geom,
        "geometryType": "esriGeometryPoint",
        "inSR": "4326",
        "spatialRel": "esriSpatialRelIntersects",
        "outFields": "OBJECTID,SpeedLimit,SRNumber,SpeedLimitDirection_Value,SpeedLimitType_Value",
        "returnGeometry": "true",
        "resultRecordCount": "10",
    }
    url = base + "?" + urllib.parse.urlencode(params)
    try:
        req = urllib.request.Request(url, headers={
            "User-Agent": USER_AGENT,
            "Accept": "application/json",
        })
        with urllib.request.urlopen(req, timeout=4) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
    except (urllib.error.HTTPError, urllib.error.URLError, json.JSONDecodeError, OSError, TimeoutError):
        return None
    features = payload.get("features") or []
    if not features:
        return None

    def match_cardinal(s):
        u = (s or "").upper()
        if "NB" in u and "SB" not in u: return 0
        if "SB" in u and "NB" not in u: return 180
        if "EB" in u and "WB" not in u: return 90
        if "WB" in u and "EB" not in u: return 270
        return None

    def normalize_angle(d):
        x = d % 360
        if x > 180: x -= 360
        if x <= -180: x += 360
        return x

    R = 6_378_137.0
    lat1 = math.radians(lat)
    best_score, best_idx = float("inf"), None
    for idx, f in enumerate(features):
        attrs = f.get("attributes") or {}
        if (attrs.get("SpeedLimit") or 0) <= 0:
            continue
        paths = ((f.get("geometry") or {}).get("paths")) or []
        if paths:
            min_dist = float("inf")
            for path in paths:
                for pair in path:
                    if len(pair) < 2: continue
                    lon2, lat2 = pair[0], math.radians(pair[1])
                    dlat = lat2 - lat1
                    dlon = math.radians(pair[0] - lon)
                    a = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) \
                        * math.sin(dlon / 2) ** 2
                    m = R * 2 * math.asin(math.sqrt(a))
                    if m < min_dist:
                        min_dist = m
            if min_dist == float("inf"):
                continue
        else:
            min_dist = 75.0  # mirror Swift fallback when geometry null
        score = min_dist + 1.0
        if heading is not None:
            road_h = match_cardinal(attrs.get("SpeedLimitDirection_Value"))
            if road_h is not None:
                diff = abs(normalize_angle(heading - road_h))
                if diff > 90: score *= 10.0
                elif diff > 40: score *= 3.0
        if score < best_score:
            best_score = score
            best_idx = idx
    if best_idx is None:
        return None
    f = features[best_idx]
    attrs = f.get("attributes") or {}
    sr = attrs.get("SRNumber") or "?"
    direction = attrs.get("SpeedLimitDirection_Value") or "?"
    kind = attrs.get("SpeedLimitType_Value") or "Speed Limit"
    return {
        "speedLimitMph": int(attrs.get("SpeedLimit")),
        "roadKey": f"SR{sr}-{direction}",
        "providerName": "ArcGIS",
        "detail": f"{kind}; SR {sr} {direction}",
    }


# ---- Nominatim /reverse: 50m grid cache + 1 req/sec throttle -------------

class ReverseGeocoder:
    """Mirrors SmartSpeedCompanion/Core/RoadGeocoder.swift. 50m grid
    cache + 1 req/sec throttle per Nominatim policy, with in-flight de-dup
    so two concurrent clicks on the same cell coalesce into one HTTP call.
    """
    def __init__(self):
        self._cache = {}
        self._inflight = {}
        self._lock = threading.Lock()
        self._last_call_at = 0.0

    def _grid_key(self, lat, lon):
        lat_k = round(lat / GEOCODE_GRID_DEGREES) * GEOCODE_GRID_DEGREES
        lon_k = round(lon / GEOCODE_GRID_DEGREES) * GEOCODE_GRID_DEGREES
        return f"g:{lat_k:.4f},{lon_k:.4f}"

    def resolve(self, lat, lon):
        key = self._grid_key(lat, lon)
        cached = self._cache.get(key)
        now = time.time()
        if cached and (now - cached["resolvedAt"]) < GEOCODE_TTL_SECONDS:
            return cached

        with self._lock:
            if key in self._inflight:
                return self._inflight[key]
            future = {}
            self._inflight[key] = future
        try:
            # Throttle to >=1.1s between ANY two Nominatim requests.
            with self._lock:
                wait = max(0.0, NOMINATIM_MIN_INTERVAL_S - (time.time() - self._last_call_at))
            if wait > 0:
                time.sleep(wait)
            params = {
                "lat": f"{lat:.6f}", "lon": f"{lon:.6f}",
                "format": "jsonv2", "zoom": "18", "addressdetails": "1",
            }
            url = NOMINATIM_URL + "?" + urllib.parse.urlencode(params)
            req = urllib.request.Request(url, headers={
                "User-Agent": USER_AGENT,
                "Accept": "application/json",
            })
            with urllib.request.urlopen(req, timeout=8) as resp:
                payload = json.loads(resp.read().decode("utf-8"))
            with self._lock:
                self._last_call_at = time.time()
            addr = payload.get("address") or {}
            road_name = addr.get("road") or addr.get("pedestrian") or addr.get("footway")
            city = addr.get("city") or addr.get("town") or addr.get("village")
            state = addr.get("state")
            entry = {
                "roadName": road_name,
                "city": city,
                "state": state,
                "resolvedAt": time.time(),
                "displayName": payload.get("display_name", ""),
            }
            self._cache[key] = entry
            return entry
        except (urllib.error.HTTPError, urllib.error.URLError, json.JSONDecodeError, OSError) as e:
            return None
        finally:
            with self._lock:
                self._inflight.pop(key, None)

REVERSE_GEOCODER = ReverseGeocoder()


# ---- HTTP handler -------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()

    def _json(self, code, payload):
        body = json.dumps(payload).encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _serve_index(self):
        file_path = os.path.join(os.path.dirname(__file__), 'index.html')
        with open(file_path, 'rb') as f:
            data = f.read()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path.split('?', 1)[0]
        if path in ('/', '/index.html'):
            return self._serve_index()
        if path == '/health':
            return self._json(200, {
                'service': 'speedio',
                'db_exists': os.path.exists(DB_PATH),
                'db_path': DB_PATH,
                'endpoints': ['/api/reverse-geocode', '/api/speedlimit-az',
                              '/api/speedlimit-arcgis', '/api/speedlimit-overpass'],
            })
        if path == '/api/reverse-geocode':
            try:
                qs = urllib.parse.parse_qs(self.path.split('?', 1)[1])
                lat = float(qs['lat'][0])
                lon = float(qs['lon'][0])
            except (KeyError, ValueError):
                return self._json(400, {'error': 'need ?lat=&lon= as floats'})
            entry = REVERSE_GEOCODER.resolve(lat, lon)
            if entry is None:
                return self._json(504, {'error': 'reverse geocode failed', 'lat': lat, 'lon': lon})
            return self._json(200, {
                'lat': lat, 'lon': lon,
                'road_name': entry.get('roadName'),
                'city': entry.get('city'),
                'state': entry.get('state'),
                'display_name': entry.get('displayName'),
            })
        return self._json(404, {'error': 'unknown route'})

    def do_POST(self):
        path = self.path.split('?', 1)[0]
        try:
            length = int(self.headers.get('Content-Length', '0'))
            raw = self.rfile.read(length).decode('utf-8') if length > 0 else '{}'
            body = json.loads(raw)
        except (ValueError, json.JSONDecodeError):
            return self._json(400, {'error': 'bad JSON body'})
        try:
            lat = float(body['lat'])
            lon = float(body['lon'])
        except (KeyError, ValueError):
            return self._json(400, {'error': 'need {"lat": float, "lon": float}'})
        road_name = body.get('road_name') or body.get('roadName') or None
        heading = body.get('heading', None)
        try:
            heading = float(heading) if heading is not None else None
        except (ValueError, TypeError):
            heading = None

        if path == '/api/speedlimit-az':
            if not os.path.exists(DB_PATH):
                return self._json(500, {'error': f'AZ sqlite not found: {DB_PATH}'})
            try:
                conn = sqlite3.connect(f'file:{DB_PATH}?mode=ro', uri=True)
                try:
                    segments = fetch_segments(conn, lat, lon)
                    snap_result = snap(segments, lat, lon, road_name=road_name)
                    # Always a 3-tuple: (limit, route, reject_reason_or_None)
                    limit, route, reject_reason = snap_result
                    if reject_reason is not None:
                        return self._json(200, {
                            'found': False,
                            'reason': reject_reason,
                            'road_name': road_name,
                        })
                    if limit <= 0:
                        return self._json(200, {
                            'found': False,
                            'reason': 'no spatial match within {}'.format(int(SNAP_RADIUS_M)),
                        })
                    return self._json(200, {
                        'found': True,
                        'speedMph': limit,
                        'roadKey': 'local-sqlite',
                        'providerName': 'AZ SQLite',
                        'detail': (
                            f'Local SQLite lookup along {road_name}'
                            if road_name
                            else 'Local SQLite lookup within 1 km corridor'
                        ),
                        'routeId': route,
                    })
                finally:
                    conn.close()
            except Exception as exc:
                return self._json(500, {'error': str(exc)})

        if path == '/api/speedlimit-arcgis':
            resp = query_arcgis_for_speed(lat, lon, heading=heading)
            if resp is None:
                return self._json(200, {'found': False})
            return self._json(200, {'found': True, **resp})

        if path == '/api/speedlimit-overpass':
            resp = query_overpass_for_speed(lat, lon, heading=heading)
            if resp is None:
                return self._json(200, {'found': False})
            return self._json(200, {'found': True, **resp})

        return self._json(404, {'error': 'unknown route'})

    def log_message(self, fmt, *args):
        # Silence the default per-request stderr access log.
        pass


def main():
    print(f'[server] AZ SQLite at {DB_PATH}')
    print(f'[server] serving http://127.0.0.1:{PORT}/ '
          '(index.html + /api/{reverse-geocode,speedlimit-az,speedlimit-arcgis,speedlimit-overpass})')
    httpd = ThreadingHTTPServer(('127.0.0.1', PORT), Handler)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == '__main__':
    main()
