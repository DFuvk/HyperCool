#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Yudharn
# HyperCool - uninstall
HC_DATA=/data/adb/hypercool
# stop the cache keeper
_cp=$(cat "$HC_DATA/cache_keeper.pid" 2>/dev/null)
case "$_cp" in ''|*[!0-9]*) ;; *) grep -q cache_clean "/proc/$_cp/cmdline" 2>/dev/null && kill "$_cp" 2>/dev/null ;; esac
# stop the CPU keeper (frequency caps / prime parking)
_kp=$(cat "$HC_DATA/cpu_watch.pid" 2>/dev/null)
case "$_kp" in ''|*[!0-9]*) ;; *) grep -q cpu_watch "/proc/$_kp/cmdline" 2>/dev/null && kill "$_kp" 2>/dev/null ;; esac
# stop a running app optimization (dex2oat); compiled apps stay compiled
_dp=$(cat "$HC_DATA/dexopt/pid" 2>/dev/null)
case "$_dp" in ''|*[!0-9]*) ;; *) grep -q dexopt "/proc/$_dp/cmdline" 2>/dev/null && kill "$_dp" 2>/dev/null ;; esac
# give back a cache dir that an interrupted clean left aside
for _d in /data/user/*/* /data/user_de/*/* /data/media/*/Android/data/*; do
  [ -d "$_d/.hc_keep_cache" ] || continue
  rmdir "$_d/cache" 2>/dev/null
  [ -e "$_d/cache" ] || mv "$_d/.hc_keep_cache" "$_d/cache" 2>/dev/null
done
# stop the charge-limit keeper and give the night charging flag back to the ROM
_wp=$(cat "$HC_DATA/chg_watch.pid" 2>/dev/null)
case "$_wp" in ''|*[!0-9]*) ;; *) grep -q chg_watch "/proc/$_wp/cmdline" 2>/dev/null && kill "$_wp" 2>/dev/null
  _i=0; while [ "$_i" -lt 5 ] && [ -d "/proc/$_wp" ]; do sleep 1; _i=$((_i + 1)); done ;; esac
for _n in /sys/class/qcom-battery/night_charging /sys/class/power_supply/battery/night_charging; do
  [ -e "$_n" ] && { echo 0 > "$_n"; } 2>/dev/null
done
# stop the screen-off profile keeper (it writes the saved values back when it stops)
_sp=$(cat "$HC_DATA/soff_watch.pid" 2>/dev/null)
case "$_sp" in ''|*[!0-9]*) ;; *) grep -q soff_watch "/proc/$_sp/cmdline" 2>/dev/null && kill "$_sp" 2>/dev/null
  _i=0; while [ "$_i" -lt 5 ] && [ -d "/proc/$_sp" ]; do sleep 1; _i=$((_i + 1)); done ;; esac
# Location / Bluetooth the keeper switched off, if it was killed without a clean stop
if [ -s "$HC_DATA/soff_radio.save" ]; then
  # shellcheck source=/dev/null
  [ -f "${0%/*}/common/radio.sh" ] && . "${0%/*}/common/radio.sh" && radio_restore
fi
# gc_urgent / wake lock of a F2FS GC run that was still going
if [ -s "$HC_DATA/f2fs_gc.save" ] || [ -s "$HC_DATA/f2fs_gc.fpid" ]; then
  # shellcheck source=/dev/null
  [ -f "${0%/*}/common/f2gc.sh" ] && . "${0%/*}/common/f2gc.sh" && gcf_restore uninstall
fi
# an automatic app optimization that was still going
if [ -f "$HC_DATA/dexopt_auto.run" ]; then
  # shellcheck source=/dev/null
  [ -f "${0%/*}/common/dxauto.sh" ] && MODDIR=${0%/*} . "${0%/*}/common/dxauto.sh" && dxa_stop uninstall
fi
# stop the battery calibration keeper
_bq=$(cat "$HC_DATA/bcal_watch.pid" 2>/dev/null)
case "$_bq" in ''|*[!0-9]*) ;; *) grep -q bcal_watch "/proc/$_bq/cmdline" 2>/dev/null && kill "$_bq" 2>/dev/null ;; esac
# stop the touch-only refresh rate keeper; wait for its trap to finish before restore
_rq=$(cat "$HC_DATA/rr_watch.pid" 2>/dev/null)
case "$_rq" in ''|*[!0-9]*) ;; *) grep -q rr_watch "/proc/$_rq/cmdline" 2>/dev/null && kill "$_rq" 2>/dev/null
  _i=0; while [ "$_i" -lt 5 ] && [ -d "/proc/$_rq" ]; do sleep 1; _i=$((_i + 1)); done ;; esac
# forced deep Doze left behind by that keeper
[ -f "$HC_DATA/doze_forced" ] && dumpsys deviceidle unforce >/dev/null 2>&1
# Keep the guard until restore succeeds. If the background restore fails,
# the guard retries on the next boot instead of losing the backup records.
if [ -f "$HC_DATA/restore.sh" ]; then
  nohup sh -c 'sh /data/adb/hypercool/restore.sh --all --wait-boot --purge && rm -f /data/adb/service.d/.hypercool_guard.sh' >/dev/null 2>&1 &
else
  rm -f /data/adb/service.d/.hypercool_guard.sh
  rm -rf "$HC_DATA"
fi
