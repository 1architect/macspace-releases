#!/bin/bash
# Tests MacSpace on this Mac by itself: no switch to flip, nothing to answer. Run it, wait, send back the report.
#
#   Scripts/SelfTest.sh
#
# It drives the installed app's own code through its command-line tool (`MacSpaceCli action`, the same module code and helper
# the app uses), checks each result against what macOS reports, and puts every switch back the way it found it. The results go to
# results/selftest-<date>/ in this repository (not committed); send report.md from there.
#
# Plain settings are written the way System Settings writes them (CFPreferences, then the setting's change notification). The
# script checks that each notification is posted, and lists the change notifications the owning frameworks export on this build,
# for the settings the research names none for (personalized ads and the ad identifier).
#
# Not tested here, and why:
# - Policies (the "Policies (need your approval)" section): macOS applies a configuration profile only after a person approves it.
# - Siri & Apple Intelligence model removal: it needs Apple Intelligence switched on first, which downloads about 12 GB.
set -uo pipefail
cd "$(dirname "$0")/.."

APP=/Applications/MacSpace.app
CLI="$APP/Contents/MacOS/MacSpaceCli"
DEBLOAT=com.macspace.debloat
OUT="results/selftest-$(date +%Y%m%d-%H%M%S)"
REPORT="$OUT/report.md"
mkdir -p "$OUT"
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode-beta.app ]; then export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer; fi
[ -x "$CLI" ] || { echo "MacSpace is not in /Applications. Build it, copy it there, open it once, then run this again."; exit 1; }

PASSED=0; FAILED=0
note() { printf '%s\n' "$*" >> "$REPORT"; }
result() { # status, item, detail
  case "$1" in PASS) PASSED=$((PASSED + 1)) ;; FAIL) FAILED=$((FAILED + 1)) ;; esac
  printf -- '- **%s** %s%s\n' "$1" "$2" "${3:+ — $3}" >> "$REPORT"
  printf '  %-7s %s %s\n' "$1" "$2" "${3:+($3)}"
}
section() { printf '\n\033[1m%s\033[0m\n' "$1"; note ""; note "## $1"; }

{
  echo "# MacSpace self-test"
  echo
  echo "- Date: $(date)"
  echo "- macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
  echo "- App: $(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null) ($(defaults read "$APP/Contents/Info" CFBundleVersion 2>/dev/null))"
} > "$REPORT"

# MARK: Release and helper

section "Release and helper"
codesign -dv --verbose=2 "$APP" > "$OUT/codesign.txt" 2>&1
grep -q "Authority=Developer ID Application" "$OUT/codesign.txt" && result PASS "Developer ID signature" || result FAIL "Developer ID signature" "see codesign.txt"
spctl -a -vv "$APP" > "$OUT/spctl.txt" 2>&1
grep -q "source=Notarized Developer ID" "$OUT/spctl.txt" && result PASS "Notarized" || result FAIL "Notarized" "$(tr '\n' ' ' < "$OUT/spctl.txt")"
xcrun stapler validate "$APP" > "$OUT/stapler.txt" 2>&1 && result PASS "Ticket stapled" || result FAIL "Ticket stapled" "see stapler.txt"
"$CLI" helper --ping > "$OUT/helper.txt" 2>&1
if grep -q "ping ok" "$OUT/helper.txt"; then result PASS "Helper answers the command-line tool"
else result FAIL "Helper" "$(head -3 "$OUT/helper.txt" | tr '\n' ' ') — open MacSpace once (it re-registers the helper), then run this again"; fi

# MARK: CacheDelete

section "CacheDelete (purgeable space)"
"$CLI" purge-assets --self-test > "$OUT/cachedelete-selftest.txt" 2>&1 && result PASS "Self-test on this build" "$(tail -1 "$OUT/cachedelete-selftest.txt")" \
  || result FAIL "Self-test on this build" "$(tail -1 "$OUT/cachedelete-selftest.txt")"
if "$CLI" purge-assets --all-services --json > "$OUT/cachedelete-services.json" 2>&1 && grep -q '"com\.' "$OUT/cachedelete-services.json"; then
  result PASS "Every service answers" "$(grep -c '"com\.' "$OUT/cachedelete-services.json") services"
else result FAIL "Every service answers" "see cachedelete-services.json"; fi

# MARK: Pages

section "Every module's page and tile"
for module in com.macspace.system-data com.macspace.other-system-files com.macspace.siri $DEBLOAT; do
  if "$CLI" screen "$module" > "$OUT/page-$module.json" 2>> "$OUT/errors.txt" && "$CLI" screen "$module" --tile > "$OUT/tile-$module.json" 2>> "$OUT/errors.txt"; then
    result PASS "$module" "$(grep -o '"status" : "[^"]*"' "$OUT/tile-$module.json" | head -1 | cut -d'"' -f4)"
  else result FAIL "$module" "see errors.txt"; fi
done

# MARK: Debloat

# Prints "<list id> <control id> <on|off|disabled> <badge>" for every switch on a saved Debloat page.
debloat_rows() {
  /usr/bin/python3 - "$1" <<'PY' 2>> "$OUT/errors.txt"
import json, sys
page = json.load(open(sys.argv[1]))
def walk(node, list_id):
    if isinstance(node, dict):
        if "rows" in node and "id" in node: list_id = node["id"]
        if "isOn" in node and "id" in node:
            badge = node.get("badge") or {}
            text = (badge.get("text") if isinstance(badge, dict) else None) or "-"
            state = "disabled" if node.get("isEnabled") is False else ("on" if node["isOn"] else "off")
            print(list_id, node["id"], state, text.replace(" ", "_"))
        for value in node.values(): walk(value, list_id)
    elif isinstance(node, list):
        for value in node: walk(value, list_id)
walk(page, "-")
PY
}

# The switch of one control on a fresh page: on, off, or missing.
switch_now() {
  "$CLI" screen $DEBLOAT > "$OUT/page-now.json" 2>> "$OUT/errors.txt" < /dev/null
  debloat_rows "$OUT/page-now.json" | awk -v id="$1" '$2 == id { print $3 "/" $4; found = 1 } END { if (!found) print "missing/-" }'
}

# What macOS stores, read directly, for the controls that are plain settings.
stored_value() {
  case "$1" in
    ads.personalized-ads) defaults read com.apple.AdLib allowApplePersonalizedAdvertising 2>/dev/null ;;
    ads.advertising-identifier) defaults read com.apple.AdLib allowIdentifierForAdvertising 2>/dev/null ;;
    telemetry.siri-improvement) defaults read com.apple.assistant.support "Siri Data Sharing Opt-In Status" 2>/dev/null ;;
  esac
}
expected_value() { # control, on|off
  case "$1/$2" in
    ads.personalized-ads/off|ads.advertising-identifier/off) echo 0 ;;
    ads.personalized-ads/on|ads.advertising-identifier/on) echo 1 ;;
    telemetry.siri-improvement/off) echo 2 ;;
    telemetry.siri-improvement/on) echo 1 ;;
  esac
}

# The change notification a control's setting posts after each write, as this build names it (resolved below).
notification_for() {
  case "$1" in
    telemetry.siri-improvement) echo "${SIRI_NOTIFICATION:-}" ;;
  esac
}

# Waits in the background for one Darwin notification; notification_received says whether it came within 5 seconds.
WATCH_PID=""
watch_notification() { # name, file
  WATCH_PID=""
  [ -n "$1" ] || return 0
  notifyutil -1 "$1" > "$2" 2>&1 &
  WATCH_PID=$!
  sleep 0.5
}
notification_received() {
  local tries=0
  while kill -0 "$WATCH_PID" 2>/dev/null; do
    tries=$((tries + 1))
    if [ $tries -gt 20 ]; then kill "$WATCH_PID" 2>/dev/null; wait "$WATCH_PID" 2>/dev/null; return 1; fi
    sleep 0.25
  done
  wait "$WATCH_PID" 2>/dev/null
  return 0
}

# Sets one control's switch through the app's code, then checks the page, the stored value and the change notification, where known.
flip() { # control, on|off
  local value=false; [ "$2" = on ] && value=true
  local notification; notification=$(notification_for "$1")
  watch_notification "$notification" "$OUT/notify-$1-$2.txt"
  "$CLI" action $DEBLOAT toggle id="$1" value=$value > "$OUT/action-$1-$2.json" 2>> "$OUT/action-$1-$2.log" < /dev/null
  local message; message=$(grep -o '"message" : "[^"]*"' "$OUT/action-$1-$2.json" | head -1 | cut -d'"' -f4)
  local posted=""
  if [ -n "$WATCH_PID" ]; then
    if notification_received; then posted="; posted $notification"; else posted=" NOT-POSTED"; fi
  fi
  local now; now=$(switch_now "$1")
  local stored expected; stored=$(stored_value "$1"); expected=$(expected_value "$1" "$2")
  case "$now" in
    "$2"/*) if [ -n "$expected" ] && [ "$stored" != "$expected" ]; then result FAIL "$1 $2" "the switch says $2 but macOS stores $stored (expected $expected)"
            elif [ "$posted" = " NOT-POSTED" ]; then result FAIL "$1 $2" "saved, but $notification was not posted within 5 seconds"
            else result PASS "$1 $2" "${message}${stored:+; stored $stored}${posted}"; fi ;;
    *) result FAIL "$1 $2" "switch reads ${now%%/*} (${now#*/}); $message" ;;
  esac
}

# Change notifications a framework exports, as "<symbol> <value>" lines (value "-" when it is not a string).
exported_notifications() { # framework binary
  "$DYLD_INFO" -exports "$1" 2>/dev/null | grep -oE '_[A-Za-z0-9_]*(Change|Changed|Update|Updated)[A-Za-z0-9_]*Notification[A-Za-z0-9_]*' \
    | sort -u | sed 's/^_//' | while read -r symbol; do "$CLI" notification "$1" "$symbol" 2>/dev/null; done
}

section "Debloat: profiles of earlier versions"
"$CLI" action $DEBLOAT removeOldProfiles > "$OUT/remove-old-profiles.json" 2>&1 \
  && result PASS "Removed through the helper" "$(grep -o '"message" : "[^"]*"' "$OUT/remove-old-profiles.json" | cut -d'"' -f4)" \
  || result FAIL "Removing them" "see remove-old-profiles.json"

section "Debloat: change notifications of plain settings"
ASSISTANT=/System/Library/PrivateFrameworks/AssistantServices.framework/AssistantServices
SIRI_NOTIFICATION=$("$CLI" notification "$ASSISTANT" kAFPreferencesDidChangeDarwinNotification 2>/dev/null | awk '$2 != "-" { print $2 }')
if [ -n "$SIRI_NOTIFICATION" ]; then result PASS "Improve Siri & Dictation: AssistantServices names its notification" "$SIRI_NOTIFICATION"
else result FAIL "Improve Siri & Dictation: AssistantServices names its notification" "kAFPreferencesDidChangeDarwinNotification is missing or not a string on this build"; fi
DYLD_INFO=$(command -v dyld_info || xcrun -f dyld_info 2>/dev/null)
if [ -z "$DYLD_INFO" ]; then
  result FAIL "Change notifications the frameworks export" "dyld_info not found (it comes with Xcode)"
else
  : > "$OUT/notifications.txt"
  for framework in "$ASSISTANT" /System/Library/PrivateFrameworks/Ad*.framework /System/Library/Frameworks/Ad*.framework; do
    [ -d "$framework" ] || [ -e "$framework" ] || continue
    [ -d "$framework" ] && framework="$framework/$(basename "$framework" .framework)"
    exported_notifications "$framework" | sed "s|^|$(basename "$framework") |" >> "$OUT/notifications.txt"
  done
  ads=$(grep -v '^AssistantServices ' "$OUT/notifications.txt" | awk '$3 != "-"' | grep -iE 'personaliz|advertis|track|adid|privacy|preference|setting|optin|opt_in' )
  result INFO "Change notifications the frameworks export" "$(wc -l < "$OUT/notifications.txt" | tr -d ' ') found, in notifications.txt"
  note ""
  note "Candidates for personalized ads and the ad identifier (the research names none yet):"
  note '```'
  note "${ads:-none found}"
  note '```'
fi

section "Debloat: every switch, off and back on (policies apart)"
"$CLI" screen $DEBLOAT > "$OUT/debloat-before.json" 2>> "$OUT/errors.txt"
debloat_rows "$OUT/debloat-before.json" > "$OUT/debloat-before.txt"
note "Before: $(awk '{ printf "%s=%s ", $2, $3 }' "$OUT/debloat-before.txt")"
while read -r list id state badge; do
  if [ "$list" = policies ]; then result SKIPPED "$id" "a policy: macOS applies it only after a person approves its profile"; continue; fi
  case "$state" in
    disabled) result SKIPPED "$id" "cannot be changed on this Mac (${badge//_/ })" ;;
    on) flip "$id" off; flip "$id" on ;;   # leaves it on, as found
    off) flip "$id" on; flip "$id" off ;;  # leaves it off, as found
  esac
done < "$OUT/debloat-before.txt"
"$CLI" screen $DEBLOAT > "$OUT/debloat-after.json" 2>> "$OUT/errors.txt"
debloat_rows "$OUT/debloat-after.json" > "$OUT/debloat-after.txt"
if diff <(awk '{ print $2, $3 }' "$OUT/debloat-before.txt") <(awk '{ print $2, $3 }' "$OUT/debloat-after.txt") > "$OUT/debloat-diff.txt"; then
  result PASS "Every switch is back where it was"
else result FAIL "Every switch is back where it was" "see debloat-diff.txt"; fi

section "Not tested here"
result SKIPPED "Debloat policies" "macOS needs a person to approve each profile"
result SKIPPED "Siri & Apple Intelligence model removal" "needs Apple Intelligence on first (about 12 GB download)"
result SKIPPED "Sparkle update" "needs a published release"
result SKIPPED "Personalized ads and ad identifier notification" "the research names none yet; candidates are listed above"

note ""
note "**$PASSED passed, $FAILED failed.**"
printf '\n%s passed, %s failed. Send this file back: %s\n' "$PASSED" "$FAILED" "$PWD/$REPORT"
