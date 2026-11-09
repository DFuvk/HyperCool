#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Yudharn
# HyperCool - late_start service
MODDIR=${0%/*}
# shellcheck source=/dev/null
. "$MODDIR/common/functions.sh"

mkdir -p "$HC_DATA" "$HC_BAKDIR"
[ -f "$HC_CFG" ] || cp -f "$MODDIR/common/default.conf" "$HC_CFG"
# post-fs-data writes this boot's boot_id into .pfd_ran when it completes. A marker without this
# boot's id means the root manager skipped that stage: the boot_config.conf snapshot is from the
# previous boot, so take a fresh one from the saved config (a WebUI save then applies this boot)
_pfd_ok=""
[ "$(cat "$HC_DATA/.pfd_ran" 2>/dev/null)" = "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" ] && _pfd_ok=1
if [ -n "$_pfd_ok" ]; then
  rm -f "$HC_DATA/.pfd_ran"
else
  cp -f "$HC_CFG" "$HC_BOOTCFG"
  log "post-fs-data stage was skipped this boot (root manager): using the saved config directly"
fi
# apply the snapshot taken at post-fs-data, so a WebUI save during boot waits for the next boot
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

# post-fs-data was skipped this boot (boot_id check at the top): its prop features were
# re-applied above (persist), but log.tag was not — set it too and make the statuses describe
# this boot honestly instead of the stale "applied" lines copied from the previous boot.
if [ -f "$MODDIR/disable" ] || [ -n "${_pfd_ok:-}" ]; then
  : # switched off / safe mode, or post-fs-data ran: status_pfd.conf is from this boot
else
  log "post-fs-data stage was skipped this boot (root manager): re-applying its features from service"
  sed -i '/^log_reduce=/d;/^debug_props=/d;/^x_props=/d' "$HC_STATUS"
  if on log_reduce; then
    if resetprop -n log.tag W >/dev/null 2>&1; then
      st log_reduce applied "only Warning+ logs written (service fallback)"
    else
      st log_reduce failed "resetprop not available or refused log.tag"
    fi
  else
    st log_reduce off
  fi
  if on debug_props; then
    _c=$(hc_props "$HC_DEBUG_PROPS")
    if [ "${_c:-0}" -gt 0 ]; then st debug_props applied "$_c debug/trace props set for this boot (service fallback)"
    else st debug_props failed "no prop accepted (resetprop missing or refused)"; fi
  else
    st debug_props off
  fi
  if on x_props; then
    _c=$(apply_props_file "$MODDIR/common/x_props.txt")
    if [ "${_c:-0}" -gt 0 ]; then st x_props applied "$_c extra logging props set for this boot (service fallback)"
    else st x_props failed "no prop accepted (resetprop missing or refused)"; fi
  else
    st x_props off
  fi
  # SurfaceFlinger reads its timers when it starts: they could not be set before it started,
  # so let rr_adapt report honestly (0 props set by post-fs-data)
  if on rr_adapt; then
    echo 0 > "$HC_DATA/.rr_props"
  else
    rm -f "$HC_DATA/.rr_props"
  fi
fi

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
f_charge_hold_gone

# ---------- kernel: drain ----------
f_cpu_idle
f_ufs_pm
f_vm_tune
f_io_tune
f_debug_off
f_wakelock_block

# ---------- ROM: blocked apps first (a moved app's protect record is restored
# by f_bg_block itself), then protected apps ----------
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
# reaching the end of the apply is a good boot, even if boot_completed was slow
rm -f "$HC_DATA/boot_tries"

_a=$(grep -c '=applied|' "$HC_STATUS")
_p=$(grep -c '=partial|' "$HC_STATUS")
_s=$(grep -c '=skipped|' "$HC_STATUS")
_f=$(grep -c '=failed|' "$HC_STATUS")
_o=$(grep -c '=off|' "$HC_STATUS")
log "done: $_a applied, $_p partial, $_s skipped, $_f failed, $_o off"

_desc="Heat and battery fix for Android - $(hc_soc_label) (one-shot at boot$(on charge_limit && echo ", charge-limit keeper running")$({ on soff_prof || on wifi_keep || on x_compact || on soff_radio || on f2fs_gc || on x_dexopt_auto; } && echo ", screen-off keeper running")). Last boot: $_a applied, $_p partial, $_s unsupported, $_f failed, $_o off. Configure in WebUI. Telegram Channel: @ModuleArchives."
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
