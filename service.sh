#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Yudharn
# HyperCool - late_start service
MODDIR=${0%/*}
# shellcheck source=/dev/null
. "$MODDIR/common/functions.sh"

mkdir -p "$HC_DATA" "$HC_BAKDIR"
[ -f "$HC_CFG" ] || cp -f "$MODDIR/common/default.conf" "$HC_CFG"
# apply the snapshot taken at post-fs-data, so a WebUI save during boot waits for the next boot
[ -f "$HC_BOOTCFG" ] || cp -f "$HC_CFG" "$HC_BOOTCFG"
HC_CFG=$HC_BOOTCFG

# persist.* props set in post-fs-data can be overwritten when init loads stored persistent props
on debug_props && hc_props "$HC_DEBUG_PROPS" persist >/dev/null
on blur_off && hc_props "$HC_BLUR_PROPS" persist >/dev/null
on x_props && apply_props_file "$MODDIR/common/x_props.txt" persist >/dev/null

# ---------- wait for boot (bounded) ----------
_i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$_i" -lt 240 ]; do
  sleep 2
  _i=$((_i + 2))
done

# Android finished booting: this boot counts as good (crash-loop safe mode, see post-fs-data.sh)
[ "$(getprop sys.boot_completed)" = "1" ] && rm -f "$HC_DATA/boot_tries"
if [ -f "$HC_DATA/safe_mode" ]; then
  log "safe mode had switched HyperCool off at $(cat "$HC_DATA/safe_mode" 2>/dev/null); it is on again"
  rm -f "$HC_DATA/safe_mode"
fi

# zram right after boot, before apps fill it (it must be emptied to be rebuilt)
HC_ZRAM_DONE=0
if on x_zram; then
  _i=0
  while [ "$_i" -lt 30 ] && ! grep -q 'zram0' /proc/swaps 2>/dev/null; do sleep 2; _i=$((_i + 2)); done
  HC_STATUS_OUT=$HC_DATA/.zram_status
  : > "$HC_STATUS_OUT"
  f_x_zram
  HC_ZRAM_DONE=1
fi

# Let the ROM finish its own boot-time tuning first, then apply on top.
_delay=$(rng apply_delay 30 10 120)
sleep "$_delay"

log "boot completed, applying after ${_delay}s delay"
if [ -f "$HC_PFD_STATUS" ]; then cp -f "$HC_PFD_STATUS" "$HC_STATUS"; else : > "$HC_STATUS"; fi
# shellcheck disable=SC2034
HC_STATUS_OUT=$HC_STATUS

# ---------- kernel: heat ----------
hc_keep_reset
f_cpu_cap
f_cpu_cap_little
f_prime_park
f_cpu_keeper
f_gpu_cap
f_gpu_idle
f_walt_tune
f_input_boost_off
f_bg_cpuset
f_blur_off_verify
f_charge_cool
f_charge_limit
f_charge_hold

# ---------- kernel: drain ----------
f_cpu_idle
f_ufs_pm
f_vm_tune
f_io_tune
f_debug_off
f_wakelock_block

# ---------- ROM: protected apps first, then restrictions ----------
f_bg_block
f_protect_apps
f_app_bucket
f_app_disable

# ---------- ROM / system ----------
f_app_freezer
f_doze_aggr
f_devcfg_lock
f_gms_doze_verify
f_scan_off
f_loc_throttle
f_net_save
f_standby
f_stats_reduce
f_tracking_off
f_debloat
f_joyose_off

# ---------- long battery ----------
f_saver_policy
f_saver_trigger
f_saver_dim
f_smart_px
f_rr_adapt
f_refresh_rate
f_anim_scale

# ---------- more: merged extras (all off unless enabled in the WebUI) ----------
f_x_sched
f_x_kquiet
f_x_net
f_x_io
f_x_xiaomi_fw
f_x_ram_opt
f_x_multitask
if [ "$HC_ZRAM_DONE" = 1 ]; then
  # some ROMs set their own zram again after boot: check once more and set it back
  HC_STATUS_OUT=$HC_DATA/.zram_status2
  : > "$HC_STATUS_OUT"
  f_x_zram
  HC_STATUS_OUT=$HC_STATUS
  if grep -q '(already set)' "$HC_DATA/.zram_status2"; then
    cat "$HC_DATA/.zram_status" >> "$HC_STATUS"
  else
    sed '/^x_zram=applied|/s/$/; set again, the ROM had changed it after boot/' "$HC_DATA/.zram_status2" >> "$HC_STATUS"
  fi
  rm -f "$HC_DATA/.zram_status" "$HC_DATA/.zram_status2"
else
  f_x_zram
fi
f_x_gms_freeze
f_x_log_nuke
f_x_track
f_x_diag
f_x_cache_auto
f_x_cache_keep
f_x_kpower
f_x_vm_lite
f_x_eas
f_x_job_limit
f_x_rpm
f_x_cache_notify
f_x_balanced
f_x_kcommon

# ---------- battery calibration in progress: start its keeper again ----------
if grep -qE '^phase=(discharge|charge|hold)$' "$HC_DATA/bcal.state" 2>/dev/null; then
  nohup sh "$MODDIR/common/bcal_watch.sh" >/dev/null 2>&1 &
  log "battery calibration in progress: keeper started"
fi

# ---------- screen-off profile keeper (after everything else, so it saves the final values) ----------
f_soff_prof

# ---------- bookkeeping ----------
cp -f "$HC_BOOTCFG" "$HC_DATA/last_applied.conf"
cp -f "$MODDIR/common/restore.sh" "$HC_DATA/restore.sh"
mkdir -p /data/adb/service.d
cp -f "$MODDIR/common/hc_guard.sh" /data/adb/service.d/.hypercool_guard.sh && chmod 0755 /data/adb/service.d/.hypercool_guard.sh
date '+%Y-%m-%d %H:%M:%S' > "$HC_DATA/last_boot"
# slow boot (boot_completed came after the wait above): count it as good now
[ "$(getprop sys.boot_completed)" = "1" ] && rm -f "$HC_DATA/boot_tries"

_a=$(grep -c '=applied|' "$HC_STATUS")
_p=$(grep -c '=partial|' "$HC_STATUS")
_s=$(grep -c '=skipped|' "$HC_STATUS")
_f=$(grep -c '=failed|' "$HC_STATUS")
_o=$(grep -c '=off|' "$HC_STATUS")
log "done: $_a applied, $_p partial, $_s skipped, $_f failed, $_o off"

_desc="Heat and battery fix for Android - $(hc_soc_label) (one-shot at boot$({ on charge_limit || on charge_hold; } && echo ", charge-limit keeper running")$({ on soff_prof || on wifi_keep || on x_compact || on soff_radio || on f2fs_gc || on x_dexopt_auto; } && echo ", screen-off keeper running")). Last boot: $_a applied, $_p partial, $_s unsupported, $_f failed, $_o off. Configure in WebUI. Telegram Channel: @ModuleArchives."
sed -i "s#^description=.*#description=$_desc#" "$MODDIR/module.prop"

# ---------- boot notification ----------
if [ "$(cfg boot_notify 1)" = 1 ]; then
  if [ "$_f" -eq 0 ]; then
    _nm="HyperCool applied successfully: $((_a + _p)) features active. Less heat, longer battery!"
  else
    _nm="HyperCool applied: $((_a + _p)) features active, $_f failed. Open the WebUI for details."
  fi
  hc_notify hc_boot "$_nm"
fi

exit 0
