from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
from PIL import Image

# ---------- Settings ----------

BASE_DIR = Path(__file__).resolve().parent

DEPTH_FILE = BASE_DIR / "example_data" / "example_depth_data.bin"
RGB_FILE = BASE_DIR / "example_data" / "example_rgb_image.jpg"

DEPTH_WIDTH = 320
DEPTH_HEIGHT = 240

# Estimated horizontal field of view—not actual camera calibration.
# Changing this changes the reconstructed width and height.
ASSUMED_HORIZONTAL_FOV_DEG = 60.0

# Preview filters, in meters.
MIN_DEPTH = 0.15
MAX_DEPTH = 5.0

OUTPUT_FILE = BASE_DIR / "approximate_point_cloud.ply"


def load_points():
    # This repository's example depth files use Float16.
    depth = np.fromfile(DEPTH_FILE, dtype="<f2")

    expected = DEPTH_WIDTH * DEPTH_HEIGHT
    if depth.size != expected:
        raise ValueError(
            f"Expected {expected * 2} depth bytes, "
            f"but found {DEPTH_FILE.stat().st_size}. "
            "Check the file and depth dimensions."
        )

    depth = depth.reshape(DEPTH_HEIGHT, DEPTH_WIDTH).astype(np.float32)

    # Assume the RGB and depth cover the same view, without rotation/crop.
    with Image.open(RGB_FILE) as image:
        image = image.convert("RGB")

        rgb_aspect = image.width / image.height
        depth_aspect = DEPTH_WIDTH / DEPTH_HEIGHT
        if not np.isclose(rgb_aspect, depth_aspect, rtol=0.01):
            raise ValueError(
                "RGB and depth aspect ratios differ. "
                "Their alignment needs checking before coloring the cloud."
            )

        colors = np.asarray(
            image.resize(
                (DEPTH_WIDTH, DEPTH_HEIGHT),
                Image.Resampling.BILINEAR,
            )
        )

    # Approximate intrinsics at DEPTH resolution.
    fov = np.deg2rad(ASSUMED_HORIZONTAL_FOV_DEG)
    fx = DEPTH_WIDTH / (2.0 * np.tan(fov / 2.0))
    fy = fx  # Assumes square pixels.
    cx = (DEPTH_WIDTH - 1) / 2.0
    cy = (DEPTH_HEIGHT - 1) / 2.0

    u, v = np.meshgrid(
        np.arange(DEPTH_WIDTH),
        np.arange(DEPTH_HEIGHT),
    )

    valid = (
        np.isfinite(depth)
        & (depth > MIN_DEPTH)
        & (depth < MAX_DEPTH)
    )

    z = depth[valid]
    x = (u[valid] - cx) * z / fx
    y = -(v[valid] - cy) * z / fy

    # Local preview coordinates: X right, Y up, Z forward.
    # These are not ARKit world coordinates.
    points = np.column_stack((x, y, z))
    point_colors = colors[valid]

    if len(points) == 0:
        raise ValueError(
            "No valid points remain. Check the depth format and filters."
        )

    print("WARNING: Using estimated camera calibration.")
    print(f"Estimated fx={fx:.2f}, fy={fy:.2f}, cx={cx:.2f}, cy={cy:.2f}")
    print(f"Valid points: {len(points):,}")
    print(f"Depth range: {z.min():.2f}–{z.max():.2f} meters")

    return points, point_colors


def save_ply(points, colors):
    with OUTPUT_FILE.open("w", encoding="ascii") as file:
        file.write(
            "ply\n"
            "format ascii 1.0\n"
            "comment Approximate calibration; not for measurements\n"
            "comment Coordinates: X right, Y up, Z forward\n"
            f"element vertex {len(points)}\n"
            "property float x\n"
            "property float y\n"
            "property float z\n"
            "property uchar red\n"
            "property uchar green\n"
            "property uchar blue\n"
            "end_header\n"
        )

        for (x, y, z), (r, g, b) in zip(points, colors):
            file.write(
                f"{x:.6f} {y:.6f} {z:.6f} "
                f"{int(r)} {int(g)} {int(b)}\n"
            )

    print(f"Saved: {OUTPUT_FILE}")


def show_points(points, colors):
    # Limit display points for smoother mouse interaction.
    step = max(1, int(np.ceil(len(points) / 20000)))
    preview = points[::step]
    preview_colors = colors[::step] / 255.0

    figure = plt.figure(figsize=(11, 8))
    axis = figure.add_subplot(111, projection="3d")

    # Plot depth along the horizontal Y axis and height vertically.
    axis.scatter(
        preview[:, 0],
        preview[:, 2],
        preview[:, 1],
        c=preview_colors,
        s=1,
        depthshade=False,
    )

    axis.set_xlabel("Right / left (X)")
    axis.set_ylabel("Forward depth (Z)")
    axis.set_zlabel("Height (Y)")
    axis.set_title(
        "Approximate single-frame point cloud\n"
        "Drag to rotate — calibration is estimated"
    )

    # Equal scale on all three axes prevents display-induced stretching.
    plotted = points[:, [0, 2, 1]]
    minimum = plotted.min(axis=0)
    maximum = plotted.max(axis=0)
    center = (minimum + maximum) / 2
    radius = max(float((maximum - minimum).max()) / 2, 0.01)

    axis.set_xlim(center[0] - radius, center[0] + radius)
    axis.set_ylim(center[1] - radius, center[1] + radius)
    axis.set_zlim(center[2] - radius, center[2] + radius)
    axis.set_box_aspect((1, 1, 1))

    plt.tight_layout()
    plt.show()


if __name__ == "__main__":
    points, colors = load_points()
    save_ply(points, colors)
    show_points(points, colors)