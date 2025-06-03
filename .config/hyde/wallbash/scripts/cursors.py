#!/usr/bin/env python3
import sys
import json
import os
import numpy as np
from PIL import Image
from concurrent.futures import ProcessPoolExecutor
from skimage.color import rgb2lab

def hex_to_rgb(hex_color):
    hex_color = hex_color.lstrip("#")
    return [int(hex_color[i:i+2], 16) for i in (0, 2, 4)]

def get_palette_maps(base_palette, target_palette):
    base_rgb = np.array([hex_to_rgb(c) for c in base_palette]) / 255.0
    target_rgb = np.array([hex_to_rgb(c) for c in target_palette])

    base_lab = rgb2lab(base_rgb.reshape(1, -1, 3)).reshape(-1, 3)
    return base_lab, target_rgb

def recolor_image(job):
    img_path = job["img_path"]
    out_path = job["out_path"]
    base_lab = job["base_lab"]
    target_rgb = job["target_rgb"]

    try:
        img = Image.open(img_path).convert("RGBA")
        data = np.array(img)

        rgb = data[:, :, :3].reshape(-1, 3).astype(np.float32) / 255.0
        alpha = data[:, :, 3].reshape(-1)

        recolored = rgb.copy()

        # Prepare masks
        fully_transparent = alpha == 0
        semi_transparent = (alpha > 0) & (alpha < 255)
        opaque_or_semi = ~fully_transparent

        rgb[semi_transparent] = [0, 0, 0]  # match as black

        # Convert to Lab
        rgb_lab = rgb2lab(rgb.reshape(1, -1, 3)).reshape(-1, 3)

        # Only recolor pixels that aren't fully transparent
        recolor_lab = rgb_lab[opaque_or_semi]

        # Compute distances to palette
        distances = np.linalg.norm(recolor_lab[:, None, :] - base_lab[None, :, :], axis=2)

        # Use inverse distance weighting for smooth interpolation
        inv_dist = 1 / (distances + 1e-6)
        weights = inv_dist / np.sum(inv_dist, axis=1, keepdims=True)

        # Interpolated RGB (in float 0–255)
        new_rgb = weights @ target_rgb

        # Merge recolored pixels back into full image
        full_rgb = recolored.reshape(-1, 3) * 255
        full_rgb[opaque_or_semi] = new_rgb

        final_rgb = np.clip(full_rgb, 0, 255).astype(np.uint8)
        final_rgba = np.concatenate([final_rgb, alpha[:, None]], axis=1).reshape(data.shape)

        out_img = Image.fromarray(final_rgba, "RGBA")
        os.makedirs(os.path.dirname(out_path), exist_ok=True)
        out_img.save(out_path)

    except Exception as e:
        print(f"Failed to process {img_path}: {e}", file=sys.stderr)

def main():
    jobs = json.load(sys.stdin)
    if not jobs:
        sys.exit("No jobs provided.")

    base_palette = jobs[0]["base_palette"]
    target_palette = jobs[0]["target_palette"]
    base_lab, target_rgb = get_palette_maps(base_palette, target_palette)

    for job in jobs:
        job["base_lab"] = base_lab
        job["target_rgb"] = target_rgb

    with ProcessPoolExecutor() as executor:
        executor.map(recolor_image, jobs)

if __name__ == "__main__":
    main()
