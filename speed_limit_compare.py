#!/usr/bin/env python3
# speed_limit_compare.py
#
# Compare speed-limit data across the three real sources used by the Speedio
# iOS app, for every named road in a given radius around a home address.
#
# Data sources (all live, all free, no API keys required):
#   1. Overpass / OpenStreetMap   - queries OSM `highway` + `maxspeed` tags.
#                                   Worldwide coverage.
#   2. ArcGIS HPMS (layer 48)    - federal sample-panel data, SpeedLimit_2024.
#                                   AZ-only (XMin -114.95, XMax -108.87,
#                                            YMin 31.30,  YMax 37.03).
#   3. Local AZ SQLite (optional) - bundled `ArizonaSpeedLimits.sqlite` file
#                                   shipped with the iOS app.
#
# Usage:
#   python speed_limit_compare.py "Phoenix, AZ" --cap 500
#   python speed_limit_compare.py "123 Main St, Phoenix, AZ" --radius-mi 25 \
#       --sqlite ./SmartSpeedCompanion/Resources/ArizonaSpeedLimits.sqlite \
#       --output-dir ./out
#
# Output:
#   out/speed_limits_<safe_address>.csv
#   out/speed_limits_<safe_address>.json
#
# Notes:
#   - All distances are computed with the Haversine formula on an Earth
#     radius of 6,378,137 m (matching the iOS `SpeedLimitProvider.swift`
#     constants).
#   - Per-road alignment uses OSM `way center` as the master sample point
#     and matches ArcGIS polygons + SQLite bbox nearest vertices to that.
#   - The script does NOT hammer any API per-road. Each provider is hit with
#     exactly ONE bulk bounding-box query covering the entire radius.
#
# Tested with Python 3.10+. Pure stdlib + sqlite3.

import argparse
import json
import math
import os
import sqlite3
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# --------------- Constants ---------------
EARTH_RADIUS_M = 6_378_137.0
DEFAULT_RADIUS_MI = 50.0
ARCGIS_AZ_BBOX = (-114.95, -108.87, 31.30, 37.03)  # (xmin, xmax, ymin, ymax)
USER_AGENT = "Speedio-SpeedLimitCompare/1.0 (research; speedsenseapp@gmail.com)"
NOMINATIM_URL = "https://nominatim.openstreetmap.org/search"
OVERPASS_URL = "https://overpass-api.de/api/interpreter"
ARCGIS_URL = (
    "https://services6.arcgis.com/clPWQMwZfdWn4MQZ/arcgis/rest/services/"
    "HPMS_2024_Data/FeatureServer/48/query"
)
OVERPASS_TIMEOUT_S = 30
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
    p.add_argument("--match-radius-m", type=float, default=2000.0,
                   help="For each OSM road, drop the ArcGIS/SQLite match if "
                        "its nearest vertex/bbox edge is further than this "
                        "from the OSM way center. Default 2km works well "
                        "even for long state routes that don't tile "
                        "perfectly across providers.")
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
    longitude axis so a 50-mile circle at 33°N isn't shortchanged in the E/W
    direction (1° of longitude shrinks to ~93 km at 33°N from the standard
    111 km at the equator)."""
    dlat = radius_m / 111_111.0
    dlon = radius_m / (111_111.0 * math.cos(math.radians(lat)))
    return (lon - dlon, lon + dlon, lat - dlat, lat + dlat)


def point_in_bbox(lat: float, lon: float, bbox) -> bool:
    minx, maxx, miny, maxy = bbox
    return (minx <= lon <= maxx) and (miny <= lat <= maxy)


def parse_maxspeed(raw: str):
    """Same logic as `OverpassSpeedLimitProvider.parseMaxspeed(_:)` in the
    Swift app: handles '25 mph', '40', '60 km/h', '50 kmh', 'ROAD TYPE: 30 mph'.
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


# --------------- HTTP helpers ---------------
def _http_get_json(url: str, params=None, timeout=15, headers=None):
    """GET request returns parsed JSON. Raises on non-2xx or network error."""
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
    """POST application/x-www-form-urlencoded. Returns parsed JSON."""
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
    """Returns dict with at least keys: lat, lon, display_name. Nominatim
    usage policy: no key, max 1 req/sec, must identify via User-Agent.
    Sleeps 1s up-front as politeness; this script only makes one geocode
    call, so it's a no-op for the user but keeps us polite if this is
    ever wrapped by a batch driver."""
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
def query_overpass_bbox(lat: float, lon: float, radius_m: float, max_roads: int,
                        verbose=False) -> list:
    """Single bulk Overpass query returning every named `highway` way within
    `radius_m` of (lat, lon). Result passes include `name` tag if present, the
    OSM `way id`, the highway class, and a center lat/lon (Overpass `out center`).

    Overpass server-side throttle is 2 req/sec/IP; with one query per run,
    we never approach it, but we honor 429 with a 60s backoff window.

    Returns: list of dicts (sorted by distance from (lat,lon), so truncation
    to `max_roads` keeps the most-relevant ones):
      {osm_id:int, name:str, highway:str, maxspeed_raw:str|None,
       maxspeed_mph:int|None, lat:float, lon:float}
    """
    radius_m_int = int(round(radius_m))
    # Filter to ways that have BOTH `highway` (so we don't pick up coastlines,
    # railways) and `name` (so unnamed residentials don't bloat output).
    query = (
        f'[out:json][timeout:25];\n'
        f'way(around:{radius_m_int},{lat:.6f},{lon:.6f})[highway][name];\n'
        f'out tags center 1;\n'
    )
    if verbose:
        print(f"[overpass] radius={radius_m_int}m, cap={max_roads}")
    try:
        data = _http_post_form(OVERPASS_URL, {"data": query}, timeout=OVERPASS_TIMEOUT_S)
    except urllib.error.HTTPError as e:
        if e.code == 429:
            print("[overpass] HIT 429, sleeping 60s then retrying once...")
            time.sleep(60)
            data = _http_post_form(OVERPASS_URL, {"data": query}, timeout=OVERPASS_TIMEOUT_S)
        else:
            raise
    elements = (data.get("elements") or [])
    roads = []
    for el in elements:
        if el.get("type") != "way":
            continue
        tags = el.get("tags") or {}
        name = tags.get("name") or tags.get("ref")
        if not name:
            continue
        # Get center
        center = el.get("center") or {}
        if "lat" not in center and "lon" not in center:
            # Some elements come with the way itself uncentered; skip (we asked
            # for `out center` so this should be rare).
            continue
        raw = tags.get("maxspeed")
        roads.append({
            "osm_id": el["id"],
            "name": str(name),
            "highway": tags.get("highway", ""),
            "maxspeed_raw": raw,
            "maxspeed_mph": parse_maxspeed(raw) if raw else None,
            "lat": float(center["lat"]),
            "lon": float(center["lon"]),
        })
    if verbose:
        print(f"[overpass] raw element count: {len(elements)}, named: {len(roads)}")
    # Sort by distance from center so the --cap truncation keeps the
    # most-relevant (closest to home) roads rather than an arbitrary slice.
    roads.sort(key=lambda r: haversine_m(lat, lon, r["lat"], r["lon"]))
    return roads[:max_roads]


# --------------- ArcGIS HPMS ---------------
def _arcgis_query_envelope(minx, maxx, miny, maxy, offset=0, count=2000):
    """One ArcGIS polygon-envelope query. Returns (features, exceededTransferLimit).
    Public ArcGIS service: no key, default `maxRecordCount` is typically 2000;
    if exceededTransferLimit is true, caller paginates with offset.

    Honors 429 with a 60s backoff and one retry, mirroring the Overpass
    pattern -- it's the same public ArcGIS service gRPC/HTTP behavior.
    Honors 5xx with a 10s backoff once."""
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
    return ([], False)  # unreachable but well-typed


def query_arcgis_bbox(minx, maxx, miny, maxy, verbose=False):
    """All ArcGIS HPMS features whose envelope intersects the given bbox.
    Returns: (features_list, truncated_bool)
    `truncated` is True when the 50k safety cap fired -- caller should
    surface this in metadata so the user knows the result is a sample.
    Auto-paginates via resultOffset."""
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
            # Hard safety stop; AZ statewide index is ~tens of thousands.
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
    """Mirrors the SQL filter used by `ArizonaSpeedLimitService.queryDatabase`,
    but expanded to a bounding box rather than a single (lat,lon) + buffer.

    SQL is the same as the iOS app:
        SELECT a.SpeedLimit, b.minx, b.maxx, b.miny, b.maxy, a.RouteId
        FROM SpeedLimit_2024 a
        JOIN st_spindex__SpeedLimit_2024_SHAPE b ON a.OBJECTID = b.pkid
        WHERE ? <= b.maxx AND ? >= b.minx
          AND ? <= b.maxy AND ? >= b.miny

    Bind values are: (minx-buf, maxx+buf, miny-buf, maxy+buf) so the predicate
    selects any segment whose bbox intersects our query bbox (with a small
    buffer epsilon, matching the Swift `gridPrecision` 0.02-cell behavior).
    Filters `SpeedLimit > 0` (matches app's `guard segment.limit > 0`).

    Note on the SQL textual order: the WHERE clause reads ? against b.maxx
    then b.minx then b.maxy then b.miny -- so the FIRST bind is matched
    against the SHAPE's max-longitude. So we pass minx-buf first."""
    # Schema probe up-front: better to fail loudly with a clear message than
    # to die mid-query with `no such table: SpeedLimit_2024` halfway through.
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
            "AND name IN (%s, %s)" % ("?", "?"),
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
        # Match the iOS bind order so behavior is provably identical:
        # ?1 -> b.maxx  (we want the longitude_min of our bbox = minx - buf,
        #                ANY bbox whose maxx is >= that string qualifies)
        # ?2 -> b.minx  (we want the longitude_max of our bbox = maxx + buf)
        # ?3 -> b.maxy  (we want the latitude_min  of our bbox = miny - buf)
        # ?4 -> b.miny  (we want the latitude_max  of our bbox = maxy + buf)
        cur.execute(sql, (minx - buf, maxx + buf,
                          miny - buf, maxy + buf))
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
def _arcgis_nearest_arc_feature(road_lat, road_lon, features):
    """Return (best_feature_dict, distance_m) for the closest path-vertex across
    all features, ignoring intersection geometry. Mirrors the Swift
    `ArcGISHPMSSpeedLimitProvider.bestFeatureIndex` scoring style."""
    best_f, best_d = None, None
    for f in features:
        paths = f.get("paths") or []
        if not paths:
            # No geometry -- skip rather than guess.
            continue
        for path in paths:
            for pair in path:
                if not isinstance(pair, list) or len(pair) < 2:
                    continue
                lon2 = pair[0]
                lat2 = pair[1]
                d = haversine_m(road_lat, road_lon, lat2, lon2)
                if best_d is None or d < best_d:
                    best_d = d
                    best_f = f
    if best_f is None:
        return None, None
    return best_f, best_d


def _sqlite_nearest_row(road_lat, road_lon, rows):
    """Distance from (lat,lon) to nearest vertex on the segmented bbox (we have
    no polylines for SQLite, only bounding boxes -- so use a point-to-bbox
    distance fallback like the Swift `RoadSegment.distance(to:)`)."""
    best_r, best_d = None, None
    for r in rows:
        dx = max(0.0, r["minx"] - road_lon, road_lon - r["maxx"])
        dy = max(0.0, r["miny"] - road_lat, road_lat - r["maxy"])
        if dx == 0 and dy == 0:
            d = 0.0
        else:
            lat_m = dy * 111111.0
            lon_m = dx * 111111.0 * math.cos(road_lat * math.pi / 180.0)
            d = math.sqrt(lat_m * lat_m + lon_m * lon_m)
        if best_d is None or d < best_d:
            best_d = d
            best_r = r
    return best_r, best_d


def align(roads, arcgis_features, sqlite_rows, match_radius_m=2000.0,
           dropped_out_of_range=None):
    """For each OSM road, find the nearest ArcGIS feature and SQLite row.
    Drops matches beyond `match_radius_m` -- the match is unlikely to mean
    the same physical road past this range. Drops are counted into
    `dropped_out_of_range` if provided so the caller can surface in metadata.

    Returns: list[dict] (one row per OSM road)."""
    if dropped_out_of_range is None:
        dropped_out_of_range = {"arcgis": 0, "sqlite": 0}
    enriched = []
    for road in roads:
        row = {
            "road_name":              road["name"],
            "highway_type":           road["highway"],
            "osm_way_id":             road["osm_id"],
            "sample_lat":             f"{road['lat']:.6f}",
            "sample_lon":             f"{road['lon']:.6f}",
            "overpass_maxspeed_raw":  road["maxspeed_raw"] or "",
            "overpass_mph":           road["maxspeed_mph"] if road["maxspeed_mph"] else "",
            "arcgis_mph":             "",
            "arcgis_sr_number":       "",
            "arcgis_direction":       "",
            "arcgis_object_id":       "",
            "arcgis_match_meters":    "",
            "sqlite_mph":             "",
            "sqlite_route_id":        "",
            "sqlite_match_meters":    "",
        }
        if arcgis_features:
            arcgis_match, arcgis_dist = _arcgis_nearest_arc_feature(
                road["lat"], road["lon"], arcgis_features
            )
            if arcgis_match and (arcgis_dist is None or arcgis_dist <= match_radius_m):
                d_m = arcgis_dist or 0
                row["arcgis_mph"]          = arcgis_match["speed_limit"]
                row["arcgis_sr_number"]    = arcgis_match["sr_number"] or ""
                row["arcgis_direction"]    = arcgis_match["direction"] or ""
                row["arcgis_object_id"]    = arcgis_match["object_id"] or ""
                row["arcgis_match_meters"] = f"{d_m:.1f}"
            elif arcgis_match:
                dropped_out_of_range["arcgis"] += 1
        if sqlite_rows:
            sqlite_match, sqlite_dist = _sqlite_nearest_row(
                road["lat"], road["lon"], sqlite_rows
            )
            if sqlite_match and (sqlite_dist is None or sqlite_dist <= match_radius_m):
                d_m = sqlite_dist or 0
                row["sqlite_mph"]          = sqlite_match["speed_limit"]
                row["sqlite_route_id"]    = sqlite_match["route_id"] or ""
                row["sqlite_match_meters"] = f"{d_m:.1f}"
            elif sqlite_match:
                dropped_out_of_range["sqlite"] += 1

        # Match status
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
        "road_name", "highway_type", "osm_way_id",
        "sample_lat", "sample_lon",
        "overpass_maxspeed_raw", "overpass_mph",
        "arcgis_mph", "arcgis_sr_number", "arcgis_direction", "arcgis_object_id",
        "arcgis_match_meters",
        "sqlite_mph", "sqlite_route_id", "sqlite_match_meters",
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
                # Quote anything containing comma, quote, or newline.
                if any(ch in s for ch in [',', '"', '\n']):
                    s = '"' + s.replace('"', '""') + '"'
                cells.append(s)
            f.write(",".join(cells) + "\n")


def write_json(rows, path, meta):
    payload = {
        "metadata": meta,
        "rows": rows,
    }
    with open(path, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2)


# --------------- Main ---------------
def run(args):
    # 1. Validate args.
    if args.cap <= 0:
        raise SystemExit("--cap must be > 0")
    if args.radius_mi <= 0:
        raise SystemExit("--radius-mi must be > 0")

    # 2. Geocode.
    geo = geocode_nominatim(args.address, verbose=args.verbose)
    lat, lon = geo["lat"], geo["lon"]
    print(f"[geo] {geo['display_name']}  ->  ({lat:.6f}, {lon:.6f})")
    radius_m = meters_from_mi(args.radius_mi)
    in_az = point_in_bbox(lat, lon, ARCGIS_AZ_BBOX)
    print(f"[bbox] radius={args.radius_mi}mi ({radius_m:.0f}m)  in_az={in_az}")

    # 3. Bulk Overpass.
    overpass_roads = []
    if not args.no_overpass:
        overpass_roads = query_overpass_bbox(
            lat, lon, radius_m, args.cap, verbose=args.verbose
        )
        print(f"[overpass] {len(overpass_roads)} named roads returned (cap={args.cap})")

    # 4. Bulk ArcGIS (if in AZ and not disabled).
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

    # 5. Local SQLite (if --sqlite and in AZ).
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

    # 6. Align per road.
    if not overpass_roads:
        print("[align] No overpass roads to align; exiting.")
        return
    dropped = {"arcgis": 0, "sqlite": 0}
    rows = align(overpass_roads, arcgis_features, sqlite_rows,
                 match_radius_m=args.match_radius_m,
                 dropped_out_of_range=dropped)
    if (dropped["arcgis"] or dropped["sqlite"]):
        print(f"[align] dropped out-of-range matches: arcgis={dropped['arcgis']}, sqlite={dropped['sqlite']}")

    # 7. Write outputs.
    os.makedirs(args.output_dir, exist_ok=True)
    fname = safe_filename(geo["display_name"])
    csv_path  = os.path.join(args.output_dir, f"speed_limits_{fname}.csv")
    json_path = os.path.join(args.output_dir, f"speed_limits_{fname}.json")
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
        "drops": {"matches_out_of_range": dropped},
        "row_count": len(rows),
        "generated_at_unix": int(time.time()),
    }
    write_csv(rows, csv_path)
    write_json(rows, json_path, meta)
    print(f"[write] CSV  ->  {csv_path}")
    print(f"[write] JSON ->  {json_path}")

    # 8. Summary stats.
    counts = {"overpass_only": 0, "overpass+arcgis": 0, "overpass+sqlite": 0,
              "all_three": 0}
    for r in rows:
        p = r["providers_present"]
        if p == "overpass":
            counts["overpass_only"] += 1
        elif p == "overpass+arcgis":
            counts["overpass+arcgis"] += 1
        elif p == "overpass+sqlite":
            counts["overpass+sqlite"] += 1
        elif p == "overpass+arcgis+sqlite":
            counts["all_three"] += 1
    print("[summary] providers breakdown:")
    for k, v in counts.items():
        print(f"          {k:20s} {v}")


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
