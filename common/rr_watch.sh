#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Yudharn
# HyperCool - touch-only refresh rate keeper: <active Hz> <idle Hz> <hold s> [miui 0|1]
# Peak refresh rate = idle Hz (so screen content can't raise it); a touch or a key press sets the
# active Hz, and the idle Hz comes back <hold s> after the last finger is lifted. It sleeps in a
# blocking read on getevent (touch down/up and key lines only), so it uses no CPU while idle.
# HyperOS / MIUI ignore peak_refresh_rate: their own limit is secure miui_refresh_rate, set too.
export PATH=/system/bin:/system/xbin:/vendor/bin:/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:"$PATH"
HC_DATA=/data/adb/hypercool
MODDIR=/data/adb/modules/hypercool
ACT=$1; IDL=$2; HOLD=${3:-1}; MIUI=${4:-0}
PIDF=$HC_DATA/rr_watch.pid
F1=$HC_DATA/rr_watch.raw
F2=$HC_DATA/rr_watch.fifo

_old=$(cat "$PIDF" 2>/dev/null)
case "$_old" in ''|*[!0-9]*) ;; *)
  [ "$_old" != "$$" ] && grep -q rr_watch "/proc/$_old/cmdline" 2>/dev/null && kill "$_old" 2>/dev/null; sleep 1 ;;
esac
echo $$ > "$PIDF"

CUR=""
# the value is read back: a rejected write is not counted, so it is tried again
_hz_now() { # -> the peak rate that is really set right now (Hz, without decimals)
  _hz=$(settings get system peak_refresh_rate 2>/dev/null)
  case "$_hz" in ''|null) return 1 ;; esac
  _hz=${_hz%%.*}
  case "$_hz" in ''|*[!0-9]*) return 1 ;; esac
  echo "$_hz"
}
put() {
  [ "$CUR" = "$1" ] && return 0
  cmd settings put system peak_refresh_rate "$1.0" </dev/null >/dev/null 2>&1 ||
    settings put system peak_refresh_rate "$1.0" </dev/null >/dev/null 2>&1
  _ok=0
  [ "$(_hz_now)" = "$1" ] && _ok=1
  if [ "$MIUI" = 1 ] && [ "$_ok" = 1 ]; then
    cmd settings put secure miui_refresh_rate "$1" </dev/null >/dev/null 2>&1 ||
      settings put secure miui_refresh_rate "$1" </dev/null >/dev/null 2>&1
    [ "$(settings get secure miui_refresh_rate 2>/dev/null)" = "$1" ] || _ok=0
  fi
  [ "$_ok" = 1 ] || return 1
  CUR=$1
  return 0
}
PIDS=""
stop() {
  # shellcheck disable=SC2086
  [ -n "$PIDS" ] && kill $PIDS 2>/dev/null
  rm -f "$F1" "$F2"
  # back to the normal adaptive range (the boot apply or the restore takes it from here)
  put "$ACT" || { sleep 1; put "$ACT"; }
  [ "$(cat "$PIDF" 2>/dev/null)" = "$$" ] && rm -f "$PIDF"
  exit 0
}
trap stop TERM INT HUP

# input devices with a touchscreen or keys (power / volume); getevent watches only those
DEVS=$(getevent -pl 2>/dev/null | awk '/^add device/ { d = $NF } /BTN_TOUCH|ABS_MT_POSITION_X|KEY_POWER|KEY_VOLUMEDOWN/ { if (d != "" && !(d in s)) { s[d] = 1; print d } }')
[ -n "$DEVS" ] || { echo "no touch / key input device" > "$HC_DATA/rr_watch.state"; rm -f "$PIDF"; exit 1; }

rm -f "$F1" "$F2"
mkfifo "$F1" "$F2" || { rm -f "$PIDF"; exit 1; }
exec 3<>"$F2"
GPID=""
if echo BTN_TOUCH | grep --line-buffered -qE 'BTN_TOUCH' 2>/dev/null; then
  # getevent output is unbuffered; grep passes on only touch down/up and key lines
  grep --line-buffered -E 'BTN_TOUCH|ABS_MT_TRACKING_ID|EV_KEY +KEY_' < "$F1" >&3 2>/dev/null &
  PIDS=$!
  GPID=$!
  exec 4<>"$F1"
else
  # no line-buffered grep: every event line comes to the loop (a bit more CPU while touching)
  exec 4>&3
fi
for _d in $DEVS; do
  getevent -ql "$_d" >&4 2>/dev/null &
  PIDS="$PIDS $!"
done
exec 4>&-
echo "devices=$(echo $DEVS) active=$ACT idle=$IDL hold=${HOLD}s miui=$MIUI" > "$HC_DATA/rr_watch.state"

put "$IDL"
down=0; btn=0
while :; do
  # at most a minute without an event, so that a disabled module is noticed quickly
  if [ "$down" = 0 ] && [ "$CUR" = "$IDL" ]; then _t=60; elif [ "$down" = 1 ]; then _t=60; else _t=$HOLD; fi
  # shellcheck disable=SC3045
  if read -r -t "$_t" _l <&3; then
    case "$_l" in
      *BTN_TOUCH*DOWN*) btn=1; down=1; put "$ACT" ;;
      *BTN_TOUCH*UP*) btn=1; down=0 ;;
      *ABS_MT_TRACKING_ID*)
        # touchscreens that never send BTN_TOUCH: a tracking id starts a touch, ffffffff ends it
        [ "$btn" = 1 ] && continue
        case "$_l" in *ffffffff*) down=0 ;; *) down=1; put "$ACT" ;; esac ;;
      *KEY_*DOWN*) put "$ACT" ;;
    esac
    continue
  fi
  # timeout: no touch for <hold s> -> idle rate
  [ "$down" = 0 ] && put "$IDL"
  [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ] || [ ! -d "$MODDIR" ] && stop
  grep -q '^rr_adapt=1' "$HC_DATA/config.conf" 2>/dev/null || stop
  # the event feed died (all getevent gone): nothing more to watch
  _alive=0
  for _p in $PIDS; do [ -d "/proc/$_p" ] && _alive=1; done
  [ "$_alive" = 1 ] || stop
  # the filter process died: the touch events would no longer come through, so stop instead of
  # keeping a rate that never changes again
  [ -n "$GPID" ] && { kill -0 "$GPID" 2>/dev/null || stop; }
done
