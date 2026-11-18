#!/bin/bash
# Stands in for `scriptwidget watch`: draws pictures with ImageMagick and
# prints one JSON event per line. Commands arrive on a named pipe:
#   tap <id> <n> | move <id> <x> <y> | mode <desktop|peek> | now
dir="$XDG_RUNTIME_DIR/scriptwidget-spike"
mkdir -p "$dir/frames"; rm -f "$dir"/frames/*
fifo="$dir/ctl"; rm -f "$fifo"; mkfifo -m 600 "$fifo"
exec 3<>"$fifo"
log="$dir/log"; : > "$log"

ax=80; ay=80; bx=460; by=80; count=0; version=0
echo '{"event":"hello","version":1}'

colors=("#e64553" "#fe640b" "#40a02b" "#1e66f5")
frames=""
for i in 0 1 2 3; do
  magick -size 170x170 xc:none -fill "${colors[$i]}" -draw "roundrectangle 0,0 169,169 28,28" \
    -fill white -pointsize 64 -gravity center -annotate 0 "$i" "$dir/frames/b-$i.png"
  frames="$frames\"$dir/frames/b-$i.png\","
done
emit_b() { echo "{\"event\":\"widget\",\"id\":\"b\",\"x\":$bx,\"y\":$by,\"width\":170,\"height\":170,\"frames\":[${frames%,}],\"delay\":250,\"taps\":[]}"; }

emit_a() {
  version=$((version + 1))
  local file="$dir/frames/a-$version.png" stamp
  stamp=$(date +%H:%M:%S.%N | cut -c1-12)
  magick -size 329x170 xc:none -fill "#1e1e2ee6" -draw "roundrectangle 0,0 328,169 28,28" \
    -fill white -pointsize 24 -gravity north -annotate +0+18 "$stamp" \
    -pointsize 20 -annotate +0+60 "count $count   v$version" \
    -fill "#1e66f5" -draw "roundrectangle 100,105 228,150 12,12" \
    -fill white -pointsize 20 -gravity north -annotate +0+116 "+1" "$file"
  echo "{\"event\":\"widget\",\"id\":\"a\",\"x\":$ax,\"y\":$ay,\"width\":329,\"height\":170,\"frames\":[\"$file\"],\"taps\":[{\"n\":1,\"x\":100,\"y\":105,\"width\":128,\"height\":45}]}"
  echo "$stamp emit a v$version" >> "$log"
  [ "$version" -gt 2 ] && rm -f "$dir/frames/a-$((version - 2)).png"
}

emit_b; emit_a
while true; do
  if read -r -t 2 -u 3 verb one two three; then
    echo "$(date +%H:%M:%S.%N | cut -c1-12) command $verb $one $two $three" >> "$log"
    case "$verb" in
      tap) [ "$one" = a ] && count=$((count + 1)); emit_a ;;
      move)
        case "$two$three" in *[!0-9-]*|"") continue ;; esac
        if [ "$one" = a ]; then ax=$two; ay=$three; emit_a; elif [ "$one" = b ]; then bx=$two; by=$three; emit_b; fi ;;
      mode) case "$one" in desktop|peek) echo "{\"event\":\"mode\",\"mode\":\"$one\"}" ;; esac ;;
      now) emit_a ;;
    esac
  else
    emit_a
  fi
done
