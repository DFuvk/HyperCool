#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Yudharn
# HyperCool - keeper event log, shown in the WebUI (Home > Keepers).
# klog <keeper> <action> <result> appends "MM-DD HH:MM:SS|keeper|action|result" to keeper.log.
# Only the last 30 lines are kept; the file is cut back only when it passes 40 lines, so most
# events are a single small append.
HC_KLOG=${HC_KLOG:-${HC_DATA:-/data/adb/hypercool}/keeper.log}
klog() {
  _k1=$(printf '%s' "$1" | tr -d '\r\n|')
  _k2=$(printf '%s' "$2" | tr '\r\n|' '  /')
  _k3=$(printf '%s' "$3" | tr '\r\n|' '  /')
  printf '%s|%s|%s|%s\n' "$(date '+%m-%d %H:%M:%S')" "$_k1" "$_k2" "$_k3" >> "$HC_KLOG" 2>/dev/null || return 0
  _kn=$(grep -c . "$HC_KLOG" 2>/dev/null)
  if [ "${_kn:-0}" -gt 40 ]; then
    tail -n 30 "$HC_KLOG" > "$HC_KLOG.$$" 2>/dev/null && mv -f "$HC_KLOG.$$" "$HC_KLOG"
    rm -f "$HC_KLOG.$$"
  fi
  return 0
}
