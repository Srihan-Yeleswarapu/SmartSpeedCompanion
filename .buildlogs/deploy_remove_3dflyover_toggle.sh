#!/usr/bin/env bash
# Deploy the "remove 3D flyover (long highways) toggle" change.
# - Verify no orphan refs to threeDFlyoverEnabled remain in code.
# - Verify the toggle ("3D flyover (long highways)") string is gone.
# - Verify the gate in LiveMapView is now default-on (no threeDFlyoverEnabled flag).
# - Stage + commit + push to version2.
# - Watch the resulting GH Action run on version2 to completion (up to 60*12s).

set -euo pipefail

cd "$(dirname "$0")/.."

echo "=== [1] orphan-ref check on threeDFlyoverEnabled ==="
if grep -rn 'threeDFlyoverEnabled' SmartSpeedCompanion/ | grep -v 'NB:\|removed\|toggle removed\|NB-style\|testflight' >/dev/null 2>&1; then
  echo "FAIL: stray runtime reference survived"
  grep -rn 'threeDFlyoverEnabled' SmartSpeedCompanion/
  exit 1
fi
echo "  OK"

echo "=== [2] SettingsView toggle string gone ==="
if grep -n 'Toggle.*"3D flyover (long highways)"' SmartSpeedCompanion/Views/Settings/SettingsView.swift; then
  echo "FAIL: toggle still present"
  exit 1
fi
echo "  OK"

echo "=== [3] LiveMapView gate now reads plain `if isNavigating` (no flag) ==="
if ! grep -n 'if isNavigating && distanceToTurn > 4000 && speed > 50' SmartSpeedCompanion/Views/Drive/LiveMapView.swift >/dev/null; then
  echo "FAIL: gate line not where expected"
  exit 1
fi
if grep -n 'viewModel.threeDFlyoverEnabled' SmartSpeedCompanion/Views/Drive/LiveMapView.swift; then
  echo "FAIL: old flag still referenced in LiveMapView"
  exit 1
fi
echo "  OK"

echo "=== [4] Hybrid 3D basemap (a SEPARATE option in the Map Style picker) is preserved ==="
grep -n 'hybridFlyover' SmartSpeedCompanion/ | head -3 || echo "WARN: hybridFlyover usage not grep-visible"
echo

echo "=== [5] git status ==="
git status --short

echo "=== [6] diff summary ==="
git diff --stat

echo "=== [7] commit ==="
git add -A
git commit -m "fix(settings): remove \"3D flyover (long highways)\" toggle (bake into LiveMapView)

The user never knew what the toggle did, so it has been retired.
The flyover camera is now default-on in LiveMapView.updateSmartAltitude,
gated to fire only when actively navigating, above 50 mph, with no turn
coming up within 4 km — exactly the conditions where a tilted,
pulled-back highway perspective looks good.

Touched:
- SettingsView.swift: drop @AppStorage(\"threeDFlyoverEnabled\") + the Toggle row
  in the MAP section.
- DriveViewModel.swift: drop the `threeDFlyoverEnabled` UserDefaults
  bridge property; the MAP Pitch pill toggle (2D/3D/Auto) is the
  only remaining camera control.
- LiveMapView.swift: the flyover branch in updateSmartAltitude now
  reads `isNavigating && distanceToTurn > 4000 && speed > 50`
  directly, no flag.

The \"Hybrid 3D\" Map Style picker option remains: it is the user
choosing the satellite-with-terrain basemap, not the auto-tilt
on long highways."

HEADER=$(git rev-parse HEAD)
echo "  committed: $HEADER"

echo "=== [8] push origin version2 ==="
git push origin version2

echo "=== [9] watch GH Action runs on this SHA ==="
for ((i=0; i<60; i++)); do
  sleep 12
  RUN_JSON=$(curl -s -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/Srihan-Yeleswarapu/SmartSpeedCompanion/actions/runs?head_sha=${HEADER}&per_page=1" \
    | head -200)
  RUN_ID=$(echo "$RUN_JSON" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*' || true)
  RUN_STATUS=$(echo "$RUN_JSON" | grep -o '"status":"[^"]*"' | head -1 | sed 's/"status":"//;s/"$//' || true)
  RUN_CONCLUSION=$(echo "$RUN_JSON" | grep -o '"conclusion":"[^"]*"' | head -1 | sed 's/"conclusion":"//;s/"$//' || true)
  RUN_URL=$(echo "$RUN_JSON" | grep -o '"html_url":"[^"]*"' | head -1 | sed 's/"html_url":"//;s/"$//' || true)
  if [ -n "$RUN_ID" ]; then
    echo "  [poll $i] run=$RUN_ID  status=$RUN_STATUS  conclusion=$RUN_CONCLUSION"
    if [ "$RUN_STATUS" = "completed" ]; then
      echo
      echo "========================================================================"
      echo " FINAL: run=$RUN_ID  conclusion=$RUN_CONCLUSION"
      echo " URL: $RUN_URL"
      echo "========================================================================"
      if [ "$RUN_CONCLUSION" = "success" ]; then exit 0; else exit 2; fi
    fi
  else
    echo "  [poll $i] no run yet for $HEADER"
  fi
done
echo "TIMEOUT waiting for GH Action completion"
exit 3
