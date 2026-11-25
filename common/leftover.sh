#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Yudharn
# HyperCool - folders that uninstalled apps left in Android/data and Android/obb (WebUI, on demand)
#   leftover.sh scan   prints L|<data|obb>|<package>|<KB> per folder, then T|<folders>|<KB>
#   leftover.sh clean  deletes the folders of the last scan whose app is still not installed,
#                      prints R|<deleted>|<KB>|<failed>
# Nothing is deleted without a scan first, and every folder is checked again just before it goes.
# Apps uninstalled with "keep data" still count as installed (pm list packages -u), so their files stay.
export PATH=/system/bin:/system/xbin:/vendor/bin:$PATH
HC_DATA=${HC_DATA:-/data/adb/hypercool}
MODDIR=${0%/*}; MODDIR=${MODDIR%/common}
[ -f "$MODDIR/common/klog.sh" ] && . "$MODDIR/common/klog.sh" || klog() { :; }
BASE=${HC_MEDIA:-/data/media/0}/Android
LIST=$HC_DATA/leftover.list

pkgs() {
  { pm list packages -u --user 0 </dev/null 2>/dev/null; pm list packages -u </dev/null 2>/dev/null; } |
    tr -d '\r' | sed -n 's/^package://p' | sort -u
}
# installed packages, one per line; fewer than 20 means the package list is not trustworthy
PK=$HC_DATA/leftover.pk.$$
trap 'rm -f "$PK"' EXIT
pkgs > "$PK"
_np=$(grep -c . "$PK" 2>/dev/null)
if [ "${_np:-0}" -lt 20 ]; then echo "R|nopkgs"; exit 0; fi

scan() {
  for _t in data obb; do
    for _d in "$BASE/$_t"/*; do
      [ -d "$_d" ] || continue
      _p=${_d##*/}
      case "$_p" in .*) continue ;; esac
      echo "$_p" | grep -qE '^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+$' || continue
      grep -qxF "$_p" "$PK" && continue
      echo "L|$_t|$_p|$(du -sk "$_d" 2>/dev/null | cut -f1)"
    done
  done
}

case "$1" in
  scan)
    scan > "$LIST"
    cat "$LIST"
    awk -F'|' '{ n++; k += $4 } END { printf "T|%d|%d\n", n, k }' "$LIST" ;;
  clean)
    [ -s "$LIST" ] || { echo "R|0|0|0"; exit 0; }
    _n=0; _k=0; _f=0; _names=""
    while IFS='|' read -r _l _t _p _kb; do
      [ "$_l" = L ] || continue
      case "$_t" in data|obb) ;; *) continue ;; esac
      echo "$_p" | grep -qE '^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+$' || continue
      # installed again since the scan: keep it
      grep -qxF "$_p" "$PK" && continue
      _d=$BASE/$_t/$_p
      [ -d "$_d" ] || continue
      if rm -rf "$_d" 2>/dev/null && [ ! -e "$_d" ]; then
        _n=$((_n + 1)); _k=$((_k + ${_kb:-0}))
        [ "$_n" -le 5 ] && _names="$_names${_names:+, }$_p"
      else
        _f=$((_f + 1))
      fi
    done < "$LIST"
    rm -f "$LIST"
    if [ "$_n" -gt 0 ]; then
      _mb=$(awk -v k="$_k" 'BEGIN { printf "%.1f", k / 1024 }')
      klog tools "Leftover app folders deleted" "$_n folder(s), $_mb MB: $_names$([ "$_n" -gt 5 ] && echo " +$((_n - 5)) more")$([ "$_f" -gt 0 ] && echo "; $_f failed")"
    fi
    echo "R|$_n|$_k|$_f" ;;
  *) echo "usage: leftover.sh scan|clean" ;;
esac
exit 0
