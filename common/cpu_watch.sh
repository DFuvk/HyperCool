#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Yudharn
# HyperCool - CPU keeper: puts the big/little frequency caps and the prime-core parking back
# when the ROM undoes them. Only started when one of these features was applied at boot.
# Reads $HC_DATA/cpu_keep.list (written by service.sh):
#   node|<scaling_max_freq path>|<cap kHz>|<lock 0/1>   raised above the cap -> written back
#   park|<cpu>|<core_ctl dir>                            core_ctl off / max_cpus raised -> parked again
export PATH=/system/bin:/system/xbin:/vendor/bin:/data/adb/ksu/bin:/data/adb/magisk:"$PATH"
HC_DATA=${HC_DATA:-/data/adb/hypercool}
MODDIR=${MODDIR:-/data/adb/modules/hypercool}
LIST=$HC_DATA/cpu_keep.list
PIDF=$HC_DATA/cpu_watch.pid
STATE=$HC_DATA/cpu_watch.state
STEP=${HC_STEP:-30}
BACKOFF=${HC_BACKOFF:-600}
MAXFIX=5

_old=$(cat "$PIDF" 2>/dev/null)
case "$_old" in ''|*[!0-9]*) ;; *)
  [ "$_old" != "$$" ] && grep -q cpu_watch "/proc/$_old/cmdline" 2>/dev/null && exit 0 ;;
esac
echo $$ > "$PIDF"
trap 'rm -f "$PIDF"; exit 0' INT TERM

num() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
# write even when the node is read-only (0444), then put the mode back
wr() {
  [ -e "$1" ] || return 1
  _m=$(stat -c %a "$1" 2>/dev/null)
  chmod u+w "$1" 2>/dev/null
  _r=0; { echo "$2" > "$1"; } 2>/dev/null || _r=1
  [ -n "$_m" ] && chmod "$_m" "$1" 2>/dev/null
  return $_r
}

TOT=0; WIN=0; WSTART=$(date +%s)
while :; do
  [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ] || [ ! -d "$MODDIR" ] && break
  [ -s "$LIST" ] || break
  _fix=""
  while IFS='|' read -r _t _a _b _c; do
    case "$_t" in
      node)
        num "$_b" || continue
        _cur=$(cat "$_a" 2>/dev/null); num "$_cur" || continue
        # only a value ABOVE the cap is undone (the screen-off profile lowers it on purpose)
        if [ "$_cur" -gt "$_b" ]; then
          if wr "$_a" "$_b"; then
            [ "$_c" = 1 ] && chmod 0444 "$_a" 2>/dev/null
            _fix="$_fix ${_a#/sys/devices/system/cpu/cpufreq/}"
          fi
        fi ;;
      park)
        _d=$_b
        [ -f "$_d/enable" ] && [ -f "$_d/max_cpus" ] || continue
        if [ "$(cat "$_d/enable" 2>/dev/null)" != 1 ] || [ "$(cat "$_d/max_cpus" 2>/dev/null)" != 0 ]; then
          [ -f "$_d/min_cpus" ] && wr "$_d/min_cpus" 0
          wr "$_d/max_cpus" 0
          if wr "$_d/enable" 1; then
            chmod 0444 "$_d/enable" "$_d/min_cpus" "$_d/max_cpus" 2>/dev/null
            _fix="$_fix park-cpu$_a"
          fi
        fi ;;
    esac
  done < "$LIST"
  if [ -n "$_fix" ]; then
    TOT=$((TOT + 1)); WIN=$((WIN + 1))
    echo "fixed=$TOT last=$(date '+%Y-%m-%d %H:%M:%S') what=${_fix# }" > "$STATE"
  fi
  # the ROM keeps undoing it: do not fight it every 30 s
  _now=$(date +%s)
  if [ $((_now - WSTART)) -gt 600 ]; then WIN=0; WSTART=$_now; fi
  if [ "$WIN" -ge "$MAXFIX" ]; then
    echo "fixed=$TOT last=$(date '+%Y-%m-%d %H:%M:%S') backoff=${BACKOFF}s (undone $WIN times in 10 min)" > "$STATE"
    sleep "$BACKOFF"
    WIN=0; WSTART=$(date +%s)
  else
    sleep "$STEP"
  fi
done
rm -f "$PIDF"
exit 0
