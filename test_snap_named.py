"""Regression test for the road-name-first snap fix.

Background
----------
The Spatial-only snap would pick Santan Freeway (S 202, 65 mph) at the West
Frye Road coordinate because the S 202 bbox is enormous and engulfs the user's
GPS coord. The fix: when a road name is reverse-geocoded (or supplied in the
test), the SQLite scoring uses RoadNameMatcher to apply a massive negative
score offset to candidates whose RouteId matches the road name. With the
name fix, "West Frye Road" matches the SQLite entry "07 FRYE RD" (35 mph)
and decisively out-scores S 202.

Run:  python3 test_snap_named.py
Exit: 0 on all-pass, 1 on any failure.
"""

import os
import sys

# Server.py lives in website/ subdir; add to path.
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
        print(f"{name:64s} {PASS}")
        return True
    except AssertionError as e:
        print(f"{name:64s} {FAIL}: {e}")
        return False
    except Exception as e:
        print(f"{name:64s} {FAIL}: unexpected {type(e).__name__}: {e}")
        return False


# ---------- T1: exact canonical name match ----------
def t1():
    """road_name='West Frye Road' (Apple Maps) vs '07 FRYE RD' (HPMS SQLite).
    Both normalize to 'FRYE RD', so score must be 1.0."""
    s = srv.name_match_score("West Frye Road", "07 FRYE RD")
    assert s == 1.0, f"expected 1.0 (exact canonical), got {s}"


# ---------- T2: token subset ----------
def t2():
    """road_name='W Frye Rd' vs HPMS '07 FRYE RD'. Normalized: 'FRYE RD' and
    'FRYE RD' = exact match => 1.0."""
    s = srv.name_match_score("W Frye Rd", "07 FRYE RD")
    assert s == 1.0, f"expected 1.0, got {s}"


# ---------- T3: freeway-family numeric mismatch is rejected ----------
def t3():
    """road_name='US Highway 60' vs HPMS 'SR-60'. SR prefix != US family, so
    numeric-portions-match rule must REJECT => 0.0."""
    s = srv.name_match_score("US Highway 60", "SR 60")
    assert s < 0.7, (
        f"strict-family rule failed: US Highway 60 vs SR-60 must score < 0.7, got {s}"
    )


# ---------- T4: REGRESSION -- West Frye Road coord with road_name resolves to 35 mph ----------
def t4():
    """This is the actual bug. The user is at (33.29883, -111.84346) on
    West Frye Road (a 35 mph residential street in Gilbert AZ).

    With road_name='West Frye Road':
      The name-aware scoring MUST resolve to 07 FRYE RD (35 mph). The
      match is canonical ('FRYE RD' == 'FRYE RD'), so score = 1.0 and the
      candidate gets a -10000 offset.

    Without road_name:
      Spatial scoring alone does the right thing IF the local-road bbox
      covers the test coord (its centerline offset is 0 and the spatial
      gate doesn't filter it out). The synthetic bbox is widened so it
      covers the test coord, mirroring how a real-world residential block
      bbox looks (multiple 25m segments stretched across a few hundred
      meters of lat).
    """
    fake_segments = [
        # Santan Freeway east/west (matches earlier test).
        {'limit': 65, 'minx': -112.0050, 'maxx': -111.6790,
         'miny': 33.2620, 'maxy': 33.3104, 'route_id': 'S 202 EB'},
        {'limit': 65, 'minx': -112.0050, 'maxx': -111.6859,
         'miny': 33.2620, 'maxy': 33.3104, 'route_id': 'S 202 WB'},
        # 07 FRYE RD -- bbox widened to cover the actual bug coord.
        # Real world: 07 FRYE RD covers multiple short segments that span
        # ~200 m of lat (a few blocks N-S); the synthetic bbox mimics this.
        {'limit': 35, 'minx': -111.8761, 'maxx': -111.8391,
         'miny': 33.29800, 'maxy': 33.29970, 'route_id': '07 FRYE RD'},
    ]
    # WITHOUT road_name: spatial scoring alone must pick 07 FRYE RD. Its
    # bbox covers the test coord (centerline offset = 0, score = 25),
    # while S 202's perpendicular offset + base is ~1235. 07 FRYE RD wins.
    limit, route, _reject = srv.snap(fake_segments, 33.29883, -111.84346,
                                     road_name=None)
    assert limit == 35 and "FRYE" in (route or ""), (
        f"with road_name=None, snap(frye coord) MUST return 35 mph on 07 FRYE RD; "
        f"got {limit!r} on {route!r}"
    )

    # WITH road_name -- the name-aware scoring MUST also resolve to 35 mph
    # (same answer; name match confirms it with a much stronger margin).
    limit, route, _reject = srv.snap(fake_segments, 33.29883, -111.84346,
                                     road_name="West Frye Road")
    assert limit == 35 and "FRYE" in (route or ""), (
        f"with road_name='West Frye Road', snap(frye coord) MUST return 35 mph; "
        f"got {limit!r} on {route!r}"
    )


# ---------- T5: REGRESSION -- user genuinely ON S 202 picks S 202 via the spatial (centerlineOffset) path ----------
def t5():
    """A user genuinely driving on the S 202 Freeway: road_name from
    CLGeocoder is 'Santan Freeway', but the matcher has NO way to connect
    a colloquial name to a numbered route ID (no digits in 'Santan
    Freeway'). This is a known limitation -- the spatial path picks S 202
    because the user is AT THE FREEWAY CENTERLINE where centerlineOffset=0
    and no cross-street segments require name-match to win. Verifies that
    name-match scoring NEVER accidentally out-scores a genuine S 202 pick
    when road_name is non-empty but unmatched.
    """
    fake_segments = [
        # Freeway: 'S 202' canonicalizes to 'S 202 EB'.
        {'limit': 65, 'minx': -112.0050, 'maxx': -111.6790,
         'miny': 33.2617, 'maxy': 33.3104, 'route_id': 'S 202 EB'},
        # Cross street. Wider bbox but lon range is well west of test lon.
        {'limit': 35, 'minx': -111.8761, 'maxx': -111.8391,
         'miny': 33.29800, 'maxy': 33.29970, 'route_id': '07 FRYE RD'},
    ]
    # User ON the freeway centerline (lat at center of S 202 bbox). The
    # test lon (-111.84147) sits OUTSIDE the 07 FRYE RD bbox's lon range,
    # so 07 FRYE RD is filtered out by the spatial gate and S 202 wins.
    test_lat, test_lon = 33.28605, -111.84147
    # Without road_name, on-centerline should pick S 202 (centerlineOffset=0).
    limit, route, _reject = srv.snap(fake_segments, test_lat, test_lon,
                                     road_name=None)
    assert limit == 65, (
        f"on-freeway centerline without road_name should pick S 202, got {limit} on {route!r}"
    )

    # With road_name='Santan Freeway' -- name match scoring returns 0.0
    # (no digits in 'Santan Freeway' means no numeric-portions match).
    # The two-pass model REJECTS Sqlite when road_name has no SQL match
    # within the 200 m gate -- even if the user is genuinely on the freeway.
    # That's the intentional choice: the orchestrator then
    # tries ArcGIS / Overpass (which DO know S 202's 65 mph).
    s202_match = srv.name_match_score("Santan Freeway", "S 202 EB")
    assert s202_match == 0.0, (
        f"'Santan Freeway' has no digits -> scorer must return 0.0 (no false "
        f"name boost on state routes), got {s202_match}"
    )
    limit, route, reject_reason = srv.snap(fake_segments, test_lat, test_lon,
                                           road_name="Santan Freeway")
    assert limit == 0 and route is None and reject_reason is not None, (
        f"with road_name='Santan Freeway' and no SQL name match, snap MUST "
        f"REJECT (limit=0, route=None, reason non-empty); "
        f"got limit={limit} route={route!r} reason={reject_reason!r}"
    )


# ---------- T6: REGRESSION -- cross-street w/ road_name wins over distant cross-street ----------
def t6():
    """Edge case: 'W Frye Rd' test where road_name match scores 1.0,
    S 202 has no name match. Both have a similar spatial score distribution;
    the name bonus must make '07 FRYE RD' decisive."""
    fake_segments = [
        {'limit': 65, 'minx': -112.0050, 'maxx': -111.6790,
         'miny': 33.2620, 'maxy': 33.3104, 'route_id': 'S 202 EB'},
        {'limit': 35, 'minx': -111.84225, 'maxx': -111.84075,
         'miny': 33.29870, 'maxy': 33.29895, 'route_id': '07 FRYE RD'},
    ]
    # Coordinate inside Frye Road's tight bbox so the spatial score is ~equal.
    limit, route, _reject = srv.snap(fake_segments, 33.29883, -111.84150,
                                     road_name="W Frye Rd")
    assert limit == 35 and "FRYE" in (route or ""), (
        f"with road_name='W Frye Rd' on Frye Rd's bbox: expected 35 mph; "
        f"got {limit} on {route!r}"
    )


# ---------- T7: Numeric part match works for interstate / highway ----------
def t7():
    """'Interstate 17' canonicalizes to 'INTERSTATE 17'. Provider 'I-17'
    canonicalizes to 'I-17'. The numeric portion is '17' in both. The name
    contains the strict family keyword 'INTERSTATE', and the provider's
    alpha prefix 'I' matches the strict family 'I'. So score = 0.7."""
    s = srv.name_match_score("Interstate 17", "I-17")
    assert s == 0.7, f"expected 0.7 (strict family I match), got {s}"


def main():
    tests = [t1, t2, t3, t4, t5, t6, t7]
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
