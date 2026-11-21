#!/system/bin/sh
# HyperCool - hibernate background apps
# By Yudharn | Telegram: @ModuleArchives | GPL-3.0-or-later
#
# Run by the screen-off keeper once per screen-off period, N minutes after the screen goes off,
# or from the WebUI (Hibernate apps now).
#   hibernate.sh <stop|kill> <minutes|now|preview>   (preview: the same checks, nothing is stopped or logged)
#   stop   am force-stop: the app stays stopped (no alarms, jobs or pushes) until opened
#   kill   am kill: only its background processes are closed, pushes still arrive
# Prints R|<stopped>|<protected>|<in use>|<alarm clock>|<state unknown>|<failed>|<stopped packages, comma list>
# or R|busy (another run is going) or R|noalarm (alarm list not readable: nothing is stopped).
# User apps (pm list packages -3, user 0) with a running process are stopped, except:
#   Protected apps, default dialer / SMS / keyboard / launcher, accessibility, notification listeners,
#   always-on VPN, live wallpaper, device admins, core apps (HC_BGB_NEVER), apps with an alarm clock set,
#   and apps Android still counts as in use (top, top while asleep = the last app, foreground service,
#   bound to something important, the launcher, persistent, heavy, backup).
# One line goes to Recent activity when something was stopped; the counts go to hibernate.state.
MODDIR=${0%/*}; MODDIR=${MODDIR%/common}
HC_DATA=${HC_DATA:-/data/adb/hypercool}
export PATH=/system/bin:/system/xbin:/vendor/bin:$PATH
[ -f "$MODDIR/common/klog.sh" ] && . "$MODDIR/common/klog.sh" || klog() { :; }
MODE=${1:-stop}; case "$MODE" in stop|kill) ;; *) MODE=stop ;; esac
MIN=${2:-}
DRY=0; [ "$MIN" = preview ] && DRY=1
PR=${HC_PROC:-/proc}
# one run at a time (keeper and WebUI); its own package list file
LOCK=$HC_DATA/hib.lock
_lp=$(cat "$LOCK" 2>/dev/null)
case "$_lp" in ''|*[!0-9]*) ;; *) if [ "$_lp" != $$ ] && grep -q hibernate.sh "/proc/$_lp/cmdline" 2>/dev/null; then echo "R|busy"; exit 0; fi ;; esac
echo $$ > "$LOCK"
PK=$HC_DATA/hib.pk.$$
trap 'rm -f "$PK"; [ "$(cat "$LOCK" 2>/dev/null)" = $$ ] && rm -f "$LOCK"' EXIT
trap 'exit 1' TERM INT HUP
CONF=$HC_DATA/config.conf
STATE=$HC_DATA/hibernate.state
NEVER="android,com.android.systemui,com.android.phone,com.android.settings,com.google.android.gms,com.google.android.gsf,com.xiaomi.xmsf,com.miui.securitycenter,com.miui.powerkeeper,com.miui.home,me.weishu.kernelsu,com.rifsxd.ksunext,com.topjohnwu.magisk,me.bmax.apatch"

cfgv() { _cv=$(sed -n "s/^$1=//p" "$CONF" 2>/dev/null | tail -n 1 | tr -d '\r'); echo "${_cv:-$2}"; }

# ---------------------------------------------------------------- apps that are never stopped
skip_list() {
  # Protected apps: always honoured here, also while "Keep important apps alive" is off
  printf '%s,' "$(cfgv protect_pkgs "")"
  printf '%s,' "$NEVER"
  _x=$(cmd telecom get-default-dialer </dev/null 2>/dev/null); printf '%s,' "$_x"
  _x=$(settings get secure sms_default_application </dev/null 2>/dev/null); printf '%s,' "$_x"
  settings get secure default_input_method </dev/null 2>/dev/null | sed 's#/.*##' | tr -d '\n'; printf ','
  cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME </dev/null 2>/dev/null |
    grep / | tail -n 1 | sed 's#/.*##' | tr -d '\n'; printf ','
  for _k in enabled_accessibility_services enabled_notification_listeners; do
    settings get secure "$_k" </dev/null 2>/dev/null | tr ':' '\n' | sed -n 's#^\([A-Za-z0-9._]*\)/.*#\1#p'
  done | tr '\n' ','
  _x=$(settings get secure always_on_vpn_app </dev/null 2>/dev/null); printf '%s,' "$_x"
  # live wallpaper and device admins: ComponentInfo{pkg/cls}
  { dumpsys wallpaper </dev/null 2>/dev/null | grep -m 2 'mWallpaperComponent'
    dumpsys device_policy </dev/null 2>/dev/null | grep 'admin=ComponentInfo'; } |
    sed -n 's#.*ComponentInfo{\([A-Za-z0-9._]*\)/.*#\1#p' | tr '\n' ','
}
# apps with an alarm clock set (dumpsys alarm: "Alarm{… <package>}" then "Alarm clock:").
# An "Alarm clock:" line with no package read from its header means the format is not the one
# expected: "!" is printed and nothing gets stopped (a stopped clock app would miss its alarm).
alarm_apps() {
  dumpsys alarm </dev/null 2>/dev/null | awk '
    /Alarm\{[0-9a-f]+ type / { p = $0; sub(/\}.*$/, "", p); n = split(p, a, " "); p = a[n]; if (p !~ /^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+$/) p = ""; next }
    /^ *Alarm clock:$/ { if (p == "") { bad = 1; next } if (!(p in s)) { s[p] = 1; printf "%s,", p } }
    END { if (bad) printf "!," }'
}

# ---------------------------------------------------------------- running user apps
# package and uid of each user app: "<pkg> <uid>"
pm list packages -3 -U </dev/null 2>/dev/null | tr -d '\r' |
  sed -n 's/^package:\([^ ]*\) uid:\([0-9][0-9]*\).*/\1 \2/p' > "$PK" 2>/dev/null
[ -s "$PK" ] || { echo "time=$(date '+%H:%M:%S') stopped=0 error=no-packages" > "$STATE"; echo "R|0|0|0|0|0|0|"; exit 0; }
# process names (first argument of the command line, builtins only): "com.app" or "com.app:service"
_run=" "
for _c in "$PR"/[0-9]*/cmdline; do
  _n=""; { read -d '' -r _n < "$_c"; } 2>/dev/null
  case "$_n" in ''|/*|*' '*) continue ;; *.*) ;; *) continue ;; esac
  _n=${_n%%:*}
  case "$_run" in *" $_n "*) ;; *) _run="$_run$_n " ;; esac
done

# one comma list, whatever line breaks the commands above printed
SKIP=",$(skip_list | tr -d '\n\r '),"
ALRM=",$(alarm_apps | tr -d '\n\r '),"
case "$ALRM" in
  *",!,"*)
    [ "$DRY" = 1 ] && { echo "R|noalarm"; exit 0; }
    echo "time=$(date '+%H:%M:%S') stopped=0 error=alarm-list" > "$STATE"
    klog "$([ "$MIN" = now ] && echo tools || echo screen-off)" "Hibernation skipped" "the alarm list of this ROM could not be read, so no app was stopped (a clock app could miss its alarm)"
    echo "R|noalarm"; exit 0 ;;
esac
_ns=0; _np=0; _nu=0; _na=0; _nx=0; _nf=0; _names=""; _all=""
while read -r _p _u; do
  case "$_run" in *" $_p "*) ;; *) continue ;; esac
  case "$SKIP" in *",$_p,"*) _np=$((_np + 1)); continue ;; esac
  case "$ALRM" in *",$_p,"*) _na=$((_na + 1)); continue ;; esac
  # "4 (FOREGROUND_SERVICE)": anything Android still counts as in use stays
  _st=$(cmd activity get-uid-state "$_u" </dev/null 2>/dev/null | sed -n 's/.*(\(.*\)).*/\1/p' | head -n 1)
  case "$_st" in
    '') _nx=$((_nx + 1)); continue ;;
    # not running in user 0 (the process seen belongs to a dual app or work profile copy)
    NONEXISTENT) continue ;;
    # HOME: the launcher in use, also when the default launcher could not be read above
    *TOP*|*FOREGROUND*|PERSISTENT*|IMPORTANT_BACKGROUND|HEAVY_WEIGHT|BACKUP|HOME) _nu=$((_nu + 1)); continue ;;
  esac
  # user 0 only: that is the copy whose state was checked above. Without --user, am stops the app in
  # every user, so a dual app or work profile copy in a call or playing would be stopped too
  if [ "$DRY" = 1 ]; then
    :
  elif [ "$MODE" = kill ]; then am kill --user 0 "$_p" </dev/null >/dev/null 2>&1; else am force-stop --user 0 "$_p" </dev/null >/dev/null 2>&1; fi
  if [ $? = 0 ]; then
    _ns=$((_ns + 1)); _all="$_all${_all:+,}$_p"; [ "$_ns" -le 5 ] && _names="$_names${_names:+, }$_p"
  else
    _nf=$((_nf + 1))
  fi
done < "$PK"

_sk="protected $_np, in use $_nu, alarm clock $_na$([ "$_nx" -gt 0 ] && echo ", state unknown $_nx")"
[ "$DRY" = 1 ] && { echo "R|$_ns|$_np|$_nu|$_na|$_nx|0|$_all"; exit 0; }
echo "time=$(date '+%H:%M:%S') mode=$MODE stopped=$_ns failed=$_nf protected=$_np in_use=$_nu alarm=$_na unknown=$_nx" > "$STATE"
if [ "$_ns" -gt 0 ]; then
  _more=""; [ "$_ns" -gt 5 ] && _more=" +$((_ns - 5)) more"
  _what=$([ "$MODE" = kill ] && echo "Background apps closed" || echo "Apps hibernated")
  if [ "$MIN" = now ]; then
    klog tools "$_what (manual)" "$_ns: $_names$_more; skipped: $_sk$([ "$_nf" -gt 0 ] && echo "; $_nf failed")"
  else
    klog screen-off "$_what" "$_ns after ${MIN:-?} min of screen-off: $_names$_more; skipped: $_sk$([ "$_nf" -gt 0 ] && echo "; $_nf failed")"
  fi
fi
echo "R|$_ns|$_np|$_nu|$_na|$_nx|$_nf|$_all"
exit 0
