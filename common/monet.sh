#!/system/bin/sh
# Prints the system Material You colours as one JSON line for the WebUI:
#   {"seed":"#rrggbb","palette":{"light":{role:"#rrggbb",...},"dark":{...}}|null}
# Read only. Prints nothing when the ROM has no dynamic colours.

hexn() {
  r=$(printf '%s' "$1" | tr -d '\r\n\t ')
  case "$r" in *'#'*) h=${r##*#} ;; 0[xX]*) h=${r#0[xX]} ;; *) return 1 ;; esac
  case "$h" in ''|*[!0-9a-fA-F]*) return 1 ;; esac
  case ${#h} in 8) h=$(printf '%s' "$h" | cut -c3-8) ;; 6) : ;; *) return 1 ;; esac
  printf '#%s' "$h" | tr 'A-F' 'a-f'
}

hexd() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#1}" -gt 6 ] || return 1
  h=$(printf '%x' "$1" 2>/dev/null)
  case ${#h} in 8) h=$(printf '%s' "$h" | cut -c3-8) ;; 6) : ;; *) return 1 ;; esac
  printf '#%s' "$h"
}

seed=""
v=$(cmd overlay lookup android android:color/system_accent1_500 2>/dev/null)
seed=$(hexn "$v" 2>/dev/null)
if [ -z "$seed" ]; then
  for v in "$(settings get secure monet_engine_seed 2>/dev/null)" "$(getprop persist.sys.theme.color 2>/dev/null)"; do
    case "$v" in ''|null|NULL) continue ;; esac
    seed=$(hexn "$v" 2>/dev/null)
    [ -n "$seed" ] || seed=$(hexd "$v" 2>/dev/null)
    [ -n "$seed" ] && break
  done
fi
if [ -z "$seed" ]; then
  v=$(dumpsys wallpaper 2>/dev/null | grep -oE '(0x|#)[0-9a-fA-F]{8}' | tail -1)
  seed=$(hexn "$v" 2>/dev/null)
fi
[ -n "$seed" ] && [ "$seed" != "#000000" ] || exit 0

pal=$(cmd overlay dump com.android.systemui:dynamic 2>/dev/null | awk '
BEGIN {
  n = split("primary on_primary primary_container on_primary_container secondary_container on_secondary_container background on_surface on_surface_variant outline outline_variant surface_container_lowest surface_container_low surface_container surface_container_high surface_container_highest", R, " ")
}
{
  if (match($0, /color 0x[0-9a-fA-F]+ \(color\/system_/)) {
    l = $0
    sub(/^.*color 0x/, "", l)
    hex = substr(l, 1, 8)
    rest = substr(l, 10)
    sub(/^\(color\/system_/, "", rest)
    sub(/\)$/, "", rest)
    i = match(rest, /_[a-z]+$/)
    if (i > 0) {
      mode = substr(rest, i + 1)
      role = substr(rest, 1, i - 1)
      if (mode == "light") L[role] = tolower(substr(hex, 3, 6))
      else if (mode == "dark") D[role] = tolower(substr(hex, 3, 6))
    }
  }
}
END {
  for (i = 1; i <= n; i++) if (L[R[i]] == "" || D[R[i]] == "") { print "null"; exit }
  printf "{\"light\":{"
  for (i = 1; i <= n; i++) printf "%s\"%s\":\"#%s\"", (i > 1 ? "," : ""), R[i], L[R[i]]
  printf "},\"dark\":{"
  for (i = 1; i <= n; i++) printf "%s\"%s\":\"#%s\"", (i > 1 ? "," : ""), R[i], D[R[i]]
  printf "}}"
}')
case "$pal" in '{'*) : ;; *) pal=null ;; esac
printf '{"seed":"%s","palette":%s}\n' "$seed" "$pal"
