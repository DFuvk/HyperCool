#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Yudharn
# HyperCool - screen-off keeper: power profile (PROF=1: lower CPU/GPU limits while the screen is off)
# Wi-Fi keep (WIFI=1: turn Wi-Fi on again when the ROM switches it off while the screen is off) and
# background app compaction (COMPACT=1: common/compact.sh, 90 s after the screen goes off, low RAM only)
# and Location / Bluetooth off after a long screen-off (RADIO=1, RBT=1 adds Bluetooth, RMIN minutes: common/radio.sh)
# and automatic app optimization (DXF=1, DXM mode: dex2oat, screen off 10 min, once a week, no force recompile: common/dxauto.sh)
# and F2FS garbage collection (GCF=1: screen off 10 min, once a week, battery under GCT-5 C; GCGB trigger in GB, GCTRIM=1 adds fstrim, GCT stop temperature: common/f2gc.sh)
PCT=$1 GPU=$2 BST=$3 TCH=$4 CAP=${5:-0} PROF=${6:-1} WIFI=${7:-0} COMPACT=${8:-0} RADIO=${9:-0} RBT=${10:-0} RMIN=${11:-15} GCF=${12:-0} GCGB=${13:-4} GCTRIM=${14:-1} GCT=${15:-45} DXF=${16:-0} DXM=${17:-speed-profile}
HC_DATA=/data/adb/hypercool
MODDIR=/data/adb/modules/hypercool
PIDF=$HC_DATA/soff_watch.pid
STATE=$HC_DATA/soff_watch.state
SAVE=$HC_DATA/soff_watch.save

case "$PCT" in ''|*[!0-9]*) exit 1 ;; esac
case "$CAP" in ''|*[!0-9]*) CAP=0 ;; esac
_old=$(cat "$PIDF" 2>/dev/null)
case "$_old" in ''|*[!0-9]*) ;; *)
  [ "$_old" != "$$" ] && grep -q soff_watch "/proc/$_old/cmdline" 2>/dev/null && exit 0 ;;
esac
echo $$ > "$PIDF"

. "$MODDIR/common/scr_ev.sh"
CDELAY=${HC_CDELAY:-90}; CCOOL=${HC_CCOOL:-1200}
[ "$COMPACT" = 1 ] && . "$MODDIR/common/compact.sh"
case "$RMIN" in ''|*[!0-9]*) RMIN=15 ;; esac
RDELAY=${HC_RDELAY:-$((RMIN * 60))}
RSAVE=$HC_DATA/soff_radio.save
if [ -f "$MODDIR/common/radio.sh" ]; then . "$MODDIR/common/radio.sh"; else radio_off() { :; }; radio_restore() { :; }; fi
case "$GCGB" in ''|*[!0-9]*) GCGB=4 ;; esac
[ "$GCGB" -ge 1 ] && [ "$GCGB" -le 15 ] || GCGB=4
GCDELAY=${HC_GCDELAY:-600}; GCRETRY=${HC_GCRETRY:-300}; GCTRIES=${HC_GCTRIES:-12}
DXDELAY=${HC_DXDELAY:-600}; DXRETRY=${HC_DXRETRY:-300}; DXTRIES=${HC_DXTRIES:-12}
if [ "$DXF" = 1 ] && [ -f "$MODDIR/common/dxauto.sh" ]; then . "$MODDIR/common/dxauto.sh"; else DXF=0; dxa_stop() { :; }; fi
if [ "$GCF" = 1 ] && [ -f "$MODDIR/common/f2gc.sh" ]; then . "$MODDIR/common/f2gc.sh"; else GCF=0; gcf_restore() { :; }; fi

# write even when a lock (0444) is on the node, then put the lock back
wr() {
  [ -e "$1" ] || return 1
  _m=$(stat -c %a "$1" 2>/dev/null)
  chmod u+w "$1" 2>/dev/null
  _r=0; { echo "$2" > "$1"; } 2>/dev/null || _r=1
  [ -n "$_m" ] && chmod "$_m" "$1" 2>/dev/null
  return $_r
}
# save the value to put back (default: the current one), then write the screen-off value
put() {
  [ -e "$1" ] || return 1
  _cv=$(cat "$1" 2>/dev/null)
  [ -n "$_cv" ] || return 1
  [ "$_cv" = "$2" ] && return 0
  printf '%s|%s\n' "$1" "${3:-$_cv}" >> "$SAVE"
  wr "$1" "$2"
}
# highest frequency <= $2 in the policy table $1 (or $2 itself)
snap() {
  _s=0
  # shellcheck disable=SC2013
  for _f in $(cat "$1/scaling_available_frequencies" 2>/dev/null); do
    [ "$_f" -le "$2" ] && [ "$_f" -gt "$_s" ] && _s=$_f
  done
  [ "$_s" = 0 ] && _s=$2
  echo "$_s"
}

little_policy() {
  _lm=999999999; _lp=""
  for _p in /sys/devices/system/cpu/cpufreq/policy*; do
    _m=$(cat "$_p/cpuinfo_max_freq" 2>/dev/null); [ -n "$_m" ] || continue
    if [ "$_m" -lt "$_lm" ]; then _lm=$_m; _lp=$_p; fi
  done
  echo "$_lp"
}

apply_off() {
  : > "$SAVE"
  _al=""
  _lp=$(little_policy)
  for _p in /sys/devices/system/cpu/cpufreq/policy*; do
    _m=$(cat "$_p/cpuinfo_max_freq" 2>/dev/null); [ -n "$_m" ] || continue
    [ "$_p" = "$_lp" ] && continue
    _s=$(snap "$_p" $((_m * PCT / 100)))
    # put back the Big-core cap or the full range: scaling_max_freq reads the limit after thermal,
    # so the value read now may be a temporary thermal limit
    _b=$_m
    [ "$CAP" -gt 0 ] && _b=$(snap "$_p" $((_m * CAP / 100)))
    [ "$_b" -le "$_s" ] && continue
    _c=$(cat "$_p/scaling_max_freq" 2>/dev/null)
    case "$_c" in ''|*[!0-9]*) continue ;; esac
    [ "$_c" -gt "$_s" ] && put "$_p/scaling_max_freq" "$_s" "$_b" && _al="$_al${_al:+,}${_p##*/}:$((_s / 1000))"
  done
  if [ "$GPU" = 1 ]; then
    K=/sys/class/kgsl/kgsl-3d0
    if [ -f "$K/max_pwrlevel" ] && [ -f "$K/min_pwrlevel" ]; then
      put "$K/max_pwrlevel" "$(cat "$K/min_pwrlevel" 2>/dev/null)" && _al="$_al${_al:+,}gpu:lowest"
    else
      for _d in /sys/class/devfreq/*; do
        case "${_d##*/}" in *mali*|*gpu*|*GPU*) ;; *) continue ;; esac
        [ -f "$_d/available_frequencies" ] && [ -f "$_d/max_freq" ] || continue
        _lo=$(tr ' ' '\n' < "$_d/available_frequencies" | grep -E '^[1-9][0-9]*$' | sort -n | head -n 1)
        [ -n "$_lo" ] && put "$_d/max_freq" "$_lo"
        break
      done
    fi
  fi
  if [ "$BST" = 1 ]; then
    # Qualcomm WALT
    put /proc/sys/walt/sched_boost 0
    for _p in /sys/devices/system/cpu/cpufreq/policy*/walt/pl; do put "$_p" 0; done
    # MediaTek FPSGO frame boosting (0 = off)
    put /sys/kernel/fpsgo/common/force_onoff 0
  fi
  if [ "$TCH" = 1 ]; then
    put /proc/sys/walt/input_boost/input_boost_ms 0
    put /sys/module/cpu_boost/parameters/input_boost_ms 0
  fi
}

# Wi-Fi keep: the state at the moment the screen goes off is what the user wants (Wi-Fi switched off
# with the screen on stays off). Checked on every wake-up while the screen is off.
wifi_now() {
  _wo=$(cmd wifi status </dev/null 2>/dev/null | head -n 3)
  case "$_wo" in
    *"Wifi is enabled"*) echo on; return ;;
    *"Wifi is disabled"*) echo off; return ;;
  esac
  case "$(settings get global wifi_on 2>/dev/null)" in 1) echo on ;; 0) echo off ;; *) echo ? ;; esac
}
_want=off; _whold=0; _wrec=""; _wcnt=0; _wlast=""; _wpause=""
wifi_check() {
  [ "$_want" = on ] || return 0
  _wn=$(date +%s)
  [ "$_wn" -lt "$_whold" ] && return 0
  [ "$(wifi_now)" = off ] || return 0
  [ "$(settings get global airplane_mode_on 2>/dev/null)" = 1 ] && return 0
  # only ever act while the screen is really off: a stale screen event or a panel node that stays 0
  # while the screen is on must not turn Wi-Fi back on while you are using the phone
  scr_off_real || return 0
  # let the ROM finish its own change, then look again
  sleep 2
  [ "$(wifi_now)" = off ] || return 0
  scr_off_real || return 0
  # 3 re-enables in 10 min: the ROM keeps switching it off, pause 5 min
  _wk=""; _wc=0
  for _wt in $_wrec; do
    [ $((_wn - _wt)) -lt 600 ] && { _wk="$_wk $_wt"; _wc=$((_wc + 1)); }
  done
  if [ "$_wc" -ge 3 ]; then
    _whold=$((_wn + 300)); _wrec=""; _wpause=$((${_wpause:-0} + 1)); note ""
    return 0
  fi
  svc wifi enable </dev/null >/dev/null 2>&1
  _wrec="$_wk $_wn"; _wcnt=$((_wcnt + 1)); _wlast=$(date '+%H:%M:%S'); note ""
}

# at most one check per 2 s when screen and link events are flowing, else once per 60 s (polling fallback)
_wchk=0
wifi_tick() {
  _wm=60; [ "$EV" = 1 ] && [ -n "$EV_VAL" ] && _wm=${HC_WMIN:-2}
  _tn=$(date +%s)
  [ $((_tn - _wchk)) -ge "$_wm" ] || return 0
  _wchk=$_tn
  wifi_check
}
# Wi-Fi link changes (ip monitor) wake the loop through the screen-event fifo (fd 3), so Wi-Fi switched
# off by the ROM is seen when it happens, not only at the next 60 s timer (which does not run in suspend)
IPP=$HC_DATA/soff_ip.pid
ipm_stop() {
  _ip=$(cat "$IPP" 2>/dev/null)
  case "$_ip" in ''|*[!0-9]*) ;; *) grep -q monitor "/proc/$_ip/cmdline" 2>/dev/null && kill "$_ip" 2>/dev/null ;; esac
  rm -f "$IPP"
}
ipm_start() {
  ipm_stop
  [ "$EV" = 1 ] && command -v ip >/dev/null 2>&1 || return 1
  ( ( ip monitor link 2>/dev/null & echo $! > "$IPP"; wait ) | while read -r _il; do
      case "$_il" in *wlan*) echo wlan >&3 ;; esac
    done ) >/dev/null 2>&1 &
}
_cj=""; _gj=""
# a job that already ended may have had its pid reused: only kill a process that is still this keeper's child
job_kill() { [ -n "$1" ] && grep -q soff_watch "/proc/$1/cmdline" 2>/dev/null && kill "$1" 2>/dev/null; return 0; }
jobs_stop() {
  job_kill "$_cj"; _cj=""
  # the GC job is stopped first, then gc_urgent / wake lock / fstrim are put back
  job_kill "$_gj"; _gj=""
  gcf_restore keeper-stop
  # an automatic app optimization finishes the apps now compiling and starts no new ones
  dxa_stop keeper
  ipm_stop
}

restore() {
  [ -s "$SAVE" ] || return 0
  while IFS='|' read -r _n _v; do
    [ -n "$_n" ] && wr "$_n" "$_v"
  done < "$SAVE"
  : > "$SAVE"
}

trap 'jobs_stop; restore; radio_restore; ev_stop; rm -f "$PIDF"; exit 0' TERM INT HUP
# values left by a keeper that was killed while the screen was off
restore
radio_restore
gcf_restore restart
dxa_stop restart
: >> "$SAVE"
# forced deep Doze left by an older build
[ -f "$HC_DATA/doze_forced" ] && { dumpsys deviceidle unforce >/dev/null 2>&1; rm -f "$HC_DATA/doze_forced"; }
bl_check
ev_start "$HC_DATA/soff_watch.fifo"
[ "$WIFI" = 1 ] && ipm_start

_csince=0; _cdone=1; _clast=0; _cruns=0
_rsince=0; _rdone=1; _rcnt=0; _rlast=""
_gnext=0; _gdone=1; _gtries=0; _gcnt=0; _glast=""
_xnext=0; _xdone=1; _xtries=0; _xcnt=0; _xlast=""
_on=1; _offs=0; _scr=on; _since=$(date '+%H:%M:%S'); _fd=""
# feed: events = screen_toggled seen, events-wait = logcat runs but no event yet, polling = backlight
feed_now() {
  if [ "$EV" != 1 ]; then _fn=polling; elif [ -n "$EV_VAL" ]; then _fn=events; else _fn=events-wait; fi
}
note() {
  [ -n "$1" ] && { _scr=$1; _since=$(date '+%H:%M:%S'); }
  feed_now; _fd=$_fn
  echo "screen=$_scr since=$_since changed=$(grep -c . "$SAVE") offs=$_offs feed=$_fd$([ "$SCR_BLBAD" = 1 ] && echo " backlight=ignored")${_al:+ last_off_caps=$_al}$([ "$WIFI" = 1 ] && echo " wifi_on=$_wcnt${_wlast:+ wifi_last=$_wlast}${_wpause:+ wifi_pauses=$_wpause}")$([ "$RADIO" = 1 ] && echo " radio_off=$_rcnt${_rlast:+ radio_last=$_rlast}")$([ "$GCF" = 1 ] && echo " gc_runs=$_gcnt${_glast:+ gc_last=$_glast}")$([ "$DXF" = 1 ] && echo " dex_runs=$_xcnt${_xlast:+ dex_last=$_xlast}")" > "$STATE"
}
note on
while :; do
  [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ] || [ ! -d "$MODDIR" ] && break
  feed_now; [ "$_fn" != "$_fd" ] && note ""
  [ "$SCR_BLBAD" != "${_bb:-0}" ] && { _bb=$SCR_BLBAD; note ""; }
  if scr_off; then
    if [ "$_on" = 1 ]; then
      _on=0; _offs=$((_offs + 1))
      [ "$PROF" = 1 ] && apply_off
      [ "$WIFI" = 1 ] && { [ "$(wifi_now)" = on ] && _want=on || _want=off; }
      [ "$COMPACT" = 1 ] && { _csince=$(date +%s); _cdone=0; }
      [ "$RADIO" = 1 ] && { _rsince=$(date +%s); _rdone=0; }
      [ "$GCF" = 1 ] && { _gnext=$(( $(date +%s) + GCDELAY )); _gdone=0; _gtries=0; }
      [ "$DXF" = 1 ] && { _xnext=$(( $(date +%s) + DXDELAY )); _xdone=0; _xtries=0; }
      note off
    elif [ "$WIFI" = 1 ]; then
      wifi_tick
    fi
    _ew=60
    if [ "$COMPACT" = 1 ] && [ "$_cdone" = 0 ]; then
      _cn=$(date +%s); _cel=$((_cn - _csince))
      if [ "$_cel" -ge "$CDELAY" ]; then
        _cdone=1
        # once per screen-off period, at most every CCOOL s, only when free RAM is low
        if [ $((_cn - _clast)) -ge "$CCOOL" ] && compact_low_ram; then
          _clast=$_cn; _cruns=$((_cruns + 1))
          ( compact_run ) >/dev/null 2>&1 &
          _cj=$!
        fi
      else
        _ew=$((CDELAY - _cel))
      fi
    fi
    if [ "$RADIO" = 1 ] && [ "$_rdone" = 0 ]; then
      _rn=$(date +%s); _rel=$((_rn - _rsince))
      if [ "$_rel" -ge "$RDELAY" ]; then
        _rdone=1
        radio_off "$RBT"
        if [ -s "$RSAVE" ]; then _rcnt=$((_rcnt + 1)); _rlast=$(date '+%H:%M:%S'); fi
        note ""
      else
        _rw=$((RDELAY - _rel)); [ "$_rw" -lt "$_ew" ] && _ew=$_rw
      fi
    fi
    if [ "$GCF" = 1 ] && [ "$_gdone" = 0 ]; then
      _gkn=$(date +%s)
      if [ "$_gkn" -ge "$_gnext" ]; then
        gcf_check; _gkr=$?
        case "$_gkr" in
          0)
            _gdone=1; _gcnt=$((_gcnt + 1)); _glast=$(date '+%H:%M:%S')
            ( gcf_run ) >/dev/null 2>&1 &
            _gj=$!
            note "" ;;
          2)
            # battery under 30% (not charging) or too warm: look again in 5 min, give up for this screen-off period after 12 tries
            _gtries=$((_gtries + 1))
            if [ "$_gtries" -ge "$GCTRIES" ]; then _gdone=1; else _gnext=$((_gkn + GCRETRY)); fi ;;
          *) _gdone=1 ;;
        esac
      fi
      if [ "$_gdone" = 0 ]; then
        _gkw=$((_gnext - _gkn)); [ "$_gkw" -lt 1 ] && _gkw=1
        [ "$_gkw" -lt "$_ew" ] && _ew=$_gkw
      fi
    fi
    if [ "$DXF" = 1 ] && [ "$_xdone" = 0 ]; then
      _xkn=$(date +%s)
      if [ "$_xkn" -ge "$_xnext" ]; then
        dxa_check; _xkr=$?
        case "$_xkr" in
          0)
            _xdone=1; _xcnt=$((_xcnt + 1)); _xlast=$(date '+%H:%M:%S')
            dxa_start "$DXM"
            note "" ;;
          2)
            # battery under 40% (not charging), too warm or the F2FS GC is running: look again in 5 min, give up for this screen-off period after 12 tries
            _xtries=$((_xtries + 1))
            if [ "$_xtries" -ge "$DXTRIES" ]; then _xdone=1; else _xnext=$((_xkn + DXRETRY)); fi ;;
          *) _xdone=1 ;;
        esac
      fi
      if [ "$_xdone" = 0 ]; then
        _xkw=$((_xnext - _xkn)); [ "$_xkw" -lt 1 ] && _xkw=1
        [ "$_xkw" -lt "$_ew" ] && _ew=$_xkw
      fi
    fi
    ev_wait "$_ew" 2
  else
    if [ "$_on" = 0 ]; then
      _on=1
      # the screen is on: do not keep any intent to turn Wi-Fi back on
      [ "$WIFI" = 1 ] && _want=off
      # a compaction still running stops with the screen-off period
      job_kill "$_cj"; _cj=""
      job_kill "$_gj"; _gj=""
      gcf_restore screen-on
      dxa_stop screen
      restore
      radio_restore
      note on
    fi
    ev_wait 60 3
  fi
done
jobs_stop
restore
radio_restore
ev_stop
rm -f "$PIDF"
exit 0
