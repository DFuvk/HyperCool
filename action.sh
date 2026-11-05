#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Yudharn
# HyperCool - Action button: print last boot report (read-only)
HC_DATA=/data/adb/hypercool
echo "=== HyperCool - last boot report ==="
[ -f "$HC_DATA/last_boot" ] && echo "Applied at: $(cat "$HC_DATA/last_boot")"
echo ""
if [ -f "$HC_DATA/status.conf" ]; then
  while IFS='=' read -r k rest; do
    [ -n "$k" ] || continue
    state=${rest%%\|*}
    det=${rest#*\|}
    printf '%-16s %-8s %s\n' "$k" "$state" "$det"
  done < "$HC_DATA/status.conf"
else
  echo "No report yet - reboot once after installing."
fi
echo ""
echo "Open the WebUI to change options. Changes apply after reboot."
