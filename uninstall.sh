#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Yudharn
# HyperCool - uninstall
HC_DATA=/data/adb/hypercool
export PATH=/system/bin:/system/xbin:/vendor/bin:/data/adb/ksu/bin:/data/adb/magisk:"$PATH"
# module dir (also when started as "sh uninstall.sh" from inside it)
MD=${0%/*}; [ -f "$MD/common/radio.sh" ] || MD=/data/adb/modules/hypercool
# keep the standalone helpers for the background restore after the module files are gone
mkdir -p "$HC_DATA" 2>/dev/null
[ -f "$MD/common/restore.sh" ] && cp -f "$MD/common/restore.sh" "$HC_DATA/restore.sh" 2>/dev/null
[ -f "$MD/common/radio.sh" ] && cp -f "$MD/common/radio.sh" "$HC_DATA/radio.sh" 2>/dev/null
[ -f "$MD/common/soff_restore.sh" ] && cp -f "$MD/common/soff_restore.sh" "$HC_DATA/soff_restore.sh" 2>/dev/null
[ -f "$MD/common/heat_watch.sh" ] && cp -f "$MD/common/heat_watch.sh" "$HC_DATA/heat_watch.sh" 2>/dev/null
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
# stop the charge-limit keeper and give the night charging flag back to the ROM,
# but only when HyperCool set it (marker / keeper state): a flag set by the ROM itself stays
if [ -f "$HC_DATA/chg_watch.set" ] || [ -f "$HC_DATA/chg_watch.state" ]; then
  _wp=$(cat "$HC_DATA/chg_watch.pid" 2>/dev/null)
  case "$_wp" in ''|*[!0-9]*) ;; *) grep -q chg_watch "/proc/$_wp/cmdline" 2>/dev/null && kill "$_wp" 2>/dev/null
    _i=0; while [ "$_i" -lt 5 ] && [ -d "/proc/$_wp" ]; do sleep 1; _i=$((_i + 1)); done ;; esac
  for _n in /sys/class/qcom-battery/night_charging /sys/class/power_supply/battery/night_charging; do
    [ -e "$_n" ] && { echo 0 > "$_n"; } 2>/dev/null
  done
fi
# stop the battery keeper (charging pause, history, temperature warning): its trap turns charging
# back on; TERM waits for the sleep it is in, so that sleep is stopped too
_bq=$(cat "$HC_DATA/bat_watch.pid" 2>/dev/null)
case "$_bq" in ''|*[!0-9]*) ;; *) if grep -q bat_watch "/proc/$_bq/cmdline" 2>/dev/null; then
  kill "$_bq" 2>/dev/null
  for _ck in /proc/[0-9]*; do
    [ "$(awk '/^PPid:/{print $2}' "$_ck/status" 2>/dev/null)" = "$_bq" ] && kill "${_ck##*/}" 2>/dev/null
  done
  _i=0; while [ "$_i" -lt 5 ] && [ -d "/proc/$_bq" ]; do sleep 1; _i=$((_i + 1)); done
  [ -d "/proc/$_bq" ] && grep -q bat_watch "/proc/$_bq/cmdline" 2>/dev/null && kill -9 "$_bq" 2>/dev/null
fi ;; esac
if [ -s "$HC_DATA/batp.save" ]; then
  while IFS='|' read -r _bn _bb _bw _bk; do
    [ -n "$_bn" ] && [ -e "$_bn" ] || continue
    [ "$_bk" = limit ] && [ "$(cat "$_bn" 2>/dev/null)" != "$_bw" ] && continue
    { chmod u+w "$_bn" 2>/dev/null; echo "$_bb" > "$_bn"; } 2>/dev/null
  done < "$HC_DATA/batp.save"
  rm -f "$HC_DATA/batp.save"
fi
rm -f "$HC_DATA/bat_watch.pid" "$HC_DATA/batp.games" "$HC_DATA/leftover.list" "$HC_DATA"/leftover.pk.*
# Game battery mode is put back by restore.sh --all below (Android keeps game modes across reboots)
# stop the Heat guard keeper (it puts its refresh rate / CPU limits back when it stops)
_hp=$(cat "$HC_DATA/heat_watch.pid" 2>/dev/null)
case "$_hp" in ''|*[!0-9]*) ;; *) grep -q heat_watch "/proc/$_hp/cmdline" 2>/dev/null && kill "$_hp" 2>/dev/null
  _i=0; while [ "$_i" -lt 5 ] && [ -d "/proc/$_hp" ]; do sleep 1; _i=$((_i + 1)); done
  [ -d "/proc/$_hp" ] && grep -q heat_watch "/proc/$_hp/cmdline" 2>/dev/null && kill -9 "$_hp" 2>/dev/null ;; esac
[ -s "$HC_DATA/heat.save" ] && [ -f "$HC_DATA/heat_watch.sh" ] && env HC_DATA="$HC_DATA" sh "$HC_DATA/heat_watch.sh" restore </dev/null >/dev/null 2>&1
rm -f "$HC_DATA/heat_watch.pid" "$HC_DATA/heat.rr" "$HC_DATA/wk.base" "$HC_DATA/wk.apps" "$HC_DATA/wk.off" "$HC_DATA"/wk.chk.* "$HC_DATA/hibernate.state" "$HC_DATA"/hib.pk* "$HC_DATA/hib.lock"
# stop the screen-off profile keeper (it writes the saved values back when it stops)
_sp=$(cat "$HC_DATA/soff_watch.pid" 2>/dev/null)
case "$_sp" in ''|*[!0-9]*) ;; *) grep -q soff_watch "/proc/$_sp/cmdline" 2>/dev/null && kill "$_sp" 2>/dev/null
  _i=0; while [ "$_i" -lt 5 ] && [ -d "/proc/$_sp" ]; do sleep 1; _i=$((_i + 1)); done
  if [ -d "/proc/$_sp" ] && grep -q soff_watch "/proc/$_sp/cmdline" 2>/dev/null; then
    kill -9 "$_sp" 2>/dev/null
    _i=0; while [ "$_i" -lt 2 ] && [ -d "/proc/$_sp" ]; do sleep 1; _i=$((_i + 1)); done
  fi ;; esac
# CPU/GPU/boost values that the keeper could not put back before it stopped
_SLIB=$HC_DATA/soff_restore.sh
[ -f "$_SLIB" ] || _SLIB=$MD/common/soff_restore.sh
if [ -f "$_SLIB" ]; then
  # shellcheck source=/dev/null
  . "$_SLIB"
  [ -s "$HC_DATA/soff_watch.save" ] && hc_soff_restore "$HC_DATA/soff_watch.save"
fi
# Location / Bluetooth and mobile data / NFC the keeper switched off
_RLIB=$HC_DATA/radio.sh
[ -f "$_RLIB" ] || _RLIB=$MD/common/radio.sh
if [ -f "$_RLIB" ]; then
  # shellcheck source=/dev/null
  . "$_RLIB"
  [ -s "$HC_DATA/soff_radio.save" ] && radio_restore
  # mobile data / NFC the keeper switched off
  [ -s "$HC_DATA/soff_data.save" ] && data_restore
fi
# gc_urgent / wake lock of a F2FS GC run that was still going
if [ -s "$HC_DATA/f2fs_gc.save" ] || [ -s "$HC_DATA/f2fs_gc.fpid" ]; then
  # shellcheck source=/dev/null
  [ -f "$MD/common/f2gc.sh" ] && . "$MD/common/f2gc.sh" && gcf_restore uninstall
fi
# an automatic app optimization that was still going
if [ -f "$HC_DATA/dexopt_auto.run" ]; then
  # shellcheck source=/dev/null
  [ -f "$MD/common/dxauto.sh" ] && MODDIR=$MD . "$MD/common/dxauto.sh" && dxa_stop uninstall
fi
# stop the battery calibration keeper
_bq=$(cat "$HC_DATA/bcal_watch.pid" 2>/dev/null)
case "$_bq" in ''|*[!0-9]*) ;; *) grep -q bcal_watch "/proc/$_bq/cmdline" 2>/dev/null && kill "$_bq" 2>/dev/null ;; esac
# stop the touch-only refresh rate keeper; wait for its trap to finish before restore
_rq=$(cat "$HC_DATA/rr_watch.pid" 2>/dev/null)
case "$_rq" in ''|*[!0-9]*) ;; *) grep -q rr_watch "/proc/$_rq/cmdline" 2>/dev/null && kill "$_rq" 2>/dev/null
  _i=0; while [ "$_i" -lt 5 ] && [ -d "/proc/$_rq" ]; do sleep 1; _i=$((_i + 1)); done
  if [ -d "/proc/$_rq" ] && grep -q rr_watch "/proc/$_rq/cmdline" 2>/dev/null; then
    for _ck in /proc/[0-9]*; do
      _ck=${_ck##*/}
      [ "$_ck" = "$_rq" ] && continue
      [ "$(awk '/^PPid:/{print $2}' "/proc/$_ck/status" 2>/dev/null)" = "$_rq" ] && kill "$_ck" 2>/dev/null
    done
    kill -9 "$_rq" 2>/dev/null
    _i=0; while [ "$_i" -lt 2 ] && [ -d "/proc/$_rq" ]; do sleep 1; _i=$((_i + 1)); done
  fi ;; esac
# forced deep Doze left behind by that keeper
[ -f "$HC_DATA/doze_forced" ] && dumpsys deviceidle unforce >/dev/null 2>&1
# the runtime props of the RAM optimizer (ro.lmk.*) are put back
if [ -s "$HC_DATA/persist_props" ]; then
  while IFS='=' read -r _p _v; do
    [ -n "$_p" ] || continue
    resetprop -n "$_p" "$_v" 2>/dev/null
  done < "$HC_DATA/persist_props"
  rm -f "$HC_DATA/persist_props"
fi
# Keep the guard until restore succeeds. If the background restore fails,
# the guard retries on the next boot instead of losing the backup records.
if [ -f "$HC_DATA/restore.sh" ]; then
  nohup sh -c 'sh /data/adb/hypercool/restore.sh --all --wait-boot --purge && rm -f /data/adb/service.d/.hypercool_guard.sh' >/dev/null 2>&1 &
else
  # Without a restorer, deleting the records would lose the only copy of the values. Keep
  # HC_DATA for a later manual restore instead of removing it silently.
  rm -f /data/adb/service.d/.hypercool_guard.sh
fi
