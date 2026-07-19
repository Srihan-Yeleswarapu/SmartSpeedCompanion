#!/usr/bin/env bash
# Audio fix: verify + commit + push + watch GH Action
set +e
cd "$(pwd)"

f="SmartSpeedCompanion/ViewModels/DriveViewModel.swift"

echo '=== git status (before) ==='
git status --short

echo
echo '=== brace/paren balance on DriveViewModel.swift ==='
awk -v FILE="$f" 'BEGIN{o=0;c=0;p=0;po=0} {for(i=1;i<=length($0);i++){ch=substr($0,i,1); if(ch=="{")o++; else if(ch=="}")c++; else if(ch=="(")p++; else if(ch==")")po++}} END{printf "%s: braces open=%d close=%d delta=%d | parens open=%d close=%d delta=%d\n", FILE, o, c, (o-c), p, po, (p-po)}' "$f"

echo
echo '=== confirm both edits landed ==='
# Check that we still have the .spokenAudio forced setupAudioSession
if grep -nE '\.spokenAudio.*Forced|spokenAudio forced' "$f" >/dev/null 2>&1; then
  echo '[OK] setupAudioSession has spokenAudio-forced log line'
else
  echo 'WARN: setupAudioSession spoken-forced log line MISSING'
fi

# Check the new try? setActive(false) BEFORE setCategory in setupAudioSession
if grep -nE 'setActive\(false, options: \.notifyOthersOnDeactivation' "$f" >/dev/null 2>&1; then
  CNT=$(grep -cE 'setActive\(false, options: \.notifyOthersOnDeactivation' "$f")
  echo "[OK] setActive(false, notifyOthers) call count = $CNT (expect 1)"
else
  echo 'WARN: setActive(false) NOT FOUND'
fi

# Check announce() has the defensive setCategory(.spokenAudio) right before the shouldActivate block
if grep -nE '// Defensive: re-apply `\.spokenAudio` mode' "$f" >/dev/null 2>&1; then
  echo '[OK] announce() has the defensive re-apply comment'
else
  echo 'WARN: announce() defensive re-apply comment MISSING'
fi

# Confirm no orphan duplicate "Only activate audio session if other audio is playing" comment
DUP=$(grep -cE 'Only activate audio session if other audio is playing' "$f")
echo "duplicate \"Only activate\" comment count = $DUP (expect 1 — was 2 before fix)"

# Confirm .duckOthers still present in BOTH audio session blocks
DUCKDOTH=$(grep -cE '\.duckOthers' "$f")
echo ".duckOthers lines = $DUCKDOTH"

# Confirm .defaultToSpeaker + .allowBluetoothA2DP both present
echo "defaultToSpeaker lines    = $(grep -cE '\.defaultToSpeaker' $f)"
echo "allowBluetoothA2DP lines  = $(grep -cE '\.allowBluetoothA2DP' $f)"
echo "interruptSpoken lines     = $(grep -cE '\.interruptSpokenAudioAndMixWithOthers' $f)"

echo
echo '=== git diff stat ==='
git diff --stat

echo
echo '=== commit ==='
git add "$f"
git commit -m "fix(nav voice): force spokenAudio mode at launch + before each utterance

TestFlight 2.2.x feedback: 'Navigation messages/announcements were
not heard' despite DebugLogger logging 'NAV VOICE SENT' normally.

Root cause: AlertEngine's AVAudioSession setup runs INSIDE
DriveViewModel.init (alert engine is constructed by DriveViewModel
before DriveViewModel.setupAudioSession() calls) and calls:

    setCategory(.playback, mode: .default, [...])
    setActive(true)

immediately. DriveViewModel.setupAudioSession() then attempts:

    setCategory(.playback, mode: .spokenAudio, [...])

without first deactivating. iOS only honours a mode change when
the session transitions inactive -> active, so the .spokenAudio
request is recorded in logs but the underlying routing stays in
.default mode. AVSpeechSynthesizer output in .default mode is
routed through the ringer/earpiece speaker path at low volume,
which the tester perceives as silence.

Fix:
- DriveViewModel.setupAudioSession(): explicit deactivate (with
  .notifyOthersOnDeactivation so Spotify etc. drop gracefully),
  setCategory to .playback/.spokenAudio with [.duckOthers,
  .mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP,
  .interruptSpokenAudioAndMixWithOthers], then setActive(true).
  Removed the prior iOS-17-only .insert(gated) since the option
  is supported on iOS 17+ and the deployment target is iOS 17+.
- DriveViewModel.announce(): re-applies the same setCategory
  before every utterance so anything that flipped the session
  back to .default mid-drive (CarPlay audio route change,
  AlertEngine tone reset, Bluetooth re-pair) is corrected
  immediately. Pre-utterance .spokenAudio re-apply is a cheap
  no-op when already in the right state.
- Also cleaned up duplicate legacy 'Only activate audio session
  if other audio is playing' comment that was left by an earlier
  broken edit (the actual logic was setActive-guarded by
  isOtherAudioPlaying, which kept the same behavior).

Tone engine path is unchanged — AlertEngine.setupAudioSession()
is untouched because (a) testers confirmed the speeding beep is
audible in this build, and (b) the explicit setActive(true) at
init keeps the AVAudioEngine player primed for the first beep.
The only requirement the tone engine has on the session is a
.playback category which DriveViewModel's setupAudioSession()
preserves."

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
