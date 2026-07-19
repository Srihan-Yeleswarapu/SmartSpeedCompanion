#!/usr/bin/env bash
# ----------------------------------------------------------------------
# Deploy: tap-to-refetch speed limit sign (TestFlight 2.2.x feature).
# Steps:
#   1. Pre-flight whitespace / brace balance on the 3 changed Swift files.
#   2. Confirm the new symbols are wired correctly (counts == 1 each).
#   3. Confirm the SmartSpeedLimitService.forceRefresh path is still intact.
#   4. git add + commit + push origin version2.
#   5. Find the GH Action run for the new HEAD SHA and poll for completion.
# ----------------------------------------------------------------------
set -uo pipefail

CHANGED_FILES=(
  "SmartSpeedCompanion/Core/SpeedLimitService.swift"
  "SmartSpeedCompanion/ViewModels/DriveViewModel.swift"
  "SmartSpeedCompanion/Views/Drive/MapWithHUDView.swift"
)
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT" || { echo "[FATAL] cd $ROOT failed"; exit 1; }

declare -i FAIL=0
log_step() { printf '\n=========================== %s ===========================\n' "$1"; }
ok()       { printf '  [OK] %s\n' "$1"; }
warn()     { printf '  [WARN] %s\n' "$1"; }
fail()     { printf '  [FAIL] %s\n' "$1"; FAIL+=1; }

# ---- Step 1: brace balance -----------------------------------------
log_step "Step 1: brace / paren balance"
for f in "${CHANGED_FILES[@]}"; do
  o=$(grep -o '{' "$f" | wc -l | tr -d ' ')
  c=$(grep -o '}' "$f" | wc -l | tr -d ' ')
  po=$(grep -o '(' "$f" | wc -l | tr -d ' ')
  pc=$(grep -o ')' "$f" | wc -l | tr -d ' ')
  if [ "$o" -eq "$c" ]; then
    ok "$f: braces balanced ($o/$c)"
  else
    fail "$f: BRACES UNBALANCED ($o open vs $c close)"
  fi
  if [ "$po" -eq "$pc" ]; then
    ok "$f: parens balanced ($po/$pc)"
  else
    fail "$f: PARENS UNBALANCED ($po open vs $pc close)"
  fi
done

# ---- Step 2: new symbols present -----------------------------------
log_step "Step 2: new symbols present"
# DriveViewModel
DV="SmartSpeedCompanion/ViewModels/DriveViewModel.swift"
grep -q 'isRefreshingSpeedLimit' "$DV"            && ok "$DV: isRefreshingSpeedLimit @Published present"   || fail "$DV: missing isRefreshingSpeedLimit"
grep -q 'lastManualRefetchAt' "$DV"               && ok "$DV: lastManualRefetchAt throttle present"      || fail "$DV: missing lastManualRefetchAt"
grep -q 'manualRefetchThrottle' "$DV"             && ok "$DV: manualRefetchThrottle constant present"   || fail "$DV: missing manualRefetchThrottle"
grep -q 'public func manualRefetchSpeedLimit' "$DV"  && ok "$DV: manualRefetchSpeedLimit() present"      || fail "$DV: missing manualRefetchSpeedLimit()"
# MapWithHUDView
MV="SmartSpeedCompanion/Views/Drive/MapWithHUDView.swift"
grep -q 'fileprivate struct LimitSignView' "$MV"  && ok "$MV: LimitSignView preserved"                  || fail "$MV: LimitSignView missing"
grep -q 'let onTap: () -> Void' "$MV"             && ok "$MV: onTap: () -> Void parameter wired"        || fail "$MV: missing onTap param"
grep -q 'let isRefreshing: Bool' "$MV"            && ok "$MV: isRefreshing: Bool parameter wired"       || fail "$MV: missing isRefreshing param"
grep -q 'Button(action: onTap)' "$MV"             && ok "$MV: Button wrapper applied to LimitSignView"  || fail "$MV: Button wrapper missing"
grep -q '.buttonStyle(.plain)' "$MV"              && ok "$MV: .buttonStyle(.plain) applied"            || fail "$MV: .buttonStyle(.plain) missing"
grep -q 'isRefreshing ? 1.06 : 1.0' "$MV"         && ok "$MV: scaleEffect pulse wired"                 || fail "$MV: scaleEffect missing"
grep -q 'driveViewModel.isRefreshingSpeedLimit' "$MV" && ok "$MV: caller passes isRefreshingSpeedLimit" || fail "$MV: caller does not pass isRefreshing"
grep -q 'driveViewModel.manualRefetchSpeedLimit' "$MV" && ok "$MV: caller fires manualRefetchSpeedLimit" || fail "$MV: caller does not fire manualRefetchSpeedLimit"

# ---- Step 3: SpeedLimitService forceRefresh path still intact ------
log_step "Step 3: SmartSpeedLimitService.forceRefresh path is intact"
SLS="SmartSpeedCompanion/Core/SpeedLimitService.swift"
grep -q 'forceRefresh: Bool = false' "$SLS"       && ok "$SLS: forceRefresh param on updateSpeedLimit" || fail "$SLS: forceRefresh param missing on updateSpeedLimit"
grep -q 'if !forceRefresh' "$SLS"                 && ok "$SLS: cache short-circuit gates on forceRefresh" || fail "$SLS: forceRefresh gate missing in resolveCandidate"
# Confirm the call site that bypasses cache.
grep -q 'forceRefresh: true' "$DV"                && ok "$DV: manualRefetchSpeedLimit calls with forceRefresh: true" || fail "$DV: forceRefresh: true call site missing"
# Confirm no orphan reference to old struct fields (none we removed, so this is a sanity check).
for sym in 'isRefreshingSpeedLimit' 'lastManualRefetchAt' 'manualRefetchSpeedLimit'; do
  cnt=$(grep -rn "$sym" SmartSpeedCompanion/ | grep -v '\.buildlogs/' | wc -l | tr -d ' ')
  if [ "$cnt" -ge 2 ]; then
    ok "Symbol cross-references present for '$sym' (count=$cnt)"
  else
    warn "Symbol '$sym' appears only $cnt times (declaration + at least one use expected)"
  fi
done
# SpeedEngine still drives the same shared service.
grep -q 'private let speedLimitService = SmartSpeedLimitService.shared' SmartSpeedCompanion/Core/SpeedEngine.swift \
  && ok "SpeedEngine still wraps SmartSpeedLimitService.shared (no API drift)" \
  || warn "SpeedEngine wrapper shape changed unexpectedly -- inspect"

if [ "$FAIL" -gt 0 ]; then
  echo
  echo "[FATAL] Pre-commit verification failed ($FAIL issue(s)). Aborting deploy."
  exit 1
fi
ok "All pre-commit verifications passed."

# ---- Step 4: commit + push ---------------------------------------
log_step "Step 4: git commit + push"
git add "${CHANGED_FILES[@]}" || { echo "[FATAL] git add failed"; exit 1; }
MSG="feat(hud): tap-to-refetch speed limit sign (TestFlight 2.2.x)

User taps the speed-limit sign on the map HUD -> bypasses the
SpeedLimitResponseCache and re-runs the provider chain + SQLite
fallback so a wrong displayed limit self-heals in <1 s without
waiting for the next GPS-driven tick.

Changes:
- SmartSpeedLimitService.updateSpeedLimit(...) gains forceRefresh: Bool
  (forwarded into resolveCandidate(at:heading:roadName:forceRefresh:))
  which short-circuits the cache lookup when true.
- DriveViewModel: new @Published isRefreshingSpeedLimit (UI feedback),
  600 ms throttle (lastManualRefetchAt) so a frustrated double-tap
  does not double-bill the network, and public async
  manualRefetchSpeedLimit() which bails on no-GPS-fix.
- LimitSignView (MapWithHUDView): wraps the existing red-ring sign in
  a Button + .buttonStyle(.plain); brief 1.06 scale pulse while
  isRefreshing is true so the user sees their tap registered.
- Caller (MapWithHUDView) passes onTap: { Task { await ... } } and
  drives a 0.25 s ease-out scale animation through SwiftUI."
git commit -m "$MSG" || { echo "[FATAL] git commit failed"; exit 1; }
COMMIT_SHA=$(git rev-parse --short HEAD)
ok "Committed as $COMMIT_SHA"

git push origin version2 || { echo "[FATAL] git push failed"; exit 1; }
ok "Pushed to origin/version2"

# ---- Step 5: GH Action watch --------------------------------------
log_step "Step 5: GitHub Actions watch"
RUN_ID=""
for i in $(seq 1 15); do
  RUN_JSON=$(curl -sS -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/Srihan-Yeleswarapu/SmartSpeedCompanion/actions/runs?per_page=5" 2>/dev/null || true)
  if [ -z "$RUN_JSON" ]; then
    # CLI fallback
    if command -v gh >/dev/null 2>&1; then
      RUN_ID=$(gh run list --workflow=distribute.yml --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || true)
    fi
    break
  fi
  RUN_ID=$(printf '%s' "$RUN_JSON" | python -c "
import sys, json
try:
    d=json.load(sys.stdin)
    rs=d.get('workflow_runs',[])
    head='$COMMIT_SHA'
    for r in rs:
        if r.get('head_sha','').startswith(head):
            print(r['id']); sys.exit(0)
    if rs: print(rs[0]['id']); sys.exit(0)
except Exception:
    pass
print('')" 2>/dev/null || true)
  if [ -n "$RUN_ID" ]; then break; fi
  sleep 4
done

if [ -z "$RUN_ID" ]; then
  warn "Could not find GH Action run id (token-less). Watch at: https://github.com/Srihan-Yeleswarapu/SmartSpeedCompanion/actions"
else
  ok "GH Action run id: $RUN_ID -- watching..."
  STATUS=""
  CONCL=""
  for i in $(seq 1 60); do
    META=$(curl -sS -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/Srihan-Yeleswarapu/SmartSpeedCompanion/actions/runs/$RUN_ID" 2>/dev/null || true)
    STATUS=$(printf '%s' "$META" | python -c "
import sys, json
try:
    d=json.load(sys.stdin)
    print(d.get('status',''))
except Exception: print('')" 2>/dev/null || true)
    CONCL=$(printf '%s' "$META" | python -c "
import sys, json
try:
    d=json.load(sys.stdin)
    print(d.get('conclusion','') or '')
except Exception: print('')" 2>/dev/null || true)
    if [ "$STATUS" = "completed" ]; then break; fi
    sleep 12
  done
  if [ "$STATUS" = "completed" ]; then
    echo
    echo "GH Action run $RUN_ID -> $CONCL"
    echo "URL: https://github.com/Srihan-Yeleswarapu/SmartSpeedCompanion/actions/runs/$RUN_ID"
    if [ "$CONCL" != "success" ]; then
      fail "GH Action run $RUN_ID concluded with '$CONCL' (not success)"
    else
      ok "GH Action run completed: $CONCL"
    fi
  else
    warn "GH Action run $RUN_ID still pending after poll budget (status=$STATUS)"
  fi
fi

echo
echo "=========================================="
echo "Deploy summary"
echo "  Commit : $COMMIT_SHA"
echo "  Run id : ${RUN_ID:-<unknown>}"
echo "  Conclusion: ${CONCL:-<pending>}"
echo "  Verifications failed: $FAIL"
echo "=========================================="
exit $FAIL
