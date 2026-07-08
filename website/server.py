#!/usr/bin/env python3
"""
website/server.py -- Stdlib HTTP server that ports the AZ SQLite fast-path
of SmartSpeedCompanion/Core/ArizonaSpeedLimitService.swift to a JSON endpoint.

This file is a DELIBERATE PORT of the Swift actor with three omissions each
explicitly called out so future readers do not add them back by accident:

  - heading       : nil         (web context has no car heading)
  - currentSpeedMph: nil        (no driving-state)
  - lastSegmentId : nil         (no per-session hysteresis on a one-shot pin)

With those three nil, the Swift scoring collapses to:

    score = (distance + 1.0) * 1.0  +  area * AREA_WEIGHT

which is what this file computes. All other Swift constants, the SQL query,
and the per-segment distance math are kept identical. Detail / roadKey /
providerName fields returned to the browser mirror exactly what
SmartSpeedLimitService.updateSpeedLimit step 1.5 produces.

Stdlib only. Run:
    python website/server.py
Then open http://127.0.0.1:8089/.
"""

import json
import math
import os
import sqlite3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


# ---- Constants mirrored verbatim from ArizonaSpeedLimitService.swift ----
GRID_DEGREES = 0.02             # Swift: searchBuffer / gridPrecision
SNAP_RADIUS_M = 20.0           # Swift: maxSnappingDistance when expandedSearch=false
CACHE_RADIUS_DEGREES = 0.03    # Swift: cacheRadiusDegrees (~2 mi)
SKIP_DIAGONAL_DEGREES = 1.0    # Swift: county-polygon diagonal cap
AREA_WEIGHT = 50.0             # Swift: tie-breaker weight
EARTH_M_PER_DEG_LAT = 111_111.0 # Swift: dy * 111111.0 in RoadSegment.distance

PORT = int(os.environ.get('PORT', '8089'))
DB_PATH = os.path.normpath(os.path.join(
    os.path.dirname(__file__), '..',
    'SmartSpeedCompanion', 'Resources', 'ArizonaSpeedLimits.sqlite',
))


# ---- Mirrored functions ------------------------------------------------

def segment_distance_m(minx, maxx, miny, maxy, lat, lon):
    """Mirror RoadSegment.distance(to:) in ArizonaSpeedLimitService.swift.
    Uses planar approximation (deg * 111111 * cos(lat)) for longitude
    rescaling, identical to Swift; good enough for sub-100m distances at
    AZ latitudes (~33 deg)."""
    dx = max(0.0, minx - lon, lon - maxx)
    dy = max(0.0, miny - lat, lat - maxy)
    if dx == 0.0 and dy == 0.0:
        return 0.0
    cos_lat = math.cos(math.radians(lat))
    lat_m = dy * EARTH_M_PER_DEG_LAT
    lon_m = dx * EARTH_M_PER_DEG_LAT * cos_lat
    return math.sqrt(lat_m * lat_m + lon_m * lon_m)


def fetch_segments(conn, lat, lon):
    """Mirror refreshCircularCache(at:) SQL and bounds. Return positive-limit
    segments within a 0.03 deg box (~2 mi radius)."""
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


def snap(segments, lat, lon):
    """Mirror updateSpeedLimit(at:heading:currentSpeedMph:expandedSearch:) in
    Swift. Web context has heading=nil and currentSpeedMph=nil so the
    scoreMultiplier stays at 1.0; the lastSegmentId branch is dead-code."""
    best_limit, best_route, best_score = 0, None, float('inf')
    for seg in segments:
        ddx = seg['maxx'] - seg['minx']
        ddy = seg['maxy'] - seg['miny']
        if math.sqrt(ddx * ddx + ddy * ddy) > SKIP_DIAGONAL_DEGREES:
            continue
        dist = segment_distance_m(seg['minx'], seg['maxx'],
                                  seg['miny'], seg['maxy'], lat, lon)
        if dist > SNAP_RADIUS_M:
            continue
        area = ddx * ddy
        # score = (dist + 1.0) * scoreMultiplier + area * AREA_WEIGHT.
        # -- multiplier defaults to 1.0 since heading/currentSpeedMph are nil.
        score = (dist + 1.0) + area * AREA_WEIGHT
        if score < best_score:
            best_score = score
            best_limit = seg['limit']
            best_route = seg['route_id']
    return best_limit, best_route


# ---- HTTP handler -------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()

    def do_GET(self):
        path = self.path.split('?', 1)[0]
        if path == '/health':
            return self._json(200, {
                'service': 'speedio-az-sqlite',
                'db_exists': os.path.exists(DB_PATH),
                'db_path': DB_PATH,
            })
        if path in ('/', '/index.html'):
            file_path = os.path.join(os.path.dirname(__file__), 'index.html')
            if os.path.isfile(file_path):
                with open(file_path, 'rb') as f:
                    data = f.read()
                self.send_response(200)
                self.send_header('Content-Type', 'text/html; charset=utf-8')
                self.send_header('Cache-Control', 'no-store')
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
        return self._json(404, {'error': 'not found'})

    def do_POST(self):
        path = self.path.split('?', 1)[0]
        if path != '/api/speedlimit-az':
            return self._json(404, {'error': 'unknown route'})
        try:
            length = int(self.headers.get('Content-Length', '0'))
            raw = self.rfile.read(length).decode('utf-8') if length > 0 else '{}'
            body = json.loads(raw)
            lat = float(body['lat'])
            lon = float(body['lon'])
        except (ValueError, KeyError, json.JSONDecodeError):
            return self._json(
                400,
                {'error': 'bad JSON; need {"lat": float, "lon": float}'})
        if not os.path.exists(DB_PATH):
            return self._json(500, {'error': f'AZ sqlite not found: {DB_PATH}'})
        try:
            conn = sqlite3.connect(f'file:{DB_PATH}?mode=ro', uri=True)
            try:
                segments = fetch_segments(conn, lat, lon)
                limit, route = snap(segments, lat, lon)
                if limit <= 0:
                    return self._json(200, {'found': False})
                return self._json(200, {
                    'found': True,
                    'speedMph': limit,
                    # SpeedLimitResponse fields. Mirror exactly what
                    # SmartSpeedLimitService.updateSpeedLimit step 1.5 produces:
                    'roadKey': 'local-sqlite',
                    'providerName': 'AZ SQLite',
                    'detail': 'Local SQLite lookup within 1 km corridor',
                    # Extra web-only diagnostic for fact-checking.
                    'routeId': route,
                })
            finally:
                conn.close()
        except Exception as exc:
            return self._json(500, {'error': str(exc)})

    def _json(self, code, payload):
        body = json.dumps(payload).encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        # Silence the default per-request stderr access log.
        pass


def main():
    print(f'[server] AZ SQLite at {DB_PATH}')
    print(f'[server] serving http://127.0.0.1:{PORT}/ (index.html + /api/speedlimit-az)')
    httpd = ThreadingHTTPServer(('127.0.0.1', PORT), Handler)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == '__main__':
    main()
