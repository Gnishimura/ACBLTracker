#!/bin/zsh
# Re-signs and reinstalls ACBLTracker on the iPhone before the free Apple ID's
# 7-day signing runs out. Safe to run daily: it does nothing until renewal is due.
# Installs over the existing app, so the roster and saved weeks are kept.
#
# Usage: ./renew.sh             renew only if signing expires within RENEW_WITHIN_DAYS
#        ./renew.sh --force     renew now
#        ./renew.sh --schedule  run this check every day at noon while the Mac is on
set -euo pipefail

HERE=${0:A:h}
source "$HERE/renew.env"   # TEAM_ID, BUNDLE_ID, DEVICE_UDID (see renew.env.example)
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

RENEW_WITHIN_DAYS=2
APP="$HERE/build/Build/Products/Debug-iphoneos/ACBLTracker.app"
LOG="$HERE/renew.log"
PROFILE_DIRS=(
  "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
  "$HOME/Library/MobileDevice/Provisioning Profiles"
)

log()    { print -r -- "$(date '+%F %T') $*" >> "$LOG"; print -r -- "$*"; }
notify() { osascript -e "display notification \"$1\" with title \"ACBL Tracker\"" || true; }
trap 'log "FAILED - see the lines above in renew.log"; notify "Renewal failed. See renew.log."' ERR

if [[ ${1:-} == --schedule ]]; then
  label="$BUNDLE_ID.renew"
  plist="$HOME/Library/LaunchAgents/$label.plist"
  mkdir -p "${plist:h}"
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$label</string>
	<key>ProgramArguments</key><array><string>$HERE/renew.sh</string></array>
	<key>StartCalendarInterval</key><dict><key>Hour</key><integer>12</integer><key>Minute</key><integer>0</integer></dict>
	<key>StandardOutPath</key><string>$HERE/launchd.log</string>
	<key>StandardErrorPath</key><string>$HERE/launchd.log</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$plist"
  log "Scheduled: checks daily at 12:00 ($plist)."
  exit 0
fi

# Prints the epoch time a .mobileprovision file expires.
expiry_of() {
  local iso
  iso=$(security cms -D -i "$1" 2>/dev/null | plutil -extract ExpirationDate raw -o - -)
  date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s
}

old_expiry=0
[[ -f "$APP/embedded.mobileprovision" ]] && old_expiry=$(expiry_of "$APP/embedded.mobileprovision")
days_left=$(( (old_expiry - $(date +%s)) / 86400 ))

if [[ ${1:-} != --force ]] && (( days_left > RENEW_WITHIN_DAYS )); then
  log "Signing good for $days_left more days; nothing to do."
  exit 0
fi

if ! xcrun devicectl device info details --device "$DEVICE_UDID" --timeout 60 >/dev/null 2>&1; then
  log "Renewal due ($days_left days left) but the iPhone isn't reachable."
  notify "Renewal due, but your iPhone isn't reachable. Unlock it on the same Wi-Fi, or plug it in."
  exit 0
fi

# Clear this app's cached profile so Xcode issues a fresh 7-day one
# instead of reusing the one that is about to expire.
for dir in $PROFILE_DIRS; do
  for f in "$dir"/*.mobileprovision(N); do
    if security cms -D -i "$f" 2>/dev/null | grep -q "\.$BUNDLE_ID<"; then
      rm -f "$f"
    fi
  done
done

log "Building..."
xcodebuild -quiet \
  -project "$HERE/ACBLTracker.xcodeproj" -scheme ACBLTracker -configuration Debug \
  -destination "id=$DEVICE_UDID" -derivedDataPath "$HERE/build" \
  -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM_ID" \
  build >> "$LOG" 2>&1

new_expiry=$(expiry_of "$APP/embedded.mobileprovision")
if (( new_expiry <= old_expiry )); then
  log "Build did not get a newer profile (expires $(date -r $new_expiry))."
  false
fi

log "Installing..."
xcrun devicectl device install app --device "$DEVICE_UDID" "$APP" >> "$LOG" 2>&1

log "Renewed. Good until $(date -r $new_expiry '+%a %b %-d, %-I:%M %p')."
notify "Renewed. Good until $(date -r $new_expiry '+%a %b %-d')."
