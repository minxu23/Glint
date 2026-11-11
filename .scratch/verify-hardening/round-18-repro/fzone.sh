#!/bin/sh
# 一个畸形样本：换 EXIF，读回比对，校验前后比对。输出一行。
W=$(dirname "$0"); n="$1"; src="$W/fz/in/$n.jpg"; base="$W/fz/base/$n.heic"; ext="$W/fz/ext/$n.heic"; t="$W/fz/tmp/$n"
[ -f "$base" ] || { echo "$n|NOPRODUCT"; exit 0; }
r=$(python3 "$W/exifswap.py" swapx "$src" "$base" "$ext" 2>&1 | tail -1)
[ -f "$ext" ] || { echo "$n|NOSWAP|$r"; exit 0; }
T="perl -e 'alarm shift; exec @ARGV' 60"
sh -c "$T \"$W/chk\" \"$base\"" 2>/dev/null | grep -aE '^(status|PIXELS|THUMB|HDR|AUX|DECODE|OPEN)' > "$t.b"; rb=$?
sh -c "$T \"$W/chk\" \"$ext\"" 2>/dev/null | grep -aE '^(status|PIXELS|THUMB|HDR|AUX|DECODE|OPEN)' > "$t.e"
px=same; cmp -s "$t.b" "$t.e" || px=DIFF; [ -s "$t.e" ] || px=EMPTY
sh -c "$T \"$W/vdiff\" \"$src\" \"$base\"" > "$t.vb" 2>/dev/null; v1=$?
sh -c "$T \"$W/vdiff\" \"$src\" \"$ext\"" > "$t.ve" 2>/dev/null; v2=$?
# 差异行按「到冒号或等号为止的条目名」归并，看换完之后有没有新出现的条目
key() { tail -n +2 "$1" | sed -E 's/^ +- //; s/( = |: |：).*$//' | sort -u; }
key "$t.vb" > "$t.kb"; key "$t.ve" > "$t.ke"
new=$(comm -13 "$t.kb" "$t.ke" | tr '\n' ';' | cut -c1-300)
echo "$n|SWAPPED|$px|rc=$v1,$v2|pre=$(head -1 "$t.vb" | cut -d' ' -f1)|post=$(head -1 "$t.ve" | cut -d' ' -f1)|new=$new"
