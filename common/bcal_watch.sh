#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Yudharn
# HyperCool - battery calibration keeper (only runs during a calibration started from the WebUI)
# One full cycle lets the fuel gauge learn the real capacity: use the phone down to 5%, charge to
# 100% without unplugging, keep it plugged in until charging really ends (status Full + 5 min,
# at most 1 h after 100%). Checks once a minute, no wakelock; the charge
# limit keeper pauses itself while a calibration is running. State: phase=discharge|charge|hold|done
export PATH=/system/bin:/system/xbin:/vendor/bin:/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:"$PATH"
HC_DATA=/data/adb/hypercool
MODDIR=/data/adb/modules/hypercool
S=$HC_DATA/bcal.state
PIDF=$HC_DATA/bcal_watch.pid
LOW=5
HOLD=3600
SETTLE=300

_old=$(cat "$PIDF" 2>/dev/null)
case "$_old" in ''|*[!0-9]*) ;; *)
  [ "$_old" != "$$" ] && grep -q bcal_watch "/proc/$_old/cmdline" 2>/dev/null && exit 0 ;;
esac
echo $$ > "$PIDF"

get() { sed -n "s/^$1=//p" "$S" 2>/dev/null | tail -n 1; }
setk() {
  { grep -v "^$1=" "$S" 2>/dev/null; echo "$1=$2"; } > "$S.t" && mv -f "$S.t" "$S"
}
notify() {
  su -lp 2000 -c "cmd notification post -S bigtext -t 'HyperCool' hc_bcal '$1'" </dev/null >/dev/null 2>&1 ||
    cmd notification post -S bigtext -t HyperCool hc_bcal "$1" </dev/null >/dev/null 2>&1
}
B=/sys/class/power_supply/battery
lvl() { _l=$(cat "$B/capacity" 2>/dev/null); case "$_l" in ''|*[!0-9]*) echo 50 ;; *) echo "$_l" ;; esac; }
plugged() {
  case "$(cat "$B/status" 2>/dev/null)" in Charging|Full) return 0 ;; esac
  for _p in /sys/class/power_supply/usb/online /sys/class/power_supply/ac/online \
            /sys/class/power_supply/wireless/online /sys/class/power_supply/dc/online; do
    [ "$(cat "$_p" 2>/dev/null)" = 1 ] && return 0
  done
  return 1
}
capnow() { cat "$B/charge_full" 2>/dev/null || cat /sys/class/power_supply/bms/charge_full 2>/dev/null; }

while :; do
  [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ] || [ ! -d "$MODDIR" ] && break
  _l=$(lvl); _now=$(date +%s)
  case "$(get phase)" in
    discharge)
      if [ "$_l" -le "$LOW" ]; then
        setk phase charge
        plugged || notify "Battery calibration: battery at ${_l}%. Plug in the charger now and charge to 100% without unplugging."
      fi ;;
    charge)
      if plugged; then
        [ "$(get seen)" = 1 ] || setk seen 1
        [ "$(get warned)" = 1 ] && setk warned 0
        if [ "$(cat "$B/status" 2>/dev/null)" = Full ] || [ "$_l" -ge 100 ]; then
          setk phase hold; setk full "$_now"
          notify "Battery calibration: battery at 100%. Keep the charger plugged in until charging finishes (at most 1 h), HyperCool tells you when."
        fi
      elif [ "$(get seen)" = 1 ] && [ "$(get warned)" != 1 ]; then
        # unplugged after charging had started (before that, it is still waiting for the charger)
        setk warned 1; setk breaks $(( $(get breaks) + 1 ))
        notify "Battery calibration: charging stopped at ${_l}%. Plug the charger back in and charge to 100% without unplugging."
      fi ;;
    hold)
      _f=$(get full); case "$_f" in ''|*[!0-9]*) _f=$_now ;; esac
      # charging really ended (Android reports Full): give the gauge a few more minutes
      _e=$(get fullst)
      if [ -z "$_e" ] && [ "$(cat "$B/status" 2>/dev/null)" = Full ]; then setk fullst "$_now"; _e=$_now; fi
      if ! plugged || [ $((_now - _f)) -ge "$HOLD" ] || { [ -n "$_e" ] && [ $((_now - _e)) -ge "$SETTLE" ]; }; then
        plugged || setk early 1
        setk cap1 "$(capnow)"; setk end "$_now"; setk phase "done"
        notify "Battery calibration done. You can unplug the charger now."
        break
      fi ;;
    *) break ;;
  esac
  sleep 60
done
rm -f "$PIDF"
exit 0
