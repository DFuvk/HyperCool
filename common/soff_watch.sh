#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Yudharn
# HyperCool - screen-off keeper: power profile (PROF=1: lower CPU/GPU limits while the screen is off)
# Wi-Fi keep (WIFI=1: turn Wi-Fi on again when the ROM switches it off while the screen is off) and
# background app compaction (COMPACT=1: common/compact.sh, 90 s after the screen goes off, low RAM only)
# and Location / Bluetooth off after a long screen-off (RADIO=1, RBT=1 adds Bluetooth, RMIN minutes: common/radio.sh)
# and mobile data / NFC off after a screen-off (DATA=1, DMIN minutes, DMOB=1 mobile data, DNFC=1 NFC: common/radio.sh)
# and automatic app optimization (DXF=1, DXM mode: dex2oat, screen off 10 min, once a week, no force recompile: common/dxauto.sh)
# and the screen-off drain check (DRA=1: notification on high drain, the app that held wake locks the longest)
# and F2FS garbage collection (GCF=1: screen off 10 min, once a week, battery under GCT-5 C; GCGB trigger in GB, GCTRIM=1 adds fstrim, GCT stop temperature: common/f2gc.sh)
PCT=$1 GPU=$2 BST=$3 TCH=$4 CAP=${5:-0} PROF=${6:-1} WIFI=${7:-0} COMPACT=${8:-0} RADIO=${9:-0} RBT=${10:-0} RMIN=${11:-15} GCF=${12:-0} GCGB=${13:-4} GCTRIM=${14:-1} GCT=${15:-45} DXF=${16:-0} DXM=${17:-speed-profile} DATA=${18:-0} DMIN=${19:-10} DMOB=${20:-1} DNFC=${21:-1} DRA=${22:-0}
HC_DATA=/data/adb/hypercool
MODDIR=/data/adb/modules/hypercool
PIDF=$HC_DATA/soff_watch.pid
STATE=$HC_DATA/soff_watch.state
SAVE=$HC_DATA/soff_watch.save
HC_SOFF_LIB_OK=0
[ -f "$MODDIR/common/soff_restore.sh" ] && . "$MODDIR/common/soff_restore.sh" && HC_SOFF_LIB_OK=1
[ -f "$MODDIR/common/klog.sh" ] && . "$MODDIR/common/klog.sh" || { klog() { :; }; kstop() { :; }; }

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
RRETRY=${HC_RRETRY:-300}; RTRIES=${HC_RTRIES:-12}
RSAVE=$HC_DATA/soff_radio.save
DSAVE=$HC_DATA/soff_data.save
case "$DMIN" in ''|*[!0-9]*) DMIN=10 ;; esac
DDELAY=${HC_DDELAY:-$((DMIN * 60))}; DRETRY=${HC_DRETRY:-300}; DTRIES=${HC_DTRIES:-24}
if [ -f "$MODDIR/common/radio.sh" ]; then . "$MODDIR/common/radio.sh"; else DATA=0; radio_off() { :; }; radio_restore() { :; }; data_off() { :; }; data_restore() { :; }; fi
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
# node already in $SAVE: a value that could not be put back at screen-on is still the original
saved_has() { [ -s "$SAVE" ] && awk -F'|' -v n="$1" '$1 == n { f = 1 } END { exit !f }' "$SAVE"; }
# save the value to put back (default: the current one), then write the screen-off value
# the original is only recorded when the write worked: a rejected write changes nothing
put() {
  [ -e "$1" ] || return 1
  _cv=$(cat "$1" 2>/dev/null)
  [ -n "$_cv" ] || return 1
  [ "$_cv" = "$2" ] && return 0
  wr "$1" "$2" || return 1
  saved_has "$1" || printf '%s|%s\n' "$1" "${3:-$_cv}" >> "$SAVE"
  return 0
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
  # entries left by a failed restore stay: they hold the real values to put back
  [ -e "$SAVE" ] || : > "$SAVE"
  _al=""
  _np=0
  for _p in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$_p" ] && _np=$((_np + 1))
  done
  _lp=$(little_policy)
  for _p in /sys/devices/system/cpu/cpufreq/policy*; do
    _m=$(cat "$_p/cpuinfo_max_freq" 2>/dev/null); [ -n "$_m" ] || continue
    # a single-policy kernel has no separate little cluster to skip
    [ "$_np" -gt 1 ] && [ "$_p" = "$_lp" ] && continue
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
  # 3 attempts in 10 min: the ROM keeps switching it off, pause 5 min
  _wk=""; _wc=0
  for _wt in $_wrec; do
    [ $((_wn - _wt)) -lt 600 ] && { _wk="$_wk $_wt"; _wc=$((_wc + 1)); }
  done
  if [ "$_wc" -ge 3 ]; then
    _whold=$((_wn + 300)); _wrec=""; _wpause=$((${_wpause:-0} + 1)); note ""
    klog screen-off "Wi-Fi keep paused" "the ROM switched it off 3 times in 10 min, pausing 5 min"
    return 0
  fi
  svc wifi enable </dev/null >/dev/null 2>&1
  # Android 13+ may ignore the legacy svc wrapper; use the Wi-Fi shell command too
  sleep 1
  [ "$(wifi_now)" = on ] || cmd wifi set-wifi-enabled enabled </dev/null >/dev/null 2>&1
  # every attempt counts for the limiter, even when the radio takes longer than 1 s to come up;
  # wait up to 5 s only to report a successful re-enable in the status
  _wi=0
  while [ "$_wi" -lt 5 ]; do
    [ "$(wifi_now)" = on ] && break
    sleep 1
    _wi=$((_wi + 1))
  done
  _wrec="$_wk $_wn"
  if [ "$_wi" -lt 5 ]; then
    _wcnt=$((_wcnt + 1)); _wlast=$(date '+%H:%M:%S')
    klog screen-off "Wi-Fi back on" "the ROM had switched it off"
  else
    klog screen-off "Wi-Fi did not come back" "still off after 5 s"
  fi
  note ""
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
# number of lines in a file, 0 when it is missing or empty (safe inside $(( )))
lines() { _ln=$(grep -c . "$1" 2>/dev/null); echo "${_ln:-0}"; }
# battery level and charging state, for the drain of each screen-off period
BATP=/sys/class/power_supply/battery
bat_lv() { _bl=$(cat "$BATP/capacity" 2>/dev/null); case "$_bl" in ''|*[!0-9]*) echo "" ;; *) echo "$_bl" ;; esac; }
# on the charger counts too: with the 80% charge limit the status is "Not charging" while plugged in
bat_chg() {
  case "$(cat "$BATP/status" 2>/dev/null)" in Charging|Full) return 0 ;; esac
  for _bo in /sys/class/power_supply/usb/online /sys/class/power_supply/ac/online \
             /sys/class/power_supply/wireless/online /sys/class/power_supply/dc/online; do
    [ "$(cat "$_bo" 2>/dev/null)" = 1 ] && return 0
  done
  return 1
}
_lv0=""; _chg0=0; _dok=0
# one line for a screen-off period of 30 min or more without charging: % lost and % per hour
drain_note() {
  _dok=0
  # the drain switch covers the Recent activity line too
  [ "$DRA" = 1 ] || return 0
  _dl1=$(bat_lv); _dsec=$(( $(date +%s) - _toff ))
  [ -n "$_lv0" ] && [ -n "$_dl1" ] && [ "$_chg0" = 0 ] && [ "$_dsec" -ge "${HC_DRAIN_MIN:-1800}" ] || return 0
  bat_chg && return 0
  # the level went up: it was charged in between
  [ "$_dl1" -le "$_lv0" ] || return 0
  _dd=$((_lv0 - _dl1))
  _dh=$(awk -v s="$_dsec" 'BEGIN { printf "%.1f", s / 3600 }')
  if [ "$_dd" -gt 0 ]; then
    _dr=$(awk -v d="$_dd" -v s="$_dsec" 'BEGIN { printf "%.2f", d * 3600 / s }')
    klog drain "Screen-off drain ${_dr}%/h" "${_dh} h screen off: ${_lv0}% to ${_dl1}% (${_dd}% lost)"
  else
    _dr=$(awk -v s="$_dsec" 'BEGIN { printf "%.2f", 3600 / s }')
    klog drain "Screen-off drain <${_dr}%/h" "${_dh} h screen off: still ${_dl1}% (less than 1% lost)"
  fi
  _dok=1
}
# drain check (DRA=1). Settings are read live: the WebUI saves them without restarting the keeper
CONF=$HC_DATA/config.conf
cfgv() { _cv=$(sed -n "s/^$1=//p" "$CONF" 2>/dev/null | tail -n 1 | tr -d '\r'); echo "${_cv:-$2}"; }
WKS=$MODDIR/common/wakeups.sh
WKOFF=$HC_DATA/wk.off
_wj=""; _dcj=""
# marks of checks a keeper killed hard left behind
rm -f "$HC_DATA"/wk.chk.* 2>/dev/null
# app wake locks at screen-off (one battery stats read, in the background); not while charging
drain_mark() {
  rm -f "$WKOFF"
  [ "$DRA" = 1 ] && [ "$_chg0" = 0 ] && [ -f "$WKS" ] && [ "$(cfgv drain_cause 1)" != 0 ] || return 0
  sh "$WKS" offmark >/dev/null 2>&1 &
  _wj=$!
}
# a read still running when the screen comes back is stopped (its file is dropped with it)
wk_stop() {
  [ -n "$_wj" ] && grep -q wakeups.sh "/proc/$_wj/cmdline" 2>/dev/null && kill "$_wj" 2>/dev/null
  _wj=""
}
dnotify() {
  _dm=$(printf '%s' "$1" | tr -d "'\"\\\\\`$")
  su -lp 2000 -c "cmd notification post -S bigtext -t 'HyperCool' hc_drain '$_dm'" </dev/null >/dev/null 2>&1 ||
    cmd notification post -S bigtext -t HyperCool hc_drain "$_dm" </dev/null >/dev/null 2>&1
}
# after a period drain_note counted: the user app that held wake locks the longest, and a notification
# when the drain was high. Under 1%/h nothing more is done (no second battery stats read, no extra line)
# runs in the background with its own copy of the mark ($1): the keeper goes on at once, and a
# screen-off right after (a glance at the clock) neither stops it nor clears its mark
drain_check() {
  _dchk=$1
  _dtop=""; _dtp=""; _dtm=0; _dchg=${_chgm:-0}
  if [ "$_dok" = 1 ] && [ "${_dd:-0}" -ge 1 ] && awk -v r="$_dr" 'BEGIN { exit !(r + 0 >= 1) }'; then
    if [ "$_dchg" = 0 ] && [ -s "$_dchk" ] && [ "$(cfgv drain_cause 1)" != 0 ]; then
      _dcm=$(cfgv drain_cause_min 10); case "$_dcm" in ''|*[!0-9]*) _dcm=10 ;; esac
      _dtop=$(HC_OFF=$_dchk sh "$WKS" offtop $((_dcm * 60000)) "${HC_OFFSEC:-$_dsec}" 2>/dev/null)
      case "$_dtop" in C\|charger*) _dchg=1; _dtop="" ;; esac
      _dtop=$(echo "$_dtop" | grep '^T|')
      if [ -n "$_dtop" ]; then
        _dt1=$(echo "$_dtop" | head -n 1)
        _dtp=$(echo "$_dt1" | cut -d'|' -f3); [ "$_dtp" = - ] && _dtp="uid $(echo "$_dt1" | cut -d'|' -f2)"
        _dtm=$(echo "$_dt1" | awk -F'|' '{ printf "%d", ($4 + 30000) / 60000 }')
        _dto=$(echo "$_dtop" | sed -n '2,3p' | awk -F'|' '{ printf "%s%s %d min", (NR > 1 ? ", " : ""), ($3 == "-" ? "uid " $2 : $3), ($4 + 30000) / 60000 }')
        klog drain "Kept awake by $_dtp" "$_dtm min of wake locks in ${_dh} h screen off${_dto:+; also $_dto}"
      fi
    fi
  fi
  rm -f "$_dchk"
  # the charger was in for part of the period: no notification
  [ "$_dchg" = 0 ] || return 0
  [ "$_dok" = 1 ] && [ "${_dd:-0}" -ge 2 ] && [ "$_dsec" -ge "${HC_ALERT_MIN:-3600}" ] || return 0
  [ "$(cfgv drain_alert_notify 1)" = 0 ] && return 0
  # the battery level is whole percent: 2% shown can be just over 1% lost, so the lower end is used
  awk -v d="$_dd" -v s="$_dsec" -v t="$(cfgv drain_alert_rate 1.5)" 'BEGIN { exit !(t + 0 > 0 && (d - 1) * 3600 / s >= t + 0) }' || return 0
  _dmsg="Screen-off drain was ${_dr}%/h (${_dd}% in ${_dh} h)."
  if [ -n "$_dtp" ]; then
    _dmsg="$_dmsg The app with the most wake lock time: $_dtp ($_dtm min)."
  else
    _dmsg="$_dmsg Open HyperCool, Wake sources to see what kept the phone awake."
  fi
  dnotify "$_dmsg"
}
# a job that already ended may have had its pid reused: only kill a process that is still this keeper's child
job_kill() { [ -n "$1" ] && grep -q soff_watch "/proc/$1/cmdline" 2>/dev/null && kill "$1" 2>/dev/null; return 0; }
jobs_stop() {
  job_kill "$_cj"; _cj=""
  job_kill "$_dcj"; _dcj=""
  wk_stop
  rm -f "$HC_DATA"/wk.chk.* 2>/dev/null
  # the GC job is stopped first, then gc_urgent / wake lock / fstrim are put back
  job_kill "$_gj"; _gj=""
  gcf_restore keeper-stop
  # an automatic app optimization finishes the apps now compiling and starts no new ones
  dxa_stop keeper
  ipm_stop
}

restore() {
  if [ "$HC_SOFF_LIB_OK" = 1 ]; then
    hc_soff_restore "$SAVE"
    return
  fi
  [ -s "$SAVE" ] || return 0
  # fallback for an old install that has not copied soff_restore.sh yet
  _fail=""
  while IFS='|' read -r _n _v; do
    [ -n "$_n" ] || continue
    wr "$_n" "$_v" || _fail="$_fail$_n|$_v
"
  done < "$SAVE"
  if [ -n "$_fail" ]; then
    printf '%s' "$_fail" > "$SAVE"
  else
    : > "$SAVE"
  fi
}

trap 'jobs_stop; restore; radio_restore; data_restore; ev_stop; rm -f "$PIDF"; exit 0' TERM INT HUP
# values left by a keeper that was killed while the screen was off
restore
radio_restore
data_restore
gcf_restore restart
dxa_stop restart
: >> "$SAVE"
# forced deep Doze left by an older build
[ -f "$HC_DATA/doze_forced" ] && { dumpsys deviceidle unforce >/dev/null 2>&1; rm -f "$HC_DATA/doze_forced"; }
bl_check
ev_start "$HC_DATA/soff_watch.fifo"
[ "$WIFI" = 1 ] && ipm_start

_csince=0; _cdone=1; _clast=0; _cruns=0
_rsince=0; _rdone=1; _rtries=0; _rnext=0; _rcnt=0; _rlast=""
_dnext=0; _ddone=1; _dtries=0; _dcnt=0; _dlast=""; _dseen=0
_gnext=0; _gdone=1; _gtries=0; _gcnt=0; _glast=""
_xnext=0; _xdone=1; _xtries=0; _xcnt=0; _xlast=""
_pnext=0
_on=1; _offs=0; _scr=on; _since=$(date '+%H:%M:%S'); _fd=""; _toff=0
# feed: events = screen_toggled seen, events-wait = logcat runs but no event yet, polling = backlight
feed_now() {
  if [ "$EV" != 1 ]; then _fn=polling; elif [ -n "$EV_VAL" ]; then _fn=events; else _fn=events-wait; fi
}
note() {
  [ -n "$1" ] && { _scr=$1; _since=$(date '+%H:%M:%S'); }
  feed_now; _fd=$_fn
  echo "screen=$_scr since=$_since changed=$(grep -c . "$SAVE") offs=$_offs feed=$_fd$([ "$SCR_BLBAD" = 1 ] && echo " backlight=ignored")${_al:+ last_off_caps=$_al}$([ "$WIFI" = 1 ] && echo " wifi_on=$_wcnt${_wlast:+ wifi_last=$_wlast}${_wpause:+ wifi_pauses=$_wpause}")$([ "$RADIO" = 1 ] && echo " radio_off=$_rcnt${_rlast:+ radio_last=$_rlast}")$([ "$DATA" = 1 ] && echo " data_off=$_dcnt${_dlast:+ data_last=$_dlast}")$([ "$GCF" = 1 ] && echo " gc_runs=$_gcnt${_glast:+ gc_last=$_glast}")$([ "$DXF" = 1 ] && echo " dex_runs=$_xcnt${_xlast:+ dex_last=$_xlast}")" > "$STATE"
}
note on
while :; do
  [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ] || [ ! -d "$MODDIR" ] && { _why="module disabled or removed"; break; }
  feed_now; [ "$_fn" != "$_fd" ] && note ""
  [ "$SCR_BLBAD" != "${_bb:-0}" ] && { _bb=$SCR_BLBAD; note ""; }
  if scr_off; then
    if [ "$_on" = 1 ]; then
      _on=0; _offs=$((_offs + 1)); _toff=$(date +%s)
      _lv0=$(bat_lv); if bat_chg; then _chg0=1; else _chg0=0; fi
      _chgm=0; EV_PLUGGED=0
      drain_mark
      [ "$PROF" = 1 ] && { apply_off; _pnext=$(( $(date +%s) + 60 )); }
      [ "$WIFI" = 1 ] && { [ "$(wifi_now)" = on ] && _want=on || _want=off; }
      [ "$COMPACT" = 1 ] && { _csince=$(date +%s); _cdone=0; }
      [ "$RADIO" = 1 ] && { _rsince=$(date +%s); _rdone=0; _rtries=0; _rnext=$((_rsince + RDELAY)); }
      [ "$DATA" = 1 ] && { _dnext=$(( $(date +%s) + DDELAY )); _ddone=0; _dtries=0; _dseen=0; }
      [ "$GCF" = 1 ] && { _gnext=$(( $(date +%s) + GCDELAY )); _gdone=0; _gtries=0; }
      [ "$DXF" = 1 ] && { _xnext=$(( $(date +%s) + DXDELAY )); _xdone=0; _xtries=0; }
      note off
    elif [ "$WIFI" = 1 ]; then
      wifi_tick
    fi
    # charger in at some point of this period (Android's battery_status event, or seen at a wake-up):
    # the drain is net loss then, so no notification (also when drain_cause=0 skips the stats check)
    [ "$DRA" = 1 ] && [ "$_chgm" = 0 ] && { [ "$EV_PLUGGED" = 1 ] || bat_chg; } && _chgm=1
    # ROM power/perf services can raise the limits again after the screen-off transition.
    # Re-check at most once a minute; put() only writes a node that actually changed.
    if [ "$PROF" = 1 ]; then
      _pn=$(date +%s)
      if [ "$_pn" -ge "$_pnext" ]; then
        apply_off
        _pnext=$((_pn + 60))
      fi
    fi
    _ew=60
    if [ "$COMPACT" = 1 ] && [ "$_cdone" = 0 ]; then
      _cn=$(date +%s); _cel=$((_cn - _csince))
      if [ "$_cel" -ge "$CDELAY" ]; then
        _cdone=1
        # once per screen-off period, at most every CCOOL s, only when free RAM is low
        if [ $((_cn - _clast)) -ge "$CCOOL" ] && compact_low_ram; then
          _clast=$_cn; _cruns=$((_cruns + 1))
          ( compact_run; klog screen-off "App compaction (auto)" "$(sed -n 's/.*apps=\([0-9]*\) failed=\([0-9]*\).*/\1 apps compacted, \2 failed/p' "$CSTATE" 2>/dev/null)" ) >/dev/null 2>&1 &
          _cj=$!
        fi
      else
        _ew=$((CDELAY - _cel))
      fi
    fi
    if [ "$RADIO" = 1 ] && [ "$_rdone" = 0 ]; then
      _rn=$(date +%s)
      if [ "$_rn" -ge "$_rnext" ]; then
        radio_off "$RBT"; _rr=$?
        # location/Bluetooth still on after the switch: look again in 5 min,
        # give up for this screen-off period after 12 tries
        if [ "$_rr" = 2 ]; then
          _rtries=$((_rtries + 1))
          if [ "$_rtries" -ge "$RTRIES" ]; then _rdone=1; else _rnext=$((_rn + RRETRY)); fi
        else
          _rdone=1
        fi
        if [ -s "$RSAVE" ]; then _rcnt=$((_rcnt + 1)); _rlast=$(date '+%H:%M:%S'); fi
        if [ "$_rr" = 2 ]; then
          [ "$_rdone" = 1 ] && klog screen-off "Location/Bluetooth off" "still on after $RTRIES tries, gave up until the next screen-off" ||
            { [ "$_rtries" = 1 ] && klog screen-off "Location/Bluetooth off" "still on, trying again every $((RRETRY / 60)) min"; }
        elif [ -s "$RSAVE" ]; then
          klog screen-off "Location/Bluetooth off" "done ($(cut -d'|' -f1 "$RSAVE" | tr '\n' ' ' | sed 's/ *$//'))"
        fi
        note ""
      fi
      if [ "$_rdone" = 0 ]; then
        _rw=$((_rnext - _rn)); [ "$_rw" -lt 1 ] && _rw=1
        [ "$_rw" -lt "$_ew" ] && _ew=$_rw
      fi
    fi
    if [ "$DATA" = 1 ] && [ "$_ddone" = 0 ]; then
      _dkn=$(date +%s)
      if [ "$_dkn" -ge "$_dnext" ]; then
        data_off "$DMOB" "$DNFC"; _dkr=$?
        # mobile data busy (call, audio, tethering): look again in 5 min, give up for this screen-off period after 24 tries
        if [ "$_dkr" = 2 ]; then
          _dtries=$((_dtries + 1))
          [ "$_dtries" = 1 ] && klog screen-off "Mobile data off" "waiting: call, audio or hotspot in use"
          if [ "$_dtries" -ge "$DTRIES" ]; then _ddone=1; else _dnext=$((_dkn + DRETRY)); fi
        else
          _ddone=1
        fi
        if [ -s "$DSAVE" ] && [ "$_dseen" = 0 ]; then _dseen=1; _dcnt=$((_dcnt + 1)); _dlast=$(date '+%H:%M:%S'); note ""
          klog screen-off "Mobile data/NFC off" "done ($(cut -d'|' -f1 "$DSAVE" | tr '\n' ' ' | sed 's/ *$//'))"; fi
      fi
      if [ "$_ddone" = 0 ]; then
        _dkw=$((_dnext - _dkn)); [ "$_dkw" -lt 1 ] && _dkw=1
        [ "$_dkw" -lt "$_ew" ] && _ew=$_dkw
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
      drain_note
      # the screen is on: do not keep any intent to turn Wi-Fi back on
      [ "$WIFI" = 1 ] && _want=off
      # a compaction still running stops with the screen-off period
      job_kill "$_cj"; _cj=""
      job_kill "$_gj"; _gj=""
      gcf_restore screen-on
      dxa_stop screen
      _rb=$(lines "$SAVE"); _rrb=$(lines "$RSAVE"); _drb=$(lines "$DSAVE")
      restore
      radio_restore
      data_restore
      note on
      # one line per screen-off period, and only when something was switched (no line for a plain on/off)
      _kl=$((_rb + _rrb + _drb))
      if [ "$_kl" -gt 0 ]; then
        _kleft=$(( $(lines "$SAVE") + $(lines "$RSAVE") + $(lines "$DSAVE") ))
        _km=$(( $(date +%s) - _toff )); if [ "$_km" -lt 90 ]; then _km="$_km s"; else _km="$(( (_km + 30) / 60 )) min"; fi
        if [ "$_kleft" -gt 0 ]; then
          klog screen-off "Screen on, values put back" "$_kleft of $_kl not accepted yet, tried again at the next screen-on (off for $_km)"
        else
          klog screen-off "Screen on, values put back" "all $_kl back (off for $_km)"
        fi
      fi
      # after the values are back: the battery stats read takes a second or two, in the background
      # so a slow dumpsys never holds the keeper; a still running check is stopped at the next screen-off
      if [ "$DRA" = 1 ]; then
        # a plug event read in the same wake-up as the screen-on still counts
        [ "$EV_PLUGGED" = 1 ] && _chgm=1
        wk_stop
        _dck=$HC_DATA/wk.chk.$_offs; rm -f "$_dck"
        [ -s "$WKOFF" ] && mv -f "$WKOFF" "$_dck"
        ( drain_check "$_dck" ) >/dev/null 2>&1 &
        _dcj=$!
      fi
    fi
    ev_wait 60 3
  fi
done
jobs_stop
restore
radio_restore
data_restore
ev_stop
rm -f "$PIDF"
kstop screen-off "${_why:-stopped}, values put back"
exit 0
