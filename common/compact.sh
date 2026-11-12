# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Yudharn
# HyperCool - background app compaction (sourced by soff_watch.sh when "Compact background apps" is ON).
# compact_low_ram: free RAM below LOWPCT % of the total. compact_run: asks Android to compact the memory
# of background user apps one by one (cmd activity compact some <process> <uid>); apps are not stopped.
# soff_watch runs it in a background job and stops it when the screen turns on.
HC_PROC=${HC_PROC:-/proc}
CSTATE=$HC_DATA/compact.state
LOWPCT=${HC_CLOW:-30}
MAXAPPS=40
# never compacted: launcher, keyboard, dialer, messaging, media, system and root apps
WL='launcher|inputmethod|keyboard|dialer|telecom|mms|messaging|music|spotify|player|podcast|systemui|settings|ksu|apatch|magisk|webui|bluetooth|nfc|network|com\.google\.android\.gms|com\.android\.vending|android\.process'

cfgv() { sed -n "s/^$1=//p" "$HC_DATA/config.conf" 2>/dev/null | tail -n 1 | tr -d '\r'; }
memk() { # <MemTotal|MemAvailable> -> kB
  while read -r _mk _mv _; do [ "$_mk" = "$1:" ] && { echo "$_mv"; return; }; done < "$HC_PROC/meminfo"
}
compact_low_ram() {
  _ct=$(memk MemTotal); _ca=$(memk MemAvailable)
  case "$_ct" in ''|*[!0-9]*) return 1 ;; esac
  case "$_ca" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_ct" -gt 0 ] || return 1
  # mksh uses 32-bit signed math: _ca * 100 overflows above ~21.5 GB, so compare in awk
  awk -v a="$_ca" -v t="$_ct" -v p="$LOWPCT" 'BEGIN { if (a * 100 < t * p) exit 0; exit 1 }'
}
# uid_of <proc dir>: first number of the Uid line, empty when unreadable
uid_of() {
  _u=""
  [ -r "$1/status" ] || return 1
  while read -r _k _v _; do [ "$_k" = "Uid:" ] && { _u=$_v; break; }; done < "$1/status"
  case "$_u" in ''|*[!0-9]*) _u=""; return 1 ;; esac
}
# compact_run: $_cruns = number of this run (counted by the caller)
compact_run() {
  PROT=""
  [ "$(cfgv protect_apps)" = 1 ] && PROT=",$(cfgv protect_pkgs),"
  _b=$(memk MemAvailable); _n=0; _f=0
  for _d in "$HC_PROC"/[0-9]*; do
    [ "$_n" -ge "$MAXAPPS" ] && break
    # the screen came on during the run: stop
    [ -n "$SCR_BL" ] && ! bl_off && break
    uid_of "$_d" || continue
    _m=$((_u % 100000))
    [ "$_m" -ge 10000 ] && [ "$_m" -le 19999 ] || continue
    _nm=$(tr '\0' '\n' < "$_d/cmdline" 2>/dev/null | head -n 1)
    case "$_nm" in *.*) ;; *) continue ;; esac
    case "$_nm" in *[!A-Za-z0-9._:]*|'') continue ;; esac
    echo "$_nm" | grep -qE "$WL" && continue
    case "$PROT" in *",${_nm%%:*},"*) continue ;; esac
    _o=$(cmd activity compact some "$_nm" "$_u" </dev/null 2>&1)
    # AOSP prints "Finished some compaction for <pid>" (Android 13+); "Finished compacting" was the old guess
    case "$_o" in *"Finished some compaction"*|*"Finished full compaction"*|*"Finished system compaction"*|*"Finished compacting"*) _n=$((_n + 1)) ;; *) _f=$((_f + 1)) ;; esac
  done
  sleep 2
  echo "runs=$_cruns last=$(date '+%Y-%m-%d %H:%M:%S') apps=$_n failed=$_f free_before_kb=${_b:-?} free_after_kb=$(memk MemAvailable)" > "$CSTATE"
}
