#!/usr/bin/env python3
"""
simulate_route.py -- synthetic speed-limit test route generator for
Speedio's #if DEBUG SimulationManager.

Outputs `route.json` consumed by the iOS app's replay engine. Works on
Windows against an Overpass public mirror so no macOS / Xcode / iOS
simulator is required for the data-layer validation side of the work.

Two modes:
  --mode generate   Query OpenStreetMap for one named highway polyline in
                    a bbox or near a Nominatim-geocoded address; pick the
                    best way; sample it at 1 Hz given a target speed;
                    emit route.json.
  --mode replay     Read a SpeedReading[] exported from the iOS
                    DriveSession SwiftData model; rescale to a target
                    speed (optional); emit route.json.

Output schema (route.json):
  {
    "metadata": {
      "source": "generate" | "replay",
      "speed_mph": 45, "duration_s": 300,
      "center": (lat, lon), "center_desc": "...",
      "way": {...} | None,
      "input_file": "..." | None,
      "point_count": N,
      "generated_at_unix": 1234567890
    },
    "points": [
      {"lat": 33.4, "lon": -112.0, "speed_mph": 45,
       "heading": 90, "t_offset_s": 0, "label": "I-17 NB"},
      ...one entry per simulated second, ordered...
    ]
  }
"""

import argparse
import json
import math
import os
import time
import urllib.error
import urllib.parse
import urllib.request


# --------------- Constants ---------------
EARTH_RADIUS_M = 6_378_137.0
NOMINATIM_URL = "https://nominatim.openstreetmap.org/search"
USER_AGENT = "Speedio-RouteSimulator/1.0 (research; speedsenseapp@gmail.com)"
# Same Overpass mirror chain as speed_limit_compare.py so the SLO/error
# behavior is consistent with the existing tool.
OVERPASS_URL = "https://overpass-api.de/api/interpreter"
OVERPASS_MIRRORS = [
    OVERPASS_URL,
    "https://overpass.kumi.systems/api/interpreter",
    "https://lz4.overpass-api.de/api/interpreter",
    "https://overpass.openstreetmap.fr/api/interpreter",
]
OVERPASS_TIMEOUT_S = 120


# --------------- Math helpers ---------------
def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlam = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlam / 2) ** 2
    return 2 * EARTH_RADIUS_M * math.asin(math.sqrt(a))


def initial_bearing_deg(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Forward azimuth from (lat1,lon1) to (lat2,lon2), degrees [0, 360)."""
    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    dlam = math.radians(lon2 - lon1)
    y = math.sin(dlam) * math.cos(phi2)
    x = math.cos(phi1) * math.sin(phi2) - math.sin(phi1) * math.cos(phi2) * math.cos(dlam)
    return (math.degrees(math.atan2(y, x)) + 360) % 360


def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def sample_polyline(coords, spacing_m: float):
    """Walk along a polyline returning (lat, lon, cum_distance_m) sample
    points spaced approximately `spacing_m` apart.

    Key correctness property: we ALWAYS emit the polyline's last vertex
    (and first), even when sub-spacing, so the iOS app sees every junction
    rather than skipping tight OSM nodes. Mid-polyline corner vertices
    are preserved by emitting any target_d that lands past the end of a
    short segment as the endpoint of that segment.
    """
    if not coords:
        return
    if len(coords) == 1:
        yield (coords[0][0], coords[0][1], 0.0)
        return
    if spacing_m <= 0:
        raise ValueError(f"spacing_m must be > 0; got {spacing_m}")

    # Pre-compute cumulative distance to each vertex.
    cum = [0.0] * len(coords)
    for i in range(1, len(coords)):
        cum[i] = cum[i - 1] + haversine_m(coords[i - 1][0], coords[i - 1][1],
                                         coords[i][0],     coords[i][1])
    total = cum[-1]
    if total == 0:
        yield (coords[0][0], coords[0][1], 0.0)
        return

    # First point.
    yield (coords[0][0], coords[0][1], 0.0)

    # Walk segments, emitting any target_d (k * spacing_m) that falls within.
    # We use a `while` (not `if`) for the segment-advance because target_d may
    # leap multiple segments in one iteration when spacing_m is larger than
    # any single segment length (e.g., 50 sub-3 m segments with 13 m spacing).
    seg_start_a = coords[0]
    seg_start_b = coords[1]
    seg_start_cum = 0.0
    seg_end_cum = cum[1]
    seg_idx = 0
    target_d = spacing_m
    eps = spacing_m * 1e-6  # treat "within epsilon of endpoint" as endpoint
    last_seg = len(coords) - 2

    while target_d <= total + eps:
        # Advance through every segment whose end is before target_d. Multi-
        # step advance is required when target_d leaps over multiple short
        # segments in a single iteration.
        while target_d > seg_end_cum + eps and seg_idx < last_seg:
            seg_idx += 1
            seg_start_a = coords[seg_idx]
            seg_start_b = coords[seg_idx + 1]
            seg_start_cum = cum[seg_idx]
            seg_end_cum = cum[seg_idx + 1]
        if seg_idx >= last_seg and target_d > seg_end_cum + eps:
            # Past the last segment -- only the polyline endpoint can come next.
            break
        local_d = target_d - seg_start_cum
        seg_len = seg_end_cum - seg_start_cum
        if local_d >= seg_len - eps:
            # Snap to endpoint to preserve the polyline junction.
            yield (seg_start_b[0], seg_start_b[1], seg_end_cum)
        else:
            t = local_d / seg_len if seg_len > 0 else 0.0
            lat = lerp(seg_start_a[0], seg_start_b[0], t)
            lon = lerp(seg_start_a[1], seg_start_b[1], t)
            yield (lat, lon, target_d)
        target_d += spacing_m
    # Always emit the polyline endpoint if the last interior target didn't
    # land exactly on it. This preserves the final junction for the iOS
    # app even when spacing doesn't divide the polyline evenly.
    if target_d - spacing_m < total - eps:
        yield (coords[-1][0], coords[-1][1], total)


# --------------- HTTP helpers ---------------
def http_get_json(url, params=None, timeout=15, headers=None):
    if params:
        url = url + ("&" if "?" in url else "?") + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={
        "User-Agent": USER_AGENT,
        "Accept": "application/json",
        **(headers or {}),
    })
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def http_post_form(url, form_data, timeout=30, headers=None):
    body = urllib.parse.urlencode(form_data).encode("utf-8")
    req = urllib.request.Request(url, data=body, headers={
        "User-Agent": USER_AGENT,
        "Accept": "application/json",
        "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
        **(headers or {}),
    })
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def overpass_query_with_retries(url, query):
    """Mirror of speed_limit_compare._overpass_query_with_retries: try once,
    back off on transient errors, fall to the next mirror."""
    last_err = None
    for attempt in range(2):
        try:
            return http_post_form(url, {"data": query}, timeout=OVERPASS_TIMEOUT_S)
        except urllib.error.HTTPError as e:
            last_err = e
            if e.code == 429:
                if attempt == 0:
                    print(f"[overpass] {url} HIT 429; sleeping 60s then retrying once")
                    time.sleep(60)
                    continue
                raise
            if 500 <= e.code < 600:
                if attempt == 0:
                    print(f"[overpass] {url} HIT {e.code}; sleeping 10s then retrying once")
                    time.sleep(10)
                    continue
                raise
            raise
        except (urllib.error.URLError, OSError, ValueError) as e:
            last_err = e
            if attempt == 0:
                print(f"[overpass] {url} transient error ({type(e).__name__}); sleeping 10s")
                time.sleep(10)
                continue
            raise
    raise last_err


def query_overpass_ways_in_bbox(minlat, minlon, maxlat, maxlon):
    """Bulk Overpass query returning named highway ways whose bbox overlaps
    the visible envelope. Returns a list of dicts with id, name, ref, the
    full ordered coordinate list, and a highway-type tag."""
    query = (
        "[out:json][timeout:60];\n"
        f"way({minlat:.6f},{minlon:.6f},{maxlat:.6f},{maxlon:.6f})"
        "[highway][name];\n"
        "out geom;\n"
    )
    data = None
    last_err: Exception = RuntimeError("no mirror attempted")
    for url in OVERPASS_MIRRORS:
        try:
            data = overpass_query_with_retries(url, query)
            if url != OVERPASS_MIRRORS[0]:
                print(f"[overpass] recovered via mirror: {url}")
            break
        except (urllib.error.HTTPError, urllib.error.URLError,
                OSError, ValueError) as e:
            if isinstance(e, urllib.error.HTTPError) \
                    and 400 <= e.code < 500 and e.code != 429:
                print(f"[overpass] query-level error at {url}: {e}; stopping")
                raise
            last_err = e
            print(f"[overpass] mirror {url} failed: {e}")
            continue
    if data is None:
        raise last_err
    ways = []
    for el in (data.get("elements") or []):
        if el.get("type") != "way":
            continue
        tags = el.get("tags") or {}
        name = tags.get("name") or tags.get("ref")
        if not name:
            continue
        geometry = el.get("geometry") or []
        if len(geometry) < 2:
            continue
        coords = [(float(p["lat"]), float(p["lon"])) for p in geometry]
        ways.append({
            "osm_id": el["id"],
            "name": str(name),
            "ref": tags.get("ref", "") or "",
            "highway": tags.get("highway", "") or "",
            "maxspeed_raw": tags.get("maxspeed", "") or "",
            "coords": coords,
        })
    return ways


def geocode_nominatim(address: str):
    data = http_get_json(NOMINATIM_URL,
                         params={"q": address, "format": "json", "limit": 1},
                         timeout=15)
    if not data:
        raise RuntimeError(f"Nominatim returned no results for {address!r}")
    hit = data[0]
    return {
        "lat": float(hit["lat"]),
        "lon": float(hit["lon"]),
        "display_name": hit.get("display_name", address),
    }


# --------------- Mode: generate ---------------
def _target_tokens(target: str):
    """Tokenize a target route name for fuzzy matching. Returns the union of
    whitespace-split tokens AND hyphen-stripped sub-tokens, so 'I-17'
    contributes both 'i-17' AND ['i', '17'], which lets the mainline
    "Interstate 17" outscore the service road "I-17 Service Road"."""
    tokens = set()
    for tok in target.lower().split():
        tokens.add(tok)
        if "-" in tok:
            for sub in tok.split("-"):
                if sub:
                    tokens.add(sub)
    return tokens


# OSM `highway` tag ranked by how likely the road is the "main" road for a
# named route. A user searching for "I-17" almost never wants a service road
# even if its name contains the same route designator -- so motorway/trunk/
# primary score high and service/residential/track score low. Without this
# bonus, a hyphenated target like "I-17" was always outvoted by the service
# road that literally had "I-17" in its name.
HIGHWAY_TYPE_RANK = {
    "motorway": 200, "motorway_link": 100,
    "trunk": 150, "trunk_link": 80,
    "primary": 100, "primary_link": 60,
    "secondary": 60, "secondary_link": 40,
    "tertiary": 40, "tertiary_link": 25,
    "unclassified": 10, "residential": 5,
    "service": 1, "living_street": 3,
    "pedestrian": 1, "track": 1, "footway": 1, "path": 1,
    "bus_guideway": 30,
}


def _score_way(way, target_name: str):
    """Higher = better. Weights:
        100   target substring contained in `name`
         80   target substring contained in `ref`
        +5 / +4 per token match (using _target_tokens)
        +2   bonus if OSM already carries a `maxspeed` tag
       +rank  OSM `highway` type rank from HIGHWAY_TYPE_RANK
    """
    name_low = way["name"].lower()
    ref_low = way["ref"].lower()
    target_low = target_name.lower()
    score = 0
    if target_low in name_low:
        score += 100
    if target_low in ref_low:
        score += 80
    for tok in _target_tokens(target_name):
        if tok in name_low:
            score += 5
        if tok in ref_low:
            score += 4
    if way["maxspeed_raw"]:
        score += 2
    score += HIGHWAY_TYPE_RANK.get(way["highway"], 0)
    return score


def select_way(ways, road_name: str):
    """Pick the best matching road; fall back to the longest way if no name
    hit. Returns None if the bbox had no highway ways."""
    if not ways:
        return None
    if road_name:
        scored = sorted(((ww, _score_way(ww, road_name)) for ww in ways),
                        key=lambda ws: ws[1], reverse=True)
        if scored[0][1] > 0:
            return scored[0][0]
    return max(ways, key=lambda w: len(w["coords"]))


def build_route(way, speed_mph: float, duration_s: int, label: str):
    """Sample the polyline at 1 Hz given a target speed. Returns the list of
    {lat, lon, speed_mph, heading, t_offset_s, label} dicts."""
    speed_mps = speed_mph * 0.44704
    spacing_m = speed_mps * 1.0
    samples = list(sample_polyline(way["coords"], spacing_m))
    if len(samples) < 2:
        raise RuntimeError(
            f"polyline for {way['name']!r} is too short to interpolate "
            f"at {speed_mph} mph (got {len(samples)} samples)"
        )
    target_count = max(2, duration_s + 1)
    if len(samples) > target_count:
        # Evenly downsample.
        step = (len(samples) - 1) / max(1, target_count - 1)
        samples = [samples[int(round(i * step))] for i in range(target_count)]
    last_bearing = initial_bearing_deg(samples[0][0], samples[0][1],
                                        samples[1][0], samples[1][1])
    points = []
    for i, (lat, lon, _cum_m) in enumerate(samples):
        if i + 1 < len(samples):
            next_lat, next_lon, _ = samples[i + 1]
            heading = initial_bearing_deg(lat, lon, next_lat, next_lon)
            last_bearing = heading
        else:
            heading = last_bearing
        points.append({
            "lat": float(lat),
            "lon": float(lon),
            "speed_mph": float(speed_mph),
            "heading": float(heading),
            "t_offset_s": i,
            "label": label,
        })
    return points


def run_generate(args):
    if args.bbox is not None:
        minlat, minlon, maxlat, maxlon = args.bbox
        center = ((minlat + maxlat) / 2.0, (minlon + maxlon) / 2.0)
        center_desc = (f"bbox ({minlat:.4f},{minlon:.4f})-"
                        f"({maxlat:.4f},{maxlon:.4f})")
    else:
        geo = geocode_nominatim(args.address)
        center = (geo["lat"], geo["lon"])
        center_desc = geo["display_name"]
        dlat = args.bbox_radius_m / 111_111.0
        dlon = args.bbox_radius_m / (111_111.0 * math.cos(math.radians(center[0])))
        minlat = center[0] - dlat
        maxlat = center[0] + dlat
        minlon = center[1] - dlon
        maxlon = center[1] + dlon
    print(f"[geo] {center_desc} -> center=({center[0]:.6f}, {center[1]:.6f})")
    print(f"[bbox] {minlat:.4f},{minlon:.4f},{maxlat:.4f},{maxlon:.4f}")
    ways = query_overpass_ways_in_bbox(minlat, minlon, maxlat, maxlon)
    print(f"[overpass] {len(ways)} named highway ways returned")
    if not ways:
        raise SystemExit("no highway ways found in bbox; widen --bbox or use --address")
    way = select_way(ways, args.road_name or "")
    if way is None:
        raise SystemExit("no road selected")
    print(f"[pick] {way['name']!r} (OSM way {way['osm_id']}, "
          f"{way['highway']}, maxspeed={way['maxspeed_raw'] or '<none>'})")
    label = args.label or way["name"]
    points = build_route(way, args.speed_mph, args.duration_s, label)
    write_route(args.output, points, speed_mph=args.speed_mph,
                duration_s=args.duration_s, source="generate",
                way=way, center=center, center_desc=center_desc)


# --------------- Mode: replay ---------------
def run_replay(args):
    with open(args.input, "r", encoding="utf-8") as f:
        session = json.load(f)
    if isinstance(session, list):
        readings = session
    else:
        readings = session.get("readings") or session.get("points") or []
    if not readings:
        raise SystemExit(f"no readings/points found in {args.input}")
    pts = []
    for r in readings:
        lat = r.get("lat") or r.get("latitude")
        lon = r.get("lon") or r.get("longitude")
        if lat is None or lon is None:
            continue
        speed_mph = float(r.get("speed_mph")
                          or r.get("speedMph")
                          or (r.get("speed") or 0) * 2.23694
                          or args.speed_mph)
        heading = float(r.get("heading") or r.get("course") or 0.0)
        if args.speed_mph:
            speed_mph = float(args.speed_mph)
        t_offset = int(r.get("t_offset_s") or r.get("t") or len(pts))
        pts.append({
            "lat": float(lat),
            "lon": float(lon),
            "speed_mph": speed_mph,
            "heading": heading,
            "t_offset_s": t_offset,
            "label": r.get("label") or args.label or "replay",
        })
    if args.duration_s and len(pts) > args.duration_s + 1:
        step = (len(pts) - 1) / args.duration_s
        pts = [pts[int(round(i * step))] for i in range(args.duration_s + 1)]
        for i, p in enumerate(pts):
            p["t_offset_s"] = i
    write_route(args.output, pts, speed_mph=args.speed_mph,
                duration_s=args.duration_s or (len(pts) - 1),
                source="replay", input_file=args.input)


# --------------- Output ---------------
def write_route(path, points, speed_mph, duration_s, source: str,
                way=None, center=None, center_desc=None, input_file=None):
    payload = {
        "metadata": {
            "source": source,
            "speed_mph": speed_mph,
            "duration_s": duration_s,
            "center": center,
            "center_desc": center_desc,
            "way": (
                None if way is None else {
                    "osm_id": way["osm_id"],
                    "name": way["name"],
                    "ref": way["ref"],
                    "highway": way["highway"],
                    "maxspeed_raw": way["maxspeed_raw"],
                    "coord_count": len(way["coords"]),
                }
            ),
            "input_file": input_file,
            "point_count": len(points),
            "generated_at_unix": int(time.time()),
        },
        "points": points,
    }
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2)
    total_dist_m = 0.0
    for i in range(1, len(points)):
        total_dist_m += haversine_m(points[i - 1]["lat"], points[i - 1]["lon"],
                                    points[i]["lat"], points[i]["lon"])
    print(f"[write] {path}")
    print(f"        {len(points)} points · {speed_mph} mph · "
          f"{duration_s} s est · {total_dist_m / 1609.344:.2f} mi covered")


# --------------- Argparse + main ---------------
PROG_DESCRIPTION = (
    "Generate or replay a synthetic speed-limit test route JSON for the "
    "iOS app's #if DEBUG SimulationManager."
)


def build_parser():
    p = argparse.ArgumentParser(
        description=PROG_DESCRIPTION,
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    p.add_argument("--mode", choices=("generate", "replay"), default="generate",
                   help="generate: OSM Overpass -> route.json; "
                        "replay: existing DriveSession -> route.json")
    p.add_argument("--output", required=True, help="route.json path")
    p.add_argument("--road-name", default="",
                   help="[generate] Substring/token to bias road selection "
                        "(e.g. 'I-17', 'Grand Avenue'). Empty = longest.")
    p.add_argument("--bbox", nargs=4, type=float, metavar=("LAT", "LON", "LAT", "LON"),
                   help="[generate] (minlat, minlon, maxlat, maxlon). "
                        "Mutually exclusive with --address.")
    p.add_argument("--address",
                   help="[generate] Free-text geocoded via Nominatim "
                        "(e.g. 'Phoenix, AZ'). Mutually exclusive with --bbox.")
    p.add_argument("--bbox-radius-m", type=float, default=25000.0,
                   help="[generate] If --address is set, draw this radius "
                        "around the geocoded point. Default 25 km to handle "
                        "rural addresses where the geocoded center is far "
                        "from the road.")
    p.add_argument("--speed-mph", type=float, default=45.0,
                   help="Target driving speed (used both for sampling "
                        "spacing in --mode generate and as an override "
                        "cap in --mode replay; 0 in replay = use recorded).")
    p.add_argument("--duration-s", type=int, default=300,
                   help="Target route length. generate caps by downsampling; "
                        "replay caps by trimming the input. 0 = use full input.")
    p.add_argument("--label", default="",
                   help="Custom label written into each emitted point; "
                        "defaults to the OSM way name in generate mode.")
    p.add_argument("--input",
                   help="[replay] Session JSON file to convert.")
    return p


def main():
    parser = build_parser()
    args = parser.parse_args()
    if args.mode == "replay":
        if not args.input:
            raise SystemExit("--mode replay requires --input")
        return run_replay(args)
    if args.input:
        raise SystemExit("--input is only valid with --mode replay")
    if args.bbox and args.address:
        raise SystemExit("--bbox and --address are mutually exclusive")
    if not args.bbox and not args.address:
        raise SystemExit("--mode generate requires either --bbox or --address")
    return run_generate(args)


if __name__ == "__main__":
    main()
