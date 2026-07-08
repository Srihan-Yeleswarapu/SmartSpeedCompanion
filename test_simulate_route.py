"""Unit tests for simulate_route.py math + scoring layers.

Mirrors the test_speed_limit_compare.py pattern: pure stdlib, no network,
runs in < 2 seconds.

Run:  python3 test_simulate_route.py
Exit: 0 on all-pass, 1 on any failure.
"""

import math
import sys

import simulate_route as m

PASS = "PASS"
FAIL = "FAIL"


def _run(name, fn):
    try:
        fn()
        print(f"{name:56s} {PASS}")
        return True
    except AssertionError as e:
        print(f"{name:56s} {FAIL}: {e}")
        return False
    except Exception as e:
        print(f"{name:56s} {FAIL}: unexpected {type(e).__name__}: {e}")
        return False


# ---------- T1: haversine_m golden case (0) ----------
def t1():
    assert m.haversine_m(33.0, -112.0, 33.0, -112.0) == 0.0


# ---------- T2: haversine_m 1 deg latitude at equator = ~111 km ----------
def t2():
    d = m.haversine_m(0.0, 0.0, 1.0, 0.0)
    assert 110_500 < d < 111_700, f"expected ~111 km, got {d}"


# ---------- T3: haversine_m symmetric ----------
def t3():
    a = m.haversine_m(33.4, -112.0, 33.5, -112.1)
    b = m.haversine_m(33.5, -112.1, 33.4, -112.0)
    assert abs(a - b) < 1e-6, f"a={a} b={b}"


# ---------- T4: initial_bearing_deg 0 = north ----------
def t4():
    bearing = m.initial_bearing_deg(33.0, -112.0, 33.1, -112.0)
    assert abs(bearing) < 0.5, f"expected ~0 (north), got {bearing}"


# ---------- T5: initial_bearing_deg 90 = east ----------
def t5():
    bearing = m.initial_bearing_deg(33.0, -112.0, 33.0, -111.9)
    assert abs(bearing - 90) < 0.5, f"expected ~90 (east), got {bearing}"


# ---------- T6: initial_bearing_deg 180 = south ----------
def t6():
    bearing = m.initial_bearing_deg(33.1, -112.0, 33.0, -112.0)
    assert abs(bearing - 180) < 0.5, f"expected ~180 (south), got {bearing}"


# ---------- T7: lerp at boundaries ----------
def t7():
    assert m.lerp(0.0, 10.0, 0.0) == 0.0
    assert m.lerp(0.0, 10.0, 1.0) == 10.0
    assert m.lerp(0.0, 10.0, 0.5) == 5.0


# ---------- T8: sample_polyline single coord ----------
def t8():
    pts = list(m.sample_polyline([(33.4, -112.0)], 13.0))
    assert len(pts) == 1
    assert pts[0] == (33.4, -112.0, 0.0)


# ---------- T9: sample_polyline empty ----------
def t9():
    assert list(m.sample_polyline([], 13.0)) == []


# ---------- T10: sample_polyline uniform spacing on a long segment ----------
def t10():
    # 100 m east-west line, sampling at 13 m spacing -> 8 evenly-spaced samples
    # (first at 0, last at 100m). Plus the polyline endpoint.
    coords = [(33.4, -112.0), (33.4, -111.0 + 0.000899)]
    # ^ this approximation is fuzzy; instead use a 100m polyline at higher precision
    # 100m east-west at lat 33.4: 100m / (cos(33.4)*111km) = 100m / 92700m = 0.00108 deg lon
    coords = [(33.4, -112.0), (33.4, -112.0 + 0.00108)]
    pts = list(m.sample_polyline(coords, 13.0))
    assert len(pts) >= 7, f"expected >= 7 samples (incl. endpoint), got {len(pts)}"
    # Spacing between consecutive cum distances should be ~13m.
    cums = [p[2] for p in pts]
    for i in range(1, len(cums) - 1):
        d = cums[i] - cums[i - 1]
        assert abs(d - 13.0) < 0.5, f"sample {i} spacing {d}m not 13m"


# ---------- T11: sample_polyline preserves the polyline endpoint ----------
def t11():
    # Two-segment polyline where the second segment is shorter than spacing.
    # The polyline's last vertex must still appear in the output, with cum
    # equal to the sum of both segment lengths (~109.3 m).
    coords = [(33.4, -112.0), (33.4, -112.0 + 0.00108), (33.4, -112.0 + 0.00108 + 0.0001)]
    pts = list(m.sample_polyline(coords, 13.0))
    last_lat, last_lon, last_cum = pts[-1]
    # Endpoint lat/lon must equal the polyline's last coord.
    assert last_lat == coords[-1][0] and last_lon == coords[-1][1], (
        f"endpoint lat/lon not preserved: last=({last_lat}, {last_lon}), "
        f"expected=({coords[-1][0]}, {coords[-1][1]})"
    )
    # Endpoint cum must be ~109.3 m (sum of both segment lengths).
    assert abs(last_cum - 109.3) < 1.0, f"expected cum~109.3, got {last_cum}"


# ---------- T12: sample_polyline handles sub-spacing segments without losing them ----------
def t12():
    # 50-segment polyline with each segment ~3.33 m, spacing 13 m. Polyline
    # total ~166.5 m. Expect: 12 evenly-spaced interior samples + 1 endpoint.
    coords = [(33.4 + i * 0.00003, -112.0) for i in range(51)]
    pts = list(m.sample_polyline(coords, 13.0))
    cums = [p[2] for p in pts]
    # End cumulative distance ~166.5 m (50 segments x 3.33 m).
    assert abs(cums[-1] - 166.5) < 1.0, f"expected cum~166.5, got {cums[-1]}"
    # First cum is 0.
    assert cums[0] == 0.0


# ---------- T13: _target_tokens 'I-17' produces both 'i-17' and 'i' and '17' ----------
def t13():
    toks = m._target_tokens("I-17")
    assert toks == {"i-17", "i", "17"}, f"got {toks}"


# ---------- T14: _target_tokens 'Grand Avenue' splits on whitespace only ----------
def t14():
    toks = m._target_tokens("Grand Avenue")
    assert toks == {"grand", "avenue"}, f"got {toks}"


# ---------- T15: _score_way prefers mainline over service road (regression) ----------
def t15():
    # This is the bug the previous code had: 'I-17' selected the service road
    # because 'I-17 Service Road' contains 'i-17' as substring (100pts) but
    # 'Interstate 17' does not. The fix added hyphen-stripped tokenization so
    # the mainline gets +5 from token '17' matching name.
    mainline = {
        "name": "Interstate 17", "ref": "I-17", "highway": "motorway",
        "maxspeed_raw": "75 mph",
    }
    service_road = {
        "name": "I-17 Service Road", "ref": "I-17", "highway": "service",
        "maxspeed_raw": "",
    }
    sm = m._score_way(mainline, "I-17")
    ss = m._score_way(service_road, "I-17")
    assert sm > ss, f"mainline score {sm} <= service road {ss}"


# ---------- T16: _score_way exact ref match scores high ----------
def t16():
    w = {
        "name": "Some Other Road", "ref": "I-17", "highway": "motorway",
        "maxspeed_raw": "",
    }
    score = m._score_way(w, "I-17")
    # +80 (ref substring) + +4 (token 'i-17' in ref) = 84
    assert score >= 80, f"expected >= 80 for ref match, got {score}"


# ---------- T17: _score_way returns 0 for no match ----------
def t17():
    # "construction" is a real OSM tag but not in HIGHWAY_TYPE_RANK, so
    # this way scores 0 (no name/ref/token match, no maxspeed, no rank).
    w = {
        "name": "Grand Avenue", "ref": "", "highway": "construction",
        "maxspeed_raw": "",
    }
    score = m._score_way(w, "I-17")
    assert score == 0, f"expected 0 for unrelated way, got {score}"


# ---------- T18: select_way prefers name match over fallback ----------
def t18():
    ways = [
        {"name": "Grand Avenue", "ref": "", "highway": "residential",
         "maxspeed_raw": "", "coords": [(0, 0), (0, 0)]},
        {"name": "Other Street", "ref": "Grand Ave Loop", "highway": "residential",
         "maxspeed_raw": "", "coords": [(0, 0)] * 10},  # 9 coords (longer)
    ]
    pick = m.select_way(ways, "Grand Avenue")
    assert pick is not None
    assert pick["name"] == "Grand Avenue", f"expected Grand Avenue, got {pick['name']}"


# ---------- T19: select_way falls back to longest when no name match ----------
def t19():
    # A scores 0 (no name/ref/tokens/maxspeed; "construction" is not in
    # HIGHWAY_TYPE_RANK). B scores 5 ("residential" rank). So B wins on
    # its name-agnostic score, not just on length. This also exercises
    # the highway-type-rank influence on selection.
    ways = [
        {"name": "A", "ref": "", "highway": "construction", "maxspeed_raw": "",
         "coords": [(0, 0)] * 3},
        {"name": "B", "ref": "", "highway": "residential", "maxspeed_raw": "",
         "coords": [(0, 0)] * 20},
    ]
    pick = m.select_way(ways, "Z")  # no name hit
    assert pick is not None
    assert pick["name"] == "B", f"expected fallback to B, got {pick['name']}"


# ---------- T20: select_way returns None on empty input ----------
def t20():
    assert m.select_way([], "anything") is None


def main():
    tests = [t1, t2, t3, t4, t5, t6, t7, t8, t9, t10, t11, t12,
             t13, t14, t15, t16, t17, t18, t19, t20]
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
