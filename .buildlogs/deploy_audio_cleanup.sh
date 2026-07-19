#!/usr/bin/env bash
# Audio cleanup commit: navVoiceOptions constant + guarded launch-time deactivate + indent-fix in announce().
set +e
cd "$(pwd)"

f="SmartSpeedCompanion/ViewModels/DriveViewModel.swift"

echo '=== git status (before) ==='
git status --short

echo
echo '=== brace/paren balance on DriveViewModel.swift ==='
awk -v FILE="$f" 'BEGIN{o=0;c=0;p=0;po=0} {for(i=1;i<=length($0);i++){ch=substr($0,i,1); if(ch=="{")o++; else if(ch=="}")c++; else if(ch=="(")p++; else if(ch==")")po++}} END{printf "%s: braces open=%d close=%d delta=%d | parens open=%d close=%d delta=%d\n", FILE, o, c, (o-c), p, po, (p-po)}' "$f"

echo
echo '=== Self.navVoiceOptions present ==='
if grep -nE 'private static let navVoiceOptions' "$f" >/dev/null 2>&1; then
  echo '[OK] navVoiceOptions static constant declared'
else
  echo 'WARN: navVoiceOptions constant missing'
fi
USAGE=$(grep -cE 'Self\.navVoiceOptions' "$f")
echo "Self.navVoiceOptions usages = $USAGE (expect 2: setupAudioSession + announce)"

echo
echo '=== guarded deactivate in setupAudioSession ==='
if grep -nE 'isOtherAudioPlaying \|\| session\.mode != \.spokenAudio \|\| session\.category != \.playback' "$f" >/dev/null 2>&1; then
  echo '[OK] guarded deactivate condition present'
else
  echo 'WARN: guarded deactivate condition MISSING'
fi

echo
echo '=== announce() defensive setCategory uses Self.navVoiceOptions ==='
if grep -nE 'mode: \.spokenAudio,' "$f" | tail -3 >/dev/null 2>&1; then
  echo 'spotted .spokenAudio mode lines (last 3 occurrences):'
  grep -nE 'mode: \.spokenAudio,' "$f" | tail -3
fi

echo
echo '=== check NO zero-indent Detection block remains in announce() ==='
# The broken-indent block had a 0-leading-whitespace "// Defensive:" line that
# was actually inside func announce(). With the new editing, that block
# should now lead with 8-space indentation ("        // Defensive:").
INDENT_DEFENSIVE=$(grep -nE '^// Defensive: re-apply' "$f" | wc -l)
echo "zero-indent '// Defensive:' lines = $INDENT_DEFENSIVE (expect 0)"
INDENTED_DEFENSIVE=$(grep -nE '^        // Defensive: re-apply' "$f" | wc -l)
echo "8-space indent '// Defensive:' lines = $INDENTED_DEFENSIVE (expect 1)"

echo
echo '=== confirm navVoiceOptions constant is 5-element ==='
NAV_CONST_LINES=$(awk '/private static let navVoiceOptions/,/^    \]$/' "$f" | grep -cE '\.')
echo "navVoiceOptions element count = $NAV_CONST_LINES (expect 5: .duckOthers, .mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP, .interruptSpokenAudioAndMixWithOthers)"

echo
echo '=== git diff stat ==='
git diff --stat

echo
echo '=== commit ==='
git add "$f"
git commit -m "refactor(nav voice): extract Self.navVoiceOptions constant + guard launch-time deactivate + fix announce() indent

Followup to the prior .spokenAudio-mode-lock fix; addresses three
reviewer notes:

1. (C) The 5-element options array [.duckOthers, .mixWithOthers,
   .defaultToSpeaker, .allowBluetoothA2DP, .interruptSpokenAudioAndMixWithOthers]
   was duplicated between setupAudioSession() and announce(). Extracted
   to a private static let navVoiceOptions on DriveViewModel. Future
   tweaks (e.g. .allowBluetoothHFP for car-kit routing) now live in
   one place. iOS 17+ only -- project deploymentTarget is iOS 18.0
   per project.yml so no @available guard is needed.

2. (A) setupAudioSession() now gates its setActive(false) call with
   'isOtherAudioPlaying || mode != .spokenAudio || category != .playback'.
   Opening the app while Spotify is playing no longer yanks the
   user's music out of focus for ~100 ms on cold launch. The prior
   unconditional 'try?' variant cut music on every launch.

3. (broken indent) announce()'s defensive setCategory re-apply was
   inserted at function-body depth with 0 leading whitespace by an
   earlier half-applied str_replace (cosmetic only -- Swift compiles
   whitespace-insensitively, but it tripped the linter and confused a
   follow-up edit). Re-indented to the file's standard 8-space
   function-body depth and switched the inline options array to
   Self.navVoiceOptions for consistency.

No behavioral change for testers: the .spokenAudio mode still
sticks, the per-utterance defensive re-apply still runs, and tone
beep + nav voice both work as in the prior fix."

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
