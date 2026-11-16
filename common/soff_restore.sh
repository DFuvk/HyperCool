#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Yudharn
# HyperCool - standalone screen-off value restorer (sourced by restore.sh, functions.sh,
# uninstall.sh and soff_watch.sh). Keeps entries that could not be written so a later run
# can retry them instead of losing the original values.
HC_DATA=${HC_DATA:-/data/adb/hypercool}
HC_SOFF_SAVE=${HC_SOFF_SAVE:-$HC_DATA/soff_watch.save}

# write even when a lock (0444) is on the node, then put the lock back
_hc_soff_wr() {
  [ -e "$1" ] || return 1
  _m=$(stat -c %a "$1" 2>/dev/null)
  chmod u+w "$1" 2>/dev/null
  _r=0; { echo "$2" > "$1"; } 2>/dev/null || _r=1
  [ -n "$_m" ] && chmod "$_m" "$1" 2>/dev/null
  return $_r
}

# hc_soff_restore [savefile]: put back every saved value; entries that fail stay in the file.
# Returns non-zero when at least one value could not be restored (or the file could not be
# rewritten), so callers can keep backups and retry later.
hc_soff_restore() {
  _sf=${1:-$HC_SOFF_SAVE}
  [ -s "$_sf" ] || return 0
  _fail=""
  while IFS='|' read -r _n _v; do
    [ -n "$_n" ] || continue
    _hc_soff_wr "$_n" "$_v" || _fail="$_fail$_n|$_v
"
  done < "$_sf"
  if [ -n "$_fail" ]; then
    printf '%s' "$_fail" > "$_sf" || return 1
    return 1
  fi
  : > "$_sf" || return 1
  return 0
}
