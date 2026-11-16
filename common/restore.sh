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
      # value = bucket before HyperCool changed it (5/10/20/30/40/45); anything else -> active
      # AOSP's "am set-standby-bucket" only accepts ac/wo/fr/ra/re/ne or a number
      # (bucketNameToBucketValue), so bucket 5 (EXEMPTED) cannot be restored by name,
      # and the server rejects values below ACTIVE(10) too. Restore 5 as active: when
      # the app is still exempted the server ignores the set with rc=0, so the record
      # is dropped and --purge can run (v2.2.1 behaviour).
      case "$4" in
        10|20|30|40|45) _sb=$4 ;;
        *) _sb=active ;;
      esac
      am set-standby-bucket "$3" "$_sb" </dev/null >/dev/null 2>&1 ;;
    inactive)
      # value = idle state before HyperCool changed it
      case "$4" in true|false) am set-inactive "$3" "$4" </dev/null >/dev/null 2>&1 ;; *) return 0 ;; esac ;;
  esac
}

# 0 when the record is bound to a package that is no longer installed:
# there is nothing left to undo, so the record can be dropped instead of
# failing every future restore and blocking --purge forever.
# But first make sure PackageManager is actually alive: when pm is not ready
# "pm path" is empty for every package, and dropping records then would lose
# the ROM originals without a trace. In that case fail (keep the record).
_hc_pkg_gone() {
  case "$1" in pkg|appop|bucket|inactive|wl|uwl|syswl) ;; *) return 1 ;; esac
  [ -n "$(pm path android </dev/null 2>/dev/null)" ] || return 1
  # a "pkg" record can also be a component (package/full.class.Name, x_gms_freeze):
  # "pm path" only answers for packages, so ask for the host package of the component
  _gp=$2
  case "$1" in pkg) case "$_gp" in */*) _gp=${_gp%%/*} ;; esac ;; esac
  [ -z "$(pm path "$_gp" </dev/null 2>/dev/null)" ]
}

# Restore every record whose feature matches $1 ("__all__" = everything)
restore_feature() {
  _rf=$1
  _rk=$2
  [ -f "$HC_ROMBAK" ] || return 0
  _tmp="$HC_ROMBAK.tmp.$$"
  : > "$_tmp" || return 1
  _rfail=0
  while IFS='|' read -r bf bt bns bk bv; do
    [ -n "$bf" ] || continue
    if { [ "$_rf" = "__all__" ] || [ "$bf" = "$_rf" ]; } && { [ -z "$_rk" ] || [ "$bk" = "$_rk" ]; }; then
      # package is gone: nothing to undo, drop the record
      _hc_pkg_gone "$bt" "$bk" && continue
      # Keep a record when the undo failed: the next run (or the uninstall
      # guard) can retry it instead of silently losing the ROM original.
      if ! _hc_undo "$bt" "$bns" "$bk" "$bv"; then
        _rfail=$((_rfail + 1))
        echo "restore failed: $bf|$bt|$bns|$bk" >> "$HC_DATA/boot.log" 2>/dev/null
        printf '%s|%s|%s|%s|%s\n' "$bf" "$bt" "$bns" "$bk" "$bv" >> "$_tmp"
      fi
    else
      printf '%s|%s|%s|%s|%s\n' "$bf" "$bt" "$bns" "$bk" "$bv" >> "$_tmp"
    fi
  done < "$HC_ROMBAK"
  mv -f "$_tmp" "$HC_ROMBAK" || { rm -f "$_tmp"; return 1; }
  [ "$_rfail" -eq 0 ]
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

# stop the touch-only refresh rate keeper before the restore: on its way out it writes the active
# rate, which would land on top of the stock value restored below
_hc_stop_rr() {
  _rq=$(cat "$HC_DATA/rr_watch.pid" 2>/dev/null)
  case "$_rq" in ''|*[!0-9]*) return 0 ;; esac
  grep -q rr_watch "/proc/$_rq/cmdline" 2>/dev/null || return 0
  kill "$_rq" 2>/dev/null
  _i=0; while [ "$_i" -lt 5 ] && [ -d "/proc/$_rq" ]; do sleep 1; _i=$((_i + 1)); done
  # do not let a keeper that ignored TERM write its active rate after the stock value is restored.
  # kill -9 skips its trap, so stop its getevent children first.
  if [ -d "/proc/$_rq" ] && grep -q rr_watch "/proc/$_rq/cmdline" 2>/dev/null; then
    for _ck in /proc/[0-9]*; do
      _ck=${_ck##*/}
      [ "$_ck" = "$_rq" ] && continue
      [ "$(awk '/^PPid:/{print $2}' "/proc/$_ck/status" 2>/dev/null)" = "$_rq" ] && kill "$_ck" 2>/dev/null
    done
    kill -9 "$_rq" 2>/dev/null
    _i=0; while [ "$_i" -lt 2 ] && [ -d "/proc/$_rq" ]; do sleep 1; _i=$((_i + 1)); done
  fi
  [ -d "/proc/$_rq" ] && return 1
  rm -f "$HC_DATA/rr_watch.pid"
  return 0
}

# Stop the screen-off keeper before restoring. Its trap writes the saved values back; if it is
# stuck, soff_restore.sh below still restores what it can and keeps the rest.
_hc_stop_soff() {
  _sq=$(cat "$HC_DATA/soff_watch.pid" 2>/dev/null)
  case "$_sq" in ''|*[!0-9]*) return 0 ;; esac
  grep -q soff_watch "/proc/$_sq/cmdline" 2>/dev/null || return 0
  kill "$_sq" 2>/dev/null
  _i=0; while [ "$_i" -lt 6 ] && [ -d "/proc/$_sq" ]; do sleep 1; _i=$((_i + 1)); done
  if [ -d "/proc/$_sq" ] && grep -q soff_watch "/proc/$_sq/cmdline" 2>/dev/null; then
    kill -9 "$_sq" 2>/dev/null
    _i=0; while [ "$_i" -lt 2 ] && [ -d "/proc/$_sq" ]; do sleep 1; _i=$((_i + 1)); done
  fi
  [ -d "/proc/$_sq" ] && return 1
  rm -f "$HC_DATA/soff_watch.pid"
  return 0
}

# Locate the standalone screen-off restorer. The copy next to this script is preferred.
_hc_soff_lib() {
  for _l in "$HC_DATA/soff_restore.sh" "${MODDIR:-/data/adb/modules/hypercool}/common/soff_restore.sh"; do
    [ -f "$_l" ] && { printf '%s\n' "$_l"; return 0; }
  done
  return 1
}

# Restore CPU/GPU/boost values saved by the screen-off keeper; keep records that still fail.
_hc_soff() {
  [ -s "$HC_DATA/soff_watch.save" ] || return 0
  _lib=$(_hc_soff_lib) || {
    echo "Screen-off records kept: soff_restore.sh is missing" >&2
    return 1
  }
  # shellcheck source=/dev/null
  . "$_lib"
  hc_soff_restore "$HC_DATA/soff_watch.save" || return 1
  [ ! -s "$HC_DATA/soff_watch.save" ] || return 1
  return 0
}

# Locate the radio helper for standalone restore. The copy next to this script is preferred; the
# installed module copy is used for an older install that has not copied it yet.
_hc_radio_lib() {
  for _l in "$HC_DATA/radio.sh" "${MODDIR:-/data/adb/modules/hypercool}/common/radio.sh"; do
    [ -f "$_l" ] && { printf '%s\n' "$_l"; return 0; }
  done
  return 1
}

# Location / Bluetooth and mobile data / NFC left off by a screen-off keeper that did not stop
# cleanly. Uses radio.sh (read back after each switch); what could not be put back stays in its
# file and counts as a failure, so --purge keeps it for the next retry.
# Standalone fallback used only when radio.sh is missing (for example after a partial upgrade).
# It restores the same records with the same read-back checks; anything it cannot verify stays in
# the save file. Keeping the records is more important than reporting a clean restore.
_hc_fb_loc_now() {
  case "$(cmd location is-location-enabled </dev/null 2>/dev/null | head -n 1)" in
    true*) echo on; return ;;
    false*) echo off; return ;;
  esac
  case "$(settings get secure location_mode 2>/dev/null)" in 0) echo off ;; [1-9]) echo on ;; *) echo ? ;; esac
}
_hc_fb_bt_now() {
  case "$(settings get global bluetooth_on 2>/dev/null)" in 1) echo on ;; 0) echo off ;; *) echo ? ;; esac
}
_hc_fb_data_now() {
  _dv=""
  _dsid=$(settings get global multi_sim_data_call 2>/dev/null)
  case "$_dsid" in ''|*[!0-9]*) ;; *) _dv=$(settings get global "mobile_data$_dsid" 2>/dev/null) ;; esac
  case "$_dv" in 0|1) ;; *) _dv=$(settings get global mobile_data 2>/dev/null) ;; esac
  case "$_dv" in 1) echo on ;; 0) echo off ;; *) echo ? ;; esac
}
_hc_fb_nfc_now() {
  case "$(dumpsys nfc </dev/null 2>/dev/null | grep -m 1 'mState=')" in
    *mState=on*) echo on ;;
    *mState=off*) echo off ;;
    *mState=turning*) echo turning ;;
    *) echo ? ;;
  esac
}
_hc_fb_bt_set() {
  cmd bluetooth_manager "$1" </dev/null >/dev/null 2>&1
  svc bluetooth "$1" </dev/null >/dev/null 2>&1
  return 0
}
_hc_fb_data_set() {
  svc data enable </dev/null >/dev/null 2>&1
  sleep 1
  [ "$(_hc_fb_data_now)" = on ] && return 0
  cmd phone data enable </dev/null >/dev/null 2>&1
  sleep 1
  [ "$(_hc_fb_data_now)" = on ]
}
_hc_fb_nfc_set() {
  svc nfc enable </dev/null >/dev/null 2>&1
  sleep 1
  [ "$(_hc_fb_nfc_now)" = on ] && return 0
  cmd nfc enable-nfc </dev/null >/dev/null 2>&1
  sleep 1
  [ "$(_hc_fb_nfc_now)" = on ]
}
_hc_radios_fallback() {
  _fb_rc=0
  if [ -s "$HC_DATA/soff_radio.save" ]; then
    _fb_fail=""
    while IFS='|' read -r _fk _fv; do
      case "$_fk" in
        loc)
          _fl=$(_hc_fb_loc_now)
          [ "$_fl" = on ] && continue
          if [ "$_fl" != off ]; then _fb_fail="${_fb_fail}loc|$_fv
"; continue; fi
          cmd location set-location-enabled true </dev/null >/dev/null 2>&1
          sleep 1
          case "$_fv" in [1-9]) ;; *) _fv=3 ;; esac
          settings put secure location_mode "$_fv" </dev/null >/dev/null 2>&1
          sleep 1
          [ "$(_hc_fb_loc_now)" = on ] && [ "$(settings get secure location_mode 2>/dev/null)" = "$_fv" ] ||
            _fb_fail="${_fb_fail}loc|$_fv
" ;;
        bt)
          [ "$(settings get global airplane_mode_on 2>/dev/null)" = 1 ] && { _fb_fail="${_fb_fail}bt|$_fv
"; continue; }
          _fb=$(_hc_fb_bt_now)
          [ "$_fb" = on ] && continue
          [ "$_fb" = off ] || { _fb_fail="${_fb_fail}bt|$_fv
"; continue; }
          _hc_fb_bt_set enable
          sleep 1
          [ "$(_hc_fb_bt_now)" = on ] || _fb_fail="${_fb_fail}bt|$_fv
" ;;
        *) _fb_fail="${_fb_fail}$_fk|$_fv
" ;;
      esac
    done < "$HC_DATA/soff_radio.save"
    if [ -n "$_fb_fail" ]; then
      printf '%s' "$_fb_fail" > "$HC_DATA/soff_radio.save" || _fb_rc=1
    else
      : > "$HC_DATA/soff_radio.save" || _fb_rc=1
    fi
    [ -n "$_fb_fail" ] && _fb_rc=1
  fi
  if [ -s "$HC_DATA/soff_data.save" ]; then
    _fb_fail=""
    while IFS='|' read -r _fk _fv; do
      case "$_fk" in
        data)
          _fd=$(_hc_fb_data_now)
          [ "$_fd" = on ] && continue
          [ "$_fd" = off ] && _hc_fb_data_set && continue
          _fb_fail="${_fb_fail}data|
" ;;
        nfc)
          _fn=$(_hc_fb_nfc_now)
          [ "$_fn" = turning ] && { sleep 2; _fn=$(_hc_fb_nfc_now); }
          [ "$_fn" = on ] && continue
          [ "$_fn" = off ] && _hc_fb_nfc_set && continue
          _fb_fail="${_fb_fail}nfc|
" ;;
        *) _fb_fail="${_fb_fail}$_fk|$_fv
" ;;
      esac
    done < "$HC_DATA/soff_data.save"
    if [ -n "$_fb_fail" ]; then
      printf '%s' "$_fb_fail" > "$HC_DATA/soff_data.save" || _fb_rc=1
    else
      : > "$HC_DATA/soff_data.save" || _fb_rc=1
    fi
    [ -n "$_fb_fail" ] && _fb_rc=1
  fi
  return "$_fb_rc"
}

_hc_radios() {
  [ -s "$HC_DATA/soff_radio.save" ] || [ -s "$HC_DATA/soff_data.save" ] || return 0
  if ! _lib=$(_hc_radio_lib); then
    echo "radio.sh is missing; restoring the saved radios directly" >&2
    _hc_radios_fallback
    return
  fi
  RSAVE=$HC_DATA/soff_radio.save
  DSAVE=$HC_DATA/soff_data.save
  # shellcheck source=/dev/null
  . "$_lib"
  radio_restore
  data_restore
  [ ! -s "$RSAVE" ] && [ ! -s "$DSAVE" ] || return 1
  return 0
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
  _rc=0
  if [ "$_all" = 1 ]; then
    # Stop the screen-off keeper first: its trap writes back the values, and an old keeper must
    # not reapply disabled Location/data/NFC options after a WebUI Revert.
    _hc_stop_soff || _rc=1
    _hc_stop_rr || _rc=1
    # GMS sys-whitelist removal made by an older build that did not record it
    if ! grep -q "^gms_doze|syswl|" "$HC_ROMBAK" 2>/dev/null && \
       grep -q 'un-wl n="com.google.android.gms"' /data/system/deviceidle.xml 2>/dev/null && \
       grep -q '^gms_doze=1' "$HC_DATA/last_applied.conf" 2>/dev/null; then
      dumpsys deviceidle sys-whitelist +com.google.android.gms </dev/null >/dev/null 2>&1
    fi
    restore_feature __all__ || _rc=1
    # forced deep Doze left by a keeper that did not stop cleanly
    [ -f "$HC_DATA/doze_forced" ] && dumpsys deviceidle unforce </dev/null >/dev/null 2>&1
    rm -f "$HC_DATA/doze_forced"
    # CPU/GPU/boost values saved while the screen was off
    _hc_soff || _rc=1
    # Location / Bluetooth and mobile data / NFC left off by a keeper that did not stop cleanly
    _hc_radios || _rc=1
    if [ "$_rc" -eq 0 ]; then
      echo "All recorded system changes restored."
    else
      echo "Some changes could not be restored; their records were kept for a retry."
    fi
  elif [ -n "$_feat" ]; then
    if [ "$_feat" = "rr_adapt" ]; then
      _hc_stop_rr || _rc=1
    fi
    restore_feature "$_feat" || _rc=1
    if [ "$_rc" -eq 0 ]; then
      echo "Restored: $_feat"
    else
      echo "Some changes for $_feat could not be restored; their records were kept."
    fi
  else
    echo "Usage: restore.sh --all [--wait-boot] [--purge] | --feature <key>"
  fi
  if [ "$_purge" = 1 ]; then
    if [ "$_rc" -eq 0 ]; then
      rm -rf "$HC_DATA"
    else
      echo "Backups were kept because some changes could not be restored."
    fi
  fi
  [ "$_rc" -eq 0 ]
}

if [ "${HC_LIB_ONLY:-0}" != "1" ]; then
  _hc_main "$@"
fi
