#!/usr/bin/env python3
# speed_limit_compare.py
#
# Compare speed-limit data across the three real sources used by the Speedio
# iOS app, for every named road in a given radius around a home address.
#
# Data sources (all live, all free, no API keys required):
#   1. Overpass / OpenStreetMap   - queries OSM `highway` + `name` + `ref` tags.
#                                   Worldwide coverage.
#   2. ArcGIS HPMS (layer 48)    - federal sample-panel data, SpeedLimit_2024.
#                                   AZ-only (XMin -114.95, XMax -108.87,
#                                            YMin 31.30,  YMax 37.03).
#   3. Local AZ SQLite (optional) - bundled `ArizonaSpeedLimits.sqlite` file
#                                   shipped with the iOS app.
#
# Usage:
#   python speed_limit_compare.py "Phoenix, AZ" --cap 500
#   python speed_limit_compare.py "123 Main St, Chandler, AZ" --radius-mi 25 \
#       --sqlite ./SmartSpeedCompanion/Resources/ArizonaSpeedLimits.sqlite \
#       --output-dir ./out
#
# Output:
#   out/speed_limits_<safe_address>.csv
#   out/speed_limits_<safe_address>.json
#
# Each output row is one OSM road with per-provider columns. Every match
# is annotated with a `match_basis` of "ref", "name", or "spatial":
#   - "ref"     : OSM road's `ref` tag matched the provider's SRNumber /
#                 RouteId exactly (after normalization). HIGHEST confidence
#                 this is the same physical road.
#   - "name"    : the provider's normalized RouteId appears as a discrete
#                 token in the OSM road's `name`. MEDIUM confidence.
#   - "spatial" : name/ref matched nothing; we fell back to "nearest
#                 feature within match_radius_m". LOW confidence -- the
#                 comparison may be against a different road that happens
#                 to be nearby.
# The summary block reports true same-road agreements separately from
# spatial coincidences so you don't draw "all three agree!" conclusions
# from rows that were only ever spatially proximate.
#
# Tested with Python 3.10+. Pure stdlib + sqlite3.

import argparse
import http.client
import json
import math
import os
import re
import sqlite3
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# --------------- Constants ---------------
EARTH_RADIUS_M = 6_378_137.0
DEFAULT_RADIUS_MI = 50.0
DEFAULT_MATCH_RADIUS_M = 250.0   # OSM way centers can sit 150-300m from nearest ArcGIS sample vertex; tight any smaller silently drops valid real-road matches
ARCGIS_AZ_BBOX = (-114.95, -108.87, 31.30, 37.03)  # (xmin, xmax, ymin, ymax)
USER_AGENT = "Speedio-SpeedLimitCompare/1.0 (research; speedsenseapp@gmail.com)"
NOMINATIM_URL = "https://nominatim.openstreetmap.org/search"
OVERPASS_URL = "https://overpass-api.de/api/interpreter"
# Fallback chain for the public Overpass endpoints. Different operators have
# different load profiles, so when one is throttling / 504-ing the next one
# in the list usually succeeds within seconds. All endpoints use the same
# QL syntax and Accept: application/json contract, so a single helper can
# drive them all interchangeably.
OVERPASS_MIRRORS = [
    OVERPASS_URL,                                # primary
    "https://overpass.kumi.systems/api/interpreter",     # Kumi Systems mirror
    "https://lz4.overpass-api.de/api/interpreter",       # lz4-compressed primary
    "https://overpass.openstreetmap.fr/api/interpreter", # OSM-FR mirror (stable)
]
ARCGIS_URL = (
    "https://services6.arcgis.com/clPWQMwZfdWn4MQZ/arcgis/rest/services/"
    "HPMS_2024_Data/FeatureServer/48/query"
)
OVERPASS_TIMEOUT_S = 120  # overpass in-query timeout is 60s; allow headroom for the response to stream back
ARCGIS_TIMEOUT_S = 15
NOMINATIM_TIMEOUT_S = 10
SQLITE_DEFAULT_BUFFER_DEG = 0.001  # tiny epsilon for SQL bbox JOIN safety


# --------------- Argparse ---------------
def parse_args():
    p = argparse.ArgumentParser(
        description="Compare speed-limit data across the three sources used "
                    "by the Speedio iOS app, for every named road in a "
                    "configurable radius around a home address.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    p.add_argument("address",
                   help='Free-text address, e.g. "Phoenix, AZ" or '
                        '"123 Main St, Phoenix, AZ".')
    p.add_argument("--cap", type=int, default=500,
                   help="Maximum number of named roads to include in the "
                        "output (sorted by distance from center).")
    p.add_argument("--radius-mi", type=float, default=DEFAULT_RADIUS_MI,
                   help=f"Search radius in miles (default {DEFAULT_RADIUS_MI}).")
    p.add_argument("--output-dir", default=".",
                   help="Where to write the .csv and .json files.")
    p.add_argument("--sqlite",
                   help="Path to local ArizonaSpeedLimits.sqlite (optional; "
                        "only consulted for addresses inside AZ).")
    p.add_argument("--no-arcgis", action="store_true",
                   help="Skip the ArcGIS HPMS network query.")
    p.add_argument("--no-overpass", action="store_true",
                   help="Skip the Overpass network query.")
    p.add_argument("--match-radius-m", type=float, default=DEFAULT_MATCH_RADIUS_M,
                   help="Max distance (meters) between an OSM way center and "
                        "the nearest ArcGIS polyline vertex / SQLite bbox edge "
                        "for a match to be considered at all. Default 250m "
                        "is the same-road sweet spot. Widen to 500-1000m if "
                        "you want more spatial-nearest coincidences as a "
                        "fallback (Tier 3 will dominate); 250m is already "
                        "narrow enough to skip pure-coincidence matches. Going "
                        "below 150m risks dropping legitimate Tier 1/2 hits "
                        "on long state routes where sample vertices are "
                        "sparsely placed.")
    p.add_argument("--verbose", action="store_true",
                   help="Verbose logging.")
    return p.parse_args()


# --------------- Math helpers ---------------
def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlam = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlam / 2) ** 2
    return 2 * EARTH_RADIUS_M * math.asin(math.sqrt(a))


def mi_from_meters(m: float) -> float:
    return m / 1609.344


def meters_from_mi(mi: float) -> float:
    return mi * 1609.344


def bbox_around(lat: float, lon: float, radius_m: float):
    """Return (minx, maxx, miny, maxy) envelope around (lat,lon) that fully
    contains a circle of radius `radius_m`. Correctly applies cos(lat) to the
    longitude axis so a 50-mile circle at 33 N isn't shortchanged in the E/W
    direction (1 deg of longitude shrinks to ~93 km at 33 N from the
    standard 111 km at the equator)."""
    dlat = radius_m / 111_111.0
    dlon = radius_m / (111_111.0 * math.cos(math.radians(lat)))
    return (lon - dlon, lon + dlon, lat - dlat, lat + dlat)


def point_in_bbox(lat: float, lon: float, bbox) -> bool:
    minx, maxx, miny, maxy = bbox
    return (minx <= lon <= maxx) and (miny <= lat <= maxy)


def parse_maxspeed(raw: str):
    """Mirrors `OverpassSpeedLimitProvider.parseMaxspeed(_:)` in the Swift app:
    handles '25 mph', '40', '60 km/h', '50 kmh', 'ROAD TYPE: 30 mph'.
    Returns mph as int, or None."""
    if raw is None:
        return None
    s = raw.strip().lower()
    is_kmh = ("km/h" in s) or ("kmh" in s) or ("kph" in s)
    digits = ""
    seen_digit = False
    for ch in s:
        if ch.isdigit() or ch == ".":
            digits += ch
            seen_digit = True
        elif seen_digit:
            break
    if not digits:
        return None
    n = float(digits)
    if n <= 0 or n > 200:
        return None
    if is_kmh:
        return int(round(n * 0.621371))
    return int(round(n))


def normalize_route_string(raw):
    """Normalize route designation strings to a canonical form so OSM `ref`
    and ArcGIS/SQLite designations can be compared.

    Example transforms:
        "  I 017                       0 "   ->  "I-17"
        " US 060                       0 "   ->  "US-60"
        " 087                       0 "      ->  "87"
        " AZ 101                       0 "   ->  "AZ-101"
        "I-10"                              ->  "I-10"
        "US 60"                             ->  "US-60"

    Rules:
        1. Strip + collapse whitespace.
        2. Drop a single trailing " 0" (the iOS geodatabase's direction/
           terminus marker; always 0 in this dataset).
        3. "<alpha-prefix> <numeric>" becomes "<UPPER-PREFIX>-<numeric>",
           with leading zeros stripped from the numeric.
        4. Pure numeric with leading zeros gets them stripped.
        5. Anything else: return cleaned string verbatim.
    """
    if not isinstance(raw, str):
        return ""
    s = raw.strip()
    s = re.sub(r"\s+", " ", s).strip()
    if not s:
        return ""
    if s.endswith(" 0"):
        s = s[:-2].strip()
    elif s == "0":
        return ""
    m = re.match(r"^([A-Za-z]+)\s+0*(\d+)$", s)
    if m:
        prefix = m.group(1).upper()
        num = m.group(2).lstrip("0") or "0"
        return f"{prefix}-{num}"
    m = re.match(r"^0*(\d+)$", s)
    if m:
        return m.group(1).lstrip("0") or "0"
    return s


def normalize_osm_refs(ref_tag):
    """OSM `ref` may be a semicolon/comma-separated list (e.g. 'I-10;US-60'
    on concurrent routings). Split and normalize each."""
    if not ref_tag:
        return set()
    parts = re.split(r"[;,]\s*", ref_tag)
    out = set()
    for p in parts:
        n = normalize_route_string(p)
        if n:
            out.add(n)
    return out


def _name_tokens(name):
    """Tokenize a road name for whole-token matching. Allows hyphens so
    'I-10', 'SR-101' become their own tokens. Lowercased for case-equal."""
    if not name:
        return set()
    return {t.lower() for t in re.findall(r"[\w-]+", name.lower())}


def _route_numeric_part(n):
    """Extract the (possibly alpha-suffixed) numeric portion of a normalized
    route designation. Lets Tier 2 token-match catch the common case where
    OSM name says 'Interstate 17' (tokens: {'interstate', '17'}) but the
    provider's designation is 'I-17' -- the numeric portion '17' is a token
    in the name. With this, those roads get Tier 2 (same road by name)
    instead of falling through to Tier 3 (spatial coincidence).

    Examples:
        'I-17'    -> '17'
        'US-60'   -> '60'
        '88'      -> '88'
        'I-17N'   -> '17N'
        'AZ-87A'  -> '87A'
        ''        -> ''
    """
    if not n:
        return ""
    m = re.match(r"^([A-Za-z]*)-?(\d+[A-Za-z]?)$", n)
    if m:
        return m.group(2)
    return n


# Highway-type keywords whose presence in an OSM name token set is hard
# evidence the road is a designated route (not a local street). Once we
# see one of these in the name, Tier-2 numeric match is allowed -- but
# we still gate the match on the provider's alpha-prefix family to
# avoid cross-type collisions like SR-17 vs I-17.
#   "I"-family: must see "interstate" in the OSM name
#   "US"-family: must see one of {"us", "united states", "us highway", "us route"}
#   state/county/etc.: generic type keywords (route / highway / state route /
#     state highway / freeway / expressway / turnpike / parkway) let through
HIGHWAY_TYPE_KEYWORDS_NEED_PREFIX_MATCH = {
    "interstate":         "I",
    "interstate highway": "I",
    "us":                 "US",
    "united states":      "US",
    "us highway":         "US",
    "us route":           "US",
}
GENERIC_TYPE_KEYWORDS = {
    "state route", "state highway", "route", "highway",
    "freeway", "expressway", "turnpike", "parkway",
}


def _tier2_numeric_match_allowed(provider_n_norm, osm_name_tokens):
    """Decide whether the Tier-2 numeric-portion match is safe to attempt.
    The risk without this gate: SR-17 (state route, northern Arizona) and
    I-17 (interstate, Phoenix-Flagstaff) BOTH have '17' as the numeric
    portion. Without family discrimination, Tier 2 would pair them as the
    same road. With this gate:
        OSM name 'Interstate 17'        + provider 'I-17'  -> allowed
            (strict: 'interstate' in tokens, provider prefix 'I' matches 'I' family)
        OSM name 'Arizona State Route 17' + provider 'I-17'  -> rejected
            (provider prefix 'I' would not match any keyword family in tokens,
            so generic-keyword fallback rejects I/US prefixes outright)
        OSM name 'State Route 17'      + provider 'SR-17' -> allowed
            (generic: 'state route' in tokens, provider prefix 'SR' is non-I/US)
        OSM name 'US Highway 60'       + provider 'SR-60' -> REJECTED
            (strict negative: 'us' in tokens, provider prefix 'SR' != 'US' family)
        OSM name 'Interstate 17'       + provider 'SR-17' -> rejected
            (strict negative: 'interstate' in tokens, 'SR' != 'I' family)
        OSM name 'US 60'               + provider 'US-60' -> allowed (strict positive)
        OSM name 'Grand Avenue'        + provider '87'    -> rejected (no type keyword)
    """
    if not provider_n_norm or not osm_name_tokens:
        return False
    n_low = provider_n_norm.lower()
    # Provider alpha prefix: "I-17" -> "I", "US-60" -> "US", "AZ-87" -> "AZ",
    # "87" -> "" (pure numeric).
    m = re.match(r"^([A-Za-z]+)-", n_low)
    provider_prefix = (m.group(1).upper() if m else "")
    # 1. NEGATIVE family check: if the OSM name mentions a strict family
    #    keyword ('us', 'interstate', etc.), the provider's alpha prefix MUST
    #    belong to that family -- otherwise reject outright. This blocks the
    #    generic-keyword fallback (next) from pairing e.g. 'US Highway 60'
    #    with 'SR-60' just because 'highway' is a generic type word.
    for kw, family in HIGHWAY_TYPE_KEYWORDS_NEED_PREFIX_MATCH.items():
        if kw in osm_name_tokens and provider_prefix != family:
            return False
    # 2. STRICT positive: name mentions the family AND provider is in it.
    for kw, family in HIGHWAY_TYPE_KEYWORDS_NEED_PREFIX_MATCH.items():
        if kw in osm_name_tokens and provider_prefix == family:
            return True
    # 3. GENERIC positive: route/highway/-type word in name AND provider
    #    prefix is set to a non-I, non-US family (state, county, etc.).
    #    'Grand Avenue' has no generic type word so this never fires; this
    #    is the path that lets 'State Route 202' <-> 'AZ-202' pair up.
    for kw in GENERIC_TYPE_KEYWORDS:
        if kw in osm_name_tokens and provider_prefix != "" \
                and provider_prefix not in ("I", "US"):
            return True
    return False


# --------------- HTTP helpers ---------------
def _http_get_json(url: str, params=None, timeout=15, headers=None):
    if params:
        url = url + ("&" if "?" in url else "?") + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={
        "User-Agent": USER_AGENT,
        "Accept": "application/json",
        **(headers or {}),
    })
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read()
    return json.loads(raw.decode("utf-8"))


def _http_post_form(url: str, form_data: dict, timeout=30, headers=None):
    body = urllib.parse.urlencode(form_data).encode("utf-8")
    req = urllib.request.Request(url, data=body, headers={
        "User-Agent": USER_AGENT,
        "Accept": "application/json",
        "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
        **(headers or {}),
    })
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read()
    return json.loads(raw.decode("utf-8"))


# --------------- Geocoding ---------------
def geocode_nominatim(address: str, verbose=False):
    params = {"q": address, "format": "json", "limit": 1, "addressdetails": 1}
    if verbose:
        print(f"[geocode] Nominatim: {address!r}")
    time.sleep(1.0)
    data = _http_get_json(NOMINATIM_URL, params=params, timeout=NOMINATIM_TIMEOUT_S)
    if not data:
        raise RuntimeError(f"Nominatim returned no results for {address!r}")
    hit = data[0]
    return {
        "lat": float(hit["lat"]),
        "lon": float(hit["lon"]),
        "display_name": hit.get("display_name", address),
    }


# --------------- Overpass ---------------
def _overpass_query_with_retries(url: str, query: str, verbose: bool = False):
    """Try `url` once, then with backoff on transient errors. Returns
    parsed JSON. Raises the LAST error if both attempts fail so the outer
    mirror loop can decide whether to fall through to the next mirror.
    Mirrors the existing ArcGIS retry pattern in `_arcgis_query_envelope`.

    Transient errors caught (all result in retry once, then `break` to
    fall through to next mirror):
      * urllib.error.URLError / OSError: DNS failure, connect timeout
        (socket.timeout is OSError-derived, NOT URLError in modern Python),
        refused connection.
      * http.client.HTTPException: RemoteDisconnected, BadStatusLine, etc.
        (HTTPException-derived, NOT OSError).
      * http.client.IncompleteRead: truncated response (Exception-derived
        directly, NOT OSError or HTTPException).
      * ValueError: json.JSONDecodeError (200 OK with non-JSON body) and
        UnicodeDecodeError (response body has invalid UTF-8 bytes).

    4xx-other-than-429 is NOT transient -- the query is malformed, so
    the helper bare-`raise`s immediately and the outer loop propagates
    without trying other mirrors.
    """
    last_err = None
    for attempt in range(2):
        try:
            return _http_post_form(url, {"data": query}, timeout=OVERPASS_TIMEOUT_S)
        except urllib.error.HTTPError as e:
            last_err = e
            if e.code == 429:
                if attempt == 0:
                    print(f"[overpass] {url} HIT 429, sleeping 60s then retrying once...")
                    time.sleep(60)
                    continue
                break  # second 429 -> let mirror loop try the next URL
            if 500 <= e.code < 600:
                if attempt == 0:
                    print(f"[overpass] {url} HIT {e.code}, sleeping 10s then retrying once...")
                    time.sleep(10)
                    continue
                break  # second 5xx -> next mirror
            raise  # 4xx other than 429 is a real bug, don't loop
        except (urllib.error.URLError, OSError, http.client.HTTPException,
                http.client.IncompleteRead, ValueError) as e:
            # All transient -- let the mirror loop try the next URL on
            # the second attempt.
            last_err = e
            if attempt == 0:
                print(f"[overpass] {url} transient error ({type(e).__name__}: {e}), "
                      f"sleeping 10s then retrying once...")
                time.sleep(10)
                continue
            break
    raise last_err


def query_overpass_bbox(lat: float, lon: float, radius_m: float, max_roads: int,
                        verbose=False) -> list:
    """Single bulk Overpass query returning every named `highway` way whose
    bbox intersects a square envelope around (lat, lon). Each road has its
    `name`, `ref`, `maxspeed`, and `highway` tags plus a center sample point.

    Implementation notes (learned the hard way against the live public server):
      * Use the BBOX filter (`way(SWlat,SWlon,NElat,NElon)`), NOT `around:`.
        The `around:` filter is unreliable for large radii (~>25 km).
      * The trailing integer on `out ... N;` is a HARD element-count limit
        -- `out tags center 1;` returns exactly one element. We use
        `out tags center;` (no integer) for "all elements".
      * The server returns 200 OK with a soft-fail `remark` field on
        partial / timed-out / QAL-exhausted results -- we surface it.
      * Throttle is 2 req/sec/IP; we honor 429 with a 60s backoff + 1 retry.
      * On 5xx (502/503/504) or any other transient error, we fall through
        a chain of public Overpass mirrors (OVERPASS_MIRRORS) before giving
        up. Each mirror gets one retry; if all fail, the last error raises.
    """
    minx, maxx, miny, maxy = bbox_around(lat, lon, radius_m)
    query = (
        f"[out:json][timeout:60];\n"
        f"way({miny:.6f},{minx:.6f},{maxy:.6f},{maxx:.6f})[highway][name];\n"
        f"out tags center;\n"
    )
    if verbose:
        print(f"[overpass] bbox=({miny:.4f},{minx:.4f},{maxy:.4f},{maxx:.4f}), cap={max_roads}")
    data = None
    last_err: Exception = RuntimeError("no overpass mirror attempted")
    for url in OVERPASS_MIRRORS:
        try:
            data = _overpass_query_with_retries(url, query, verbose=verbose)
            if url != OVERPASS_MIRRORS[0]:
                print(f"[overpass] recovered via mirror: {url}")
            break
        except (urllib.error.HTTPError, urllib.error.URLError,
                OSError, http.client.HTTPException, http.client.IncompleteRead,
                ValueError) as e:
            # 4xx other than 429 means our QUERY is malformed, not that the
            # server is sick. Three more mirrors will all return the same
            # 400 with the same query -- waste of 30-120s of wall time.
            # Re-raise immediately so the user sees the real error.
            if isinstance(e, urllib.error.HTTPError) \
                    and 400 <= e.code < 500 and e.code != 429:
                print(f"[overpass] mirror {url} returned {e.code} "
                      f"(query-level error, not transient) -- stopping")
                raise
            last_err = e
            print(f"[overpass] mirror {url} failed: {e}")
            continue
    if data is None:
        raise last_err
    if data.get("remark"):
        print(f"[overpass] SERVER REMARK: {data['remark']}")
    elements = (data.get("elements") or [])
    roads = []
    for el in elements:
        if el.get("type") != "way":
            continue
        tags = el.get("tags") or {}
        name = tags.get("name") or tags.get("ref")
        if not name:
            continue
        center = el.get("center") or {}
        if "lat" not in center and "lon" not in center:
            continue
        raw_ms = tags.get("maxspeed")
        roads.append({
            "osm_id": el["id"],
            "name": str(name),
            "ref": tags.get("ref", "") or "",
            "highway": tags.get("highway", ""),
            "maxspeed_raw": raw_ms,
            "maxspeed_mph": parse_maxspeed(raw_ms) if raw_ms else None,
            "lat": float(center["lat"]),
            "lon": float(center["lon"]),
        })
    if verbose:
        print(f"[overpass] raw element count: {len(elements)}, named: {len(roads)}")
    roads.sort(key=lambda r: haversine_m(lat, lon, r["lat"], r["lon"]))
    return roads[:max_roads]


# --------------- ArcGIS HPMS ---------------
def _arcgis_query_envelope(minx, maxx, miny, maxy, offset=0, count=2000):
    geom = json.dumps({"xmin": minx, "ymin": miny, "xmax": maxx, "ymax": maxy})
    params = {
        "f": "json",
        "geometry": geom,
        "geometryType": "esriGeometryEnvelope",
        "inSR": "4326",
        "spatialRel": "esriSpatialRelIntersects",
        "outFields": "OBJECTID,SpeedLimit,SRNumber,SpeedLimitDirection_Value,SpeedLimitType_Value",
        "returnGeometry": "true",
        "resultRecordCount": str(count),
        "resultOffset": str(offset),
    }
    for attempt in range(2):
        try:
            data = _http_get_json(ARCGIS_URL, params=params, timeout=ARCGIS_TIMEOUT_S)
            return (data.get("features", [])), bool(data.get("exceededTransferLimit"))
        except urllib.error.HTTPError as e:
            if e.code == 429:
                if attempt == 0:
                    print("[arcgis] HIT 429, sleeping 60s then retrying once...")
                    time.sleep(60)
                    continue
                raise
            if 500 <= e.code < 600 and attempt == 0:
                print(f"[arcgis] HIT {e.code}, sleeping 10s then retrying once...")
                time.sleep(10)
                continue
            raise
    return ([], False)


def query_arcgis_bbox(minx, maxx, miny, maxy, verbose=False):
    """Bulk ArcGIS HPMS feature fetch across the envelope. Returns
    (features_list, truncated_bool). Auto-paginates via resultOffset."""
    features, offset = [], 0
    truncated = False
    while True:
        chunk, more = _arcgis_query_envelope(minx, maxx, miny, maxy, offset=offset, count=2000)
        features.extend(chunk)
        if not more:
            break
        offset += len(chunk)
        if verbose:
            print(f"[arcgis] pagination: {offset} features so far...")
        if offset > 50_000:
            print("[arcgis] WARNING: hit 50k safety cap, truncating")
            truncated = True
            break
    if verbose:
        print(f"[arcgis] total features in bbox: {len(features)} (truncated={truncated})")
    out = []
    for f in features:
        attrs = f.get("attributes", {}) or {}
        geom = f.get("geometry") or {}
        sp = attrs.get("SpeedLimit") or 0
        if sp <= 0:
            continue
        out.append({
            "object_id": attrs.get("OBJECTID"),
            "speed_limit": int(sp),
            "sr_number": attrs.get("SRNumber"),
            "direction": attrs.get("SpeedLimitDirection_Value"),
            "kind": attrs.get("SpeedLimitType_Value"),
            "paths": geom.get("paths") or [],
        })
    return out, truncated


# --------------- Local AZ SQLite ---------------
def query_sqlite_bbox(sqlite_path: str, minx, maxx, miny, maxy, verbose=False) -> list:
    """Mirrors `ArizonaSpeedLimitService.queryDatabase` semantics but expanded
    to a bbox query. SQL string + bind order identical to the iOS app. Schema
    probe runs up-front so a wrong table set fails loudly."""
    required_tables = ("SpeedLimit_2024", "st_spindex__SpeedLimit_2024_SHAPE")
    sql = (
        "SELECT a.SpeedLimit, b.minx, b.maxx, b.miny, b.maxy, a.RouteId "
        "FROM SpeedLimit_2024 a "
        "JOIN st_spindex__SpeedLimit_2024_SHAPE b ON a.OBJECTID = b.pkid "
        "WHERE ? <= b.maxx AND ? >= b.minx "
        "  AND ? <= b.maxy AND ? >= b.miny "
        "  AND a.SpeedLimit > 0"
    )
    buf = SQLITE_DEFAULT_BUFFER_DEG
    conn = sqlite3.connect(sqlite_path)
    try:
        cur = conn.cursor()
        cur.execute(
            "SELECT name FROM sqlite_master WHERE type='table' "
            "AND name IN (?, ?)",
            required_tables,
        )
        present = {row[0] for row in cur.fetchall()}
        missing = [t for t in required_tables if t not in present]
        if missing:
            raise RuntimeError(
                f"--sqlite {sqlite_path!r} is missing required table(s): "
                f"{', '.join(missing)}. Is this the app's "
                "ArizonaSpeedLimits.sqlite file?"
            )
        cur.execute(sql, (minx - buf, maxx + buf, miny - buf, maxy + buf))
        out = []
        for row in cur.fetchall():
            sp, mx0, mx1, my0, my1, rid = row
            out.append({
                "speed_limit": int(sp),
                "minx": float(mx0), "maxx": float(mx1),
                "miny": float(my0), "maxy": float(my1),
                "route_id": rid,
            })
        if verbose:
            print(f"[sqlite] rows in bbox: {len(out)}")
        return out
    finally:
        conn.close()


# --------------- Per-road alignment ---------------
def _arcgis_candidates_with_dist(road_lat, road_lon, features, max_dist):
    """[(feature, distance_m)] for ArcGIS features whose nearest polyline
    vertex is within max_dist meters, sorted by distance asc.
    Mirrors the Swift `ArcGISHPMSSpeedLimitProvider.bestFeatureIndex`
    scoring style."""
    out = []
    for f in features:
        paths = f.get("paths") or []
        if not paths:
            continue
        best = None
        for path in paths:
            for pair in path:
                if not isinstance(pair, list) or len(pair) < 2:
                    continue
                lon2 = pair[0]
                lat2 = pair[1]
                d = haversine_m(road_lat, road_lon, lat2, lon2)
                if best is None or d < best:
                    best = d
        if best is not None and best <= max_dist:
            out.append((f, best))
    out.sort(key=lambda fd: fd[1])
    return out


def _sqlite_candidates_with_dist(road_lat, road_lon, rows, max_dist):
    """[(row, distance_m)] for SQLite rows whose bbox is within max_dist.
    Distance uses the Swift-compatible point-to-bbox formula
    (`RoadSegment.distance(to:)` in iOS). d=0.0 means point is inside the
    segment bbox; matches at d=0.0 are NOT guaranteed same-road and rely on
    the match_basis column to disambiguate."""
    out = []
    for r in rows:
        dx = max(0.0, r["minx"] - road_lon, road_lon - r["maxx"])
        dy = max(0.0, r["miny"] - road_lat, road_lat - r["maxy"])
        if dx == 0 and dy == 0:
            d = 0.0
        else:
            lat_m = dy * 111111.0
            lon_m = dx * 111111.0 * math.cos(road_lat * math.pi / 180.0)
            d = math.sqrt(lat_m * lat_m + lon_m * lon_m)
        if d <= max_dist:
            out.append((r, d))
    out.sort(key=lambda rd: rd[1])
    return out


def _tiered_pick(candidates, osm_ref_set, osm_name_tokens, provider_key):
    """Pick the highest-confidence match from `candidates` [(item, dist), ...].
    Returns (item, dist, basis, normalized_route) or None.

    IMPORTANT INVARIANT -- callers must not treat basis == "spatial" as
    evidence the provider is talking about the same physical road. "spatial"
    means: no ref matched, no name matched, we fell back to nearest feature
    inside match_radius_m. Two roads 50m apart whose OSM/HPMS tag sets
    disagree will get matched this way; the mph columns compare may show
    a "disagreement" that is in fact a coincidence.

    Tier 1: provider's normalized route string is in the OSM `ref` set
            (exact match after normalization). Highest confidence.
    Tier 2: provider's normalized route OR its numeric portion is a
            whole-token of the OSM road's `name`. Catches the common case
            where `name="Interstate 17"` and provider's designation is
            `I-17` -- the numeric portion "17" is a name token even though
            the full "I-17" is not.
    Tier 3: spatial nearest (lowest confidence, EXPLICITLY spatial-only).

    `provider_key` tells us which raw field to read on each candidate:
        "sr_number"  -> ArcGIS feature["sr_number"]
        "route_id"   -> SQLite row["route_id"]
    """
    def _normalize(item):
        return normalize_route_string(item.get(provider_key) or "")
    # Tier 1
    for item, d in candidates:
        n = _normalize(item)
        if n in osm_ref_set:
            return (item, d, "ref", n)
    # Tier 2 -- whole-token match against OSM name (full canonical OR, with
    # safety gate, numeric portion).
    for item, d in candidates:
        n = _normalize(item)
        if not n:
            continue
        # Whole-string token match. Already safe: requires the canonical form
        # to appear verbatim as a name token (e.g. 'US-60' in OSM name 'US-60').
        if n.lower() in osm_name_tokens:
            return (item, d, "name", n)
        # Numeric-portion match is dangerous in isolation (SR-17 vs I-17),
        # so we require a "highway type" keyword present in the OSM name AND
        # the provider's alpha prefix to be in the matching family.
        numeric = _route_numeric_part(n).lower()
        if numeric and numeric in osm_name_tokens \
                and _tier2_numeric_match_allowed(n, osm_name_tokens):
            return (item, d, "name", n)
    # Tier 3 -- EXPLICITLY "this is NOT a same-road match, only a spatial coincidence"
    if candidates:
        item, d = candidates[0]
        return (item, d, "spatial", _normalize(item))
    return None


def align(roads, arcgis_features, sqlite_rows, match_radius_m=DEFAULT_MATCH_RADIUS_M,
           dropped_out_of_range=None):
    """For each OSM road (master record), determine the matching tier against
    each provider and write enriched rows.

    Returns list[dict]: one row per OSM road; per-provider columns include
    speed limit + match metadata + a `match_basis` ("ref"/"name"/"spatial")
    so callers can distinguish real same-road agreements from spatial
    coincidences in their summaries."""
    if dropped_out_of_range is None:
        dropped_out_of_range = {"arcgis": 0, "sqlite": 0}
    enriched = []
    for road in roads:
        osm_ref_set = normalize_osm_refs(road.get("ref", ""))
        osm_name_tokens = _name_tokens(road.get("name", ""))
        arcgis_cands = _arcgis_candidates_with_dist(
            road["lat"], road["lon"], arcgis_features, match_radius_m
        )
        sqlite_cands = _sqlite_candidates_with_dist(
            road["lat"], road["lon"], sqlite_rows, match_radius_m
        )

        arcgis_pick = _tiered_pick(arcgis_cands, osm_ref_set,
                                    osm_name_tokens, "sr_number")
        sqlite_pick = _tiered_pick(sqlite_cands, osm_ref_set,
                                    osm_name_tokens, "route_id")

        row = {
            "road_name":                    road["name"],
            "highway_type":                 road["highway"],
            "osm_way_id":                   road["osm_id"],
            "osm_ref":                      road.get("ref", "") or "",
            "sample_lat":                   f"{road['lat']:.6f}",
            "sample_lon":                   f"{road['lon']:.6f}",
            "overpass_maxspeed_raw":        road["maxspeed_raw"] or "",
            "overpass_mph":                 road["maxspeed_mph"] if road["maxspeed_mph"] else "",
            "arcgis_mph":                   "",
            "arcgis_sr_number":             "",
            "arcgis_sr_number_normalized":  "",
            "arcgis_direction":             "",
            "arcgis_object_id":             "",
            "arcgis_match_meters":          "",
            "arcgis_match_basis":           "",
            "sqlite_mph":                   "",
            "sqlite_route_id":              "",
            "sqlite_route_id_normalized":   "",
            "sqlite_match_meters":          "",
            "sqlite_match_basis":           "",
            "providers_present":            "overpass",
        }
        if arcgis_pick:
            f, d, basis, norm = arcgis_pick
            row["arcgis_mph"]                  = f["speed_limit"]
            row["arcgis_sr_number"]            = f.get("sr_number") or ""
            row["arcgis_sr_number_normalized"] = norm
            row["arcgis_direction"]            = f.get("direction") or ""
            row["arcgis_object_id"]            = f.get("object_id") or ""
            row["arcgis_match_meters"]         = f"{d:.1f}"
            row["arcgis_match_basis"]          = basis
        if sqlite_pick:
            r, d, basis, norm = sqlite_pick
            row["sqlite_mph"]                  = r["speed_limit"]
            row["sqlite_route_id"]             = r.get("route_id") or ""
            row["sqlite_route_id_normalized"]  = norm
            row["sqlite_match_meters"]         = f"{d:.1f}"
            row["sqlite_match_basis"]          = basis

        parts = ["overpass"]
        if row["arcgis_mph"] != "":
            parts.append("arcgis")
        if row["sqlite_mph"] != "":
            parts.append("sqlite")
        row["providers_present"] = "+".join(parts)
        enriched.append(row)
    return enriched


# --------------- Writers ---------------
def safe_filename(s: str) -> str:
    keep = "abcdefghijklmnopqrstuvwxyz0123456789-_"
    out = "".join(c if c.lower() in keep else "_" for c in s).strip("_")
    return (out or "address")[:60]


def write_csv(rows, path):
    cols = [
        "road_name", "highway_type", "osm_way_id", "osm_ref",
        "sample_lat", "sample_lon",
        "overpass_maxspeed_raw", "overpass_mph",
        "arcgis_mph", "arcgis_sr_number", "arcgis_sr_number_normalized",
        "arcgis_direction", "arcgis_object_id", "arcgis_match_meters",
        "arcgis_match_basis",
        "sqlite_mph", "sqlite_route_id", "sqlite_route_id_normalized",
        "sqlite_match_meters", "sqlite_match_basis",
        "providers_present",
    ]
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(",".join(cols) + "\n")
        for r in rows:
            cells = []
            for c in cols:
                v = r.get(c, "")
                if v is None:
                    v = ""
                s = str(v)
                if any(ch in s for ch in [",", '"', "\n"]):
                    s = '"' + s.replace('"', '""') + '"'
                cells.append(s)
            f.write(",".join(cells) + "\n")


def write_json(rows, path, meta):
    with open(path, "w", encoding="utf-8") as f:
        json.dump({"metadata": meta, "rows": rows}, f, indent=2)


# --------------- Main ---------------
def run(args):
    if args.cap <= 0:
        raise SystemExit("--cap must be > 0")
    if args.radius_mi <= 0:
        raise SystemExit("--radius-mi must be > 0")

    geo = geocode_nominatim(args.address, verbose=args.verbose)
    lat, lon = geo["lat"], geo["lon"]
    print(f"[geo] {geo['display_name']}  ->  ({lat:.6f}, {lon:.6f})")
    radius_m = meters_from_mi(args.radius_mi)
    in_az = point_in_bbox(lat, lon, ARCGIS_AZ_BBOX)
    print(f"[bbox] radius={args.radius_mi}mi ({radius_m:.0f}m)  in_az={in_az}")

    overpass_roads = []
    if not args.no_overpass:
        overpass_roads = query_overpass_bbox(
            lat, lon, radius_m, args.cap, verbose=args.verbose
        )
        print(f"[overpass] {len(overpass_roads)} named roads returned (cap={args.cap})")

    arcgis_features = []
    arcgis_truncated = False
    if not args.no_arcgis and in_az:
        minx, maxx, miny, maxy = bbox_around(lat, lon, radius_m)
        arcgis_features, arcgis_truncated = query_arcgis_bbox(
            minx, maxx, miny, maxy, verbose=args.verbose
        )
        print(f"[arcgis] {len(arcgis_features)} HPMS features in bbox (AZ-only, truncated={arcgis_truncated})")
    elif not args.no_arcgis and not in_az:
        print("[arcgis] SKIPPED: address is outside AZ HPMS coverage")

    sqlite_rows = []
    if args.sqlite:
        if not in_az:
            print("[sqlite] SKIPPED: address is outside AZ")
        elif not os.path.exists(args.sqlite):
            print(f"[sqlite] WARNING: --sqlite file not found: {args.sqlite}")
        else:
            minx, maxx, miny, maxy = bbox_around(lat, lon, radius_m)
            sqlite_rows = query_sqlite_bbox(args.sqlite, minx, maxx, miny, maxy,
                                            verbose=args.verbose)
            print(f"[sqlite] {len(sqlite_rows)} rows from {args.sqlite}")

    if not overpass_roads:
        print("[align] No overpass roads to align; exiting.")
        return
    rows = align(overpass_roads, arcgis_features, sqlite_rows,
                 match_radius_m=args.match_radius_m)

    os.makedirs(args.output_dir, exist_ok=True)
    fname = safe_filename(geo["display_name"])
    csv_path  = os.path.join(args.output_dir, f"speed_limits_{fname}.csv")
    json_path = os.path.join(args.output_dir, f"speed_limits_{fname}.json")

    # Honest summary stats -- aggregated PER-PROVIDER so a row that has
    # Tier 1 from one provider and Tier 3 (spatial) from another is treated
    # as Tier 1 in the row count, AND its mph values are gated per-provider
    # when deciding whether to count as "same-road agreement".
    counts = {
        "total_roads":                       len(rows),
        "overpass_only_no_provider_hit":     0,
        "tier1_ref_match":                   0,  # at least one provider matched at Tier 1
        "tier2_name_match_only":             0,  # no Tier 1 hits; at least one Tier 2 hit
        "tier3_spatial_only_coincidence":    0,  # ALL contributing providers were spatial-only
        "true_same_road_agreement":          0,  # every mph-providing provider was Tier 1 or 2 + all agree
    }
    for r in rows:
        arb = r.get("arcgis_match_basis", "") or ""
        srb = r.get("sqlite_match_basis", "") or ""
        arcgis_real = arb in ("ref", "name")
        sqlite_real = srb in ("ref", "name")
        has_ref     = (arb == "ref" or srb == "ref")
        has_name    = (not has_ref) and (arb == "name" or srb == "name")
        has_any_provider_data = (r["arcgis_mph"] != "" or r["sqlite_mph"] != "")
        all_contributing_spatial = (
            has_any_provider_data
            and not arcgis_real and not sqlite_real
        )
        if r["providers_present"] == "overpass":
            counts["overpass_only_no_provider_hit"] += 1
            continue  # no further classification needed
        if has_ref:
            counts["tier1_ref_match"] += 1
        elif has_name:
            counts["tier2_name_match_only"] += 1
        elif all_contributing_spatial:
            counts["tier3_spatial_only_coincidence"] += 1
        # Per-provider same-road agreement: every mph value on this row must
        # come from a Tier 1/Tier 2 provider, AND all mph values equal.
        mphs = [r["overpass_mph"]] if r["overpass_mph"] != "" else []
        if arcgis_real: mphs.append(r["arcgis_mph"])
        if sqlite_real: mphs.append(r["sqlite_mph"])
        if len(mphs) >= 2 and len(set(mphs)) == 1 and (arcgis_real or sqlite_real):
            counts["true_same_road_agreement"] += 1

    meta = {
        "address": args.address,
        "resolved": geo["display_name"],
        "lat": lat, "lon": lon,
        "radius_mi": args.radius_mi,
        "cap": args.cap,
        "match_radius_m": args.match_radius_m,
        "in_az": in_az,
        "sources_used": {
            "overpass": (not args.no_overpass),
            "arcgis":   (not args.no_arcgis and in_az),
            "sqlite":   bool(args.sqlite and in_az and os.path.exists(args.sqlite or "")),
        },
        "truncated": {
            "arcgis_hit_50k_cap": arcgis_truncated,
            "overpass_results_capped_to_cap": (
                len(overpass_roads) >= args.cap and args.cap > 0
            ),
        },
        "drops": {"matches_out_of_range": 0},  # legacy field; preserved for downstream tooling
        "row_count": len(rows),
        "summary_by_match_basis": counts,
        "generated_at_unix": int(time.time()),
    }
    write_csv(rows, csv_path)
    write_json(rows, json_path, meta)
    print(f"[write] CSV  ->  {csv_path}")
    print(f"[write] JSON ->  {json_path}")

    total = counts["total_roads"]
    def _pct(n):
        if total == 0:
            return "(n/a)"
        return f"({100.0 * n / total:5.1f}%)"
    print("[summary] equality-of-comparison counts:")
    print(f"          total_roads                        {counts['total_roads']:5d}  {f'(n/a)' if total == 0 else '(100.0%)'}")
    print(f"          overpass_only_no_provider_hit      {counts['overpass_only_no_provider_hit']:5d}  {_pct(counts['overpass_only_no_provider_hit'])}")
    print(f"          tier1_ref_match                    {counts['tier1_ref_match']:5d}  {_pct(counts['tier1_ref_match'])}")
    print(f"          tier2_name_match_only              {counts['tier2_name_match_only']:5d}  {_pct(counts['tier2_name_match_only'])}")
    print(f"          tier3_spatial_only_coincidence     {counts['tier3_spatial_only_coincidence']:5d}  {_pct(counts['tier3_spatial_only_coincidence'])}")
    print(f"          true_same_road_agreement           {counts['true_same_road_agreement']:5d}  {_pct(counts['true_same_road_agreement'])}")


def main():
    args = parse_args()
    try:
        run(args)
    except urllib.error.URLError as e:
        print(f"[error] network: {e}", file=sys.stderr)
        sys.exit(2)
    except (KeyError, ValueError) as e:
        print(f"[error] data: {e}", file=sys.stderr)
        sys.exit(3)


if __name__ == "__main__":
    main()
