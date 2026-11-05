#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Yudharn
# HyperCool - charge level calibration (runs ONLY when started from the WebUI)
export PATH=/system/bin:/system/xbin:/vendor/bin:/data/adb/ksu/bin:/data/adb/magisk:"$PATH"

HC_DATA=/data/adb/hypercool
B=/sys/class/power_supply/battery
N=$B/charge_control_limit
OUT=$HC_DATA/charge_levels.conf
TMP=$HC_DATA/.charge_levels.tmp
PROG=$HC_DATA/charge_cal.progress
LOCK=$HC_DATA/.charge_cal.lock

prog() { echo "$*" > "$PROG"; }

# single instance (stale lock = dead PID)
if [ -f "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then
  exit 0
fi
echo $$ > "$LOCK"

ORIG=$(cat "$N" 2>/dev/null)
DONE=0
# shellcheck disable=SC2329
finish() {
  [ -n "$ORIG" ] && { echo "$ORIG" > "$N"; } 2>/dev/null
  # stopped early: let the WebUI stop polling
  if [ "$DONE" != 1 ] && ! grep -q '^error|' "$PROG" 2>/dev/null; then prog "error|interrupted"; fi
  rm -f "$LOCK" "$TMP"
}
trap finish EXIT
trap 'exit 1' INT TERM

MAX=$(cat $B/charge_control_limit_max 2>/dev/null)
case "$MAX" in ''|*[!0-9]*|0) prog "error|no charge_control_limit on this kernel"; exit 1 ;; esac
[ "$(cat $B/status 2>/dev/null)" = "Charging" ] || { prog "error|plug in the fast charger first"; exit 1; }

# average current_now over N seconds in mA, signed (current_now is in uA)
meas() {
  _s=0; _n=0; _i=0
  while [ "$_i" -lt "$1" ]; do
    _v=$(cat $B/current_now 2>/dev/null)
    case "$_v" in ''|-|*[!0-9-]*) ;; *)
      _s=$((_s + _v / 1000)); _n=$((_n + 1)) ;;
    esac
    sleep 1; _i=$((_i + 1))
  done
  [ "$_n" -gt 0 ] && echo $((_s / _n)) || echo 0
}
# charging direction differs per device: taken from level 0 (full charging)
SIGN=1

T0=$(( $(cat $B/temp 2>/dev/null || echo 0) / 10 ))
C0=$(cat $B/capacity 2>/dev/null)
{
  echo "# HyperCool charge level calibration $(date '+%Y-%m-%d %H:%M')"
  echo "# start: ${C0}% ${T0}C, levels 0..$((MAX - 1)) of $MAX (level=mA)"
} > "$TMP"

L=0
while [ "$L" -lt "$MAX" ]; do
  prog "run|$L|$MAX"
  if [ "$(cat $B/status 2>/dev/null)" != "Charging" ]; then
    prog "error|charger was unplugged at level $L"; exit 1
  fi
  { echo "$L" > "$N"; } 2>/dev/null
  sleep 12
  MA=$(meas 8)
  if [ "$L" = 0 ] && [ "$MA" -lt 0 ]; then SIGN=-1; fi
  MA=$((MA * SIGN))
  # current flowing out of the battery = this level does not charge at all
  [ "$MA" -lt 0 ] && MA=0
  RB=$(cat "$N" 2>/dev/null)
  if [ "$RB" != "$L" ]; then
    echo "# level $L overridden (reads $RB) - thermal daemon active" >> "$TMP"
  fi
  echo "$L=$MA" >> "$TMP"
  L=$((L + 1))
done

T1=$(( $(cat $B/temp 2>/dev/null || echo 0) / 10 ))
echo "# end: $(cat $B/capacity 2>/dev/null)% ${T1}C" >> "$TMP"
mv -f "$TMP" "$OUT"
DONE=1
prog "done|$MAX"
exit 0
