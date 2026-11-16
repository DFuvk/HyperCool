#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Yudharn
# HyperCool - config migration for an existing /data/adb/hypercool/config.conf
# Called by customize.sh when the module is flashed over an old install.
# A value moves to the new default only while it still holds the old default:
# anything the user chose is kept exactly as it is.

# hc_migrate_config <config-file>
# Returns 0 when a migration was applied, 1 when the config is already current.
hc_migrate_config() {
  _f=$1
  [ -f "$_f" ] || return 0
  # config version: 4 or newer is already current, so an update never migrates twice
  # and a downgrade of a newer module does not rewrite the config backwards
  _cv=$(sed -n 's/^cfg_ver=//p' "$_f" | tail -n 1 | tr -d '\r')
  case "$_cv" in
    ''|*[!0-9]*) ;;
    *) [ "$_cv" -ge 4 ] && return 1 ;;
  esac
  _hc_mv() { # <key> <old default> <new default>
    _cur=$(sed -n "s/^$1=//p" "$_f" | tail -n 1 | tr -d '\r')
    [ "$_cur" = "$2" ] && sed -i "s/^$1=.*/$1=$3/" "$_f"
    return 0
  }
  # v2.3.3 battery inputs
  _hc_mv cpu_cap 95 88
  _hc_mv gpu_idle_timer 64 20
  _hc_mv walt_hispeed_load 95 99
  _hc_mv walt_up_rate 1000 5000
  _hc_mv bg_uclamp 30 25
  _hc_mv soff_cpu 60 30
  _hc_mv soff_radio_min 15 5
  _hc_mv soff_data_min 10 5
  _hc_mv vm_writeback 3000 6000
  _hc_mv vm_stat_interval 10 60
  _hc_mv vm_dirty_bg 10 20
  _hc_mv vm_dirty 30 40
  # the old fixed refresh pair becomes Auto: panel max while active, panel min while idle
  _ra=$(sed -n 's/^rr_active=//p' "$_f" | tail -n 1 | tr -d '\r')
  _ri=$(sed -n 's/^rr_idle=//p' "$_f" | tail -n 1 | tr -d '\r')
  if [ "$_ra" = 120 ] && [ "$_ri" = 60 ]; then
    sed -i -e 's/^rr_active=.*/rr_active=0/' -e 's/^rr_idle=.*/rr_idle=0/' "$_f"
  fi
  # never append to a last line without a newline: cfg_ver would join that value
  [ -s "$_f" ] && [ -n "$(tail -c1 "$_f")" ] && echo >> "$_f"
  if grep -q '^cfg_ver=' "$_f"; then
    sed -i 's/^cfg_ver=.*/cfg_ver=4/' "$_f"
  else
    echo 'cfg_ver=4' >> "$_f"
  fi
  return 0
}
