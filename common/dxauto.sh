#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Yudharn
# HyperCool - automatic app optimization (dex2oat), sourced by soff_watch.sh and uninstall.sh
# Same job as the WebUI "Optimize apps" card, started by the screen-off keeper: mode of your choice (speed-profile by default), all apps,
# 1 app at a time, NO force recompile (apps that are already optimized are skipped by Android).
# Starts only when: screen off 10 min (keeper), last complete run at least 7 days ago, at most one try per 20 h,
# no other optimization running, no F2FS GC running, battery under 40 C, charging or battery at least 40%.
# Stops (common/dexopt.sh finishes the apps now compiling) when the screen turns on, at 45 C (dexopt.sh), under 15%
# battery or when storage is under 1 GB. Result as a notification (config x_dexopt_notify).
# dxa_check : 0 = start now, 1 = nothing to do this screen-off period, 2 = battery low / too warm / GC running, retry later
# dxa_start [mode] : start the run (background); mode speed-profile (default), speed or everything
# dxa_stop [reason] : ask the run this keeper started to stop (a manual run from the WebUI is never touched)
DXA=${HC_DATA:-/data/adb/hypercool}
HC_SYS=${HC_SYS:-/sys}
HC_PS=${HC_PS:-$HC_SYS/class/power_supply}
HC_PROC=${HC_PROC:-/proc}
DXD=$DXA/dexopt
DXMETA=$DXA/dexopt_auto.meta
DXMARK=$DXA/dexopt_auto.run
DXSH=${HC_DXSH:-${MODDIR:-/data/adb/modules/hypercool}/common/dexopt.sh}
DXGAP=${HC_DXGAP:-604800}
DXTRYGAP=${HC_DXTRYGAP:-72000}
DXHOT=${HC_DXHOT:-400}
DXMINBAT=${HC_DXMINBAT:-40}

dm_get() { sed -n "s/^$1=//p" "$DXMETA" 2>/dev/null | tail -n 1 | tr -d '\r'; }
dm_set() { { grep -v "^$1=" "$DXMETA" 2>/dev/null; echo "$1=$2"; } > "$DXMETA.t" && mv "$DXMETA.t" "$DXMETA"; }
dm_num() { _dx=$(dm_get "$1"); case "$_dx" in ''|*[!0-9]*) _dx=0 ;; esac; echo "$_dx"; }

# an optimization (any) is running
dxa_alive() {
  _dxp=$(cat "$DXD/pid" 2>/dev/null)
  case "$_dxp" in ''|*[!0-9]*) return 1 ;; esac
  grep -q dexopt "$HC_PROC/$_dxp/cmdline" 2>/dev/null
}
dxa_chg() {
  case "$(cat "$HC_PS/battery/status" 2>/dev/null)" in Charging|Full) return 0 ;; esac
  for _dxo in usb ac wireless dc; do
    [ "$(cat "$HC_PS/$_dxo/online" 2>/dev/null)" = 1 ] && return 0
  done
  return 1
}
dxa_pw() {
  dxa_chg && return 0
  _dxl=$(cat "$HC_PS/battery/capacity" 2>/dev/null)
  case "$_dxl" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_dxl" -ge "$DXMINBAT" ]
}
# battery temperature in tenths of a degree; unknown = too warm
dxa_temp() {
  _dxt=$(cat "$HC_PS/battery/temp" 2>/dev/null)
  case "$_dxt" in ''|*[!0-9-]*) echo 999; return ;; esac
  echo "$_dxt"
}
# a finished run of all apps (any mode but reset) counts as this week's run, also one started by hand
dxa_sync() {
  [ -f "$DXD/state" ] || return 0
  grep -q '^phase=done' "$DXD/state" || return 0
  grep -q '^mode=reset' "$DXD/state" && return 0
  grep -q '^scope=all' "$DXD/state" || return 0
  _dxe=$(sed -n 's/^end=//p' "$DXD/state" | tail -n 1)
  case "$_dxe" in ''|*[!0-9]*) return 0 ;; esac
  [ "$_dxe" -gt "$(dm_num last)" ] && dm_set last "$_dxe"
  return 0
}

dxa_check() {
  [ -f "$DXSH" ] || return 1
  dxa_sync
  dxa_alive && return 1
  _dxn=$(date +%s)
  _dxk=$(dm_num last); [ "$_dxk" -gt "$_dxn" ] && _dxk=0
  [ $((_dxn - _dxk)) -ge "$DXGAP" ] || return 1
  _dxk=$(dm_num try); [ "$_dxk" -gt "$_dxn" ] && _dxk=0
  [ $((_dxn - _dxk)) -ge "$DXTRYGAP" ] || return 1
  # the F2FS GC job is running: wait for it
  [ -s "$DXA/f2fs_gc.save" ] && return 2
  [ "$(dxa_temp)" -lt "$DXHOT" ] || return 2
  dxa_pw || return 2
  return 0
}

dxa_start() {
  dm_set try "$(date +%s)"
  dm_set runs "$(( $(dm_num runs) + 1 ))"
  case "$1" in speed|everything) _dxmo=$1 ;; *) _dxmo=speed-profile ;; esac
  HC_DXAUTO=1 sh "$DXSH" run "$_dxmo" 1 0 </dev/null >/dev/null 2>&1 &
  echo $! > "$DXMARK"
}

dxa_stop() {
  [ -f "$DXMARK" ] || return 0
  _dxm=$(cat "$DXMARK" 2>/dev/null)
  case "$_dxm" in ''|*[!0-9]*) rm -f "$DXMARK"; return 0 ;; esac
  if grep -q dexopt "$HC_PROC/$_dxm/cmdline" 2>/dev/null && [ "$(cat "$DXD/pid" 2>/dev/null)" = "$_dxm" ]; then
    [ -e "$DXD/reason" ] || echo "${1:-screen}" > "$DXD/reason"
    sh "$DXSH" stop </dev/null >/dev/null 2>&1
  else
    rm -f "$DXMARK"
  fi
  return 0
}
