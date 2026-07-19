#!/usr/bin/env bash
# Voice enhancements Phase B followup:
#  - #2 3rd 'approaching' cue at ~643 m + highway merge variant
#  - #3 initial ETA announcement in startNavigation
#  - #4 highway merge cue (folded into #2's approaching block)
#  - #5 verification-only (roundabout-safe). expandAbbreviations uses \b
#       word-boundary regex so "1st/2nd/3rd exit" never gets mangled.
#  - #6 speed camera voice alert (dedupe via spokenCameraKeys set)
#  - #8 drop "You are arriving" announce + hasAnnouncedArrival
set +e
cd "$(pwd)"

f="SmartSpeedCompanion/ViewModels/DriveViewModel.swift"

echo '=== git status (before) ==='
git status --short

echo
echo '=== brace/paren balance on DriveViewModel.swift ==='
awk -v FILE="$f" 'BEGIN{o=0;c=0;p=0;po=0} {for(i=1;i<=length($0);i++){ch=substr($0,i,1); if(ch=="{")o++; else if(ch=="}")c++; else if(ch=="(")p++; else if(ch==")")po++}} END{printf "%s: braces open=%d close=%d delta=%d | parens open=%d close=%d delta=%d\n", FILE, o, c, (o-c), p, po, (p-po)}' "$f"

echo
echo '=== #2/#4: approaching flag + highway merge variant ==='
APPROACH="$(grep -cE 'flags\.contains\(\"approaching\"\)|flags\.insert\(\"approaching\"\)|!flags\.contains\(\"approaching\"\)' "$f")"
echo "approaching flag refs = $APPROACH (expect >= 3: condition + insert + dedup-check)"
if grep -nE 'approachingDist|Merging in \\\(|distanceToTurn <= 643\.0' "$f" >/dev/null 2>&1; then
  echo '[OK] approaching-stage code present'
else
  echo 'WARN: approaching-stage code MISSING'
fi
if grep -nE 'merge onto.*take exit|take exit.*merge onto' "$f" >/dev/null 2>&1; then
  echo '[OK] highway-class detection (merge onto / take exit) present'
else
  echo 'WARN: highway-class detection MISSING'
fi

echo
echo '=== #3: initial ETA announce ==='
if grep -nE 'Starting route to' "$f" >/dev/null 2>&1; then
  echo '[OK] "Starting route to X" announce literal present'
else
  echo 'WARN: initial ETA announce MISSING'
fi
if grep -nE 'if !isReroute, let etaValue = self\.eta' "$f" >/dev/null 2>&1; then
  echo '[OK] reroute-gated ETA announce'
else
  echo 'WARN: reroute-gated ETA block not found'
fi

echo
echo '=== #6: speed camera wiring + alert ==='
SPEED_BIND="$(grep -cE 'SpeedCameraService\.shared\.\$cameras' "$f")"
echo "SpeedCameraService.shared.\$cameras refs = $SPEED_BIND (expect 1: binding in init)"
SPOKEN_DECL="$(grep -cE 'private var spokenCameraKeys' "$f")"
echo "spokenCameraKeys field decl = $SPOKEN_DECL (expect 1)"
SPOKEN_RESET="$(grep -cE 'spokenCameraKeys\.removeAll\(\)' "$f")"
echo "spokenCameraKeys.removeAll() calls = $SPOKEN_RESET (expect 2: startNav + endNav)"
SPOKEN_INSERT="$(grep -cE 'spokenCameraKeys\.insert' "$f")"
echo "spokenCameraKeys.insert() calls = $SPOKEN_INSERT (expect 1: dedup gate in updateNav)"
SPOKEN_ALERT="$(grep -cE 'Reduce speed, speed camera ahead' "$f")"
echo "speed-camera announce literal = $SPOKEN_ALERT (expect 1) if grep -E \\\"Reduce speed, speed camera ahead\\\" $f | wc -l ; fi"

echo
echo '=== #8: announce \"arriving\" + hasAnnouncedArrival must be GONE ==='
HA="$(grep -cE 'hasAnnouncedArrival' "$f")"
echo "hasAnnouncedArrival refs remaining = $HA (expect 0)"
ARR="$(grep -cE 'You are arriving at your destination' "$f")"
echo "\"You are arriving\" announce remaining = $ARR (expect 0)"

echo
echo '=== sanity: arrival announce still kept in advanceToNextStep ==='
ARRIVED="$(grep -cE 'You have arrived at your destination' "$f")"
echo "\"You have arrived\" announce ref = $ARRIVED (expect 1)"

echo
echo '=== #5 (roundabout): expandAbbreviations uses \\b boundaries ==='
if grep -nE 'let pattern = \\\"\\\\\\\\b' "$f" >/dev/null 2>&1; then
  echo '[OK] expandAbbreviations uses \\\\b word-boundary regex so ordinals like 1st/2nd/3rd exit are safe'
else
  echo 'WARN: expandAbbreviations does NOT use \\\\b boundaries'
fi

echo
echo '=== git diff stat ==='
git diff --stat

echo
echo '=== commit ==='
git add "$f"
git commit -m "feat(nav voice): 6 user-approved voice enhancements (Phase B)

User sign-off via ask_user multi-select on TestFlight 2.2.x nav-voice
enhancement menu. Approved items (6 of 9):

  #2  Add 'approaching' stage cue at ~643 m / 0.4 mi between the
      existing initial + immediate cues. Fires ONCE per step (gated
      by new 'approaching' flag in stepStageFlags), and only AFTER
      'initial' has spoken AND we're still above the immediate
      threshold. Short-step guard: cues don't fire if the entire
      step was already < 643 m on first observation.

  #3  Speak 'Starting route to X, N miles, arriving at HH:MM' once
      on initial startNavigation. Skips on reroute so we don't
      repeat mid-drive. formatDistance() routes through the user's
      measurement setting, DateFormatter(.short) renders in the
      device locale's time style.

  #4  Highway merge cue (folded into #2's 'approaching' stage):
      when the step's instruction text contains 'Merge onto' or
      'Take exit' (case-insensitive), the approaching cue prefix
      becomes 'Merging in 0.4 mile' instead of the generic
      'In 0.4 mile, <instruction>'. Gives the driver a clean
      highway-transition reminder before the bare instruction
      fires at 220 m.

  #5  Roundabout phrasing: no code change. Verified by inspection
      that expandAbbreviations uses \\b word-boundary regex on every
      abbreviation entry, so 'take the 2nd exit onto Main St' is
      unaffected by the abbreviation table (the 'St' boundary at
      word end maps to 'Street' as intended; the '2nd' inside is
      safe because the boundary requires a non-word char on BOTH
      sides of 'St', and 'n' / 'd' inside '2nd' never match).

  #6  Speed camera voice alert: new spokenCameraKeys Set<String>
      keyed by 'lat,lon' rounded to 4 decimals. In
      updateNavigationProgress, when location.distance(to camera)
      crosses <= 245 m (800 ft), speak 'Reduce speed, speed
      camera ahead.' ONCE per camera. The new
      SpeedCameraService.shared.\$cameras binding (which was
      previously declared but never wired) mirrors the service
      onto @Published nearbyCameras so the alert actually has data.

  #8  Drop the proactive 'You are arriving at your destination'
      voice cue (<= 10 m) that was redundant with the 'You have
      arrived at your destination' cue from advanceToNextStep
      (<= 50 m). Removed the hasAnnouncedArrival bool,
      stepStageFlags-style gate, and the announce block. Only one
      arrival cue lives in the navigation lifecycle now.

No behavior change for the audio routing bug from the prior
commits -- this commit assumes the .spokenAudio mode-locked fix
on commit e020c7c is already in place. The announce() defensive
setCategory re-apply handles any mid-drive session state flip.

The arriving-cue removal addresses an ask_user-verified user
preference for 'drop the arriving announce, keep the arrived
announce'."

echo
echo '=== push ==='
git push origin version2 2>&1 | tail -10

echo
echo '=== local vs upstream ==='
LOCAL=$(git rev-parse HEAD)
UPSTREAM=$(git rev-parse @{u} 2>/dev/null)
echo "local     = $LOCAL"
echo "upstream  = $UPSTREAM"

echo
echo '=== find GH Action run for new HEAD ==='
SHA=$(git rev-parse HEAD)
echo "head SHA = $SHA"
sleep 10
ID=$(gh run list --limit 200 --json databaseId,headSha --jq ".[] | select(.headSha == \"$SHA\") | .databaseId" 2>/dev/null | head -1)
echo "run id = $ID"

if [ -z "$ID" ]; then
  echo 'no run yet for current HEAD; showing recent 5:'
  gh run list --branch version2 --limit 5 --json databaseId,name,headSha,status,conclusion,createdAt 2>&1 | head -40
  exit 0
fi

echo
echo '=== poll status (up to 12 minutes) ==='
JC=queued
URL=""
for i in $(seq 1 60); do
  RAW=$(gh run view "$ID" --json status,conclusion,url 2>/dev/null)
  JC=$(echo "$RAW" | jq -r '.conclusion // .status' 2>/dev/null)
  URL=$(echo "$RAW" | jq -r '.url' 2>/dev/null)
  echo "[$(date +%H:%M:%S)] attempt $i/60 verdict=$JC"
  case "$JC" in
    success|failure|cancelled|completed)
      break ;;
  esac
  sleep 12
done

echo
echo "FINAL: run=$ID verdict=$JC"
echo "URL: $URL"
gh run view "$ID" --json status,conclusion,url,headSha,name 2>&1
