#!/usr/bin/env python3
"""
test_continuity.py -- Regression tests for the SpeedLimit continuity guard
that mirrors SmartSpeedCompanion/Core/SpeedLimitService.swift
`finalizeWithContinuity(...)`.

Each test exercises ONE branch of the Swift guard and asserts both the
`action` label and the displayed limit so a regression in either the
Swift code OR the Python mirror gets caught.

Run:   python test_continuity.py
"""
from website.server import ContinuityGuard


PASS = "[PASS]"
FAIL = "[FAIL]"


def _candidate(limit, road_name, road_key, source="localDB"):
    """Builder for the candidate dict shape the guard expects."""
    return {
        "limit": limit,
        "source": source,
        "road_key": road_key,
        "road_name": road_name,
    }


# ---------- t1: TRANSIENT FLYOVER RESOLVE gets dampened ----------
def t1_transient_flyover_dampened():
    """Setup: user is stable on South Alma School Rd (45 mph, roadKey="07 ALMA").
    Inject ONE aggressive candidate (75 mph on US-60, different roadKey +
    different roadName). User's GPS speed = 45 mph (parked under the
    flyover). Expectation: guard HOLDS 45, does NOT commit 75. This is the
    exact bug the user reported -- the flyover flicker.
    """
    g = ContinuityGuard()
    pre = g.step(_candidate(45, "South Alma School Road", "07ALMARD"),
                 user_speed_mph=45)
    assert pre["action"] == "commit_first" and pre["display"] == 45, (
        f"t1 preamble failed: expected commit_first display=45, got {pre!r}"
    )

    actual = g.step(_candidate(75, "US-60", "US60WB"),
                    user_speed_mph=45)
    assert actual["action"] == "hold" and actual["display"] == 45, (
        f"t1 FAILED: expected hold/45 for flyover flicker; got {actual!r}. "
        "The flyover-resolve flicker must NOT leak to the HUD."
    )


# ---------- t2: PHYSICS OVERRIDE commits immediately ----------
def t2_physics_override_commits_immediately():
    """Real highway on-ramp transition: user accelerates from 45 mph to 70 mph
    moving onto a 75 mph on-ramp. The 75 mph answer is the only one matching
    physics; even though the road identity flipped, Rule 2 must commit it
    on the FIRST fetch.
    """
    g = ContinuityGuard()
    pre = g.step(_candidate(45, "South Alma School Road", "07ALMARD"),
                 user_speed_mph=45)
    assert pre["action"] == "commit_first"

    actual = g.step(_candidate(75, "US-60", "US60EB"),
                    user_speed_mph=72)
    assert actual["action"] == "commit_physics" and actual["display"] == 75, (
        f"t2 FAILED: expected commit_physics with display=75; got {actual!r}. "
        "Physics override must commit on first fetch when driver is at new speed."
    )


# ---------- t3: SINK-IN commits after 5 suspect fetches ----------
def t3_sink_in_after_5_consecutive_suspects():
    """User truly exits onto a freeway: geocode is dragging (won't catch up),
    user's GPS speed still at 45 mph (climbing slowly). The first FOUR
    suspect fetches hold 45 (Rule 3); the FIFTH commits 75 (sink-in).
    """
    g = ContinuityGuard()
    pre = g.step(_candidate(45, "South Alma School Road", "07ALMARD"),
                 user_speed_mph=45)
    assert pre["action"] == "commit_first"

    candidate = _candidate(75, "US-60", "US60EB")
    expected_seq = ["hold"] * 4 + ["commit_sinkin"]
    expected_display = [45] * 4 + [75]
    for i, (e_action, e_disp) in enumerate(zip(expected_seq, expected_display)):
        actual = g.step(candidate, user_speed_mph=45)
        assert actual["action"] == e_action and actual["display"] == e_disp, (
            f"t3 FAILED at fetch #{i + 2}: expected action={e_action!r} "
            f"display={e_disp}; got {actual!r}"
        )


# ---------- t4: SAME-ROAD commutative update commits ----------
def t4_same_road_commutative_commit():
    """User cruising on South Alma School Road stays at 45 mph. Re-fetch
    with same roadName + same roadKey returns 45 mph. Rule 1 commits
    immediately even though we just had a "previous" state. No flicker.
    """
    g = ContinuityGuard()
    pre = g.step(_candidate(45, "South Alma School Road", "07ALMARD"),
                 user_speed_mph=44)
    assert pre["action"] == "commit_first"

    actual = g.step(_candidate(45, "South Alma School Road", "07ALMARD"),
                    user_speed_mph=46)
    assert actual["action"] == "commit" and actual["display"] == 45, (
        f"t4 FAILED: expected commit/45 for same-road re-fetch; got {actual!r}."
    )


# ---------- t5: LEGITIMATE ARTERIAL->HIGHWAY transition commits via physics ----------
def t5_legit_road_change_commits():
    """Real transition: 45 mph surface street -> 70 mph highway. The 25 mph
    delta EXCEEDS SUSPICIOUS_JUMP_MPH(20) so Rule 1 deliberately doesn't
    fire -- Rule 2 must gate the commit until GPS catches up.

    Step 2 -- user at 58 mph, candidate 70 mph: |70-58|=12 > 10, so Rule 2's
    first clause (physics tolerance) fails; falls to Rule 3 suspect hold.
    This is the realistic case the user described: the geocode resolves the
    new road first, but the driver hasn't accelerated enough yet for the
    physics sanity check to override the hold.
    """
    g = ContinuityGuard()
    pre = g.step(_candidate(45, "South Alma School Road", "07ALMARD"),
                 user_speed_mph=45)
    assert pre["action"] == "commit_first"

    # First suspect fetch: |70-45|=25 > 20 so Rule 1 holds off. Now Rule 2
    # tries: |70-58|=12 > 10 fails the physics-tolerance clause, so Rule 3
    # suspect hold takes over.
    first = g.step(_candidate(70, "State Route 87", "SR087NB"),
                   user_speed_mph=58)
    assert first["action"] == "hold" and first["display"] == 45, (
        f"t5 first fetch: expected hold/45 (Rule 3, because |70-58|=12 > 10 "
        f"failed Rule 2's physics-tolerance clause); got {first!r}"
    )

    # Second suspect fetch -- driver has merged, GPS at 68 mph. Delta still
    # exceeds SUSPICIOUS_JUMP_MPH. Rule 2 fires: |70-68|=2 <= 10 AND
    # |45-68|=23 > 15 -- commit_physics, the on-ramp scenario.
    second = g.step(_candidate(70, "State Route 87", "SR087NB"),
                    user_speed_mph=68)
    assert second["action"] == "commit_physics" and second["display"] == 70, (
        f"t5 FAILED: expected commit_physics/70 on second fetch once GPS "
        f"agrees with new road; got {second!r}"
    )


# ---------- runner ----------
def main():
    tests = [t1_transient_flyover_dampened,
             t2_physics_override_commits_immediately,
             t3_sink_in_after_5_consecutive_suspects,
             t4_same_road_commutative_commit,
             t5_legit_road_change_commits]
    passed = 0
    failed = 0
    for t in tests:
        try:
            t()
            print(f"{PASS} {t.__name__}")
        except AssertionError as exc:
            print(f"{FAIL} {t.__name__}: {exc}")
            failed += 1
        except Exception as exc:
            print(f"{FAIL} {t.__name__}: {type(exc).__name__}: {exc}")
            failed += 1
    if failed == 0:
        print(f"\nAll {len(tests)} tests passed.")
    else:
        print(f"\n{passed} passed, {failed} failed.")


if __name__ == "__main__":
    main()
