#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Yudharn
# HyperCool - hold the charge at a set level (only used when "Hold charge at a set level" is ON)
#   charge_hold.sh find <pct>          first charge-control node of this kernel that accepts a write:
#                                      "threshold|node|start-node" (kernel stops by itself), "suspend|node|hold|release"
#                                      (keeper needed) or "none|<what was tried>"
#   charge_hold.sh run <pct> <gap>     keeper: when a charger is online and the level reaches <pct> the charger input is cut,
#                                      it is let through again at <pct>-<gap>; checked at every battery level event
#   charge_hold.sh restore             put every node back to the value it had (marker charge_hold.save)
# Nodes tried, in this order (none is invented: a node that is missing or not writable is skipped):
#   power_supply/battery/charge_control_end_threshold   (mainline; the kernel does the stopping)
#   power_supply/battery/input_suspend      1 = cut   0 = normal
#   qcom-battery/input_suspend              1 = cut   0 = normal
#   power_supply/battery/charging_enabled   0 = cut   1 = normal
#   power_supply/battery/battery_charging_enabled   0 = cut   1 = normal
# A cut node must really stop the charging (status leaves "Charging" within 10 s), otherwise it is put back and the next one is tried.
# The input is always let through again: when the level falls to <pct>-<gap>, under 30%, during a battery calibration,
# when the keeper stops (switch off, module disabled / removed, uninstall) and at every boot.
export PATH=/system/bin:/system/xbin:/vendor/bin:/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:"$PATH"
HC_DATA=/data/adb/hypercool
MODDIR=/data/adb/modules/hypercool
HC_SYS=${HC_SYS:-/sys}
HC_PS=${HC_PS:-$HC_SYS/class/power_supply}
PIDF=$HC_DATA/charge_hold.pid
STATE=$HC_DATA/charge_hold.state
SAVE=$HC_DATA/charge_hold.save
FIFO=$HC_DATA/charge_hold.fifo
TICK=${HC_CHHTICK:-30}
NEAR=${HC_CHHNEAR:-10}
VER=${HC_CHHVER:-10}
FLOOR=30

num() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }

# write even when a lock (0444) is on the node, then put the lock back
wr() {
  [ -e "$1" ] || return 1
  _m=$(stat -c %a "$1" 2>/dev/null)
  chmod u+w "$1" 2>/dev/null
  _r=0; { echo "$2" > "$1"; } 2>/dev/null || _r=1
  [ -n "$_m" ] && chmod "$_m" "$1" 2>/dev/null
  return $_r
}
# the node exists, holds a number and accepts a write (its own value written back)
usable() {
  [ -e "$1" ] || return 1
  _uv=$(cat "$1" 2>/dev/null)
  num "$_uv" || return 1
  wr "$1" "$_uv"
}
cands() {
  echo "threshold|$HC_PS/battery/charge_control_end_threshold|$1|100"
  echo "suspend|$HC_PS/battery/input_suspend|1|0"
  echo "suspend|$HC_SYS/class/qcom-battery/input_suspend|1|0"
  echo "suspend|$HC_PS/battery/charging_enabled|0|1"
  echo "suspend|$HC_PS/battery/battery_charging_enabled|0|1"
}
# put every saved node back (marker lines: node|value)
restore() {
  [ -s "$SAVE" ] || { rm -f "$SAVE"; return 0; }
  while IFS='|' read -r _n _v; do
    [ -n "$_n" ] && wr "$_n" "$_v"
  done < "$SAVE"
  rm -f "$SAVE"
  return 0
}

case "$1" in
  restore) restore; exit 0 ;;
  find)
    _tried=""
    for _c in $(cands "$2"); do
      _t=${_c%%|*}; _rest=${_c#*|}; _n=${_rest%%|*}
      if usable "$_n"; then
        if [ "$_t" = threshold ]; then
          _sn=$HC_PS/battery/charge_control_start_threshold
          usable "$_sn" || _sn=-
          echo "threshold|$_n|$_sn"
        else
          echo "$_c"
        fi
        exit 0
      fi
      _tried="$_tried ${_n#$HC_SYS/class/}"
    done
    echo "none|$_tried"
    exit 0 ;;
  run) ;;
  *) echo "usage: charge_hold.sh find <pct> | run <pct> <gap> | restore"; exit 2 ;;
esac

PCT=$2; GAP=$3
num "$PCT" && [ "$PCT" -ge 50 ] && [ "$PCT" -le 99 ] || exit 1
num "$GAP" && [ "$GAP" -ge 1 ] && [ "$GAP" -le 15 ] || GAP=3
RES=$((PCT - GAP)); [ "$RES" -lt 1 ] && RES=1

_old=$(cat "$PIDF" 2>/dev/null)
case "$_old" in ''|*[!0-9]*) ;; *)
  [ "$_old" != "$$" ] && grep -q charge_hold "/proc/$_old/cmdline" 2>/dev/null && exit 0 ;;
esac
echo $$ > "$PIDF"

# ---------------------------------------------------------------- battery level events (fifo on fd 3)
EV=0; LP=""
ev_stop() {
  [ -n "$LP" ] && kill "$LP" 2>/dev/null
  LP=""; EV=0
  rm -f "$FIFO" "$FIFO.pid"
}
ev_start() {
  _op=$(cat "$FIFO.pid" 2>/dev/null)
  case "$_op" in ''|*[!0-9]*) ;; *) grep -q battery_level "/proc/$_op/cmdline" 2>/dev/null && kill "$_op" 2>/dev/null ;; esac
  rm -f "$FIFO" "$FIFO.pid"
  command -v logcat >/dev/null 2>&1 && command -v mkfifo >/dev/null 2>&1 || return 1
  echo x | { read -r -t 1 _v 2>/dev/null && [ "$_v" = x ]; } || return 1
  mkfifo "$FIFO" 2>/dev/null || return 1
  ( exec 3<>"$FIFO" ) 2>/dev/null || { rm -f "$FIFO"; return 1; }
  exec 3<>"$FIFO"
  logcat -b events -T 1 -s battery_level >&3 2>/dev/null &
  LP=$!
  echo "$LP" > "$FIFO.pid"
  EV=1
}
# wait for the next battery level event, at most $1 s (a plain sleep when there is no feed)
ev_wait() {
  if [ "$EV" = 1 ]; then
    read -r -t "$1" _l <&3 && return 0
    kill -0 "$LP" 2>/dev/null || ev_stop
    return 0
  fi
  # a trapped TERM interrupts wait at once, a plain sleep would delay it
  sleep "$1" &
  _sp=$!
  wait "$_sp" 2>/dev/null
  kill "$_sp" 2>/dev/null
  return 0
}

online() {
  case "$(cat "$HC_PS/battery/status" 2>/dev/null)" in Charging) return 0 ;; esac
  for _p in usb wireless dc ac; do
    [ "$(cat "$HC_PS/$_p/online" 2>/dev/null)" = 1 ] && return 0
  done
  return 1
}
# a battery calibration (WebUI) needs one charge to 100%
cal() { grep -qE '^phase=(discharge|charge|hold)$' "$HC_DATA/bcal.state" 2>/dev/null; }

NODE=""; HOLD=""; REL=""; VERIFIED=no
BADN=""; FAILED=0; HOLDS=0; LAST=""; HELD=0
state() {
  echo "state=$1 limit=$PCT resume=$RES${NODE:+ node=${NODE#$HC_SYS/class/} verified=$VERIFIED} holds=$HOLDS${LAST:+ last=$LAST}$([ "$FAILED" = 1 ] && echo " failed=no-node-cut-the-charging")" > "$STATE"
}
release() {
  [ "$HELD" = 1 ] || [ -s "$SAVE" ] || return 0
  restore
  HELD=0
  state charging
}
# cut the charger input with the first node that really stops the charging
hold() {
  for _c in $(cands 0); do
    case "${_c%%|*}" in suspend) ;; *) continue ;; esac
    _rest=${_c#*|}; _n=${_rest%%|*}; _rest=${_rest#*|}; _h=${_rest%%|*}; _r=${_rest#*|}
    case " $BADN " in *" $_n "*) continue ;; esac
    usable "$_n" || continue
    _was=$(cat "$HC_PS/battery/status" 2>/dev/null)
    printf '%s|%s\n' "$_n" "$_r" > "$SAVE"
    wr "$_n" "$_h" || { rm -f "$SAVE"; BADN="$BADN $_n"; continue; }
    NODE=$_n; HOLD=$_h; REL=$_r; VERIFIED=no
    if [ "$_was" = Charging ]; then
      _i=0
      while [ "$_i" -lt "$VER" ]; do
        [ "$(cat "$HC_PS/battery/status" 2>/dev/null)" = Charging ] || { VERIFIED=yes; break; }
        sleep 1; _i=$((_i + 1))
      done
      if [ "$VERIFIED" != yes ]; then
        # the charging went on: this node does nothing here
        restore; BADN="$BADN $_n"; NODE=""; continue
      fi
    fi
    HELD=1; HOLDS=$((HOLDS + 1)); LAST=$(date '+%H:%M:%S')
    state holding
    return 0
  done
  FAILED=1; NODE=""; state idle
  return 1
}

trap 'release; ev_stop; rm -f "$PIDF"; exit 0' TERM INT HUP
# a cut left by a keeper that was killed
restore
ev_start
state idle
_lt=0
while :; do
  [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ] || [ ! -d "$MODDIR" ] && break
  _now=$(date +%s)
  if [ $((_now - _lt)) -ge 3 ]; then
    _lt=$_now
    _cap=$(cat "$HC_PS/battery/capacity" 2>/dev/null)
    if ! num "$_cap" || cal; then
      # unknown level or a calibration: never hold
      release
    elif [ "$HELD" = 1 ]; then
      if [ "$_cap" -le "$RES" ] || [ "$_cap" -lt "$FLOOR" ]; then
        release
      elif [ "$(cat "$NODE" 2>/dev/null)" != "$HOLD" ]; then
        # the kernel put it back (plug event): cut again
        wr "$NODE" "$HOLD"
      fi
    elif [ "$FAILED" = 0 ] && [ "$_cap" -ge "$PCT" ] && online; then
      hold
    fi
  fi
  _w=$TICK
  [ "$HELD" = 1 ] || [ "$(cat "$HC_PS/battery/capacity" 2>/dev/null)" -ge $((PCT - 3)) ] 2>/dev/null && _w=$NEAR
  ev_wait "$_w"
done
release
ev_stop
rm -f "$PIDF"
exit 0
