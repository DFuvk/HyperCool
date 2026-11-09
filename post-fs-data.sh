#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Yudharn
# HyperCool - post-fs-data (blocking stage, kept minimal)
MODDIR=${0%/*}
. "$MODDIR/common/functions.sh"

mkdir -p "$HC_DATA" "$HC_BAKDIR"
[ -f "$HC_CFG" ] || cp -f "$MODDIR/common/default.conf" "$HC_CFG"
# snapshot: this whole boot applies the config as it is right now
cp -f "$HC_CFG" "$HC_BOOTCFG"
HC_CFG=$HC_BOOTCFG

: > "$HC_LOG"
: > "$HC_PFD_STATUS"
HC_STATUS_OUT=$HC_PFD_STATUS
log "HyperCool post-fs-data - $(getprop ro.product.device) / $(getprop ro.build.version.incremental)"

# ---------- crash-loop safe mode ----------
# every boot adds one try here and service.sh clears it once Android has finished booting. Three tries in a
# row without that (a boot loop) = switch the module off for the next boot, leaving the ROM as it is
_bf=$HC_DATA/boot_tries
_bt=$(cat "$_bf" 2>/dev/null)
case "$_bt" in ''|*[!0-9]*) _bt=0 ;; esac
_bt=$((_bt + 1))
echo "$_bt" > "$_bf"
if [ "$_bt" -ge 3 ]; then
  rm -f "$_bf"
  rm -rf "$MODDIR/system" "$MODDIR/product" "$MODDIR/system_ext"
  touch "$MODDIR/disable"
  _sd=$(date '+%Y-%m-%d %H:%M:%S')
  echo "$_sd" > "$HC_DATA/safe_mode"
  log "SAFE MODE: 3 boots in a row did not finish, HyperCool switched itself off ($_sd)"
  sed -i "s#^description=.*#description=SAFE MODE: HyperCool switched itself off after 3 boots that did not finish ($_sd). Turn it on again in the manager to use it.#" "$MODDIR/module.prop"
  exit 0
fi

# ---------- GMS Doze: rebuild sysconfig overlay each boot ----------
rm -rf "$MODDIR/system" "$MODDIR/product" "$MODDIR/system_ext"
if on gms_doze; then
  _n=0
  for _d in /system/etc/sysconfig /product/etc/sysconfig /system_ext/etc/sysconfig; do
    [ -d "$_d" ] || continue
    for _x in "$_d"/*.xml; do
      [ -f "$_x" ] || continue
      grep -q 'allow-in-power-save package="com.google.android.gms"' "$_x" || continue
      # module root mirrors the real partition: /product -> $MODDIR/product,
      # /system_ext -> $MODDIR/system_ext (not $MODDIR/system/product/...)
      _t="$MODDIR$_d"
      mkdir -p "$_t"
      grep -v 'allow-in-power-save package="com.google.android.gms"' "$_x" > "$_t/${_x##*/}"
      _n=$((_n + 1))
    done
  done
  for _r in "$MODDIR/system" "$MODDIR/product" "$MODDIR/system_ext"; do
    [ -d "$_r" ] || continue
    find "$_r" -type d -exec chmod 755 {} + 2>/dev/null
    find "$_r" -type f -exec chmod 644 {} + 2>/dev/null
    chcon -R u:object_r:system_file:s0 "$_r" 2>/dev/null
  done
  if [ "$_n" -gt 0 ]; then
    st gms_doze applied "GMS removed from Doze whitelist ($_n sysconfig file(s))"
  else
    st gms_doze skipped "GMS whitelist entry not found (already removed?)"
  fi
else
  st gms_doze off
fi

# ---------- Battery calibration: delete Android's battery stats files (asked for in the WebUI) ----------
# done here, before system_server starts, or it writes its copy back at shutdown
if [ -f "$HC_DATA/bcal_delstats" ]; then
  rm -f /data/system/batterystats.bin /data/system/batterystats-checkin.bin /data/system/batterystats-daily.xml
  rm -rf /data/system/battery-history
  rm -f "$HC_DATA/bcal_delstats"
  log "battery calibration: battery stats files deleted"
fi

# ---------- Reduce logging (non-persistent, gone when turned off) ----------
if on log_reduce; then
  if resetprop -n log.tag W 2>/dev/null; then
    st log_reduce applied "only Warning+ logs written"
  else
    st log_reduce failed "resetprop not available or refused log.tag"
  fi
else
  st log_reduce off
fi

# ---------- Debug / ramdump / trace props (runtime only, never persisted) ----------
if on debug_props; then
  _c=$(hc_props "$HC_DEBUG_PROPS")
  if [ "${_c:-0}" -gt 0 ]; then st debug_props applied "$_c debug/trace props set for this boot"
  else st debug_props failed "no prop accepted (resetprop missing or refused)"; fi
else
  st debug_props off
fi

# ---------- Extra logging props (runtime only) ----------
if on x_props; then
  _c=$(apply_props_file "$MODDIR/common/x_props.txt")
  if [ "${_c:-0}" -gt 0 ]; then st x_props applied "$_c extra logging props set for this boot"
  else st x_props failed "no prop accepted (resetprop missing or refused)"; fi
else
  st x_props off
fi

# ---------- Adaptive refresh rate: SurfaceFlinger touch / idle timers (read when it starts) ----------
if on rr_adapt; then
  _rp=0
  for _pv in ro.surface_flinger.set_touch_timer_ms=500 ro.surface_flinger.set_idle_timer_ms=1000 \
    ro.surface_flinger.use_content_detection_for_refresh_rate=true; do
    resetprop -n "${_pv%%=*}" "${_pv#*=}" 2>/dev/null && _rp=$((_rp + 1))
  done
  echo "$_rp" > "$HC_DATA/.rr_props"
else
  rm -f "$HC_DATA/.rr_props"
fi

# ---------- UI blur off (HyperOS/MIUI props) (GPU heat) - runtime props ----------
if on blur_off; then
  hc_props "$HC_BLUR_PROPS" >/dev/null
fi
# marker for service.sh: this stage ran to the end (service.sh deletes it once seen)
touch "$HC_DATA/.pfd_ran"

exit 0
