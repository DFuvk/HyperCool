#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Yudharn
# HyperCool - ROM change restorer (standalone)

export PATH=/system/bin:/system/xbin:/vendor/bin:/data/adb/ksu/bin:/data/adb/magisk:"$PATH"
HC_DATA=${HC_DATA:-/data/adb/hypercool}
HC_ROMBAK=$HC_DATA/backup/rom.bak

# Undo one backup record. Args: type ns key value
_hc_undo() {
  case "$1" in
    settings)
      if [ "$4" = "null" ]; then
        settings delete "$2" "$3" </dev/null >/dev/null 2>&1
      else
        settings put "$2" "$3" "$4" </dev/null >/dev/null 2>&1
      fi ;;
    devcfg)
      if [ "$4" = "null" ]; then
        device_config delete "$2" "$3" </dev/null >/dev/null 2>&1
      else
        device_config put "$2" "$3" "$4" </dev/null >/dev/null 2>&1
      fi ;;
    sync)
      device_config set_sync_disabled_for_tests "${4:-none}" </dev/null >/dev/null 2>&1 ;;
    pkg)
      pm enable --user 0 "$3" </dev/null >/dev/null 2>&1 ;;
    wl)
      dumpsys deviceidle whitelist -"$3" </dev/null >/dev/null 2>&1 ;;
    uwl)
      dumpsys deviceidle whitelist +"$3" </dev/null >/dev/null 2>&1 ;;
    syswl)
      # sys-whitelist removals are saved in /data/system/deviceidle.xml, so undo explicitly
      dumpsys deviceidle sys-whitelist +"$3" </dev/null >/dev/null 2>&1 ;;
    appop)
      # value = mode before HyperCool changed it ("-" in old records = default)
      case "$4" in allow|ignore|deny|default|foreground|errored) _m=$4 ;; *) _m=default ;; esac
      cmd appops set "$3" "$2" "$_m" </dev/null >/dev/null 2>&1 ;;
    bucket)
      # value = bucket before HyperCool changed it (10/20/30/40/45); anything else -> active
      case "$4" in 10|20|30|40|45) _sb=$4 ;; *) _sb=active ;; esac
      am set-standby-bucket "$3" "$_sb" </dev/null >/dev/null 2>&1 ;;
  esac
}

# Restore every record whose feature matches $1 ("__all__" = everything)
restore_feature() {
  _rf=$1
  _rk=$2
  [ -f "$HC_ROMBAK" ] || return 0
  _tmp="$HC_ROMBAK.tmp.$$"
  : > "$_tmp"
  while IFS='|' read -r bf bt bns bk bv; do
    [ -n "$bf" ] || continue
    if { [ "$_rf" = "__all__" ] || [ "$bf" = "$_rf" ]; } && { [ -z "$_rk" ] || [ "$bk" = "$_rk" ]; }; then
      _hc_undo "$bt" "$bns" "$bk" "$bv"
    else
      printf '%s|%s|%s|%s|%s\n' "$bf" "$bt" "$bns" "$bk" "$bv" >> "$_tmp"
    fi
  done < "$HC_ROMBAK"
  mv -f "$_tmp" "$HC_ROMBAK"
}

_hc_wait_boot() {
  _i=0
  while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$_i" -lt 900 ]; do
    sleep 2
    _i=$((_i + 2))
  done
  [ "$(getprop sys.boot_completed)" = "1" ] || return 1
  sleep 10
}

_hc_main() {
  _all=0; _wait=0; _purge=0; _feat=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --all) _all=1 ;;
      --wait-boot) _wait=1 ;;
      --purge) _purge=1 ;;
      --feature) shift; _feat=$1 ;;
    esac
    shift
  done
  # Android never finished booting: keep every record (and this script) for a later run
  if [ "$_wait" = 1 ] && ! _hc_wait_boot; then
    echo "Android did not finish booting; nothing restored. Run: sh $HC_DATA/restore.sh --all"
    return 1
  fi
  if [ "$_all" = 1 ]; then
    # GMS sys-whitelist removal made by an older build that did not record it
    if ! grep -q "^gms_doze|syswl|" "$HC_ROMBAK" 2>/dev/null && \
       grep -q 'un-wl n="com.google.android.gms"' /data/system/deviceidle.xml 2>/dev/null && \
       grep -q '^gms_doze=1' "$HC_DATA/last_applied.conf" 2>/dev/null; then
      dumpsys deviceidle sys-whitelist +com.google.android.gms </dev/null >/dev/null 2>&1
    fi
    restore_feature __all__
    # forced deep Doze left by a keeper that did not stop cleanly
    [ -f "$HC_DATA/doze_forced" ] && dumpsys deviceidle unforce </dev/null >/dev/null 2>&1
    rm -f "$HC_DATA/doze_forced"
    echo "All recorded system changes restored."
  elif [ -n "$_feat" ]; then
    restore_feature "$_feat"
    echo "Restored: $_feat"
  else
    echo "Usage: restore.sh --all [--wait-boot] [--purge] | --feature <key>"
  fi
  if [ "$_purge" = 1 ]; then
    rm -rf "$HC_DATA"
  fi
}

if [ "${HC_LIB_ONLY:-0}" != "1" ]; then
  _hc_main "$@"
fi
