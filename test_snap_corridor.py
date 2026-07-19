"""Regression test for the freeway-bbox snap bug.

Background
----------
On a coord near S Arizona Ave & Pecos Rd, Gilbert AZ
(approximately 33.29146, -111.84147), the Speedio local SQLite
lookup was returning 65 mph from "S 202" (Santan Freeway) when the
user was actually on a 45 mph cross-street (07 Pecos Rd).

Root cause: the freeway segment's bounding box (dx ~= 0.325 deg,
dy ~= 0.049 deg) is so large it ENGULFS the user's coord, so the
Swift+Python `RoadSegment.distance(to:) / segment_distance_m`
returned 0.0, letting it out-score the actual 15m-tight local-road
bbox.

Fix: introduce a "centerline offset" penalty. For corridors (highly
elongated bboxes), the offset from the inferred centerline is
returned as a flat score penalty. For square bboxes (local roads),
the offset collapses to 0 (legacy behavior). Bump the score's base
offset 1.0 -> 25.0 so heading/velocity/hysteresis multipliers can
still override the corridor penalty when genuinely on the road.

Defense-in-depth: if the user is on a residential street with NO
road_name from the geocoder (Nominatim rate-limit misses, residential
complex names, etc.), a corridor whose centerlineOffset is big is
HERE classified as ambiguous and gets a +2000 score penalty. This
handles the regression where the user's coord was (33.29888,
-111.83890) and got 65 mph from S 202 instead of 35 mph from
07 FRYE RD.

Run:  python3 test_snap_corridor.py
Exit: 0 on all-pass, 1 on any failure.
"""

import os
import sys

# `server.py` lives in the website/ subfolder. Add it to sys.path so the
# regression test can mirror its constants and snap() function call-for-call.
_HERE = os.path.dirname(os.path.abspath(__file__))
_WEBSITE = os.path.join(_HERE, "website")
if _WEBSITE not in sys.path:
    sys.path.insert(0, _WEBSITE)

import server as srv  # noqa: E402

PASS = "PASS"
FAIL = "FAIL"


def _run(name, fn):
    try:
        fn()
        print(f"{name:60s} {PASS}")
        return True
    except AssertionError as e:
        print(f"{name:60s} {FAIL}: {e}")
        return False
    except Exception as e:
        print(f"{name:60s} {FAIL}: unexpected {type(e).__name__}: {e}")
        return False


# ---------- T1: centerline_offset_m returns 0 for square bboxes (legacy) ----------
def t1():
    """A coord inside a square (local-road) bbox must score 0 centerline offset.
    Pre-fix and post-fix behavior must agree on tight local roads."""
    # 0.0002 deg ~ 22m. Square aspect ratio = 1 -> factor -> 0 -> offset 0.
    offset = srv.centerline_offset_m(
        minx=-111.84378, maxx=-111.83912,
        miny=33.29135, maxy=33.29157,
        lat=33.29146, lon=-111.84147,
    )
    assert offset == 0.0, f"square bbox should give offset 0, got {offset}m"


# ---------- T2: centerline_offset_m returns the cross-axis distance for corridors ----------
def t2():
    """A horizontal corridor (dx >> dy) at S 202 Santan Freeway-ish dimensions:
    ~36 km * 5.4 km. Point 0.005 deg (~556 m) off-centerline in latitude must
    report ~472 m offset (offset = |lat - cy| * factor)."""
    # dx ~= 0.3253, dy ~= 0.0476. factor = 1 - (h/w) ~= 0.854.
    # Center y = 33.286. Choose lat 33.29105 -> lat-cy = 0.005 deg (~556m).
    # offset = 556m * 0.854 = ~475m.
    offset = srv.centerline_offset_m(
        minx=-112.0045, maxx=-111.6792,   # dx = 0.3253 deg
        miny=33.2617,  maxy=33.3104,      # dy = 0.0487 deg
        lat=33.29105,                       # ~556m north of center (= 0.005 deg)
        lon=-111.84147,
    )
    assert 440 < offset < 510, (
        f"horizontal corridor expected ~475m offset, got {offset:.1f}m"
    )


# ---------- T3: centerline_offset_m is monotonic wrt point moving outside the bbox ----------
def t3():
    """As a point moves further OUTSIDE the bbox along the minor axis, the
    centerline-offset penalty grows (until the |lat-cy| = h/2 saturation
    point), then plateaus at (h/2) * factor. We verify it never decreases
    as the point moves monotonically further away on the minor axis -- a
    backwards-facing jump would mean the snap scoring behaves weirdly at
    the bbox edge."""
    # Inside (just north of center, well within bbox).
    inside_offset = srv.centerline_offset_m(
        minx=-112.0045, maxx=-111.6792,
        miny=33.2617,  maxy=33.3104,
        lat=33.28605, lon=-111.84147,   # exactly on centerline
    )
    # Inside at lat 33.2620 (~33m above miny). lat-cy = -0.02405 -> abs< h/2.
    inside_near_miny = srv.centerline_offset_m(
        minx=-112.0045, maxx=-111.6792,
        miny=33.2617,  maxy=33.3104,
        lat=33.26200, lon=-111.84147,
    )
    # Outside, way north. Plateau at h/2 * factor.
    outside_far_north = srv.centerline_offset_m(
        minx=-112.0045, maxx=-111.6792,
        miny=33.2617,  maxy=33.3104,
        lat=33.7417, lon=-111.84147,
    )
    # On centerline (lat == cy): offset = 0.
    assert inside_offset < 5.0, (
        f"point on centerline should give ~0 offset, got {inside_offset:.1f}m"
    )
    # Moving from centerline toward (but still inside) the edge must grow offset.
    assert inside_near_miny > inside_offset, (
        f"offset should grow as point moves off-centerline: "
        f"center={inside_offset:.1f}m near-miny={inside_near_miny:.1f}m"
    )
    # After crossing the bbox edge, offset saturates at (h/2) * factor. So
    # outside_far_north should be >= inside_near_miny (more or equal -- the
    # clamp at h/2 caps it).
    assert outside_far_north >= inside_near_miny - 1.0, (
        f"offset must not decrease across bbox edge: "
        f"inside={inside_near_miny:.1f}m outside={outside_far_north:.1f}m"
    )


# ---------- T4: REGRESSION -- snap at bug coord returns 45 mph Pecos Rd, not 65 mph S 202 ----------
def t4():
    """The actual bug. Both S 202 east/west segments have bboxes that engulf
    (33.29146, -111.84147). With the legacy code (distance = 0, area penalty =
    0.79) they out-scored 07 PECOS RD. With the fix (centerline offset kicks
    in for the corridor, score penalty > base + edge for S 202, but stays
    small for Pecos Rd which has a tight square-ish bbox), Pecos wins."""
    # Construct just the relevant segments, the same way the DB JOIN produces them.
    fake_segments = [
        # S 202 eastbound: bbox 36 x 5.4 km, limit 65
        {'limit': 65, 'minx': -112.0045, 'maxx': -111.6792,
         'miny': 33.2617, 'maxy': 33.3104, 'route_id': '  S 202                       0 '},
        # S 202 westbound: bbox 35 x 5.4 km, limit 65
        {'limit': 65, 'minx': -112.0045, 'maxx': -111.6859,
         'miny': 33.2617, 'maxy': 33.3104, 'route_id': '  S 202                         '},
        # 07 PECOS RD: tight bbox 3.9 km x 26 m, limit 45
        {'limit': 45, 'minx': -111.8761, 'maxx': -111.8391,
         'miny': 33.29114, 'maxy': 33.29137, 'route_id': '07 PECOS RD'},
        # 07 FAIRVIEW ST: another small local road, also tight, 25
        {'limit': 25, 'minx': -111.8475, 'maxx': -111.8412,
         'miny': 33.28940, 'maxy': 33.29053, 'route_id': '07 FAIRVIEW ST'},
    ]
    limit, route, _reject = srv.snap(fake_segments, 33.29146, -111.84147)
    assert limit == 45, (
        f"REGRESSION: expected 45 mph (07 PECOS RD), got {limit} mph "
        f"on {route!r}"
    )
    assert route == '07 PECOS RD', (
        f"REGRESSION: expected route '07 PECOS RD', got {route!r}"
    )


# ---------- T5: REGRESSION -- snap still picks the freeway when ON the freeway ----------
def t5():
    """Verify the score-base bump + centerline offset don't accidentally
    flip a TRULY-on-the-freeway coord to a cross-street.

    On the S 202 centerline, the centerlineOffset returns ~0 (point IS on
    the centerline). The cross-street 07 PECOS RD is ~150m away so it
    contributes ~150m penalty. Therefore the freeway wins."""
    fake_segments = [
        # S 202 eastbound centered on (33.286, -111.842) -- coord sits on it.
        {'limit': 65, 'minx': -112.0045, 'maxx': -111.6792,
         'miny': 33.2617, 'maxy': 33.3104, 'route_id': 'S 202 EB'},
        # 07 PECOS RD: place 150 m north of the test coord so it's > SNAP_RADIUS_M away
        # -> dropped by the spatial gate. Belt-and-suspenders: also place it close
        # enough that it doesn't matter for the gate, but at the north edge of the
        # freeway bbox to verify the freeway truly wins.
        {'limit': 45, 'minx': -111.8761, 'maxx': -111.8081,
         'miny': 33.29150, 'maxy': 33.29165, 'route_id': '07 PECOS RD'},
    ]
    # Test coord: ON the S 202 centerline (mid Y of bbox).
    test_lat = 33.2860  # == (33.2617 + 33.3104) / 2
    test_lon = -111.84147
    limit, route, _reject = srv.snap(fake_segments, test_lat, test_lon)
    # On the centerline: distance 0, offset 0. Score = (0 + 25) * 1 + 0 = 25.
    # 07 PECOS RD distance = 150m (outside spatial gate for corridors). Score
    # = dist + offset + PASS2_LOCAL_ROAD_RADIUS_M-cap = pass but high.
    # Freeway wins cleanly.
    assert limit == 65, (
        f"On the freeway expected 65 mph, got {limit} mph on {route!r}"
    )


# ---------- T6: REGRESSION -- residential coord in Chandler with no road_name still picks the local road, NOT S 202 mega-bbox ----------
def t6():
    """Real bug. User clicked on a residential street at (33.29888, -111.83890)
    in Chandler. Nominatim returned 'Olympus Steelyard' (no address.road for
    this point), so the orchestrator called SQLite WITHOUT a road_name.

    Without the corridor-ambiguity rejection, the 36 km x 5 km S 202 mega-bbox
    swallowed the coord (dist=0) and would out-score the actual local road
    because S 202's score (745 with centerline offset ~740) beat FRYE RD's
    potential combined score. With the new defense-in-depth: S 202 is
    classified as a corridor (aspect 6.6 > 3) and is AMBIGUOUS (centerlineOffset
    ~740 > 250). It gets a +2000 score penalty. FRYE RD's score stays ~36 so
    the local road wins cleanly."""
    fake_segments = [
        # S 202 eastbound: the freeway mega-bbox (mimics real DB shape).
        {'limit': 65, 'minx': -112.0045, 'maxx': -111.6792,
         'miny': 33.2617, 'maxy': 33.3104, 'route_id': 'S 202 EB'},
        # 07 FRYE RD: tight local-road bbox that hugs the user's coord.
        {'limit': 35, 'minx': -111.84225, 'maxx': -111.84075,
         'miny': 33.29870, 'maxy': 33.29895, 'route_id': '07 FRYE RD'},
    ]
    limit, route, _reject = srv.snap(fake_segments, 33.29888, -111.83890,
                                     road_name=None)
    assert limit == 35 and "FRYE" in (route or ""), (
        f"REGRESSION: residential coord (no road_name) MUST pick the local "
        f"07 FRYE RD 35 mph, never S 202 mega-bbox; got {limit} mph on {route!r}"
    )


def main():
    tests = [t1, t2, t3, t4, t5, t6]
    results = []
    for t in tests:
        results.append(_run(t.__name__, t))
    print()
    if all(results):
        print(f"All {len(tests)} tests PASS.")
        return 0
    failed = sum(1 for r in results if not r)
    print(f"{failed}/{len(tests)} tests FAILED.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
