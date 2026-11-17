#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Yudharn
# HyperCool - Heat guard keeper: <limit 0.1 C> <cpu % while hot> <refresh Hz while hot, 0 = leave> <miui 0|1> [big-core cap %]
# Reads the battery temperature every 30 s (20 s while hot). At or above the limit the big / prime
# cores get a lower scaling_max_freq and the refresh rate a lower peak; 3 C below the limit (and at
# least 2 min later) both go back. A plain `sleep` does not wake the phone from deep sleep, so this
# only runs while the phone is awake anyway.
# heat.save: cpu|<node>|<value to put back>|<value written>
#            set|<namespace>|<key>|<value to put back>|<value written>
# A value is only put back while it still holds what this keeper wrote: if the ROM, the screen-off
# profile or another feature changed it in the meantime, that change is left alone.
export PATH=/system/bin:/system/xbin:/vendor/bin:/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:"$PATH"
HC_DATA=${HC_DATA:-/data/adb/hypercool}
MODDIR=${MODDIR:-/data/adb/modules/hypercool}
HC_SYS=${HC_SYS:-/sys}
LIM=$1; PCT=$2; RR=${3:-0}; MIUI=${4:-0}; CAP=${5:-0}
PIDF=$HC_DATA/heat_watch.pid
STATE=$HC_DATA/heat_watch.state
SAVE=$HC_DATA/heat.save
RRF=$HC_DATA/heat.rr
TNODE=${HC_TNODE:-$HC_SYS/class/power_supply/battery/temp}
STEP=${HC_HSTEP:-30}; HSTEP=${HC_HSTEP_HOT:-20}; MINHOT=${HC_HMIN:-120}
[ -f "$MODDIR/common/klog.sh" ] && . "$MODDIR/common/klog.sh" || klog() { :; }

MODE=run; [ "$1" = restore ] && MODE=restore
if [ "$MODE" = run ]; then
  for _a in "$LIM" "$PCT" "$RR" "$CAP"; do case "$_a" in ''|*[!0-9]*) exit 1 ;; esac; done
fi

# wrf: write a cpufreq limit. scaling_max_freq reads back the limit after thermal, which can be
# lower than the value written, so only the write itself is checked here
wrf() {
  [ -e "$1" ] || return 1
  _m=$(stat -c %a "$1" 2>/dev/null)
  chmod u+w "$1" 2>/dev/null
  _r=0; { echo "$2" > "$1"; } 2>/dev/null || _r=1
  [ -n "$_m" ] && chmod "$_m" "$1" 2>/dev/null
  return $_r
}
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
  for _p in "$HC_SYS"/devices/system/cpu/cpufreq/policy*; do
    _m=$(cat "$_p/cpuinfo_max_freq" 2>/dev/null); [ -n "$_m" ] || continue
    if [ "$_m" -lt "$_lm" ]; then _lm=$_m; _lp=$_p; fi
  done
  echo "$_lp"
}
# battery temperature in 0.1 C (some kernels report millidegrees)
temp() {
  _t=$(cat "$TNODE" 2>/dev/null)
  # a bare "-", "--" or "1-2" must not pass: only an optional leading minus and digits
  case "$_t" in ''|-) return 1 ;; esac
  case "${_t#-}" in *[!0-9]*) return 1 ;; esac
  [ "$_t" -gt 2000 ] && _t=$((_t / 100))
  echo "$_t"
}
fmt() { awk -v t="$1" 'BEGIN { printf "%.1f C", t / 10 }'; }
# saved <type> <field2> [field3]: a record for this node / setting is already there
saved() { [ -s "$SAVE" ] && awk -F'|' -v a="$1" -v b="$2" -v c="${3:-}" '$1 == a && $2 == b && (c == "" || $3 == c) { f = 1 } END { exit !f }' "$SAVE"; }
rr_alive() {
  _rq=$(cat "$HC_DATA/rr_watch.pid" 2>/dev/null)
  case "$_rq" in ''|*[!0-9]*) return 1 ;; esac
  grep -q rr_watch "/proc/$_rq/cmdline" 2>/dev/null
}
sget() { settings get "$1" "$2" 2>/dev/null; }
sput() { cmd settings put "$1" "$2" "$3" </dev/null >/dev/null 2>&1 || settings put "$1" "$2" "$3" </dev/null >/dev/null 2>&1; [ "$(hz "$(sget "$1" "$2")")" = "$(hz "$3")" ]; }
hz() { _h=${1%%.*}; case "$_h" in ''|*[!0-9]*) echo 0 ;; *) echo "$_h" ;; esac; }
# set_low <ns> <key> <value>: lower a refresh setting and record what to put back
set_low() {
  _cv=$(sget "$1" "$2")
  case "$_cv" in ''|null) return 0 ;; esac
  [ "$(hz "$_cv")" -gt "$(hz "$3")" ] || return 0
  sput "$1" "$2" "$3" || return 1
  saved set "$1" "$2" || echo "set|$1|$2|$_cv|$3" >> "$SAVE"
}

# apply / keep the hot limits (also every tick while hot: the ROM or another keeper may raise them)
hot_apply() {
  [ -e "$SAVE" ] || : > "$SAVE"
  _np=0
  for _p in "$HC_SYS"/devices/system/cpu/cpufreq/policy*; do [ -d "$_p" ] && _np=$((_np + 1)); done
  _lp=$(little_policy)
  for _p in "$HC_SYS"/devices/system/cpu/cpufreq/policy*; do
    _m=$(cat "$_p/cpuinfo_max_freq" 2>/dev/null); [ -n "$_m" ] || continue
    [ "$_np" -gt 1 ] && [ "$_p" = "$_lp" ] && continue
    _s=$(snap "$_p" $((_m * PCT / 100)))
    # put back the Big-core cap or the full range, not the value read now (it may be a thermal limit)
    _b=$_m; [ "$CAP" -gt 0 ] && _b=$(snap "$_p" $((_m * CAP / 100)))
    [ "$_b" -le "$_s" ] && continue
    _n=$_p/scaling_max_freq
    _c=$(cat "$_n" 2>/dev/null); case "$_c" in ''|*[!0-9]*) continue ;; esac
    [ "$_c" -gt "$_s" ] || continue
    wrf "$_n" "$_s" && { saved cpu "$_n" || echo "cpu|$_n|$_b|$_s" >> "$SAVE"; }
  done
  [ "$RR" -gt 0 ] || return 0
  if rr_alive; then
    # the touch keeper owns the rate: it caps every rate it sets at this value while the file is there
    [ "$(cat "$RRF" 2>/dev/null)" = "$RR" ] || echo "$RR" > "$RRF"
    _cv=$(sget system peak_refresh_rate)
    if [ "$(hz "$_cv")" -gt "$RR" ]; then
      sput system peak_refresh_rate "$RR.0"
      [ "$MIUI" = 1 ] && sput secure miui_refresh_rate "$RR"
    fi
    # the touch keeper owns peak, not min: a min above the cap is an invalid range, so lower
    # it too and record it (cool-down puts it back; the keeper does not touch min)
    set_low system min_refresh_rate "$RR.0"
  else
    set_low system peak_refresh_rate "$RR.0"
    set_low system min_refresh_rate "$RR.0"
    [ "$MIUI" = 1 ] && set_low secure miui_refresh_rate "$RR"
  fi
  return 0
}

# cooled down / stopping: put back what is still as this keeper left it
hot_leave() {
  rm -f "$RRF"
  HL_BACK=0
  [ -s "$SAVE" ] || { HL_MSG=""; return 0; }
  _hk=""; _hn=0; _hs=0
  while IFS='|' read -r _ty _a _b _c _d; do
    case "$_ty" in
      cpu)
        _hn=$((_hn + 1))
        _cv=$(cat "$_a" 2>/dev/null)
        case "$_cv" in ''|*[!0-9]*) _cv=0 ;; esac
        if [ "$_cv" -gt "$_c" ]; then
          # raised meanwhile (ROM, CPU cap keeper, screen-on restore): leave it
          _hs=$((_hs + 1))
        elif [ -s "$HC_DATA/soff_watch.save" ] && grep -q "^$_a|" "$HC_DATA/soff_watch.save" 2>/dev/null; then
          # the screen is off and the screen-off profile holds this node: it puts its own value back at screen-on
          :
        else
          # still what was written, or lower because of a thermal limit: back to the normal cap
          wrf "$_a" "$_b" || _hk="$_hk$_ty|$_a|$_b|$_c
"
        fi ;;
      set)
        _hn=$((_hn + 1))
        if [ "$(hz "$(sget "$_a" "$_b")")" = "$(hz "$_d")" ]; then
          sput "$_a" "$_b" "$_c" || _hk="$_hk$_ty|$_a|$_b|$_c|$_d
"
        else
          _hs=$((_hs + 1))
        fi ;;
    esac
  done < "$SAVE"
  if [ -n "$_hk" ]; then printf '%s' "$_hk" > "$SAVE"; else : > "$SAVE"; fi
  _hleft=$(grep -c . "$SAVE" 2>/dev/null)
  HL_BACK=$((_hn - _hs - ${_hleft:-0}))
  HL_MSG="$HL_BACK of $_hn limits put back"
  [ "$_hs" -gt 0 ] && HL_MSG="$HL_MSG, $_hs changed by something else and left alone"
  [ "${_hleft:-0}" -gt 0 ] && HL_MSG="$HL_MSG, $_hleft not accepted (tried again later)"
}

# restore: put back what a keeper that is gone left (boot, feature off, Revert, module off, uninstall)
if [ "$MODE" = restore ]; then
  rm -f "$RRF"
  hot_leave
  # after a reboot the CPU limits are already back to normal: log only what really had to be put back
  [ "${HL_BACK:-0}" -gt 0 ] && klog heat "Limits put back" "$HL_BACK left from a keeper that stopped while hot"
  exit 0
fi
COOL=$((LIM - 30))
_old=$(cat "$PIDF" 2>/dev/null)
case "$_old" in ''|*[!0-9]*) ;; *)
  [ "$_old" != "$$" ] && grep -q heat_watch "/proc/$_old/cmdline" 2>/dev/null && exit 0 ;;
esac
echo $$ > "$PIDF"

HOT=0; SINCE=0; NHOT=0
# state file: written when hot/cool changes and at most every 10 min otherwise (no write every tick)
_nlast=0; _nhot=x
note() {
  _nn=$(date +%s)
  [ "$HOT" != "$_nhot" ] || [ $((_nn - _nlast)) -ge 600 ] || return 0
  _nhot=$HOT; _nlast=$_nn
  echo "hot=$HOT temp=${1:-?} limit=$LIM back_at=$COOL hot_times=$NHOT last=$(date '+%H:%M:%S')" > "$STATE"
}
stop() {
  if [ "$HOT" = 1 ]; then hot_leave; klog heat "Limits put back" "keeper stopped while hot${HL_MSG:+: $HL_MSG}"; else hot_leave; fi
  [ "$(cat "$PIDF" 2>/dev/null)" = "$$" ] && rm -f "$PIDF"
  exit 0
}
trap stop TERM INT HUP

# leftovers from a keeper that was killed while hot
hot_leave
_bad=0
while :; do
  [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ] || [ ! -d "$MODDIR" ] && stop
  grep -q '^heat_guard=1' "$HC_DATA/config.conf" 2>/dev/null || stop
  if ! _t=$(temp); then
    _bad=$((_bad + 1))
    # the temperature cannot be read: never keep the limits on blind
    if [ "$_bad" -ge 3 ]; then
      [ "$HOT" = 1 ] && { HOT=0; hot_leave; klog heat "Temperature not readable" "${HL_MSG:-no hot limits were applied}"; }
    fi
    sleep "$STEP"; continue
  fi
  _bad=0
  _now=$(date +%s)
  if [ "$HOT" = 0 ]; then
    # values that were not accepted when it cooled down: try again
    [ -s "$SAVE" ] && [ "$_t" -lt "$LIM" ] && hot_leave
    if [ "$_t" -ge "$LIM" ]; then
      HOT=1; SINCE=$_now; NHOT=$((NHOT + 1))
      hot_apply
      klog heat "Battery hot" "$(fmt "$_t"): big cores ${PCT}%$([ "$RR" -gt 0 ] && echo ", ${RR} Hz") until $(fmt "$COOL")"
    fi
  elif [ "$_t" -le "$COOL" ] && [ $((_now - SINCE)) -ge "$MINHOT" ]; then
    HOT=0
    hot_leave
    _hd=$((_now - SINCE)); if [ "$_hd" -lt 90 ]; then _hd="$_hd s"; else _hd="$(( (_hd + 30) / 60 )) min"; fi
    klog heat "Cooled down" "$(fmt "$_t") after $_hd${HL_MSG:+: $HL_MSG}"
  else
    hot_apply
  fi
  note "$_t"
  if [ "$HOT" = 1 ]; then sleep "$HSTEP"; else sleep "$STEP"; fi
done
