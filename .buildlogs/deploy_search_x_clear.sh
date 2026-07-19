#!/usr/bin/env bash
# Fix: TestFlight 2.2.0 (b377) — when user X-es out of the search bar,
# the proposed route polylines lingered on the map. The X button only
# cleared the search TEXT and didn't reset isSelectingRoute / availableRoutes,
# so RouteSelectionCard + map polylines both stayed visible.
#
# Fix: extend the SearchBarView's X Button action to also reset those three
# fields, mirroring the dismissal logic that RouteSelectionCard's own X
# already performs (so both dismissal paths agree).
set +e
cd "$(pwd)"

f="SmartSpeedCompanion/Views/Drive/MapWithHUDView.swift"

echo '=== git status (before) ==='
git status --short

echo
echo '=== brace/paren balance on MapWithHUDView.swift ==='
awk -v FILE="$f" 'BEGIN{o=0;c=0;p=0;po=0} {for(i=1;i<=length($0);i++){ch=substr($0,i,1); if(ch=="{")o++; else if(ch=="}")c++; else if(ch=="(")p++; else if(ch==")")po++}} END{printf "%s: braces open=%d close=%d delta=%d | parens open=%d close=%d delta=%d\n", FILE, o, c, (o-c), p, po, (p-po)}' "$f"

echo
echo '=== confirm SearchBarView X handler now clears route state ==='
# Count of "isSelectingRoute = false" assignments on this file: we expect
# exactly 2 (one in RouteSelectionCard X handler, one in SearchBarView X handler).
ISSELECT="$(grep -cE 'driveViewModel\.isSelectingRoute = false' "$f")"
echo "driveViewModel.isSelectingRoute = false refs = $ISSELECT (expect 2 = RouteSelectionCard X + new SearchBarView X)"
AVAILCLEAR="$(grep -cE 'driveViewModel\.availableRoutes = \[\]' "$f")"
echo "driveViewModel.availableRoutes = [] refs = $AVAILCLEAR (expect 2 = same two dismiss paths)"
DESTCLEAR="$(grep -cE 'driveViewModel\.destination = nil' "$f")"
echo "driveViewModel.destination = nil refs = $DESTCLEAR (expect 2)"

echo
echo '=== confirm new dismiss comment is in place ==='
if grep -nE "directions options should also go away|TestFlight 2\.2\.0 \(b377\)" "$f" >/dev/null 2>&1; then
  echo '[OK] new dismiss-comment block + TestFlight b377 anchor present'
else
  echo 'WARN: dismiss comment MISSING'
fi

echo
echo '=== sanity: SearchBarView X character count unchanged (still xmark.circle.fill) ==='
if grep -nE 'xmark\.circle\.fill' "$f" | grep -B 5 'updateSearchQuery("")' >/dev/null 2>&1; then
  echo '[OK] xmark.circle.fill icon still wired to SearchBarView X'
else
  echo 'WARN: xmark.circle.fill icon link to SearchBarView X may be broken'
fi

echo
echo '=== git diff stat ==='
git diff --stat

echo
echo '=== commit ==='
git add "$f"
git commit -m "fix(search): dismiss route alternatives when SearchBarView is X-ed

TestFlight 2.2.0 (b377) feedback from srihan.yeleswarapu@gmail.com:
  'When I X out of the search, the directions options should also
   go away! Why are they still here and visible.'

Root cause:
- SearchBarView's X button only cleared the search TEXT
  (searchText = '', driveViewModel.updateSearchQuery('')) and didn't
  touch the route-selection state published by DriveViewModel.
- RouteSelectionCard's own X handler did clear isSelectingRoute,
  availableRoutes, and destination -- but the user X-es the search
  from the top bar BEFORE the picker card gets displayed, so that
  dismissal path never runs.
- Result: the cyan-glow + light-white polylines from the proposed
  routes stayed visible on the map even after the search was
  dismissed.

Fix: extend SearchBarView's X button action to also reset the
three fields, mirroring RouteSelectionCard's logic so both
dismissal paths reach the same end state:

    driveViewModel.isSelectingRoute = false
    driveViewModel.availableRoutes = []
    driveViewModel.destination = nil

Notes:
- We do NOT call driveViewModel.endNavigation() here because the
  X is a search-clear action, not an end-of-trip action. If the
  user was already navigating (startNavigation was called from a
  previous tap), isNavigating remains true and the active route
  polylines still render. That is correct: tapping the search-bar
  X should NOT cancel an in-progress navigation.
- The change is single-file (MapWithHUDView.swift only) and
  ~5 lines added inside an existing Button action. The
  RouteSelectionCard dismiss path is unmodified -- it remains the
  source of truth for the three-field reset pattern."

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
