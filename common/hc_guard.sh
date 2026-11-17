#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Yudharn
# HyperCool guard (installed to /data/adb/service.d by HyperCool)
MOD=/data/adb/modules/hypercool
D=/data/adb/hypercool
# release the 80% charge cap only when HyperCool set it (marker / keeper state)
_hc_release_cap() {
  if [ -f "$D/chg_watch.set" ] || [ -f "$D/chg_watch.state" ]; then
    for _n in /sys/class/qcom-battery/night_charging /sys/class/power_supply/battery/night_charging; do
      [ -e "$_n" ] && { echo 0 > "$_n"; } 2>/dev/null
    done
  fi
}
if [ ! -d "$MOD" ] || [ -f "$MOD/remove" ]; then
  # uninstall.sh normally restores everything; give it time, then clean up whatever is left
  sleep 180
  # a reinstall during the grace period must keep its fresh data and guard
  if [ -d "$MOD" ] && [ ! -f "$MOD/remove" ]; then
    exit 0
  fi
  _hc_release_cap
  if [ -f "$D/restore.sh" ]; then
    sh "$D/restore.sh" --all --wait-boot --purge >/dev/null 2>&1 || exit 0
  fi
  rm -f "$0"
  exit 0
fi
[ -f "$MOD/disable" ] || exit 0
_hc_release_cap
_need=0
[ -s "$D/backup/rom.bak" ] && _need=1
[ -s "$D/soff_radio.save" ] && _need=1
[ -s "$D/soff_data.save" ] && _need=1
[ -s "$D/soff_watch.save" ] && _need=1
[ -s "$D/heat.save" ] && _need=1
[ -e "$D/doze_forced" ] && _need=1
if [ "$_need" = 1 ] && [ -f "$D/restore.sh" ]; then
  [ -f "$MOD/common/klog.sh" ] && HC_DATA=$D . "$MOD/common/klog.sh" || klog() { :; }
  if sh "$D/restore.sh" --all --wait-boot >/dev/null 2>&1; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') module disabled: pending changes restored by the guard" >> "$D/boot.log"
    klog restore "Values put back" "module disabled: every change HyperCool had left was restored"
  else
    echo "$(date '+%Y-%m-%d %H:%M:%S') module disabled: some pending changes kept for a retry" >> "$D/boot.log"
    klog restore "Values put back (partly)" "module disabled: some changes were not accepted, tried again at the next boot"
  fi
fi
exit 0
