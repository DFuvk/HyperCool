#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Yudharn
# HyperCool - F2FS garbage collection (sourced by soff_watch.sh, functions.sh and uninstall.sh)
# Same kernel switch the Android idle maintenance uses: /sys/fs/f2fs/<dev>/gc_urgent (1 = collect now, 0 = normal).
# Trigger: "unusable" (4 KB blocks that only GC can give back) >= GCGB GB. Runs only while the screen is off (10 min),
# at most once a week, battery under GCT-5 C; no charger needed, but not charging needs 30% battery.
# Stops when unusable is under the target, after GCTMAX s, at GCT C, under 20% battery, or when the screen turns on.
# gcf_check : 0 = start now, 1 = nothing to do this screen-off period, 2 = battery low / too warm, retry later
# gcf_run   : the GC job (run it in the background)
# gcf_restore [reason] : gc_urgent back to 0, wake lock and fstrim released, marker removed (reason = run was cut)
GCD=${HC_DATA:-/data/adb/hypercool}
HC_SYS=${HC_SYS:-/sys}
HC_PS=${HC_PS:-$HC_SYS/class/power_supply}
HC_PROC=${HC_PROC:-/proc}
GCSTATE=$GCD/f2fs_gc.state
GCMARK=$GCD/f2fs_gc.save
GCMETA=$GCD/f2fs_gc.meta
GCFPID=$GCD/f2fs_gc.fpid
GCGB=${GCGB:-4}
GCTRIM=${GCTRIM:-1}
GCTMAX=${HC_GCTMAX:-420}
GCPOLL=${HC_GCPOLL:-10}
# GCT = battery temperature in C at which a run is stopped (default 45); a run starts only 5 C below that
case "$GCT" in ''|*[!0-9]*) GCT=45 ;; esac
[ "$GCT" -ge 41 ] && [ "$GCT" -le 50 ] || GCT=45
GCSTOP=${HC_GCSTOP:-$((GCT * 10))}
GCHOT=${HC_GCHOT:-$((GCT * 10 - 50))}
GCGAP=${HC_GCGAP:-604800}
GCPAUSE=${HC_GCPAUSE:-604800}
GCTRIMGAP=${HC_GCTRIMGAP:-604800}
GCWL=hypercool_gc

# notification after a run (config f2fs_gc_notify, read live like the cache clean notification; 0 = off)
gcf_post() {
  su -lp 2000 -c "cmd notification post -S bigtext -t 'HyperCool' hc_f2gc '$1'" </dev/null >/dev/null 2>&1 ||
    cmd notification post -S bigtext -t HyperCool hc_f2gc "$1" </dev/null >/dev/null 2>&1
}
# gcf_notify <result> <trim>: needs _u0 _u1 _t0 _te
gcf_notify() {
  [ "$(sed -n 's/^f2fs_gc_notify=//p' "$GCD/config.conf" 2>/dev/null | tail -n 1 | tr -d '\r')" = 0 ] && return 0
  _gnb=$(awk -v m=$((_u0 / 256)) 'BEGIN { printf "%.1f", m / 1024 }')
  _gna=$(awk -v m=$((_u1 / 256)) 'BEGIN { printf "%.1f", m / 1024 }')
  _gns=$((_te - _t0)); if [ "$_gns" -lt 90 ]; then _gnt="${_gns} s"; else _gnt="$(((_gns + 30) / 60)) min"; fi
  case "$1" in
    done|timeout) _gnm="F2FS cleanup done: reclaimable space ${_gnb} GB to ${_gna} GB in ${_gnt}"
      [ "$2" = yes ] && _gnm="$_gnm, fstrim done" ;;
    aborted:battery) _gnm="F2FS cleanup stopped, battery low: reclaimable space ${_gnb} GB to ${_gna} GB" ;;
    aborted:hot) _gnm="F2FS cleanup stopped, battery too warm: reclaimable space ${_gnb} GB to ${_gna} GB" ;;
    aborted:screen-on) _gnm="F2FS cleanup stopped, screen turned on: reclaimable space ${_gnb} GB to ${_gna} GB" ;;
    failed:*) _gnm="F2FS cleanup could not start: this kernel did not accept gc_urgent" ;;
    *) return 0 ;;
  esac
  gcf_post "$_gnm"
}

# directory of the F2FS device that holds /data (empty + status 1 when /data is not F2FS or the nodes are missing)
gcf_dev() {
  if [ -r "$HC_PROC/mounts" ]; then
    _gm=$(grep ' /data f2fs ' "$HC_PROC/mounts" 2>/dev/null | head -n 1)
    [ -n "$_gm" ] || return 1
  else
    _gm=""
  fi
  _gb=$(getprop dev.mnt.blk.data 2>/dev/null)
  _gs=${_gm%% *}; _gs=${_gs##*/}
  for _gc in "$_gb" "$_gs"; do
    [ -n "$_gc" ] || continue
    if [ -f "$HC_SYS/fs/f2fs/$_gc/gc_urgent" ] && [ -f "$HC_SYS/fs/f2fs/$_gc/unusable" ]; then
      echo "$HC_SYS/fs/f2fs/$_gc"; return 0
    fi
  done
  # last resort: the only F2FS device that has both nodes
  _gn=0; _gf=""
  for _gc in "$HC_SYS"/fs/f2fs/*/; do
    _gc=${_gc%/}
    [ -f "$_gc/gc_urgent" ] && [ -f "$_gc/unusable" ] || continue
    _gn=$((_gn + 1)); _gf=$_gc
  done
  [ "$_gn" = 1 ] && { echo "$_gf"; return 0; }
  return 1
}
gcf_unusable() {
  _gv=$(cat "$1/unusable" 2>/dev/null)
  case "$_gv" in ''|*[!0-9]*) return 1 ;; esac
  echo "$_gv"
}
# charging, or plugged in while the charge limit / night charging holds the battery ("Not charging")
gcf_chg() {
  case "$(cat "$HC_PS/battery/status" 2>/dev/null)" in Charging|Full) return 0 ;; esac
  for _go in usb ac wireless dc; do
    [ "$(cat "$HC_PS/$_go/online" 2>/dev/null)" = 1 ] && return 0
  done
  return 1
}
# power condition: charging, or a battery level of at least $1 %
gcf_pw() {
  gcf_chg && return 0
  _gcl=$(cat "$HC_PS/battery/capacity" 2>/dev/null)
  case "$_gcl" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_gcl" -ge "$1" ]
}
# battery temperature in tenths of a degree; 999 when unknown (unknown = treated as too warm)
gcf_temp() {
  _gt=$(cat "$HC_PS/battery/temp" 2>/dev/null)
  case "$_gt" in ''|-) echo 999; return ;; esac
  case "${_gt#-}" in *[!0-9]*) echo 999; return ;; esac
  echo "$_gt"
}
gm_get() { sed -n "s/^$1=//p" "$GCMETA" 2>/dev/null | tail -n 1 | tr -d '\r'; }
gm_set() { { grep -v "^$1=" "$GCMETA" 2>/dev/null; echo "$1=$2"; } > "$GCMETA.t" && mv "$GCMETA.t" "$GCMETA"; }
gm_num() { _gx=$(gm_get "$1"); case "$_gx" in ''|*[!0-9]*) _gx=0 ;; esac; echo "$_gx"; }
# wake lock while the job runs (the phone would suspend and the GC thread with it); it expires by itself
gcf_wl() {
  [ -w "$HC_SYS/power/wake_lock" ] || return 0
  if [ "$1" = 1 ]; then
    { echo "$GCWL $(( (GCTMAX + 300) * 1000000000 ))" > "$HC_SYS/power/wake_lock"; } 2>/dev/null
  else
    { echo "$GCWL" > "$HC_SYS/power/wake_unlock"; } 2>/dev/null
  fi
  return 0
}

gcf_check() {
  _gd=$(gcf_dev) || return 1
  [ "$(cat "$_gd/gc_urgent" 2>/dev/null)" = 0 ] || return 1
  _gu=$(gcf_unusable "$_gd") || return 1
  [ "$_gu" -ge $((GCGB * 262144)) ] || return 1
  _gn=$(date +%s)
  _gl=$(gm_num last); [ "$_gl" -gt "$_gn" ] && _gl=0
  [ $((_gn - _gl)) -ge "$GCGAP" ] || return 1
  [ "$_gn" -lt "$(gm_num pause)" ] && return 1
  gcf_pw 30 || return 2
  [ "$(gcf_temp)" -lt "$GCHOT" ] || return 2
  return 0
}

# state line: needs _u0 _f0 _t0 _u1 _f1 _te; $1 = result, $2 = trim
gcf_state_w() {
  _gpz=""
  if [ "$(gm_num pause)" -gt "$(date +%s)" ]; then
    _gpd=$(date -d "@$(gm_num pause)" '+%Y-%m-%d' 2>/dev/null); _gpz=" paused_until=${_gpd:-7d}"
  fi
  echo "runs=$(gm_num runs) last=$(date '+%Y-%m-%d %H:%M:%S') unusable_mb_before=$((_u0 / 256)) unusable_mb_after=$((_u1 / 256)) free_seg_before=$_f0 free_seg_after=$_f1 secs=$((_te - _t0)) result=$1 trim=$2$_gpz" > "$GCSTATE"
}
gcf_fstrim_stop() {
  _fp=$(cat "$GCFPID" 2>/dev/null)
  case "$_fp" in ''|*[!0-9]*) ;; *) grep -q fstrim "/proc/$_fp/cmdline" 2>/dev/null && kill "$_fp" 2>/dev/null ;; esac
  rm -f "$GCFPID"
}

gcf_run() {
  _gd=$(gcf_dev) || return 1
  _u0=$(gcf_unusable "$_gd") || return 1
  _f0=$(cat "$_gd/free_segments" 2>/dev/null); case "$_f0" in ''|*[!0-9]*) _f0=0 ;; esac
  _t0=$(date +%s)
  # stop target: 1 GB of unusable space, or a quarter of the trigger when that is smaller
  _tg=$((GCGB * 262144 / 4)); [ "$_tg" -gt 262144 ] && _tg=262144
  gm_set runs $(($(gm_num runs) + 1))
  echo "$_u0|$_f0|$_t0|gc" > "$GCMARK"
  gcf_wl 1
  { echo 1 > "$_gd/gc_urgent"; } 2>/dev/null
  if [ "$(cat "$_gd/gc_urgent" 2>/dev/null)" = 0 ]; then
    _u1=$_u0; _f1=$_f0; _te=$(date +%s)
    gcf_state_w failed:gc_urgent -
    gcf_notify failed:gc_urgent -
    gcf_wl 0; rm -f "$GCMARK"
    return 1
  fi
  _res=timeout
  while [ $(($(date +%s) - _t0)) -lt "$GCTMAX" ]; do
    sleep "$GCPOLL"
    _u1=$(gcf_unusable "$_gd") || _u1=$_u0
    [ "$_u1" -le "$_tg" ] && { _res=done; break; }
    gcf_pw 20 || { _res=aborted:battery; break; }
    [ "$(gcf_temp)" -lt "$GCSTOP" ] || { _res=aborted:hot; break; }
  done
  { echo 0 > "$_gd/gc_urgent"; } 2>/dev/null
  _u1=$(gcf_unusable "$_gd") || _u1=$_u0
  _f1=$(cat "$_gd/free_segments" 2>/dev/null); case "$_f1" in ''|*[!0-9]*) _f1=0 ;; esac
  _te=$(date +%s)
  _tr=-
  case "$_res" in
    done|timeout)
      gm_set last "$_te"
      # GC that frees (almost) nothing twice in a row: pause 7 days
      _k=$(gm_num strikes)
      if [ $((_u1 * 100)) -ge $((_u0 * 99)) ]; then
        _k=$((_k + 1))
        [ "$_k" -ge 2 ] && { gm_set pause $((_te + GCPAUSE)); _k=0; }
      else
        _k=0
      fi
      gm_set strikes "$_k"
      _tl=$(gm_num trimlast); [ "$_tl" -gt "$_te" ] && _tl=0
      if [ "$GCTRIM" = 1 ] && [ $((_te - _tl)) -ge "$GCTRIMGAP" ] && command -v fstrim >/dev/null 2>&1; then
        echo "$_u0|$_f0|$_t0|trim" > "$GCMARK"
        gcf_state_w "$_res" running
        if command -v timeout >/dev/null 2>&1; then timeout 180 fstrim /data >/dev/null 2>&1 & else fstrim /data >/dev/null 2>&1 & fi
        echo $! > "$GCFPID"
        wait $!; _rc=$?
        rm -f "$GCFPID"
        if [ "$_rc" = 0 ]; then gm_set trimlast "$(date +%s)"; _tr=yes; else _tr=failed; fi
      elif [ "$GCTRIM" = 1 ]; then
        _tr=skipped
      else
        _tr=off
      fi ;;
  esac
  gcf_state_w "$_res" "$_tr"
  gcf_notify "$_res" "$_tr"
  gcf_wl 0
  rm -f "$GCMARK"
}

gcf_restore() {
  gcf_fstrim_stop
  [ -s "$GCMARK" ] || return 0
  IFS='|' read -r _u0 _f0 _t0 _ph < "$GCMARK"
  _gd=$(gcf_dev) || _gd=""
  if [ -n "$_gd" ]; then
    [ "$(cat "$_gd/gc_urgent" 2>/dev/null)" = 0 ] || { echo 0 > "$_gd/gc_urgent"; } 2>/dev/null
  fi
  if [ -n "$1" ]; then
    case "$_ph" in
      gc)
        case "$_u0$_f0$_t0" in ''|*[!0-9]*) ;; *)
          _u1=$_u0; _f1=$_f0
          [ -n "$_gd" ] && { _u1=$(gcf_unusable "$_gd") || _u1=$_u0; _f1=$(cat "$_gd/free_segments" 2>/dev/null); }
          case "$_f1" in ''|*[!0-9]*) _f1=$_f0 ;; esac
          _te=$(date +%s)
          gcf_state_w "aborted:$1" -
          [ "$1" = screen-on ] && gcf_notify "aborted:$1" - ;;
        esac ;;
      trim)
        [ -f "$GCSTATE" ] && sed 's/ trim=running/ trim=aborted/' "$GCSTATE" > "$GCSTATE.t" && mv "$GCSTATE.t" "$GCSTATE" ;;
    esac
  fi
  gcf_wl 0
  rm -f "$GCMARK"
  return 0
}
