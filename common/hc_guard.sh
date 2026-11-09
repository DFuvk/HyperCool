#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Yudharn
# HyperCool guard (installed to /data/adb/service.d by HyperCool)
MOD=/data/adb/modules/hypercool
D=/data/adb/hypercool
if [ ! -d "$MOD" ] || [ -f "$MOD/remove" ]; then
  # uninstall.sh normally restores everything; give it time, then clean up whatever is left
  sleep 180
  # a reinstall during the grace period must keep its fresh data and guard
  if [ -d "$MOD" ] && [ ! -f "$MOD/remove" ]; then
    exit 0
  fi
  if [ -f "$D/restore.sh" ]; then
    sh "$D/restore.sh" --all --wait-boot --purge >/dev/null 2>&1 || exit 0
  fi
  rm -f "$0"
  exit 0
fi
[ -f "$MOD/disable" ] || exit 0
# release the 80% charge cap only when HyperCool set it (marker / keeper state)
if [ -f "$D/chg_watch.set" ] || [ -f "$D/chg_watch.state" ]; then
  for _n in /sys/class/qcom-battery/night_charging /sys/class/power_supply/battery/night_charging; do
    [ -e "$_n" ] && { echo 0 > "$_n"; } 2>/dev/null
  done
fi
if [ -s "$D/backup/rom.bak" ] && [ -f "$D/restore.sh" ]; then
  sh "$D/restore.sh" --all --wait-boot >/dev/null 2>&1
  echo "$(date '+%Y-%m-%d %H:%M:%S') module disabled: ROM changes restored by the guard" >> "$D/boot.log"
fi
exit 0
