#!/bin/bash
# Walks through everything in MacSpace that has not been tested yet, records what happened, and writes one report to send back.
#
#   Scripts/TestUntested.sh            all sections, in order
#   Scripts/TestUntested.sh release    only one section: release | debloat | downloads | siri
#
# It changes nothing by itself: it reads the state before and after, and you make the changes in MacSpace when it asks. Run it on the
# Mac with MacSpace installed in /Applications. The results go to results/untested-<date>/ in this repository (not committed); send
# report.md from there.
set -uo pipefail
cd "$(dirname "$0")/.."

APP=/Applications/MacSpace.app
CLI="$APP/Contents/MacOS/MacSpaceCli"
OUT="results/untested-$(date +%Y%m%d-%H%M%S)"
REPORT="$OUT/report.md"
SECTION=${1:-all}
mkdir -p "$OUT"
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode-beta.app ]; then export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer; fi

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
note() { printf '%s\n' "$*" >> "$REPORT"; }
result() { # status, item, detail
  printf -- '- **%s** %s%s\n' "$1" "$2" "${3:+ — $3}" >> "$REPORT"
  printf '  %s  %s %s\n' "$1" "$2" "${3:+($3)}"
}
pause() { printf '\n%s\nPress Enter when done. ' "$*"; read -r _; }
# Asks a yes/no question; anything else typed is kept as a note. Records PASS for yes, FAIL for no.
ask() { # item, question
  local answer
  printf '\n%s\n  [y]es / [n]o / or type what you saw: ' "$2"
  read -r answer
  case "$answer" in
    y|Y|yes) result PASS "$1" ;;
    n|N|no) result FAIL "$1" ;;
    "") result SKIPPED "$1" "no answer" ;;
    *) result NOTE "$1" "$answer" ;;
  esac
}
# Saves a module's page (or tile) as MacSpace draws it now.
screen() { "$CLI" screen "$1" ${3:-} > "$OUT/$2.json" 2>> "$OUT/errors.txt"; }
free_bytes() { df -k /System/Volumes/Data | awk 'NR==2 { print $4 * 1024 }'; }
human() { awk -v b="$1" 'BEGIN { split("B KB MB GB TB", u); i = 1; while (b >= 1000 && i < 5) { b /= 1000; i++ } printf "%.2f %s", b, u[i] }'; }

[ -x "$CLI" ] || { echo "MacSpace is not in /Applications. Build it, copy it there, then run this again."; exit 1; }
{
  echo "# MacSpace: untested items"
  echo
  echo "- Date: $(date)"
  echo "- macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
  echo "- App: $(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null) ($(defaults read "$APP/Contents/Info" CFBundleVersion 2>/dev/null))"
  echo "- Section: $SECTION"
} > "$REPORT"

# MARK: Release

release() {
  say "1. Release: signature, notarization, helper"
  note ""; note "## Release"
  codesign -dv --verbose=2 "$APP" > "$OUT/codesign.txt" 2>&1
  if grep -q "Authority=Developer ID Application" "$OUT/codesign.txt"; then result PASS "Signed with Developer ID"; else result FAIL "Signed with Developer ID" "see codesign.txt"; fi
  if grep -q "Runtime Version" "$OUT/codesign.txt"; then result PASS "Hardened runtime"; else result FAIL "Hardened runtime"; fi
  spctl -a -vv "$APP" > "$OUT/spctl.txt" 2>&1
  if grep -q "source=Notarized Developer ID" "$OUT/spctl.txt"; then result PASS "Notarized (Gatekeeper accepts it on any Mac)"
  else result FAIL "Notarized" "$(tr '\n' ' ' < "$OUT/spctl.txt")"; fi
  if xcrun stapler validate "$APP" > "$OUT/stapler.txt" 2>&1; then result PASS "Ticket stapled (opens offline)"; else result FAIL "Ticket stapled" "see stapler.txt"; fi

  "$CLI" helper --ping > "$OUT/helper.txt" 2>&1
  if grep -q "^status: 1" "$OUT/helper.txt" && grep -q "ping ok" "$OUT/helper.txt"; then
    result PASS "Helper installed from a notarized build and answering"
  else
    result FAIL "Helper" "$(head -3 "$OUT/helper.txt" | tr '\n' ' ')"
    pause "In MacSpace → Settings, press Install helper and approve it in System Settings → General → Login Items & Extensions."
    "$CLI" helper --ping > "$OUT/helper-after-install.txt" 2>&1
    if grep -q "ping ok" "$OUT/helper-after-install.txt"; then result PASS "Helper after installing"; else result FAIL "Helper after installing" "$(head -3 "$OUT/helper-after-install.txt" | tr '\n' ' ')"; fi
  fi

  local key
  key=$(defaults read "$APP/Contents/Info" SUPublicEDKey 2>/dev/null)
  if [ -z "$key" ] || [ "$key" = "__SPARKLE_PUBLIC_KEY__" ]; then
    result SKIPPED "Sparkle update from an older build" "this build has no update key (SPARKLE_PUBLIC_KEY); it needs a published release to test"
  else
    result SKIPPED "Sparkle update from an older build" "needs a published release with an appcast; install the previous release, then check for updates"
  fi
}

# MARK: Debloat

DEBLOAT_UNTESTED="ads.personalized-ads-policy ads.advertising-identifier-policy telemetry.siri-server-logging-policy telemetry.on-device-speech-policy suggestions.spotlight-internet-policy ai.features-policy apps.game-center-policy apps.news-policy"

# Prints "<id> <switch on|off> <badge>" for each untested control, from a saved Debloat page.
debloat_states() {
  /usr/bin/python3 - "$1" $DEBLOAT_UNTESTED <<'PY' 2>> "$OUT/errors.txt"
import json, sys
page = json.load(open(sys.argv[1]))
wanted = sys.argv[2:]
found = {}
def walk(node):
    if isinstance(node, dict):
        if node.get("id") in wanted and "isOn" in node:
            badge = node.get("badge") or {}
            found[node["id"]] = ("on" if node["isOn"] else "off", badge.get("text", "-") if isinstance(badge, dict) else "-")
        for value in node.values(): walk(value)
    elif isinstance(node, list):
        for value in node: walk(value)
walk(page)
for control in wanted:
    switch, badge = found.get(control, ("missing", "-"))
    print(control, switch, badge.replace(" ", "_"))
PY
}

news_opens() { # exit 0 when `open -a News` opens News
  if open -a News 2>/dev/null; then sleep 2; osascript -e 'quit app "News"' 2>/dev/null; return 0; fi
  return 1
}

debloat() {
  say "2. Debloat: the 8 controls marked \"Not tested\""
  note ""; note "## Debloat (controls marked Not tested)"
  screen com.macspace.debloat debloat-before
  defaults read com.apple.AdLib > "$OUT/adlib-before.txt" 2>&1
  profiles list > "$OUT/profiles-before.txt" 2>&1
  local news_before=no
  news_opens && news_before=yes
  note "- News opened before: $news_before"

  pause "In MacSpace → Debloat, switch OFF these 8 (one at a time; each says \"Not tested\"):
  Personalized ads, Advertising identifier, Siri server-side logging, Dictation and translation on Apple servers,
  Spotlight internet results, Apple Intelligence features, Game Center, Apple News.
Then approve the MacSpace profile in System Settings → General → Device Management (or Profiles)."
  screen com.macspace.debloat debloat-after
  defaults read com.apple.AdLib > "$OUT/adlib-after.txt" 2>&1
  profiles list > "$OUT/profiles-after.txt" 2>&1

  local id switch badge
  while read -r id switch badge; do
    case "$switch" in
      off) case "$badge" in
             Waiting_for_approval) result FAIL "$id applied" "the MacSpace profile is not approved yet" ;;
             Undone_by_macOS|Not_working|Cannot_take_effect_here) result FAIL "$id applied" "${badge//_/ }" ;;
             *) result PASS "$id applied" "switch off${badge:+, badge ${badge//_/ }}" ;;
           esac ;;
      on) result FAIL "$id applied" "the switch still shows the feature on, badge ${badge//_/ }" ;;
      *) result FAIL "$id applied" "not found on the Debloat page (see debloat-after.json)" ;;
    esac
  done < <(debloat_states "$OUT/debloat-after.json")

  # What each one should change, checked where a script can see it, asked where only you can.
  if diff -q "$OUT/adlib-before.txt" "$OUT/adlib-after.txt" > /dev/null; then result NOTE "Personalized ads: com.apple.AdLib" "unchanged (see adlib-*.txt)"
  else result PASS "Personalized ads: com.apple.AdLib changed" "see adlib-after.txt"; fi
  ask "Personalized ads: locked off" "System Settings → Privacy & Security → Apple Advertising: is Personalized Ads off and locked (greyed)?"
  ask "Spotlight internet results" "Open Spotlight (⌘Space) and type \"weather\": are the web and Siri suggestions gone (only local results)?"
  ask "Apple Intelligence features" "In TextEdit, type a sentence, select it and right-click: is Writing Tools gone from the menu?"
  ask "On-device dictation" "Press the Dictation shortcut and dictate a sentence in your language: does it still work (on device)?"
  note "- Advertising identifier and Siri server-side logging change nothing visible; the switch state above is their test."

  printf '\nGame Center and News take effect after logging out and back in. Have you logged out and back in since switching them off? [y/n] '
  local loggedout; read -r loggedout
  if [ "$loggedout" = y ]; then
    if news_opens; then result FAIL "Apple News blocked" "open -a News still opens it"; else result PASS "Apple News blocked" "open -a News fails"; fi
    ask "Game Center" "System Settings → Game Center: is it unavailable or locked?"
  else
    result PENDING "Game Center and Apple News" "log out and back in, then run: Scripts/TestUntested.sh debloat-logout"
  fi
}

debloat_logout() {
  say "Debloat after logging out: Game Center and News"
  note ""; note "## Debloat after logging out"
  if news_opens; then result FAIL "Apple News blocked" "open -a News still opens it"; else result PASS "Apple News blocked" "open -a News fails"; fi
  ask "Game Center" "System Settings → Game Center: is it unavailable or locked?"
}

# MARK: Downloads you can turn off

downloads() {
  say "3. System Data → Downloads you can turn off: are the steps right?"
  note ""; note "## Steps under Downloads you can turn off"
  ask "Siri voices steps" "Open System Settings → Apple Intelligence & Siri → Siri Voice. Is it there, and can you choose a voice that is not a downloaded premium one?"
  ask "Speech recognition steps" "Open System Settings → Keyboard → Dictation. Can you remove the languages you do not dictate in there?"
  ask "Developer documentation steps" "Open Xcode → Settings. Is the downloaded documentation listed under Components (or Documentation), with a way to remove it?"
  ask "Dictionaries steps" "Open the Dictionary app → Settings. Can you turn off the dictionaries you do not use there?"
}

# MARK: Siri & Apple Intelligence

siri() {
  say "4. Siri & Apple Intelligence: the purge after switching off, and the automatic release of leftover models"
  note ""; note "## Siri & Apple Intelligence"
  local language state
  language=$(defaults read com.apple.assistant.backedup "Session Language" 2>/dev/null)
  screen com.macspace.siri siri-before
  screen com.macspace.siri siri-tile-before --tile
  state=$(grep -o '"AI is [a-z]*"' "$OUT/siri-tile-before.json" | head -1)
  note "- Before: Siri language $language; tile ${state:-unknown}; free $(human "$(free_bytes)")"
  echo "Siri language now: $language. Apple Intelligence: ${state:-unknown}."
  printf '\nThis test needs Apple Intelligence ON first (macOS may download its model, about 12 GB) and then switched OFF in MacSpace.\nRun it now? [y/n] '
  local go; read -r go
  if [ "$go" != y ]; then result SKIPPED "Purge after switching off and automatic release" "not run"; return; fi

  pause "In MacSpace → Siri & Apple Intelligence, switch Apple Intelligence ON and wait until macOS has downloaded the model
(System Settings → Apple Intelligence & Siri shows it ready)."
  local before; before=$(free_bytes)
  pause "Now switch Apple Intelligence OFF in MacSpace and wait for the result message (it waits about 15 s, then removes the models)."
  local after; after=$(free_bytes)
  if [ "$after" -gt "$((before + 500000000))" ]; then result PASS "Purge after switching off" "free space +$(human $((after - before)))"
  else result FAIL "Purge after switching off" "free space changed by $(( (after - before) / 1000000 )) MB"; fi

  say "Watching for 20 minutes: if macOS keeps the models, MacSpace releases them after 10 minutes (keep MacSpace open)."
  echo "time,siri_language,free_bytes,releasing_since,auto_released_at" > "$OUT/siri-timeline.csv"
  local minute
  for minute in $(seq 0 40); do
    printf '%s,%s,%s,%s,%s\n' "$(date +%H:%M:%S)" \
      "$(defaults read com.apple.assistant.backedup "Session Language" 2>/dev/null)" "$(free_bytes)" \
      "$(defaults read com.macspace.app siri.modelsReleasingSince 2>/dev/null)" \
      "$(defaults read com.macspace.app siri.modelsAutoReleasedAt 2>/dev/null)" >> "$OUT/siri-timeline.csv"
    printf '.'
    [ "$minute" -lt 40 ] && sleep 30
  done
  echo
  screen com.macspace.siri siri-after
  local released; released=$(defaults read com.macspace.app siri.modelsAutoReleasedAt 2>/dev/null)
  if [ -n "$released" ]; then result PASS "Automatic release ran" "at $released; see siri-timeline.csv"
  elif awk -F, 'NR > 1 && $4 != "" { found = 1 } END { exit !found }' "$OUT/siri-timeline.csv"; then
    result FAIL "Automatic release" "macOS kept the models but no release ran; see siri-timeline.csv"
  else
    result PASS "No leftover models" "macOS removed the model by itself, so no release was needed"
  fi
  local end; end=$(defaults read com.apple.assistant.backedup "Session Language" 2>/dev/null)
  note "- After: Siri language $end; free $(human "$(free_bytes)")"
  ask "Siri language on the iPhone" "On your iPhone, Settings → Siri → Language: is it the same as on the Mac now ($end)?"
}

case "$SECTION" in
  all) release; debloat; downloads; siri ;;
  release) release ;;
  debloat) debloat ;;
  debloat-logout) debloat_logout ;;
  downloads) downloads ;;
  siri) siri ;;
  *) echo "usage: Scripts/TestUntested.sh [all|release|debloat|debloat-logout|downloads|siri]"; exit 64 ;;
esac

say "Done. Send this file back: $PWD/$REPORT"
echo "(The raw readings are next to it, in $PWD/$OUT.)"
