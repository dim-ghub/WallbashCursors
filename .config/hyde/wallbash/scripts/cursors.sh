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

# Base palette
base_palette=("#D40000" "#E6E6E6" "#303030" "#F49436" "#FAB365" "#000000")

mkdir -p "$WORK_DIR" "$CONF_DIR" "$RECOLOR_DIR" "$XCURSORS_OUT" "$HYPRCURSORS_OUT" "$THEME_DIR"

rm -rf "$WORK_DIR"/*.png "$CONF_DIR" "$RECOLOR_DIR"
mkdir -p "$CONF_DIR" "$RECOLOR_DIR"

mapfile -t replacement_colors < "$COLOR_FILE"

# Extract PNGs and configs from cursors
for file in "$CURSOR_DIR"/*; do
  [ -f "$file" ] || continue

  name="$(basename "$file")"
  out_dir="$RECOLOR_DIR/$name"
  conf_path="$CONF_DIR/$name.conf"

  mkdir -p "$out_dir"
  xcur2png -d "$out_dir" -c "$conf_path" "$file"

  # Remove any PNG not 240x240 before recolor to prevent artifacts with color detection on smaller images (thanks to a friend for helping me figure out a way to prevent that)
  find "$out_dir" -type f -name '*.png' | while read -r png; do
    size=$(identify -format "%wx%h" "$png" 2>/dev/null || echo "")
    if [[ "$size" != "240x240" ]]; then
      echo "Removing non-240x240 image: $png ($size)"
      rm -f "$png"
    fi
  done
done

# Generate recolor jobs for the cursors.py script (modified version of recolor.py from the minecraft pack generator, modified to work with gradients)
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

printf '[%s]\n' "$(IFS=,; echo "${jobs[*]}")" | python3 "$RECOLOR_SCRIPT"

# Resize recolored images to support other smaller sizes and renaming of the images to work with the xcursor configs
for out_dir in "$RECOLOR_DIR"/*; do
  [ -d "$out_dir" ] || continue

  echo "Processing resizing in $out_dir"

  imgs=("$out_dir"/*.png)
  num_imgs=${#imgs[@]}

  for img in "${imgs[@]}"; do
    base=$(basename "$img" .png)

    num_str="${base##*_}"
    num_i=$((10#$num_str))
    num=$(printf "%03d" "$num_i")

    # Determine decrement value
    if [[ $num_imgs -eq 1 || $num_i -eq 9 ]]; then
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
      echo " -> Creating resized $size x $size: $new_name"
      magick "$img" -resize "${size}x${size}" "$out_dir/$new_name"
    done
  done
done

# Rebuild cursors using xcursorgen
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
  xcursorgen "$conf_file" "$out_cursor"
done

# Create symlinks for aliases (ill figure out more eventually)
echo "Creating symlinks for aliases..."
declare -A aliases=(
  ["left_ptr"]="default"
  ["pointer"]="default"
)
for alias in "${!aliases[@]}"; do
  target="${aliases[$alias]}"
  ln -sf "$target" "$XCURSORS_OUT/$alias"
done

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

# Generate hyprcursors
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
  # Get relative path from hyprcursors folder: folder_name/image.png
  rel_path="${png#$WORK_DIR/hyprcursors/}"
  folder_name="${rel_path%%/*}"
  filename="${rel_path#*/}"
  
  recolor_png="$RECOLOR_DIR/$folder_name/$filename"
  if [ -f "$recolor_png" ]; then
    cp -f "$recolor_png" "$png"
    echo "Replaced $png"
  fi
done

echo "Re-zipping folders to .hlc files in Wallbash-Cursor hyprcursors..."
mkdir -p "$HYPRCURSORS_OUT"
find "$WORK_DIR/hyprcursors" -mindepth 1 -maxdepth 1 -type d | while read -r folder; do
  name=$(basename "$folder")
  hlc_path="$HYPRCURSORS_OUT/$name.hlc"
  (cd "$folder" && zip -r -q "$hlc_path" .)
  echo "Created $hlc_path"
done

# Preferably delete these to save space if you dont use Sober

# Prepare centered cursor image and move to Sober
src="$HOME/.cache/cursors/recolor/hand1/hand1_000.png"
temp_dst="$HOME/.cache/cursors/recolor/hand1/ArrowCursor.png"
final_dst="$HOME/.var/app/org.vinegarhq.Sober/data/sober/assets/content/textures/Cursors/KeyboardMouse/ArrowCursor.png"

if [[ -f "$src" ]]; then
  echo "Creating centered ArrowCursor.png from $src..."

  offset_x=$((32 - 8))
  offset_y=$((32 - 3))

  magick "$src" -background none -gravity NorthWest \
    -splice "${offset_x}x${offset_y}" \
    -background none -extent 64x64 "$temp_dst"

  echo "Moving to Sober assets directory..."
  install -Dm644 "$temp_dst" "$final_dst"
else
  echo "Source image $src not found!"
fi

# Prepare centered ArrowFarCursor image and move to Sober
src="$HOME/.cache/cursors/recolor/left_ptr/left_ptr_000.png"
temp_dst="$HOME/.cache/cursors/recolor/left_ptr/ArrowFarCursor.png"
final_dst="$HOME/.var/app/org.vinegarhq.Sober/data/sober/assets/content/textures/Cursors/KeyboardMouse/ArrowFarCursor.png"

if [[ -f "$src" ]]; then
  echo "Creating centered ArrowFarCursor.png from $src..."

  offset_x=$((32 - 3))
  offset_y=$((32 - 3))

  magick "$src" -background none -gravity NorthWest \
    -splice "${offset_x}x${offset_y}" \
    -background none -extent 64x64 "$temp_dst"

  echo "Moving to Sober assets directory..."
  install -Dm644 "$temp_dst" "$final_dst"
else
  echo "Source image $src not found!"
fi

# Prepare centered IBeamCursor image and move to Sober
src="$HOME/.cache/cursors/recolor/text/text_000.png"
temp_dst="$HOME/.cache/cursors/recolor/left_ptr/IBeamCursor.png"
final_dst="$HOME/.var/app/org.vinegarhq.Sober/data/sober/assets/content/textures/Cursors/KeyboardMouse/IBeamCursor.png"

if [[ -f "$src" ]]; then
  echo "Creating centered IBeamCursor.png from $src..."

  offset_x=$((32 - 12))
  offset_y=$((32 - 12))

  magick "$src" -background none -gravity NorthWest \
    -splice "${offset_x}x${offset_y}" \
    -background none -extent 64x64 "$temp_dst"

  echo "Moving to Sober assets directory..."
  install -Dm644 "$temp_dst" "$final_dst"
else
  echo "Source image $src not found!"
fi

# Prepare centered MouseLockedCursor image and move to Sober
src="$HOME/.cache/cursors/recolor/crosshair/crosshair_000.png"
temp_dst="$HOME/.cache/cursors/recolor/left_ptr/MouseLockedCursor.png"
final_dst="$HOME/.var/app/org.vinegarhq.Sober/data/sober/assets/content/textures/MouseLockedCursor.png"

if [[ -f "$src" ]]; then
  echo "Creating centered IBeamCursor.png from $src..."

  offset_x=$((32 - 12))
  offset_y=$((32 - 13))

  magick "$src" -background none -gravity NorthWest \
    -splice "${offset_x}x${offset_y}" \
    -background none -extent 64x64 "$temp_dst"

  echo "Moving to Sober assets directory..."
  install -Dm644 "$temp_dst" "$final_dst"
else
  echo "Source image $src not found!"
fi

# Will probably turn these into a single function eventually but didnt feel like it and it works fine

echo "All done!"
