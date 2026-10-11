#!/bin/bash
# DE0CH fork: re-identify the app for team S64YL394S3 at build time, so the committed project
# stays identical to upstream (merges stay clean) and the TestFlight build is its own app.
#   scripts/de0ch/identity.sh      (run from anywhere, before xcodebuild; edits the working tree)
# - bundle ids / app group / notification names com.void.smarttube.* -> dev.de0ch.smarttube.*
# - team 5A4JA438MW -> S64YL394S3, Secrets.xcconfig with the team
# - home-screen name "SmartTube JP" (the App Store record name is "SmartTube JP DE0CH")
# - the Apple Watch app is no longer embedded in the iOS app (drop-watch.rb)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
TEAM=S64YL394S3
git ls-files -z -- . ':!scripts/de0ch' | xargs -0 grep -lIZ -e 'com\.void\.smarttube' -e '5A4JA438MW' \
  | xargs -0 perl -pi -e 's/com\.void\.smarttube/dev.de0ch.smarttube/g; s/5A4JA438MW/'"$TEAM"'/g'
perl -pi -e 's/INFOPLIST_KEY_CFBundleDisplayName = "Smart Tube";/INFOPLIST_KEY_CFBundleDisplayName = "SmartTube JP";/g' \
  SmartTubeApp/SmartTubeApp.xcodeproj/project.pbxproj
printf 'SMARTTUBE_TEAM_ID = %s\nSMARTTUBE_TV_TEAM_ID = %s\n' "$TEAM" "$TEAM" > SmartTubeApp/Config/Secrets.xcconfig
# the project copies GoogleService-Info.plist; the placeholder keeps Firebase off at runtime
# (CrashlyticsLogger.hasFirebaseConfig)
cp SmartTubeApp/SmartTubeApp/GoogleService-Info.plist.example SmartTubeApp/SmartTubeApp/GoogleService-Info.plist
ruby "$ROOT/scripts/de0ch/drop-watch.rb" SmartTubeApp/SmartTubeApp.xcodeproj
echo "identity applied: dev.de0ch.smarttube.*, team $TEAM"
