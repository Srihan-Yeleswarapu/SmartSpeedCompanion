"""Unit tests for speed_limit_compare.py Overpass mirror-fallback logic.

Mocks speed_limit_compare._http_post_form to simulate every failure mode the
real Overpass mirrors can produce, then verifies the right fall-through /
retry / propagation behavior. Pure stdlib, runs in < 5 seconds.

Run:  python3 test_speed_limit_compare.py
Exit: 0 on all-pass, 1 on any failure.
"""
import sys
import json
import socket
import http.client
import urllib.error

import speed_limit_compare as m

CALL_LAT, CALL_LON, RADIUS_M = 33.242907, -111.785290, 80467.0

FAIL = "FAIL"
PASS = "PASS"

# Save the real _http_post_form at import time so _reset() can restore it.
m._http_post_form_REAL = m._http_post_form

# Disable the 10s/60s backoff sleeps in the production code. The mocked
# _http_post_form raises errors synchronously, but the production code still
# sleeps before the retry. Without this mock the test suite would take
# 2-3 minutes; with it, well under a second.
m.time.sleep = lambda _s: None


def _reset():
    """Restore the real _http_post_form so each test starts from a clean
    slate. (Without this, a test that forgets to install its own mock would
    silently use the previous test's mock and produce a confusing failure.)
    """
    m._http_post_form = m._http_post_form_REAL


def _run(name, fn):
    try:
        fn()
        print(f"{name:48s} {PASS}")
        return True
    except AssertionError as e:
        print(f"{name:48s} {FAIL}: {e}")
        return False
    except Exception as e:
        print(f"{name:48s} {FAIL}: unexpected {type(e).__name__}: {e}")
        return False


def _ok_response(elements=None):
    return {"version": 0.6, "generator": "Overpass API",
            "elements": elements or []}


def _mock_for(err_factory, ok_elements=None):
    """Return a mock that calls err_factory(url) for each request. If the
    factory returns an exception, raise it. Otherwise return a valid
    Overpass response. `ok_elements` defaults to a single named road
    element so most tests can assert on parsed output; tests that want to
    assert on call counts only can pass `ok_elements=[]` for an empty
    response. The mock records every call to `mock.calls`."""
    if ok_elements is None:
        ok_elements = [{"type": "way", "id": 1, "center": {"lat": 33.4, "lon": -111.8},
                        "tags": {"highway": "residential", "name": "Mock Road",
                                 "maxspeed": "25 mph"}}]
    calls = []
    def mock(url, form_data, timeout, headers=None):
        calls.append(url)
        err = err_factory(url)
        if err is not None:
            raise err
        return _ok_response(ok_elements)
    mock.calls = calls
    return mock


# ---------- T1: 504 on primary 2x -> 200 on mirror 2 ----------
def t1():
    m._http_post_form = _mock_for(
        lambda u: urllib.error.HTTPError(u, 504, "Gateway Timeout", {}, None)
        if u == m.OVERPASS_MIRRORS[0] else None)
    roads = m.query_overpass_bbox(CALL_LAT, CALL_LON, RADIUS_M, 500, verbose=False)
    assert len(roads) == 1, f"expected 1 road, got {len(roads)}"
    assert roads[0]["name"] == "Mock Road"
    calls = m._http_post_form.calls
    assert len(calls) == 3, f"expected 3 calls, got {len(calls)}"
    assert calls[0] == m.OVERPASS_MIRRORS[0]
    assert calls[1] == m.OVERPASS_MIRRORS[0]
    assert calls[2] == m.OVERPASS_MIRRORS[1]


# ---------- T2: JSONDecodeError on primary 2x -> 200 on mirror 2 ----------
def t2():
    m._http_post_form = _mock_for(
        lambda u: json.JSONDecodeError("Expecting value", "<html>nope</html>", 0)
        if u == m.OVERPASS_MIRRORS[0] else None,
        ok_elements=[])  # empty ok response so we can assert no rows came back
    m.query_overpass_bbox(CALL_LAT, CALL_LON, RADIUS_M, 500, verbose=False)
    calls = m._http_post_form.calls
    assert len(calls) == 3, f"expected 3 calls, got {len(calls)}"
    assert calls[2] == m.OVERPASS_MIRRORS[1]


# ---------- T3: all 4 mirrors 504 -> raises HTTPError ----------
def t3():
    m._http_post_form = _mock_for(
        lambda u: urllib.error.HTTPError(u, 504, "Gateway Timeout", {}, None))
    try:
        m.query_overpass_bbox(CALL_LAT, CALL_LON, RADIUS_M, 500, verbose=False)
        raise AssertionError("expected HTTPError, got success")
    except urllib.error.HTTPError as e:
        assert e.code == 504


# ---------- T4: all 4 mirrors JSONDecodeError -> raises JSONDecodeError ----------
def t4():
    m._http_post_form = _mock_for(
        lambda u: json.JSONDecodeError("Expecting value", "<html>nope</html>", 0))
    try:
        m.query_overpass_bbox(CALL_LAT, CALL_LON, RADIUS_M, 500, verbose=False)
        raise AssertionError("expected JSONDecodeError, got success")
    except json.JSONDecodeError:
        pass


# ---------- T5: 400 other-than-429 -> 1 call, raise immediately ----------
def t5():
    m._http_post_form = _mock_for(
        lambda u: urllib.error.HTTPError(u, 400, "Bad Request", {}, None))
    try:
        m.query_overpass_bbox(CALL_LAT, CALL_LON, RADIUS_M, 500, verbose=False)
        raise AssertionError("expected HTTPError, got success")
    except urllib.error.HTTPError as e:
        assert e.code == 400
        assert len(m._http_post_form.calls) == 1, \
            f"expected 1 call, got {len(m._http_post_form.calls)} (still falling through)"


# ---------- T6: primary success -> 1 call only ----------
def t6():
    m._http_post_form = _mock_for(lambda u: None)
    m.query_overpass_bbox(CALL_LAT, CALL_LON, RADIUS_M, 500, verbose=False)
    assert m._http_post_form.calls == [m.OVERPASS_MIRRORS[0]]


# ---------- T7: URLError on primary -> 200 on mirror 2 ----------
def t7():
    m._http_post_form = _mock_for(
        lambda u: urllib.error.URLError("Connection refused")
        if u == m.OVERPASS_MIRRORS[0] else None)
    m.query_overpass_bbox(CALL_LAT, CALL_LON, RADIUS_M, 500, verbose=False)
    assert len(m._http_post_form.calls) == 3


# ---------- T8: socket.timeout on primary -> 200 on mirror 2 ----------
def t8():
    m._http_post_form = _mock_for(
        lambda u: socket.timeout("timed out")
        if u == m.OVERPASS_MIRRORS[0] else None)
    m.query_overpass_bbox(CALL_LAT, CALL_LON, RADIUS_M, 500, verbose=False)
    assert len(m._http_post_form.calls) == 3, \
        f"socket.timeout should fall through; calls={m._http_post_form.calls}"


# ---------- T9: RemoteDisconnected on primary -> 200 on mirror 2 ----------
def t9():
    m._http_post_form = _mock_for(
        lambda u: http.client.RemoteDisconnected("Remote end closed connection")
        if u == m.OVERPASS_MIRRORS[0] else None)
    m.query_overpass_bbox(CALL_LAT, CALL_LON, RADIUS_M, 500, verbose=False)
    assert len(m._http_post_form.calls) == 3, \
        f"RemoteDisconnected should fall through; calls={m._http_post_form.calls}"


# ---------- T10: IncompleteRead on primary -> 200 on mirror 2 ----------
def t10():
    m._http_post_form = _mock_for(
        lambda u: http.client.IncompleteRead("partial", 1000)
        if u == m.OVERPASS_MIRRORS[0] else None)
    m.query_overpass_bbox(CALL_LAT, CALL_LON, RADIUS_M, 500, verbose=False)
    assert len(m._http_post_form.calls) == 3, \
        f"IncompleteRead should fall through; calls={m._http_post_form.calls}"


# ---------- T11: UnicodeDecodeError on primary -> 200 on mirror 2 ----------
def t11():
    m._http_post_form = _mock_for(
        lambda u: UnicodeDecodeError("utf-8", b"\xff\xfe\x00", 0, 1, "invalid start byte")
        if u == m.OVERPASS_MIRRORS[0] else None)
    m.query_overpass_bbox(CALL_LAT, CALL_LON, RADIUS_M, 500, verbose=False)
    assert len(m._http_post_form.calls) == 3, \
        f"UnicodeDecodeError should fall through; calls={m._http_post_form.calls}"


def main():
    tests = [t1, t2, t3, t4, t5, t6, t7, t8, t9, t10, t11]
    results = []
    for t in tests:
        _reset()
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
