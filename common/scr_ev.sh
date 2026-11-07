# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Yudharn
# HyperCool - screen state for the keepers (sourced). Android's screen_toggled events give the
# state (0 = off, AOD included) and let a keeper sleep until it changes; without them the panel
# backlight is polled.

SCR_BL=""
for _b in /sys/class/backlight/*/brightness /sys/class/leds/lcd-backlight/brightness; do
  [ -f "$_b" ] && { SCR_BL=$_b; break; }
done
bl_off() {
  [ -n "$SCR_BL" ] || return 1
  read -r _v < "$SCR_BL" 2>/dev/null
  [ "$_v" = 0 ]
}
# some panels (OLED brightness set by the display driver) keep the node at 0 while the screen is on:
# such a node can't tell on from off, so stop using it
SCR_BLBAD=0
bl_bad() { SCR_BL=""; SCR_BLBAD=1; }
# at start: node at 0 while Android says the screen is awake = unreliable node
bl_check() {
  bl_off || return 0
  dumpsys power 2>/dev/null | grep -q 'mWakefulness=Awake' && bl_bad
  return 0
}
scr_off() {
  if [ "$EV" = 1 ] && [ -n "$EV_VAL" ]; then
    [ "$EV_VAL" = 0 ]
  elif [ -n "$SCR_BL" ]; then
    bl_off
  else
    dumpsys power 2>/dev/null | grep -qE 'mWakefulness=(Asleep|Dozing)'
  fi
}
# The event feed and the panel node can be wrong (an event replayed at start, a node that stays 0
# while the screen is on): ask the power service too when the screen state decides an action.
scr_awake() { dumpsys power 2>/dev/null | grep -q 'mWakefulness=Awake'; }
scr_off_real() {
  scr_off || return 1
  if scr_awake; then
    # the panel node says off while the power service says the screen is on: stop trusting it
    # (only when the state came from that node, not from a screen event)
    [ -z "$EV_VAL" ] && [ -n "$SCR_BL" ] && bl_bad
    return 1
  fi
  return 0
}

EV=0; EV_VAL=""; EV_PID=""; EV_FIFO=""
ev_stop() {
  [ -n "$EV_PID" ] && kill "$EV_PID" 2>/dev/null
  EV_PID=""; EV=0; EV_VAL=""
  [ -n "$EV_FIFO" ] && rm -f "$EV_FIFO" "$EV_FIFO.pid"
}
# ev_start <fifo>: logcat feed of screen_toggled into a fifo on fd 3 (EV=1 when it runs)
ev_start() {
  EV_FIFO=$1
  # a feed left by a keeper that was killed hard
  _op=$(cat "$EV_FIFO.pid" 2>/dev/null)
  case "$_op" in ''|*[!0-9]*) ;; *) grep -q screen_toggled "/proc/$_op/cmdline" 2>/dev/null && kill "$_op" 2>/dev/null ;; esac
  rm -f "$EV_FIFO" "$EV_FIFO.pid"
  command -v logcat >/dev/null 2>&1 && command -v mkfifo >/dev/null 2>&1 || return 1
  echo x | { read -r -t 1 _v 2>/dev/null && [ "$_v" = x ]; } || return 1
  mkfifo "$EV_FIFO" 2>/dev/null || return 1
  ( exec 3<>"$EV_FIFO" ) 2>/dev/null || { rm -f "$EV_FIFO"; return 1; }
  exec 3<>"$EV_FIFO"
  logcat -b events -T 1 -s screen_toggled >&3 2>/dev/null &
  EV_PID=$!
  echo "$EV_PID" > "$EV_FIFO.pid"
  EV=1
  # -T 1 replays the last buffered event: it can be from before the keeper started (the screen was
  # off then), so drop it and take the screen state right now from the power service
  read -r -t 1 _l <&3 2>/dev/null
  EV_VAL=""
  case "$(dumpsys power 2>/dev/null)" in
    *mWakefulness=Awake*) EV_VAL=1 ;;
    *mWakefulness=Asleep*|*mWakefulness=Dozing*) EV_VAL=0 ;;
  esac
}
# ev_line <line>: keep the value of a screen_toggled line (anything but 0 = on)
ev_line() {
  case "$1" in *screen_toggled*) ;; *) return 1 ;; esac
  _x=${1##*:}
  case "$_x" in *[!0\ ]*) EV_VAL=1 ;; *) EV_VAL=0 ;; esac
}
# ev_wait <max s> <poll s>: returns after a line from the feed or a timeout; the caller re-checks
# scr_off. Until the first event arrives the state comes from the backlight, every <poll s>.
ev_wait() {
  _ps=$2
  # no backlight node: every check is a dumpsys call, so check less often
  [ -z "$SCR_BL" ] && [ "$_ps" -lt 10 ] && _ps=10
  if [ "$EV" = 1 ]; then
    _t=$1
    [ -n "$EV_VAL" ] || _t=$_ps
    if read -r -t "$_t" _l <&3; then
      ev_line "$_l"
      return 0
    fi
    # logcat gone: back to polling the backlight
    kill -0 "$EV_PID" 2>/dev/null || ev_stop
    return 0
  fi
  sleep "$_ps"
}
