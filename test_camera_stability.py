#!/usr/bin/env python3
"""
test_camera_stability.py -- Numerical regression harness for Camera System v2
("steady-cam"), mirroring SmartSpeedCompanion/Core/CameraSystem.swift on Windows
(the same pattern test_continuity.py uses for SpeedLimitService).

The port is line-faithful to the Swift implementation: same tables, same
governor state machine, same envelope/release maths, same kinematics. A
simulated drive (GPS noise included) is pushed through the pipeline and the
anti-jitter guarantees are asserted numerically:

  S1  Boundary-noise immunity   -- ±3 mph GPS noise at a level edge must not
                                   move the camera target at all.
  S2  Navigation leg            -- highway -> city -> approach -> PASS TURN:
                                   bounded per-frame steps everywhere; after
                                   passing the turn the framing HOLDS then
                                   releases gradually (no whiplash).
  S3  Red light mid-route       -- navigation framing must not park/flatten.
  S4  Stop-and-go free drive    -- no pitch/altitude oscillation around the
                                   stationary threshold.
  S5  Highway -> city exit       -- multi-band drop converges fast but bounded,
                                   and never overshoots the target.

Run:   python test_camera_stability.py
"""
import math

PASS = "[PASS]"
FAIL = "[FAIL]"

# ── Faithful port of CameraTuning.fallback ────────────────────────────────
LEVELS = [
    # (maxSpeedMph, holdSpeedMph, altitude, pitch)
    (3,   0,  320,  0),
    (15,  11, 420,  16),
    (25,  19, 560,  26),
    (35,  27, 780,  34),
    (45,  35, 1100, 42),
    (55,  43, 1550, 48),
    (65,  51, 2100, 53),
    (999, 56, 2800, 57),
]
MANEUVER = {"start": 700.0, "full": 90.0, "min_mult": 0.5}
FLATTEN = {"trigger": 180.0, "full": 40.0, "max_deg": 14.0}
DEST = {"start": 500.0, "min_mult": 0.5, "max_pitch_red": 18.0}
TIMING = {
    "dwell": 2.5, "tighten_tau": 0.6, "release_tau": 1.8,
    "alt_cap": 900.0, "pitch_cap": 25.0,
    "post_hold": 1.2, "post_release": 2.5, "speed_tau": 1.8,
}


def smoothstep(x: float) -> float:
    t = min(max(x, 0.0), 1.0)
    return t * t * (3.0 - 2.0 * t)


def quantize(speed: float) -> int:
    for i, row in enumerate(LEVELS):
        if speed <= row[0]:
            return i
    return len(LEVELS) - 1


def anchor(i: int) -> float:
    if i >= len(LEVELS) - 1:
        return LEVELS[-1][0] + 10.0
    return LEVELS[i][0] * 0.98


# ── CruiseGovernor (Swift: struct CruiseGovernor) ─────────────────────────
class Governor:
    def __init__(self, initial_speed: float = 0.0):
        self.cur = quantize(initial_speed)
        self.cand = None
        self.since = None

    def update(self, speed: float, now: float, allow_park: bool) -> int:
        desired = quantize(speed)
        if not allow_park:
            # Navigation down-shift lock: only up-shifts permitted.
            desired = max(desired, max(self.cur, 1))
        elif desired < self.cur and speed >= LEVELS[self.cur][1]:
            # Free-drive hysteresis band.
            desired = self.cur
        if desired == self.cur:
            self.cand = None
            self.since = None
            return self.cur

        new_dir_up = desired > self.cur
        if self.cand != desired:
            restarting = self.since is None
            if self.cand is not None:
                restarting = restarting or ((self.cand > self.cur) != new_dir_up)
            self.cand = desired
            if restarting:
                self.since = now
            # Same-direction advancement keeps the running dwell clock.

        committed = self.cand
        jump = abs(committed - self.cur)
        eff = TIMING["dwell"] / min(jump, 3)
        if self.since is None or now - self.since < eff:
            return self.cur
        self.cur = committed
        self.cand = None
        self.since = None
        return committed


# ── Envelopes (Swift: enum CameraMath) ────────────────────────────────────
def maneuver_envelope(d: float) -> float:
    if d >= MANEUVER["start"]:
        return 1.0
    if d <= MANEUVER["full"]:
        return MANEUVER["min_mult"]
    x = (MANEUVER["start"] - d) / (MANEUVER["start"] - MANEUVER["full"])
    return 1.0 - (1.0 - MANEUVER["min_mult"]) * smoothstep(x)


def flatten_reduction(d: float) -> float:
    if d >= FLATTEN["trigger"]:
        return 0.0
    if d <= FLATTEN["full"]:
        return FLATTEN["max_deg"]
    x = (FLATTEN["trigger"] - d) / (FLATTEN["trigger"] - FLATTEN["full"])
    return FLATTEN["max_deg"] * smoothstep(x)


def dest_modifier(d: float):
    if d >= DEST["start"]:
        return (1.0, 0.0)
    x = smoothstep(d / DEST["start"])
    return (DEST["min_mult"] + (1.0 - DEST["min_mult"]) * x,
            DEST["max_pitch_red"] * (1.0 - x))


# ── Decision engine (Swift: CameraDecisionEngine.computeTarget) ───────────
def compute_target(speed, navigating, dtt, dest_dist, mult_override=None,
                   pitch_mode="auto"):
    if pitch_mode == "forced2D":
        alt = _resolved_altitude(speed, navigating, dtt, dest_dist, mult_override)
        return {"alt": alt, "pitch": 0.0}

    idx = quantize(speed)
    alt = float(LEVELS[idx][2])
    pitch = float(LEVELS[idx][3])

    if navigating:
        envelope = mult_override if mult_override is not None else maneuver_envelope(dtt)
        alt *= envelope
        pitch -= flatten_reduction(dtt)
        dm, dp = dest_modifier(dest_dist)
        alt *= dm
        pitch -= dp

    alt = min(max(alt, 250.0), 4200.0)
    pitch = min(max(pitch, 0.0), 60.0)

    if pitch_mode == "auto" and speed < 5.0:
        pitch *= smoothstep(speed / 5.0)

    if pitch_mode == "forced2D":
        pitch = 0.0
    elif pitch_mode == "forced3D":
        pitch = 45.0
    return {"alt": alt, "pitch": pitch}


def _resolved_altitude(speed, navigating, dtt, dest_dist, mult_override):
    idx = quantize(speed)
    alt = float(LEVELS[idx][2])
    if navigating:
        envelope = mult_override if mult_override is not None else maneuver_envelope(dtt)
        alt *= envelope
        dm, _ = dest_modifier(dest_dist)
        alt *= dm
    return min(max(alt, 250.0), 4200.0)


# ── CameraStabilizer (Swift: final class CameraStabilizer) ────────────────
class Stabilizer:
    def __init__(self):
        self.gov = Governor()
        self.smoothed = 0.0
        self.primed = False
        self.last_instr = ""
        self.last_dtt = 0.0
        self.release_start = None
        self.held = 1.0
        self.level = 0
        self.target = {"alt": 320.0, "pitch": 0.0}

    def prime(self, speed, dtt, instr):
        self.smoothed = speed
        self.primed = True
        idx = quantize(speed)
        self.level = idx
        self.gov.cur = idx
        self.gov.cand = None
        self.gov.since = None
        self.last_instr = instr
        self.last_dtt = dtt

    def _release_bookkeeping(self, ctx, now):
        if not ctx["navigating"]:
            self.release_start = None
            self.last_instr = ctx["instr"]
            self.last_dtt = ctx["dtt"]
            return
        changed = ctx["instr"] != self.last_instr
        just_passed = changed and self.last_instr != "" and 0 < self.last_dtt < 120
        if just_passed and self.release_start is None:
            self.held = maneuver_envelope(self.last_dtt)
            self.release_start = now
        if (self.release_start is not None
                and ctx["dtt"] <= MANEUVER["full"] * 2):
            self.release_start = None
        self.last_instr = ctx["instr"]
        self.last_dtt = ctx["dtt"]

    def _effective_mult(self, computed, now):
        if self.release_start is None:
            return computed
        elapsed = now - self.release_start
        if elapsed < TIMING["post_hold"]:
            return self.held
        if elapsed < TIMING["post_hold"] + TIMING["post_release"]:
            x = smoothstep((elapsed - TIMING["post_hold"]) / TIMING["post_release"])
            return self.held + (computed - self.held) * x
        self.release_start = None
        return computed

    def ingest(self, ctx, now):
        if not self.primed:
            self.smoothed = ctx["speed"]
            self.primed = True
        else:
            alpha = 1.0 - math.exp(-0.5 / TIMING["speed_tau"])
            self.smoothed += alpha * (ctx["speed"] - self.smoothed)

        self._release_bookkeeping(ctx, now)
        self.level = self.gov.update(self.smoothed, now, not ctx["navigating"])

        computed = maneuver_envelope(ctx["dtt"]) if ctx["navigating"] else 1.0
        effective = self._effective_mult(computed, now)
        self.target = compute_target(
            anchor(self.level), ctx["navigating"], ctx["dtt"], ctx["dest"],
            mult_override=effective, pitch_mode="auto",
        )


# ── Kinematics (Swift: enum CameraKinematics.approach) ────────────────────
def approach(current, target, dt, rate_cap, snap_eps):
    tau = TIMING["tighten_tau"] if target < current else TIMING["release_tau"]
    alpha = 1.0 - math.exp(-dt / tau)
    nxt = current + alpha * (target - current)
    max_step = rate_cap * dt
    delta = nxt - current
    if abs(delta) > max_step:
        nxt = current + (max_step if delta > 0 else -max_step)
    if abs(target - nxt) < snap_eps:
        nxt = target
    return nxt


# ════════════════════════════════════════════════════════════════════════════
# Simulated drive runner: app ticks every 0.5 s (ingest), display link runs at
# 30 fps between ticks (integrate). Returns full telemetry.
# ════════════════════════════════════════════════════════════════════════════
FRAME_DT = 1.0 / 30.0


def run_drive(tick_contexts, tick_period=0.5, prime_speed=None):
    """tick_contexts: list of (time, context-dict). Returns telemetry lists.
    prime_speed seeds the stabilizer like restoreCamera does (defaults to the
    first context's own speed)."""
    stab = Stabilizer()
    disp_alt, disp_pitch = 320.0, 0.0
    frames = []          # (time, disp_alt, disp_pitch, target_alt)
    targets = []         # (time, target_alt, target_pitch)

    seed = prime_speed if prime_speed is not None else tick_contexts[0][1]["speed"]
    stab.prime(seed, tick_contexts[0][1]["dtt"], tick_contexts[0][1]["instr"])

    for t, ctx in tick_contexts:
        stab.ingest(ctx, t)
        targets.append((t, stab.target["alt"], stab.target["pitch"]))
        # integrate frames until the next tick (or end)
        n_frames = int(round(tick_period / FRAME_DT))
        end = t + tick_period
        for k in range(n_frames):
            ft = t + k * FRAME_DT
            disp_alt = approach(disp_alt, stab.target["alt"], FRAME_DT,
                                TIMING["alt_cap"], 0.25)
            disp_pitch = approach(disp_pitch, stab.target["pitch"], FRAME_DT,
                                  TIMING["pitch_cap"], 0.02)
            frames.append((ft, disp_alt, disp_pitch))
        del end
    return frames, targets, stab


def max_frame_step(frames, lo, hi):
    steps = []
    prev = None
    for t, a, p in frames:
        if lo <= t <= hi and prev is not None:
            steps.append(abs(a - prev))
        if lo <= t <= hi:
            prev = a
    return max(steps) if steps else 0.0


def direction_reversals(frames, lo, hi, deadzone=0.05):
    """Count sign changes in d(altitude)/dt above deadzone."""
    signs = []
    prev_a = None
    for t, a, _p in frames:
        if t < lo or t > hi:
            continue
        if prev_a is not None:
            d = a - prev_a
            if abs(d) > deadzone:
                signs.append(1 if d > 0 else -1)
        prev_a = a
    reversals = sum(1 for i in range(1, len(signs)) if signs[i] != signs[i - 1])
    return reversals


# ── S1: boundary-noise immunity ───────────────────────────────────────────
def s1_boundary_noise():
    """True speed 54 mph, ±3 mph alternating every 0.4 s across the 55 edge.
    The governed target must NEVER leave the level-5 altitude."""
    ctxs = []
    t = 0.0
    for step in range(150):                      # 60 s
        noisy = 54.0 + (3.0 if step % 2 == 0 else -3.0)
        ctxs.append((t, {"speed": noisy, "dtt": 5000.0, "instr": "Continue straight",
                         "dest": 50000.0, "navigating": True}))
        t += 0.4
    frames, targets, stab = run_drive(ctxs, tick_period=0.4, prime_speed=54.0)

    tgt_alts = {round(a, 6) for _, a, _p in targets}
    ok_unique = len(tgt_alts) == 1
    ok_level = stab.level == 5
    cruise_alt = float(LEVELS[5][2])
    ok_value = abs(next(iter(tgt_alts)) - cruise_alt) < 1e-6
    revs = direction_reversals(frames, 10, 60)

    passed = ok_unique and ok_level and ok_value and revs == 0
    print(f"{'S1':4} boundary-noise immunity: unique_targets={len(tgt_alts)} "
          f"level={stab.level} target_alt={next(iter(tgt_alts)):.0f} "
          f"cruise_reversals={revs} -> {'OK' if passed else 'JITTER!'}")
    return passed


# ── S2: full navigation leg with a turn pass ──────────────────────────────
def s2_navigation_leg():
    """Highway 65 mph -> decelerate to 30 -> approach turn (DTT->0) -> instruction
    advances, DTT jumps to 1800. Assert: bounded steps, post-pass HOLD then
    gradual release, no instant zoom-out."""
    ctxs = []
    t = 0.0

    # Phase 1: 0–20 s highway at 65 mph, DTT far.
    while t < 20:
        ctxs.append((t, {"speed": 65, "dtt": 20000.0, "instr": "Continue on I-10 W",
                         "dest": 80000.0, "navigating": True}))
        t += 0.5
    # Phase 2: 20–50 s decelerate 65->28 mph linearly; DTT shrinks from 4000->700.
    while t < 50:
        frac = (t - 20) / 30.0
        spd = 65 - 37 * frac
        dtt = 4000 - 3300 * frac
        ctxs.append((t, {"speed": spd, "dtt": dtt, "instr": "Turn left onto Main St",
                         "dest": 30000.0, "navigating": True}))
        t += 0.5
    # Phase 3: 50–70 s approach: DTT 700->30, speed 28.
    while t < 70:
        frac = (t - 50) / 20.0
        dtt = 700 - 670 * frac
        ctxs.append((t, {"speed": 28, "dtt": dtt, "instr": "Turn left onto Main St",
                         "dest": 12000.0, "navigating": True}))
        t += 0.5
    t_pass = t                                    # ≈70 s: instruction advances
    # Phase 4: pass the turn — DTT jumps to 1800, speed builds 28->38.
    while t < t_pass + 12:
        frac = (t - t_pass) / 12.0
        ctxs.append((t, {"speed": 28 + 10 * frac, "dtt": 1800.0,
                         "instr": "Continue onto Oak Ave", "dest": 11500.0,
                         "navigating": True}))
        t += 0.5

    frames, targets, stab = run_drive(ctxs)

    # a) Every single-frame altitude step within the global rate cap.
    worst = max_frame_step(frames, 0, t)
    cap_step = TIMING["alt_cap"] * FRAME_DT
    ok_cap = worst <= cap_step + 1e-6

    # b) Immediately after passing: target HELD tight for ≥ post_hold seconds.
    held_window = [a for (tt, a, _p) in targets if t_pass <= tt <= t_pass + 1.0]
    pre_pass = next(a for (tt, a, _p) in targets if tt < t_pass - 0.01)
    ok_hold = all(a <= pre_pass * 1.02 for a in held_window)

    # c) Zoom-out is gradual: time to travel halfway back up ≥ ~1.5 s.
    cruise_after = LEVELS[4][2]                   # governed level for ~35 mph
    start_alt = pre_pass
    half_target = (start_alt + cruise_after) / 2.0
    half_time = None
    for (tt, a, _p) in targets:
        if tt > t_pass + 0.5 and a >= half_target:
            half_time = tt - t_pass
            break
    ok_gradual = half_time is None or half_time >= 1.4

    # d) No oscillation during the release: ≤ 2 direction reversals.
    revs = direction_reversals(frames, t_pass, t_pass + 12)
    ok_no_osc = revs <= 2

    passed = ok_cap and ok_hold and ok_gradual and ok_no_osc
    print(f"{'S2':4} navigation leg: max_step={worst:.1f}m (cap {cap_step:.1f}) "
          f"hold_ok={ok_hold} half_release_t={half_time} "
          f"release_reversals={revs} -> {'OK' if passed else 'WHIPLASH!'}")
    return passed


# ── S3: red light mid-navigation ──────────────────────────────────────────
def s3_red_light():
    """Cruising at 32 mph, stopped 20 s at a light, resumes. Navigation framing
    must never collapse toward parked altitude/pitch."""
    ctxs = []
    t = 0.0
    while t < 30:
        ctxs.append((t, {"speed": 32, "dtt": 2500.0, "instr": "Continue straight",
                         "dest": 20000.0, "navigating": True}))
        t += 0.5
    while t < 50:
        ctxs.append((t, {"speed": 0, "dtt": 2200.0, "instr": "Continue straight",
                         "dest": 19500.0, "navigating": True}))
        t += 0.5
    while t < 70:
        ctxs.append((t, {"speed": 32, "dtt": 2000.0, "instr": "Continue straight",
                         "dest": 19000.0, "navigating": True}))
        t += 0.5
    frames, targets, stab = run_drive(ctxs)

    light_alts = [a for (tt, a, p) in frames if 35 <= tt <= 45]
    light_pitches = [p for (tt, a, p) in frames if 35 <= tt <= 45]
    ok_alt = min(light_alts) >= LEVELS[3][2] * 0.9      # stayed near city level
    ok_pitch = min(light_pitches) >= LEVELS[3][3] - 8   # kept meaningful tilt
    ok_level = stab.level >= 1

    passed = ok_alt and ok_pitch and ok_level
    print(f"{'S3':4} red light: min_alt={min(light_alts):.0f}m "
          f"min_pitch={min(light_pitches):.1f}° level={stab.level} "
          f"-> {'OK' if passed else 'COLLAPSED'}")
    return passed


# ── S4: stop-and-go free drive around thresholds ──────────────────────────
def s4_stop_and_go_free_drive():
    """Free-drive crawling with noisy speed around the 5 mph stationary fade.
    Pitch flips must be rare and small once settled."""
    import random
    random.seed(7)
    ctxs = []
    t = 0.0
    while t < 90:
        base = 4.0 + 3.0 * math.sin(t / 9.0)          # 1–7 mph crawl pattern
        noisy = max(0.0, base + random.uniform(-1.2, 1.2))
        ctxs.append((t, {"speed": noisy, "dtt": 0.0, "instr": "",
                         "dest": 0.0, "navigating": False}))
        t += 0.5
    frames, targets, stab = run_drive(ctxs)

    pitches = [(tt, p) for (tt, _a, p) in frames]
    settled = [(tt, p) for tt, p in pitches if tt > 20]
    pitch_flips = 0
    prev_sign = 0
    prev_p = None
    for tt, p in settled:
        if prev_p is not None:
            d = p - prev_p
            if abs(d) > 0.5:
                sign = 1 if d > 0 else -1
                if prev_sign == -sign:
                    pitch_flips += 1
                prev_sign = sign
        prev_p = p
    span = max(p for _t, p in settled) - min(p for _t, p in settled)
    ok_span = span <= 22.0                            # one band's worth max
    ok_flips = pitch_flips <= 8

    passed = ok_span and ok_flips
    print(f"{'S4':4} stop-and-go free drive: pitch_span={span:.1f}° "
          f"flips={pitch_flips} level={stab.level} -> {'OK' if passed else 'OSCILLATING'}")
    return passed


# ── S5: highway -> city exit drop ──────────────────────────────────────────
def s5_highway_exit():
    """70 mph -> 22 mph over 4 s (steep off-ramp). Converges quickly, stays
    inside the rate cap, and never overshoots below the target."""
    ctxs = []
    t = 0.0
    while t < 20:
        ctxs.append((t, {"speed": 70, "dtt": 9000.0, "instr": "Continue on US-60",
                         "dest": 60000.0, "navigating": False}))
        t += 0.5
    exit_start = t
    while t < exit_start + 8:
        spd = 70 if t < exit_start + 2 else 22
        ctxs.append((t, {"speed": spd, "dtt": 6000.0, "instr": "",
                         "dest": 0.0, "navigating": False}))
        t += 0.5
    while t < exit_start + 30:
        ctxs.append((t, {"speed": 22, "dtt": 6000.0, "instr": "",
                         "dest": 0.0, "navigating": False}))
        t += 0.5
    frames, targets, stab = run_drive(ctxs)

    alts = [a for (_t, a, _p) in frames]
    target_final = stab.target["alt"]
    converged_by = None
    for (ft, a, _p) in frames:
        if ft > exit_start + 4 and abs(a - target_final) < 5.0:
            converged_by = ft - exit_start
            break
    ok_converge = converged_by is not None and converged_by <= 12.0

    worst = max_frame_step(frames, exit_start, exit_start + 10)
    cap_step = TIMING["alt_cap"] * FRAME_DT
    ok_cap = worst <= cap_step + 1e-6

    # No overshoot past the target (undershoot means it went tighter than L2).
    min_alt = min(a for (ft, a, _p) in frames if ft > exit_start + 4)
    ok_no_overshoot = min_alt >= target_final - 1.0

    passed = ok_converge and ok_cap and ok_no_overshoot
    print(f"{'S5':4} highway exit: converged_by={converged_by}s "
          f"max_step={worst:.1f}m min_alt={min_alt:.0f} target={target_final:.0f} "
          f"-> {'OK' if passed else 'BAD DROP'}")
    return passed


if __name__ == "__main__":
    results = [
        s1_boundary_noise(),
        s2_navigation_leg(),
        s3_red_light(),
        s4_stop_and_go_free_drive(),
        s5_highway_exit(),
    ]
    total, good = len(results), sum(results)
    print(f"\n{good}/{total} scenarios passed")
    raise SystemExit(0 if good == total else 1)
