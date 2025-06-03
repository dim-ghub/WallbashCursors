#!/bin/bash
set -euo pipefail

# Paths
CURSOR_DIR="$HOME/.local/share/icons/Cosmic-C/cursors"
WORK_DIR="$HOME/.cache/cursors"
CONF_DIR="$WORK_DIR/configs"
RECOLOR_DIR="$WORK_DIR/recolor"
COLOR_FILE="$HOME/.cache/cursors.txt"
RECOLOR_SCRIPT="$HOME/.config/hyde/wallbash/scripts/cursors.py"

XCURSORS_OUT="$HOME/.local/share/icons/Wallbash-Cursor/cursors"
HYPRCURSORS_OUT="$HOME/.local/share/icons/Wallbash-Cursor/hyprcursors"
THEME_DIR="$HOME/.local/share/icons/Wallbash-Cursor"

# Base palette (Use a color picker to find whatever colors are used in the pack you are using)
base_palette=("#D40000" "#E6E6E6" "#303030" "#F49436" "#FAB365" "#000000")

# Prepare directories
mkdir -p "$WORK_DIR" "$CONF_DIR" "$RECOLOR_DIR" "$XCURSORS_OUT" "$HYPRCURSORS_OUT" "$THEME_DIR"

# Clear old data
rm -rf "$WORK_DIR"/*.png "$CONF_DIR" "$RECOLOR_DIR"
mkdir -p "$CONF_DIR" "$RECOLOR_DIR"

# Read target colors
mapfile -t replacement_colors < "$COLOR_FILE"

extract_cursor_pngs() {
  for file in "$CURSOR_DIR"/*; do
    [ -f "$file" ] || continue

    (
      name="$(basename "$file")"
      out_dir="$RECOLOR_DIR/$name"
      conf_path="$CONF_DIR/$name.conf"

      mkdir -p "$out_dir"
      xcur2png -d "$out_dir" -c "$conf_path" "$file"

      # Remove any PNG not 240x240 before recolor
      find "$out_dir" -type f -name '*.png' | while read -r png; do
        size=$(identify -format "%wx%h" "$png" 2>/dev/null || echo "")
        if [[ "$size" != "240x240" ]]; then
          echo "Removing non-240x240 image: $png ($size)"
          rm -f "$png"
        fi
      done
    ) &
  done

  wait
  echo "All cursor PNGs extracted and cleaned."
}

extract_cursor_pngs

# Generate recolor jobs
jobs=()
for dir in "$RECOLOR_DIR"/*; do
  [ -d "$dir" ] || continue

  for img in "$dir"/*.png; do
    [ -f "$img" ] || continue
    relname=$(basename "$img")
    jobs+=("{
      \"img_path\": \"$img\",
      \"out_path\": \"$dir/$relname\",
      \"base_palette\": $(printf '%s\n' "${base_palette[@]}" | jq -R . | jq -s .),
      \"target_palette\": $(printf '%s\n' "${replacement_colors[@]}" | jq -R . | jq -s .)
    }")
  done
done

# Run recoloring using cursors.py
printf '[%s]\n' "$(IFS=,; echo "${jobs[*]}")" | python3 "$RECOLOR_SCRIPT"

# Resize recolored images using background jobs
echo "Resizing recolored images with background jobs..."

resize_cursor() {
  local out_dir="$1"
  local img="$2"

  base=$(basename "$img" .png)
  num_str="${base##*_}"
  num_i=$((10#$num_str)) # base-10 safe parse
  num=$(printf "%03d" "$num_i")

  if [[ $(ls "$out_dir"/*.png | wc -l) -eq 1 || $num_i -eq 9 ]]; then
    decrement=1
  else
    decrement=24
  fi

  sizes=(144 120 96 72 60 48 36 30 24)
  for idx in "${!sizes[@]}"; do
    size=${sizes[$idx]}
    new_num=$(( num_i - decrement * (idx + 1) ))
    new_num_str=$(printf "%03d" "$new_num")
    new_name="${base%_*}_$new_num_str.png"
    magick "$img" -resize "${size}x${size}" "$out_dir/$new_name" &
  done
}

export -f resize_cursor

resize_jobs=()
for out_dir in "$RECOLOR_DIR"/*; do
  [ -d "$out_dir" ] || continue
  for img in "$out_dir"/*.png; do
    [ -f "$img" ] || continue
    resize_cursor "$out_dir" "$img"
  done
done

# Wait for all background jobs to finish
echo "Waiting for resize jobs to complete..."
wait
echo "All resizing complete."

rebuild_xcursors() {
  echo "Rebuilding cursor files into $XCURSORS_OUT"
  rm -rf "$XCURSORS_OUT"
  mkdir -p "$XCURSORS_OUT"

  for dir in "$RECOLOR_DIR"/*; do
    [ -d "$dir" ] || continue

    base_name=$(basename "$dir")
    conf_file="$CONF_DIR/$base_name.conf"
    out_cursor="$XCURSORS_OUT/$base_name"

    if [ ! -f "$conf_file" ]; then
      echo "Warning: config file $conf_file not found, skipping $base_name"
      continue
    fi

    echo "Compiling cursor: $base_name"
    xcursorgen "$conf_file" "$out_cursor" &
  done

  wait
  echo "All cursors compiled."
}

rebuild_xcursors

# Generate index.theme
cat > "$THEME_DIR/index.theme" << EOF
[Icon Theme]
Name=Wallbash-Cursor
Comment=Automatically generated cursor theme
Inherits=default
Directories=cursors hyprcursors
EOF
echo "Created $THEME_DIR/index.theme"

# Generate cursor.theme
cat > "$THEME_DIR/cursor.theme" << EOF
[Cursor Theme]
Name=Wallbash-Cursor
Comment=Automatically generated cursor theme
Size=24
EOF
echo "Created $THEME_DIR/cursor.theme"

# Generate manifest.hl for hyprcursor theme
cat > "$THEME_DIR/manifest.hl" << EOF
name = Wallbash-Cursor
description = Automatically extracted with hyprcursor-util
version = 0.1
cursors_directory = hyprcursors
EOF
echo "Created $THEME_DIR/manifest.hl"

prepare_hyprcursors() {
  echo "Copying Cosmic-C hyprcursors to working cache..."
  rm -rf "$WORK_DIR/hyprcursors"
  mkdir -p "$WORK_DIR/hyprcursors"
  cp -r "$HOME/.local/share/icons/Cosmic-C/hyprcursors/"* "$WORK_DIR/hyprcursors/"

  echo "Extracting .hlc archives and deleting originals..."
  find "$WORK_DIR/hyprcursors" -type f -name '*.hlc' | while read -r hlc; do
    dir="${hlc%.hlc}"
    mkdir -p "$dir"
    unzip -o -q "$hlc" -d "$dir"
    rm -f "$hlc"
  done

  echo "Replacing PNGs inside extracted folders with recolored versions..."
  find "$WORK_DIR/hyprcursors" -mindepth 2 -type f -name '*.png' | while read -r png; do
    rel_path="${png#$WORK_DIR/hyprcursors/}"
    folder_name="${rel_path%%/*}"
    filename="${rel_path#*/}"

    recolor_png="$RECOLOR_DIR/$folder_name/$filename"
    if [[ -f "$recolor_png" ]]; then
      cp -f "$recolor_png" "$png"
      echo "Replaced $png"
    fi
  done

  echo "Re-zipping folders to .hlc files in Wallbash-Cursor hyprcursors..."
  mkdir -p "$HYPRCURSORS_OUT"
  find "$WORK_DIR/hyprcursors" -mindepth 1 -maxdepth 1 -type d | while read -r folder; do
    (
      name=$(basename "$folder")
      hlc_path="$HYPRCURSORS_OUT/$name.hlc"
      (cd "$folder" && zip -r -q "$hlc_path" .)
      echo "Created $hlc_path"
    ) &
  done

  wait
  echo "All .hlc archives created."
}

prepare_hyprcursors

generate_cursor() {
  local src="$1"
  local temp_dst="$2"
  local final_dst="$3"
  local offset_x="$4"
  local offset_y="$5"
  local label="$6"

  if [[ -f "$src" ]]; then
    echo "Creating centered ${label} from $src..."

    magick "$src" -background none -gravity NorthWest \
      -splice "${offset_x}x${offset_y}" \
      -background none -extent 64x64 "$temp_dst"

    echo "Moving ${label} to Sober assets directory..."
    install -Dm644 "$temp_dst" "$final_dst"
  else
    echo "Source image $src not found!"
  fi
}

# Apply cursors to Sober
generate_cursor "$HOME/.cache/cursors/recolor/hand1/hand1_000.png" \
  "$HOME/.cache/cursors/recolor/hand1/ArrowCursor.png" \
  "$HOME/.var/app/org.vinegarhq.Sober/data/sober/assets/content/textures/Cursors/KeyboardMouse/ArrowCursor.png" \
  $((32 - 8)) $((32 - 3)) "ArrowCursor" &

generate_cursor "$HOME/.cache/cursors/recolor/left_ptr/left_ptr_000.png" \
  "$HOME/.cache/cursors/recolor/left_ptr/ArrowFarCursor.png" \
  "$HOME/.var/app/org.vinegarhq.Sober/data/sober/assets/content/textures/Cursors/KeyboardMouse/ArrowFarCursor.png" \
  $((32 - 3)) $((32 - 3)) "ArrowFarCursor" &

generate_cursor "$HOME/.cache/cursors/recolor/text/text_000.png" \
  "$HOME/.cache/cursors/recolor/left_ptr/IBeamCursor.png" \
  "$HOME/.var/app/org.vinegarhq.Sober/data/sober/assets/content/textures/Cursors/KeyboardMouse/IBeamCursor.png" \
  $((32 - 12)) $((32 - 12)) "IBeamCursor" &

generate_cursor "$HOME/.cache/cursors/recolor/crosshair/crosshair_000.png" \
  "$HOME/.cache/cursors/recolor/left_ptr/MouseLockedCursor.png" \
  "$HOME/.var/app/org.vinegarhq.Sober/data/sober/assets/content/textures/MouseLockedCursor.png" \
  $((32 - 12)) $((32 - 13)) "MouseLockedCursor" &

# Wait for all background jobs
wait
echo "All cursor generation jobs complete."

# hyprctl dispatch exec 'hydectl reload'
hyprctl reload
