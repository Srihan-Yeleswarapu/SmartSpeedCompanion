#!/usr/bin/env bash
set +e
cd "$(pwd)" 2>/dev/null || cd 'C:\Users\madhu\SmartSpeedCompanion iOS CarPlay'
cd "$(pwd)"

echo '=== pwd / branch ==='
pwd
git branch --show-current

echo
echo '=== before ==='
git status --short

echo
echo '=== git rm the two debug view files ==='
git rm SmartSpeedCompanion/Views/Debug/DeveloperTabView.swift 2>&1
git rm SmartSpeedCompanion/Views/Debug/DeveloperSimulatorView.swift 2>&1

echo
echo '=== rm empty Views/Debug/ dir ==='
rmdir "SmartSpeedCompanion/Views/Debug/" 2>&1 || echo 'rmdir did not succeed (dir may already be gone)'
if [ -d "SmartSpeedCompanion/Views/Debug" ]; then
  echo 'dir still exists; listing contents:'
  ls -la "SmartSpeedCompanion/Views/Debug/"
else
  echo 'Views/Debug/ removed'
fi

echo
echo '=== orphan refs ==='
for sym in DeveloperTabView DeveloperSimulatorView MockMapView CompassHeadingPicker geoapifyKeyRow geoapifyKeyDraft; do
  HIT=$(grep -rln --include='*.swift' "$sym" SmartSpeedCompanion 2>/dev/null | wc -l)
  printf '%-26s files still referencing it: %d\n' "$sym" "$HIT"
done

echo
echo '=== brace/paren balance on DriveRootView.swift ==='
f="SmartSpeedCompanion/Views/Drive/DriveRootView.swift"
awk -v FILE="$f" 'BEGIN{o=0;c=0;p=0;po=0} {for(i=1;i<=length($0);i++){ch=substr($0,i,1); if(ch=="{")o++; else if(ch=="}")c++; else if(ch=="(")p++; else if(ch==")")po++}} END{printf "%s: braces open=%d close=%d delta=%d | parens open=%d close=%d delta=%d\n", FILE, o, c, (o-c), p, po, (p-po)}' "$f"

echo
echo '=== confirm conditional block gone ==='
if grep -nE '#if DEBUG .DEVELOPER_BUILD|DeveloperTabView[(][)]' "SmartSpeedCompanion/Views/Drive/DriveRootView.swift" >/dev/null 2>&1; then
  echo 'WARN: conditional block still present'
else
  echo '[OK] conditional 4th tab removed'
fi

echo
echo '=== stat on staged diff ==='
git diff --staged --stat

echo
echo '=== commit ==='
git commit -m 'chore: remove developer tab + GPS override simulator

Removed:
- Views/Debug/DeveloperTabView.swift
- Views/Debug/DeveloperSimulatorView.swift (also dropped MockMapView + CompassHeadingPicker)
- The 4th TabView entry in DriveRootView (was gated by #if DEBUG || DEVELOPER_BUILD)

Kept (production callers exist; harmless in App Store):
- Core/DebugLogger.swift (103 call sites; #if DEVELOPER_BUILD makes calls empty in Release)
- Core/SimulationManager.swift (DriveViewModel auto-engages on iOS Simulator)
- Core/GeoapifyCredentialStore.swift (production RoadGeocoder reads the key)

Final tab structure: Map, Analytics, Settings (3 tabs).'

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
  echo 'no run for current HEAD; showing recent 5:'
  gh run list --branch version2 --limit 5 --json databaseId,headSha,status,conclusion,createdAt 2>&1 | head -40
  exit 0
fi

echo
echo '=== poll status ==='
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
