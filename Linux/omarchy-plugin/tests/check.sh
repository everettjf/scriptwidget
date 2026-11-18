#!/bin/bash
# Checks the Omarchy plugin on a live Omarchy session, against the stand-in
# `scriptwidget` in this folder. Run it on the test machine, for example over
# SSH:  bash tests/check.sh
#
# It needs: one monitor at scale 1, sudo without a password (for the virtual
# pointer, pointer.py), and jq, grim, ImageMagick, rsync and foot.
#
# What it changes, and puts back when it ends: it installs this plugin as a
# local plugin and enables it, sets three SCRIPTWIDGET_PLUGIN_* variables in
# the session (so the shell finds the stand-in), restarts the shell a few
# times, moves the bar entry to the left section, and opens one terminal
# window on the test workspace. At the end the plugin is disabled, the
# stand-in is stopped, the variables are emptied and the shell restarted.
# CHECK_WORKSPACE names the workspace to use (default 2); CHECK_KEEP=1 leaves
# everything running for a look.
#
# Exit code: 0 when every check passed, 1 when one failed, 2 when the machine
# cannot run the checks.

set -u
here=$(cd "$(dirname "$0")" && pwd)
source_dir=$(dirname "$here")
id=com.atomsprout.scriptwidget

export LANG=C.UTF-8
export OMARCHY_PATH=${OMARCHY_PATH:-/usr/share/omarchy}
export PATH=$OMARCHY_PATH/bin:$PATH
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
if [ -z "${WAYLAND_DISPLAY:-}" ]; then
  WAYLAND_DISPLAY=$(ls "$XDG_RUNTIME_DIR" | grep -E '^wayland-[0-9]+$' | head -1); export WAYLAND_DISPLAY
fi
if [ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
  HYPRLAND_INSTANCE_SIGNATURE=$(ls -t "$XDG_RUNTIME_DIR/hypr" 2>/dev/null | head -1); export HYPRLAND_INSTANCE_SIGNATURE
fi

T=$XDG_RUNTIME_DIR/scriptwidget-plugin-test
export SCRIPTWIDGET_PLUGIN_FRAMES=$T/frames
sw=$here/scriptwidget
plugin_dir=$HOME/.config/omarchy/plugins/$id
workspace=${CHECK_WORKSPACE:-2}
out=$here/out
tmp=$(mktemp -d)
failures=0
catcher_pid=""

for tool in jq grim magick rsync foot hyprctl omarchy-shell omarchy-restart-shell python3; do
  command -v "$tool" >/dev/null || { echo "cannot run: $tool is missing" >&2; exit 2; }
done
sudo -n true 2>/dev/null || { echo "cannot run: sudo needs a password (the virtual pointer needs /dev/uinput)" >&2; exit 2; }
monitors=$(hyprctl -j monitors)
[ "$(jq length <<< "$monitors")" = 1 ] || { echo "cannot run: these checks are written for one monitor" >&2; exit 2; }
screen=$(jq -r '.[0].name' <<< "$monitors")
W=$(jq -r '.[0].width' <<< "$monitors"); H=$(jq -r '.[0].height' <<< "$monitors")
jq -e '.[0].scale == 1' <<< "$monitors" >/dev/null || { echo "cannot run: these checks are written for scale 1" >&2; exit 2; }
home_workspace=$(hyprctl -j activeworkspace | jq -r .id)

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1${2:+ -- $2}"; failures=$((failures + 1)); }
# check <name> <command...>: passes when the command succeeds.
check() { local name=$1; shift; if "$@"; then pass "$name"; else fail "$name" "${DETAIL:-}"; fi; DETAIL=""; }
skip() { echo "SKIP  $1 -- $2"; }

status() { omarchy-shell "$id" status 2>/dev/null; }
field() { status | jq -r ".$1" 2>/dev/null; }
# until_true <seconds> <command...>
until_true() {
  local deadline=$((SECONDS + $1)); shift
  while ! "$@" >/dev/null 2>&1; do [ $SECONDS -ge $deadline ] && return 1; sleep 0.2; done
}
is() { [ "$(field "$1")" = "$2" ]; }
layers() { hyprctl -j layers | jq -c '[to_entries[] | .key as $m | .value.levels | to_entries[] | .key as $level | .value[] | {monitor: $m, level: $level, namespace, x, y, w, h}]'; }
# widget_layers: "level x y w h" of every widget window, sorted.
widget_layers() { layers | jq -r '.[] | select(.namespace == "scriptwidget") | "\(.level) \(.x) \(.y) \(.w) \(.h)"' | sort; }
has_layer() { widget_layers | grep -qx "$1"; }
layer_count() { layers | jq "[.[] | select(.namespace == \"$1\")] | length"; }
# count_is <namespace> <number>
count_is() { [ "$(layer_count "$1")" = "$2" ]; }
workspace_empty() { [ "$(hyprctl -j workspaces | jq "[.[] | select(.id == $workspace) | .windows] | add // 0")" = 0 ]; }
logged() { grep -qE "$1" "$T/log"; }
clear_log() { : > "$T/log"; }
# The pointer and the screenshots act on whatever workspace is in front, so
# each first makes sure it is the test workspace (something else may have
# switched away in the meantime).
in_front() {
  [ "$(hyprctl -j activeworkspace | jq -r .id)" = "$workspace" ] && return
  hyprctl dispatch "hl.dsp.focus({ workspace = \"$workspace\" })" >/dev/null; sleep 0.5
}
ptr() { in_front; sudo -n python3 "$here/pointer.py" "$W" "$H" "$@"; }
# The pointer first goes somewhere else: a "move" to where it already is moves
# nothing, and the compositor then does not look again at what is under it.
click() { ptr move $(($1 + 9)) $(($2 + 9)) sleep 0.1 move "$1" "$2" sleep 0.3 down up sleep 0.4; }
right_click() { ptr move $(($1 + 9)) $(($2 + 9)) sleep 0.1 move "$1" "$2" sleep 0.3 rdown rup sleep 0.6; }
shot() { in_front; grim -g "$1" "$2"; }
# differ <a.png> <b.png>: true when more than 20 pixels differ.
differ() { local count; count=$(magick compare -metric AE "$1" "$2" null: 2>&1 | awk '{print int($1)}'); [ "${count:-0}" -gt 20 ]; }
# changed_box <a.png> <b.png>: "x y w h" of what differs, inside the pictures.
changed_box() {
  magick "$1" "$2" -compose difference -composite -colorspace gray -threshold 8% -trim -format '%X %Y %w %h' info: 2>/dev/null | tr -d '+'
}
session_env() { hyprctl eval "hl.env(\"$1\", \"$2\")" >/dev/null; }
watch_pid() { cat "$T/watch.pid" 2>/dev/null; }
stop_watch() { local pid; pid=$(watch_pid); [ -n "$pid" ] && kill "$pid" 2>/dev/null; }
connected() { is status running && is widgets "${1:-2}"; }

cleanup() {
  [ -n "$catcher_pid" ] && kill "$catcher_pid" 2>/dev/null
  [ -f "$sw.off" ] && mv "$sw.off" "$sw"
  rm -f "$T/down" "$T/protocol"
  rm -rf "$tmp"
  if [ "${CHECK_KEEP:-0}" = 1 ]; then echo "left running (CHECK_KEEP=1)"; return; fi
  omarchy plugin disable "$id" >/dev/null 2>&1
  sleep 0.5
  stop_watch
  session_env SCRIPTWIDGET_PLUGIN_BIN ""
  session_env SCRIPTWIDGET_PLUGIN_STUDIO_BIN ""
  session_env SCRIPTWIDGET_PLUGIN_FRAMES ""
  omarchy-restart-shell >/dev/null 2>&1
  hyprctl dispatch "hl.dsp.focus({ workspace = \"$home_workspace\" })" >/dev/null
}
trap cleanup EXIT

# ------------------------------------------------------------------ set up

mkdir -p "$out" "$T"
rm -f "$T/down" "$T/protocol" "$T/clicks"
clear_log
session_env SCRIPTWIDGET_PLUGIN_BIN "$sw"
session_env SCRIPTWIDGET_PLUGIN_STUDIO_BIN "$here/scriptwidget-studio"
session_env SCRIPTWIDGET_PLUGIN_FRAMES "$T/frames"
hyprctl dispatch "hl.dsp.focus({ workspace = \"$workspace\" })" >/dev/null
workspace_empty || { echo "cannot run: workspace $workspace is not empty" >&2; exit 2; }

mkdir -p "$plugin_dir"
rsync -a --delete --exclude tests "$source_dir/" "$plugin_dir/"

check "validate: omarchy plugin validate accepts the plugin" omarchy plugin validate "$plugin_dir"
omarchy-shell shell rescanPlugins >/dev/null 2>&1; sleep 1
omarchy plugin enable "$id" >/dev/null 2>&1
check "enable: omarchy plugin list shows it enabled" sh -c "omarchy plugin list | grep -E '^$id +enabled' >/dev/null"
omarchy bar move "$id" --section left >/dev/null 2>&1
# A restart, so the shell has the variables above and the code just copied.
omarchy-restart-shell >/dev/null 2>&1
check "connect: the service runs watch and shows two widgets" until_true 20 connected

# ------------------------------------------------------- layer and geometry

sleep 0.5
DETAIL=$(widget_layers | tr '\n' ';')
check "layer: widget a is on the bottom layer at 80,80 329x170" has_layer "1 80 80 329 170"
check "layer: widget b is on the bottom layer at 460,80 170x170" has_layer "1 460 80 170 170"
check "layer: no other widget window" count_is scriptwidget 2
shot "0,0 1000x420" "$out/1-desktop.png"

check "report: scriptwidget screen <name> <scale> <width> <height>" logged "command screen $screen 1 $W $H\$"
check "report: scriptwidget theme dark or light" logged 'command theme (dark|light)$'

# ---------------------------------------------------------------- pictures

shot "80,80 329x170" "$tmp/a1.png"
"$sw" tap a 1; sleep 0.8
shot "80,80 329x170" "$tmp/a2.png"
check "swap: a new picture file is shown within a second" differ "$tmp/a1.png" "$tmp/a2.png"
"$sw" menu a refresh; sleep 0.8
shot "80,80 329x170" "$tmp/a3.png"
check "swap: a new version under the same file name is shown" differ "$tmp/a2.png" "$tmp/a3.png"

shot "460,80 170x170" "$tmp/b1.png"; sleep 0.3
shot "460,80 170x170" "$tmp/b2.png"
check "frames: the pictures of b change" differ "$tmp/b1.png" "$tmp/b2.png"
check "frames: one widget is animating" is animating 1

# -------------------------------------------------------- taps on the desktop

clear_log
click 244 207
check "tap: a click in the region sends scriptwidget tap a 1" until_true 3 logged 'command tap a 1$'
clear_log
click 120 100; click 545 165
check "tap: clicks outside a region send nothing" [ ! -s "$T/log" ]

# ---------------------------- peek, and clicks passing through to a window

hyprctl dispatch "hl.dsp.exec_cmd(\"foot --app-id=sw-click-catcher $here/click-catcher.sh $T/clicks\")" >/dev/null
until_true 8 sh -c "hyprctl -j clients | jq -e '.[] | select(.class == \"sw-click-catcher\")'"
catcher_pid=$(hyprctl -j clients | jq -r '.[] | select(.class == "sw-click-catcher") | .pid')
if [ -n "$catcher_pid" ] && until_true 5 test -e "$T/clicks"; then
  received() { stat -c %s "$T/clicks"; }
  sleep 0.5
  "$sw" peek
  check "peek: the widgets move to the overlay layer" until_true 3 has_layer "3 460 80 170 170"
  shot "0,0 1000x420" "$out/2-peek-over-window.png"

  # A widget takes the pointer over its whole area (so that a right click on
  # it can open its menu); a click on it never reaches a window below.
  before=$(received); clear_log; click 545 165
  check "on top: a click on a widget without regions stays with the widget" [ "$(received)" = "$before" ]
  before=$(received); click 120 100
  check "on top: a click beside the region stays with the widget" [ "$(received)" = "$before" ]
  no_tap() { ! logged 'command tap'; }
  check "on top: and is not a tap" no_tap
  right_click 545 165
  check "menu: a right click on a widget opens its menu outside arrange mode" until_true 3 is menu true
  check "menu: over the whole screen" until_true 3 count_is scriptwidget-menu 1
  click 1500 900
  check "menu: a click elsewhere closes it" until_true 3 is menu false
  no_menu_word() { ! logged 'command menu'; }
  check "menu: and sends nothing" no_menu_word
  before=$(received); clear_log; click 244 207
  check "pass through: a click in the region is a tap" until_true 3 logged 'command tap a 1$'
  check "pass through: and does not reach the window below" [ "$(received)" = "$before" ]

  "$sw" arrange; until_true 3 is arrange true; sleep 0.5
  before=$(received); click 545 165
  check "pass through: in arrange mode the click stays with the widget" [ "$(received)" = "$before" ]
  "$sw" arrange; until_true 3 is arrange false; sleep 0.4

  "$sw" peek
  check "peek: and back to the bottom layer" until_true 3 has_layer "1 460 80 170 170"

  hyprctl dispatch 'hl.dsp.focus({ window = "class:sw-click-catcher" })' >/dev/null
  hyprctl dispatch 'hl.dsp.window.fullscreen({ mode = "fullscreen" })' >/dev/null
  check "frames: paused behind a fullscreen window" until_true 3 is animating 0
  hyprctl dispatch 'hl.dsp.window.fullscreen({ mode = "fullscreen" })' >/dev/null
  check "frames: running again after it" until_true 3 is animating 1
else
  fail "pass through: the test window did not open"
fi
[ -n "$catcher_pid" ] && kill "$catcher_pid" 2>/dev/null
catcher_pid=""
until_true 5 workspace_empty

# ----------------------------------------------------------------- arrange

"$sw" arrange
check "arrange: the mode event turns arrange mode on" until_true 3 is arrange true
sleep 0.5
check "arrange: one window over the screen shows the widgets" count_is scriptwidget-arrange 1
check "arrange: in place of the widget windows" count_is scriptwidget 0

clear_log
# Held at 150,120, which is 70,40 inside a, and let go at 750,520 in one jump.
ptr move 150 120 sleep 0.3 down sleep 0.2 move 750 520 sleep 0.3 up sleep 0.5
DETAIL=$(grep move "$T/log")
check "arrange: a drag sends scriptwidget move a <screen> 680 480" logged "command move a $screen 680 480\$"

# The dock, where it is mapped, takes a strip at the bottom of the screen.
dock_top=$(layers | jq '[.[] | select(.namespace == "omarchy-dock" and .w > .h and .y > 300) | .y] | min // empty')
floor=${dock_top:-$H}
clear_log
ptr move 500 150 sleep 0.3 down sleep 0.2 move 60 $((H - 5)) sleep 0.3 up sleep 0.5
DETAIL="$(grep move "$T/log") (bottom of the usable area: $floor)"
check "arrange: near the left edge and the bottom it snaps to 16 px from them, above the dock" logged "command move b $screen 16 $((floor - 16 - 170))\$"

clear_log
# Away from every edge nothing snaps: b from 16,<bottom> by its middle to 1000,600.
ptr move 100 $((floor - 100)) sleep 0.3 down sleep 0.2 move 1084 686 sleep 0.3 up sleep 0.5
DETAIL=$(grep move "$T/log")
check "arrange: in the middle of the screen it stays where it is dropped" logged "command move b $screen 1000 600\$"

right_click 1050 650
check "menu: a right click opens the menu" is menu true
shot "600,400 700x460" "$out/3-arrange-menu.png"
clear_log
click 1400 300
check "menu: a click elsewhere closes it and sends nothing" sh -c "[ \"\$(omarchy-shell $id status | jq -r .menu)\" = false ] && ! grep -q 'command menu' '$T/log'"
right_click 1050 650
clear_log
# Rows are 28 px high and start 4 px below the top of the menu: the second.
click 1080 $((650 + 4 + 28 + 14))
DETAIL=$(cat "$T/log")
check "menu: the second row sends scriptwidget menu b resize-medium" until_true 3 logged 'command menu b resize-medium$'

"$sw" arrange
check "arrange: off again" until_true 3 is arrange false
sleep 0.5
DETAIL=$(widget_layers | tr '\n' ';')
# Level 1 is the bottom layer: the stand-in, like the service, has "on top" on
# while arranging, and a widget must not stay on the overlay layer afterwards.
check "arrange: the widget windows are back on the bottom layer, where they were dropped" until_true 3 has_layer "1 680 480 329 170"
check "menu: b now has the medium size" has_layer "1 1000 600 329 170"

# ------------------------------------------------- a display comes and goes

# An earlier version of the plugin made the shell crash here.
shell_now() { pgrep -f 'quickshell -n -p' | head -1; }
crash_count() { ls "$HOME/.cache/quickshell/crashes" 2>/dev/null | wc -l; }
monitor_count_is() { [ "$(hyprctl -j monitors | jq length)" = "$1" ]; }
on_display() { hyprctl -j layers | jq -e --arg m "$1" '.[$m].levels | to_entries[] | .value[] | select(.namespace == "scriptwidget")' >/dev/null; }
shell_before=$(shell_now); crashes_before=$(crash_count)
hyprctl output create headless >/dev/null
if until_true 6 monitor_count_is 2; then
  second=$(hyprctl -j monitors | jq -r --arg s "$screen" '.[] | select(.name != $s) | .name' | head -1)
  sleep 1
  "$sw" move a "$second" 100 100
  check "displays: a widget moved to a second display is shown there" until_true 6 on_display "$second"
  hyprctl output remove "$second" >/dev/null
  until_true 6 monitor_count_is 1
  check "displays: when that display goes away the widget shows on the first one" until_true 8 has_layer "1 100 100 329 170"
  "$sw" move a "$screen" 680 480
  check "displays: and it can be moved back" until_true 6 has_layer "1 680 480 329 170"
  same_shell() { [ "$(shell_now)" = "$shell_before" ]; }
  no_new_crash() { [ "$(crash_count)" = "$crashes_before" ]; }
  check "displays: the shell is still the same process" same_shell
  check "displays: and wrote no crash report" no_new_crash
else
  skip "displays" "could not add a headless display"
fi

# ------------------------------------------------- remove, and bad messages

"$sw" menu b remove
check "remove: the remove event takes the window away" until_true 3 count_is scriptwidget 1

cp "$T/frames/$(ls "$T/frames" | grep '^a-' | head -1)" "$T/outside.png"
good=$T/frames/$(ls "$T/frames" | grep '^a-' | head -1)
"$sw" raw "{\"event\":\"widget\",\"id\":\"x\",\"screen\":\"\",\"x\":900,\"y\":100,\"width\":170,\"height\":170,\"image\":\"$T/outside.png\",\"version\":1,\"regions\":[]}"
"$sw" raw "{\"event\":\"widget\",\"id\":\"y\",\"screen\":\"\",\"x\":900,\"y\":100,\"width\":170,\"height\":170,\"image\":\"$T/frames/../outside.png\",\"version\":1,\"regions\":[]}"
"$sw" raw "{\"event\":\"widget\",\"id\":\"-z\",\"screen\":\"\",\"x\":900,\"y\":100,\"width\":170,\"height\":170,\"image\":\"$good\",\"version\":1,\"regions\":[]}"
"$sw" raw "{\"event\":\"widget\",\"id\":\"w\",\"screen\":\"\",\"x\":900,\"y\":100,\"width\":0,\"height\":170,\"image\":\"$good\",\"version\":1,\"regions\":[]}"
"$sw" raw 'not json at all'
sleep 0.8
check "bad input: pictures outside the frames directory, bad ids and bad sizes are ignored" connected 1
"$sw" raw "{\"event\":\"widget\",\"id\":\"c\",\"screen\":\"no-such-screen\",\"x\":900,\"y\":100,\"width\":170,\"height\":170,\"image\":\"$good\",\"version\":1,\"regions\":[]}"
check "screen: a widget for an unknown screen is shown on the first screen" until_true 3 has_layer "1 900 100 170 170"
"$sw" raw '{"event":"remove","id":"c"}'
until_true 3 count_is scriptwidget 1

# -------------------------------------- service gone and back; the bar entry

bar_strip="0,0 ${W}x40"
click 960 300
shot "$bar_strip" "$tmp/bar-running.png"
old_pid=$(watch_pid)
touch "$T/down"; stop_watch
check "stopped: with the service gone the bar entry knows it is not running" until_true 5 is status stopped
check "stopped: the last picture stays on the desktop" count_is scriptwidget 1
sleep 0.3
shot "$bar_strip" "$tmp/bar-stopped.png"
read -r ix iy iw ih <<< "$(changed_box "$tmp/bar-running.png" "$tmp/bar-stopped.png")"
if [ "${iw:-0}" -ge 4 ] && [ "${iw:-0}" -le 60 ]; then
  pass "bar: the icon looks different while the service is not running"
  icon_x=$((ix + iw / 2)); icon_y=$((iy + ih / 2))
  clear_log
  click "$icon_x" "$icon_y"; sleep 0.5
  shot "0,0 700x300" "$out/5-bar-not-running.png"
  click 960 300
else
  fail "bar: the icon looks different while the service is not running" "changed area: ${ix:-} ${iy:-} ${iw:-} ${ih:-}"
  icon_x=""
fi
rm -f "$T/down"
check "reconnect: the service is found again after it comes back" until_true 25 connected 2
check "reconnect: by a new run of watch" [ "$(watch_pid)" != "$old_pid" ]
check "reconnect: screen and theme are reported again" until_true 3 sh -c "grep -q 'command screen' '$T/log' && grep -q 'command theme' '$T/log'"

if [ -n "$icon_x" ]; then
  clear_log
  click "$icon_x" "$icon_y"
  check "bar: a click opens the management window" until_true 3 logged 'studio opened'
  shot "0,0 440x400" "$tmp/popup-closed.png"
  right_click "$icon_x" "$icon_y"
  shot "0,0 440x400" "$tmp/popup-open.png"
  shot "0,0 700x300" "$out/4-bar-menu.png"
  read -r px py pw ph <<< "$(changed_box "$tmp/popup-closed.png" "$tmp/popup-open.png")"
  if [ "${pw:-0}" -ge 150 ] && [ "${ph:-0}" -ge 120 ]; then
    pass "bar: a right click opens the card with the two switches"
    clear_log
    click $((px + pw / 2)) $((py + ph * 38 / 100))
    check "bar: the first switch runs scriptwidget peek" until_true 3 logged 'command peek'
    check "bar: and the widgets go to the overlay layer" until_true 3 sh -c "hyprctl -j layers | jq -e '.[].levels[\"3\"][] | select(.namespace == \"scriptwidget\")'"
    click $((px + pw / 2)) $((py + ph * 38 / 100))
    check "bar: again, and they are back on the bottom layer" until_true 3 is peek false
    clear_log
    click $((px + pw / 2)) $((py + ph * 76 / 100))
    check "bar: the second switch runs scriptwidget arrange" until_true 3 logged 'command arrange'
    until_true 3 is arrange true
    click $((px + pw / 2)) $((py + ph * 76 / 100))
    check "bar: again, and arrange mode is off" until_true 3 is arrange false
  else
    fail "bar: a right click opens the card with the two switches" "changed area: ${px:-} ${py:-} ${pw:-} ${ph:-}"
  fi
  click 960 300
else
  skip "bar: clicks on the entry" "the icon was not found"
fi

"$sw" bye
check "bye: after a bye event the service counts as not running" until_true 3 is status stopped
check "bye: and watch is run again" until_true 15 connected 2

# ------------------------------------------------------------ not installed

old_pid=$(watch_pid)
mv "$sw" "$sw.off"; kill "$old_pid"
check "missing: a program that cannot be started is reported as not installed" until_true 5 is status missing
check "missing: the pictures stay" count_is scriptwidget 2
mv "$sw.off" "$sw"
check "missing: found again once it is there" until_true 25 connected 2

# --------------------------------------------------------- protocol mismatch

echo 2 > "$T/protocol"; stop_watch
check "protocol: hello with protocol 2 is refused" until_true 10 is status outdated
check "protocol: nothing is shown on the desktop" until_true 3 count_is scriptwidget 0
if [ -n "$icon_x" ]; then
  click "$icon_x" "$icon_y"; sleep 0.5
  shot "0,0 700x300" "$out/6-bar-please-update.png"
  click 960 300
fi
rm -f "$T/protocol"; stop_watch
check "protocol: with protocol 1 again the widgets are back" until_true 25 connected 2

# ------------------------------------------------------------ shell restart

old_pid=$(watch_pid)
omarchy-restart-shell >/dev/null 2>&1
check "restart: after omarchy-restart-shell the widgets are back" until_true 25 connected 2
check "restart: the old watch was ended and a new one started" sh -c "! kill -0 $old_pid 2>/dev/null && [ \"\$(cat $T/watch.pid)\" != $old_pid ]"
sleep 0.5
check "restart: two widget windows on the bottom layer" [ "$(widget_layers | grep -c '^1 ')" = 2 ]

# ------------------------------------------------------------------ disable

if [ "${CHECK_KEEP:-0}" != 1 ]; then
  old_pid=$(watch_pid)
  omarchy plugin disable "$id" >/dev/null 2>&1
  check "disable: the widget windows go away" until_true 5 count_is scriptwidget 0
  check "disable: watch is ended" until_true 5 sh -c "! kill -0 $old_pid 2>/dev/null"
fi

echo
if [ "$failures" = 0 ]; then echo "all checks passed"; else echo "$failures failed"; fi
[ "$failures" = 0 ]
