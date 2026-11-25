#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Yudharn
# HyperCool - battery keeper: charging pause / bypass, battery history and temperature warning
#   bat_watch.sh <pause 0|1> <pause temp 0.1 C, 0 = none> <pause level %, 0 = none> <auto|bypass|cut>
#                <history 0|1> <warning 0|1> <warning temp 0.1 C> <bypass while gaming 0|1> <screen on only 0|1>
# Checks every 20 s while a charger is plugged in and every 60 s otherwise (5 s while a charge current
# limit holds the bypass, the ROM thermal service may raise it again). A plain sleep does not wake the
# phone from deep sleep, so it only runs while the phone is awake anyway.
# Charging pause: at the temperature or level, or while a game is open, charging is stopped and comes
# back 3 C cooler (at least 2 min later), 3% lower or when the game is closed.
#   bypass = a charging switch of the kernel: the charger powers the phone, the battery is left alone
#   limit  = the charge current (or the charger level) is set to 0 / the lowest: the same, done the way
#            "simulated bypass" modules do it, for kernels without a switch
#   cut    = the charger input is cut, so the battery is used while plugged in (never while gaming)
# The switch that works is found the first time it is needed (within about 12 s the battery status must
# leave Charging or the battery current drop to 150 mA or less) and remembered in batp.node. Charging
# always comes back when the charger is unplugged, under 15%, during a battery calibration and when
# the keeper stops.
# batp.save: <node>|<normal value>|<value written>|<kind>, while charging is paused
# batp.games: the games for "bypass while gaming", one package per line (written at boot)
# bat_hist.csv: <epoch>,<level %>,<temp 0.1 C>,<plugged 0|1>,<screen on 0|1>,<paused 0|1>
export PATH=/system/bin:/system/xbin:/vendor/bin:/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:"$PATH"
HC_DATA=${HC_DATA:-/data/adb/hypercool}
MODDIR=${MODDIR:-/data/adb/modules/hypercool}
HC_SYS=${HC_SYS:-/sys}
BP=${HC_BPROC:-/proc}
PS=$HC_SYS/class/power_supply
PAUSE=${1:-0}; PT=${2:-0}; PL=${3:-0}; HOW=${4:-auto}; HIST=${5:-0}; WARN=${6:-0}; WT=${7:-450}; GAME=${8:-0}; GSCR=${9:-1}
for _a in "$PAUSE" "$PT" "$PL" "$HIST" "$WARN" "$WT" "$GAME" "$GSCR"; do case "$_a" in ''|*[!0-9]*) exit 1 ;; esac; done
case "$HOW" in auto|bypass|cut) ;; *) HOW=auto ;; esac
PIDF=$HC_DATA/bat_watch.pid
STATE=$HC_DATA/bat_watch.state
SAVE=$HC_DATA/batp.save
NODEF=$HC_DATA/batp.node
GAMEF=$HC_DATA/batp.games
CSV=$HC_DATA/bat_hist.csv
STEP=${HC_BSTEP:-20}; ISTEP=${HC_BSTEP_IDLE:-60}; LSTEP=${HC_BSTEP_LIM:-5}; HSTEP=${HC_BHIST:-300}
VER=${HC_BVER:-6}; MINP=${HC_BMIN:-120}; LOW=15
[ -f "$MODDIR/common/klog.sh" ] && . "$MODDIR/common/klog.sh" || { klog() { :; }; kstop() { :; }; }

_old=$(cat "$PIDF" 2>/dev/null)
case "$_old" in ''|*[!0-9]*) ;; *)
  [ "$_old" != "$$" ] && grep -q bat_watch "/proc/$_old/cmdline" 2>/dev/null && exit 0 ;;
esac
echo $$ > "$PIDF"

# kind|node|normal|paused. Qualcomm and MediaTek kernels name their charging switches differently;
# only the ones this kernel has are tried. "@" = the value it has now, "@max" = the last charger level
NODES="bypass|$PS/battery/charging_enabled|1|0
bypass|$PS/battery/battery_charging_enabled|1|0
bypass|$HC_SYS/class/qcom-battery/battery_charging_enabled|1|0
bypass|$HC_SYS/devices/platform/charger/bypass_charger|0|1
bypass|$BP/mtk_battery_cmd/current_cmd|0 0|0 1
bypass|$HC_SYS/class/qcom-battery/charging_enabled|1|0
bypass|$HC_SYS/class/qcom-battery/night_charging|0|1
bypass|$PS/battery/charge_enabled|1|0
bypass|$PS/battery/charge_disable|0|1
bypass|$PS/battery_ext/smart_charging_interruption|0|1
bypass|$PS/battery/mmi_charging_enable|1|0
bypass|$PS/battery/op_disable_charge|0|1
bypass|$HC_SYS/devices/platform/mt-battery/disable_charger|0|1
bypass|$PS/ac/charging_enabled|1|0
bypass|$PS/dc/charging_enabled|1|0
bypass|$PS/battery/batt_slate_mode|0|1
bypass|$PS/battery/stop_charge|0|1
bypass|$PS/battery/device/Charging_Enable|1|0
bypass|$PS/chargalg/disable_charging|0|1
bypass|$PS/bq2589x_charger/enable_charging|1|0
bypass|$PS/charge_data/enable_charger|1|0
bypass|$HC_SYS/class/hw_power/charger/charge_data/enable_charger|1|0
bypass|$HC_SYS/devices/platform/huawei_charger/enable_charger|1|0
bypass|$HC_SYS/class/oplus_chg/battery/mmi_charging_enable|1|0
bypass|$HC_SYS/devices/virtual/oplus_chg/battery/mmi_charging_enable|1|0
bypass|$HC_SYS/devices/platform/soc/soc:oplus,chg_intf/oplus_chg/battery/mmi_charging_enable|1|0
bypass|$HC_SYS/devices/platform/soc/soc:oplus,chg_intf/oplus_chg/battery/chg_enable|1|0
bypass|$HC_SYS/devices/platform/soc/soc:google,charger/charge_disable|0|1
bypass|$HC_SYS/kernel/nubia_charge/charger_bypass|0|1
bypass|$HC_SYS/devices/platform/lge-unified-nodes/charging_enable|1|0
bypass|$HC_SYS/devices/platform/charger/tran_aichg_disable_charger|0|1
bypass|$HC_SYS/devices/platform/battery/CCIChargerSwitch|1|0
bypass|$BP/smb1357_disable_chrg|0|1
limit|$PS/battery/constant_charge_current|@|0
limit|$PS/battery/fast_charge_current|@|0
limit|$PS/battery/thermal_input_current|@|0
limit|$PS/battery/charge_control_limit|@|@max
cut|$PS/battery/input_suspend|0|1
cut|$HC_SYS/class/qcom-battery/input_suspend|0|1
cut|$BP/mtk_battery_cmd/en_power_path|1|0
cut|$PS/battery/battery_input_suspend|0|1
cut|$HC_SYS/devices/platform/soc/soc:qcom,pmic_glink/soc:qcom,pmic_glink:qcom,battery_charger/force_charger_suspend|0|1
cut|$HC_SYS/class/asuslib/charging_suspend_en|0|1
cut|$HC_SYS/kernel/debug/google_charger/input_suspend|0|1"
GL=$(grep -E '^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+$' "$GAMEF" 2>/dev/null | tr '\n' ' ')
[ -n "$GL" ] || GAME=0

rd() { cat "$1" 2>/dev/null; }
temp() {
  _t=$(rd "$PS/battery/temp")
  case "$_t" in ''|-) return 1 ;; esac
  case "${_t#-}" in *[!0-9]*) return 1 ;; esac
  [ "$_t" -gt 2000 ] && _t=$((_t / 100))
  echo "$_t"
}
level() { _l=$(rd "$PS/battery/capacity"); case "$_l" in ''|*[!0-9]*) return 1 ;; esac; echo "$_l"; }
bstatus() { rd "$PS/battery/status"; }
fmt() { awk -v t="$1" 'BEGIN { printf "%.1f C", t / 10 }'; }
# a charger is connected: any online charger supply, the USB cable (present stays 1 while the input
# is cut), or the battery itself says it is charging
plugged() {
  case "$(bstatus)" in Charging|Full) return 0 ;; esac
  for _o in "$PS"/*/online "$PS"/usb/present; do
    [ -e "$_o" ] || continue
    _n=${_o%/*}; _n=${_n##*/}
    case "$_n" in battery|bms|bat*|*gauge*|*fg*) continue ;; esac
    [ "$(rd "$_o")" = 1 ] && return 0
  done
  return 1
}
# the battery takes no charge now: not "Charging", or 150 mA or less goes in (a current limit keeps
# the status at Charging on many kernels)
no_charge() {
  case "$(bstatus)" in Charging) ;; '') return 1 ;; *) return 0 ;; esac
  _c=$(rd "$PS/battery/current_now"); _c=${_c#-}
  case "$_c" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_c" -gt 20000 ] && _c=$((_c / 1000))
  [ "$_c" -le 150 ]
}
# a battery calibration (needs one full charge) or the charger calibration of Cooler charging (measures
# the current at each charger level) runs: charging is never paused or limited meanwhile
cal() {
  grep -qE '^phase=(discharge|charge|hold)$' "$HC_DATA/bcal.state" 2>/dev/null && return 0
  _cq=$(cat "$HC_DATA/.charge_cal.lock" 2>/dev/null)
  case "$_cq" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$_cq" 2>/dev/null
}
# screen_on: read again at most every 15 s (the keeper checks every 5 s while a current limit holds)
SCR_T=0; SCR_V=0
screen_on() {
  _sn=$(date +%s)
  if [ $((_sn - SCR_T)) -lt "${HC_BSCR:-15}" ]; then [ "$SCR_V" = 1 ]; return; fi
  SCR_T=$_sn
  if screen_read; then SCR_V=1; return 0; fi
  SCR_V=0; return 1
}
screen_read() {
  _w=$(dumpsys power </dev/null 2>/dev/null | sed -n 's/.*mWakefulness=\([A-Za-z]*\).*/\1/p' | head -n 1)
  case "$_w" in Awake) return 0 ;; Asleep|Dozing|Dreaming) return 1 ;; esac
  for _b in "$HC_SYS"/class/backlight/*/brightness "$HC_SYS"/class/leds/lcd-backlight/brightness; do
    [ -e "$_b" ] || continue
    _v=$(rd "$_b"); case "$_v" in ''|*[!0-9]*) continue ;; esac
    [ "$_v" -gt 0 ] && return 0
    return 1
  done
  return 0
}
# a game of the list is open: one of its processes is in the foreground or visible (oom_score_adj 100
# or lower; a game left in the background is cached at 900 and up). Prints the game
game_now() {
  # shellcheck disable=SC2086
  [ -n "$(pidof $GL 2>/dev/null)" ] || return 1
  for _gp in $GL; do
    for _gi in $(pidof "$_gp" 2>/dev/null); do
      _ga=$(rd "/proc/$_gi/oom_score_adj")
      case "$_ga" in ''|*[!0-9-]*) echo "$_gp"; return 0 ;; esac
      [ "$_ga" -le 100 ] && { echo "$_gp"; return 0; }
    done
  done
  return 1
}
wr() {
  [ -e "$1" ] || return 1
  chmod u+w "$1" 2>/dev/null
  { echo "$2" > "$1"; } 2>/dev/null
}
# same <value read> <value>: a node that reads back in another format (some /proc switches print a
# text) counts as the same, the battery status decides then
same() {
  _sv=$(echo "$1" | tr -s ' \t\n' '   ' | sed 's/^ *//; s/ *$//')
  case "$_sv" in *[!0-9\ ]*) return 0 ;; esac
  [ "$_sv" = "$2" ]
}

# ---------------------------------------------------------------- charging pause
PAUSED=0; PNODE=""; PNORM=""; PVAL=""; PKIND=""; PSINCE=0; PWHY=""; NPAUSE=0; POK=$PAUSE; BAD=" "
PLOGGED=""; CUTWAIT=0; HT=0; HTS=0; HLV=0; HG=0; GNAME=""; NGAME=0
# candidates in the order to try: the switch that worked before first. $1 = 1: no input cut
cands() {
  _k=$(cut -d'|' -f2 "$NODEF" 2>/dev/null)
  # auto: a remembered cut switch does not go ahead of the bypass ones (it is the last resort)
  [ "$HOW" = auto ] && [ "$(cut -d'|' -f1 "$NODEF" 2>/dev/null)" = cut ] && _k=""
  { [ -n "$_k" ] && echo "$NODES" | grep -F "|$_k|"; echo "$NODES"; } | awk -F'|' -v h="$HOW" -v nc="${1:-0}" '
    !s[$2]++ && (h == "auto" || (h == "bypass" && $1 != "cut") || h == $1) && !(nc == 1 && $1 == "cut") { print }'
}
pause_on() {
  echo "$NODES" | while IFS='|' read -r _ki _n _nv _pv; do [ -e "$_n" ] && echo x; done | grep -q x || return 1
  _cl=$(cands "$1")
  _tmp=$(echo "$_cl" | while IFS='|' read -r _ki _n _nv _pv; do
    [ -n "$_n" ] && [ -e "$_n" ] || continue
    case "$BAD" in *" $_n "*) continue ;; esac
    _cur=$(rd "$_n")
    if [ "$_nv" = @ ]; then
      # a current / level limit: what it is now comes back afterwards; already 0 = the ROM limits it
      case "$_cur" in ''|*[!0-9]*|0) continue ;; esac
      _nv=$_cur
    fi
    if [ "$_pv" = @max ]; then
      _mx=$(rd "${_n}_max"); case "$_mx" in ''|*[!0-9]*) continue ;; esac
      [ "$_mx" -gt 1 ] || continue
      _pv=$((_mx - 1)); [ "$_nv" -ge "$_pv" ] && continue
    fi
    # already at the paused value: the ROM or another tool holds it, not ours to take over
    case "$_cur" in *[!0-9\ ]*) ;; *) same "$_cur" "$_pv" && continue ;; esac
    # recorded before the write: a keeper stopped in the middle still puts it back
    echo "$_n|$_nv|$_pv|$_ki" > "$SAVE"
    wr "$_n" "$_pv" || { rm -f "$SAVE"; echo "bad|$_n"; continue; }
    if ! same "$(rd "$_n")" "$_pv"; then wr "$_n" "$_nv"; rm -f "$SAVE"; echo "bad|$_n"; continue; fi
    # two readings in a row: one read can catch the driver between two states
    _i=0; _okp=0; _hit=0
    while [ "$_i" -lt "$VER" ]; do
      if no_charge; then _hit=$((_hit + 1)); [ "$_hit" -ge 2 ] && { _okp=1; break; }; else _hit=0; fi
      sleep 2; _i=$((_i + 1))
    done
    # a switch that left the battery discharging cut the charger input, whatever its name says;
    # while gaming that is not wanted (the battery would run down on the charger)
    if [ "$_okp" = 1 ] && [ "$(bstatus)" = Discharging ]; then
      _ki="cut"
      [ "${1:-0}" = 1 ] && _okp=0
    fi
    if [ "$_okp" = 1 ]; then echo "ok|$_ki|$_n|$_nv|$_pv"; break; fi
    # the battery still charges: this switch does nothing on this phone
    wr "$_n" "$_nv"; rm -f "$SAVE"; echo "bad|$_n"
  done)
  for _b in $(echo "$_tmp" | sed -n 's/^bad|//p'); do BAD="$BAD$_b "; done
  _ok=$(echo "$_tmp" | grep '^ok|' | head -n 1)
  [ -n "$_ok" ] || return 2
  PKIND=$(echo "$_ok" | cut -d'|' -f2); PNODE=$(echo "$_ok" | cut -d'|' -f3)
  PNORM=$(echo "$_ok" | cut -d'|' -f4); PVAL=$(echo "$_ok" | cut -d'|' -f5)
  echo "$PNODE|$PNORM|$PVAL|$PKIND" > "$SAVE"
  echo "$PKIND|$PNODE" > "$NODEF"
  PAUSED=1; PSINCE=$(date +%s); NPAUSE=$((NPAUSE + 1))
  return 0
}
pause_off() {
  [ "$PAUSED" = 1 ] || return 0
  wr "$PNODE" "$PNORM"
  same "$(rd "$PNODE")" "$PNORM" || wr "$PNODE" "$PNORM"
  rm -f "$SAVE"
  PAUSED=0
}
short() { echo "${1#"$HC_SYS"/class/}" | sed "s#^$BP/##"; }
how_txt() {
  case "$PKIND" in
    bypass) echo "the charger powers the phone" ;;
    limit) echo "charge current held at the lowest, the charger powers the phone" ;;
    *) echo "charger input off, the battery is used" ;;
  esac
}
dur() { _d=$(( $(date +%s) - $1 )); if [ "$_d" -lt 90 ]; then echo "$_d s"; else echo "$(( (_d + 30) / 60 )) min"; fi; }

pause_tick() {
  [ "$POK" = 1 ] || return 0
  _now=$(date +%s)
  # never paused: no charger, battery calibration, low battery
  _sw=""
  if ! plugged; then _sw=unplug; elif cal; then _sw=calib; elif [ "${_l:-100}" -le "$LOW" ]; then _sw=low; fi
  if [ -n "$_sw" ]; then
    HT=0; HLV=0; HG=0
    if [ "$PAUSED" = 1 ]; then
      _pk=$PKIND; _pw=$PWHY; _ps=$PSINCE
      pause_off
      case "$_sw" in
        low) klog battery "Charging resumed" "battery at ${_l}%, under ${LOW}%" ;;
        calib) klog battery "Charging resumed" "a battery or charger calibration started" ;;
        # a cut charger input can look unplugged: wait 5 min before the next pause
        unplug) [ "$_pk" = cut ] && CUTWAIT=$((_now + 300))
                [ "$_pw" = game ] && klog battery "Bypass ended" "charger unplugged after $(dur "$_ps")" ;;
      esac
    fi
    [ "$_sw" = unplug ] && PLOGGED=""
    return 0
  fi
  # what holds the pause: temperature (until 3 C cooler, 2 min at least), level (until 3% lower), game
  if [ "$PT" -gt 0 ] && [ -n "$_t" ]; then
    if [ "$_t" -ge "$PT" ]; then [ "$HT" = 0 ] && HTS=$_now; HT=1
    elif [ "$HT" = 1 ] && [ "$_t" -le $((PT - 30)) ] && [ $((_now - HTS)) -ge "$MINP" ]; then HT=0; fi
  else
    # temperature not readable: never keep charging paused for the temperature blind
    HT=0
  fi
  if [ "$PL" -gt 0 ] && [ -n "$_l" ]; then
    if [ "$_l" -ge "$PL" ]; then HLV=1; elif [ "$_l" -le $((PL - 3)) ]; then HLV=0; fi
  else
    HLV=0
  fi
  HG=0
  if [ "$GAME" = 1 ] && _g=$(game_now); then
    { [ "$GSCR" = 0 ] || screen_on; } && { HG=1; GNAME=$_g; }
  fi
  if [ "$PAUSED" = 1 ]; then
    # a cut input is only for the temperature and the level: while gaming the battery would drain
    if [ "$HT" = 1 ] || [ "$HLV" = 1 ] || { [ "$HG" = 1 ] && [ "$PKIND" != cut ]; }; then
      if [ "$HT" = 1 ]; then PWHY=temp; elif [ "$HLV" = 1 ]; then PWHY=level; else PWHY=game; fi
      # put back by the ROM, its thermal service or the charger driver: write it again
      same "$(rd "$PNODE")" "$PVAL" || wr "$PNODE" "$PVAL"
      return 0
    fi
    _pw=$PWHY; _ps=$PSINCE
    pause_off
    case "$_pw" in
      temp) if [ -n "$_t" ]; then klog battery "Charging resumed" "$(fmt "$_t") after $(dur "$_ps")"
            else klog battery "Charging resumed" "battery temperature not readable"; fi ;;
      game) if [ "$GAME" = 1 ] && [ -n "$(game_now)" ]; then _gw="screen off"; else _gw="game closed or in the background"; fi
            klog battery "Bypass ended" "$_gw after $(dur "$_ps")" ;;
    esac
    return 0
  fi
  _why=""
  [ "$HT" = 1 ] && _why=temp
  [ -z "$_why" ] && [ "$HLV" = 1 ] && _why=level
  [ -z "$_why" ] && [ "$HG" = 1 ] && _why=game
  [ -n "$_why" ] || return 0
  [ "$_why" != game ] && [ "$_now" -lt "$CUTWAIT" ] && return 0
  # not charging anyway (full, or the ROM's own limit): nothing to pause
  [ "$(bstatus)" = Charging ] || return 0
  _nc=0; [ "$_why" = game ] && _nc=1
  pause_on "$_nc"; _pr=$?
  if [ "$_pr" = 0 ]; then
    PWHY=$_why
    case "$_why" in
      temp) [ "$PLOGGED" != temp ] && klog battery "Charging paused" "$(fmt "$_t"), back at $(fmt $((PT - 30))): $(how_txt) ($(short "$PNODE"))" ;;
      level) [ "$PLOGGED" != level ] && klog battery "Charging paused" "battery at ${_l}%, held at ${PL}%: $(how_txt) ($(short "$PNODE"))" ;;
      game) NGAME=$((NGAME + 1)); klog battery "Bypass while gaming" "$GNAME open: $(how_txt) ($(short "$PNODE"))" ;;
    esac
    [ "$_why" = game ] || PLOGGED=$_why
  elif [ "$_why" = game ]; then
    # gaming needs a switch that keeps the charger on: none here, the temperature / level pause stays
    GAME=0
    klog battery "Bypass while gaming not possible" "no charging switch or current limit kept the charger on$([ "$HOW" = cut ] && echo " (Cut the charger input is chosen)")"
  else
    POK=0
    if [ "$_pr" = 1 ]; then
      klog battery "Charging pause not possible" "this kernel has no charging switch HyperCool knows"
    else
      klog battery "Charging pause not possible" "no charging switch stopped the charging$([ "$HOW" != auto ] && echo " ($HOW only)"), it stays on until the next boot"
    fi
  fi
}

# ---------------------------------------------------------------- temperature warning
WARNED=0; NWARN=0
warn_tick() {
  [ "$WARN" = 1 ] && [ -n "$_t" ] || return 0
  if [ "$WARNED" = 0 ] && [ "$_t" -ge "$WT" ]; then
    WARNED=1; NWARN=$((NWARN + 1))
    _wm="Battery at $(fmt "$_t")$(plugged && echo " while charging"). Let the phone cool down: stop gaming or charging for a while."
    su -lp 2000 -c "cmd notification post -S bigtext -t 'HyperCool' hc_temp '$_wm'" </dev/null >/dev/null 2>&1 ||
      cmd notification post -S bigtext -t HyperCool hc_temp "$_wm" </dev/null >/dev/null 2>&1
    klog battery "Battery hot" "$(fmt "$_t"), warning at $(fmt "$WT")"
  elif [ "$WARNED" = 1 ] && [ "$_t" -le $((WT - 30)) ]; then
    WARNED=0
  fi
}

# ---------------------------------------------------------------- history
HLAST=0; HPLUG=x; HPAUSE=x; HN=$(grep -c . "$CSV" 2>/dev/null); HN=${HN:-0}
hist_tick() {
  [ "$HIST" = 1 ] && [ -n "$_l" ] || return 0
  _now=$(date +%s)
  _hp=0; plugged && _hp=1
  [ $((_now - HLAST)) -ge "$HSTEP" ] || [ "$_hp" != "$HPLUG" ] || [ "$PAUSED" != "$HPAUSE" ] || return 0
  _hs=0; screen_on && _hs=1
  echo "$_now,$_l,${_t:-},$_hp,$_hs,$PAUSED" >> "$CSV"
  HLAST=$_now; HPLUG=$_hp; HPAUSE=$PAUSED; HN=$((HN + 1))
  # the last 48 h (cut back only now and then)
  if [ "$HN" -gt 1300 ]; then
    awk -F, -v c=$((_now - 172800)) '$1 >= c' "$CSV" | tail -n 1200 > "$CSV.$$" && mv -f "$CSV.$$" "$CSV"
    rm -f "$CSV.$$"; HN=$(grep -c . "$CSV" 2>/dev/null); HN=${HN:-0}
  fi
}

_nlast=0; _nkey=x
note() {
  _nn=$(date +%s); _k="$PAUSED$POK$WARNED$PWHY"
  [ "$_k" != "$_nkey" ] || [ $((_nn - _nlast)) -ge 600 ] || return 0
  _nkey=$_k; _nlast=$_nn
  {
    printf 'temp=%s level=%s' "${_t:-?}" "${_l:-?}"
    [ "$PAUSE" = 1 ] && printf ' pause=%s%s pauses=%s' "$([ "$PAUSED" = 1 ] && echo on || echo off)" \
      "$([ "$POK" = 0 ] && echo ",unavailable")" "$NPAUSE"
    [ "$PAUSE" = 1 ] && [ -s "$NODEF" ] && printf ' switch=%s' "$(short "$(cut -d'|' -f2 "$NODEF")")"
    [ "$PAUSE" = 1 ] && [ "$GAME" = 1 ] && printf ' gaming=%s game_bypasses=%s' "$([ "$PAUSED" = 1 ] && [ "$PWHY" = game ] && echo on || echo off)" "$NGAME"
    [ "$WARN" = 1 ] && printf ' warnings=%s' "$NWARN"
    [ "$HIST" = 1 ] && printf ' samples=%s' "$HN"
    printf ' last=%s\n' "$(date '+%H:%M:%S')"
  } > "$STATE"
}

# put back what batp.save holds (a keeper that was killed, or stopped while it tried a switch)
rel_save() {
  [ -s "$SAVE" ] || { rm -f "$SAVE"; return 0; }
  while IFS='|' read -r _n _nv _pv _pk; do
    [ -n "$_n" ] && [ -e "$_n" ] || continue
    # a current limit that is not ours any more (the ROM changed it) stays as it is
    [ "$_pk" = limit ] && ! same "$(rd "$_n")" "$_pv" && continue
    wr "$_n" "$_nv"
  done < "$SAVE"
  rm -f "$SAVE"
}
WHY=""
stop() {
  pause_off
  rel_save
  [ -n "$WHY" ] && kstop battery "$WHY"
  [ "$(cat "$PIDF" 2>/dev/null)" = "$$" ] && rm -f "$PIDF"
  exit 0
}
trap stop TERM INT HUP

on() { grep -q "^$1=1" "$HC_DATA/config.conf" 2>/dev/null; }
# a pause left by a keeper that was killed
rel_save

while :; do
  [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ] || [ ! -d "$MODDIR" ] && { WHY="module disabled or removed"; stop; }
  # a feature turned off in the settings stops at once (the rest keeps going)
  [ "$PAUSE" = 1 ] && ! on chg_pause && { PAUSE=0; POK=0; pause_off; }
  [ "$HIST" = 1 ] && ! on bat_hist && HIST=0
  [ "$WARN" = 1 ] && ! on temp_warn && WARN=0
  [ "$PAUSE" = 0 ] && [ "$HIST" = 0 ] && [ "$WARN" = 0 ] && { WHY="turned off in the settings"; stop; }
  [ "$POK" = 0 ] && [ "$HIST" = 0 ] && [ "$WARN" = 0 ] && { WHY="charging pause not possible on this phone"; stop; }
  _t=$(temp) || _t=""
  _l=$(level) || _l=""
  pause_tick
  warn_tick
  hist_tick
  note
  if [ "$PAUSED" = 1 ] && [ "$PKIND" = limit ]; then sleep "$LSTEP"
  elif plugged || [ "$PAUSED" = 1 ]; then sleep "$STEP"; else sleep "$ISTEP"; fi
done
