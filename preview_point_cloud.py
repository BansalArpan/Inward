import json
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
from PIL import Image

# ---------- Settings ----------

BASE_DIR = Path(__file__).resolve().parent

FRAME_DIR = (
    BASE_DIR
    / "iLiDAR"
    / "9D6D7A6E-4CD6-4883-9C04-9DDDB12982EC"
    / "frame_000298"
)
METADATA_FILE = FRAME_DIR / "metadata.json"
DEPTH_FILE = FRAME_DIR / "depth.bin"
RGB_FILE = FRAME_DIR / "rgb.jpg"

# Preview filters, in meters.
MIN_DEPTH = 0.15
MAX_DEPTH = 5.0
SH_C0 = 0.28209479177387814
SPLAT_SIZE = 0.01
SPLAT_OPACITY = 8.0

OUTPUT_FILE = BASE_DIR / "approximate_point_cloud.ply"


def load_points():
    with METADATA_FILE.open(encoding="utf-8") as file:
        metadata = json.load(file)

    depth_width = metadata["depth_width"]
    depth_height = metadata["depth_height"]
    expected_bytes = depth_width * depth_height * 4
    if (
        metadata["depth_dtype"] != "float32"
        or metadata["depth_byte_order"] != "little"
    ):
        raise ValueError("Expected little-endian Float32 depth in meters.")
    if DEPTH_FILE.stat().st_size != expected_bytes:
        raise ValueError(
            f"Expected {expected_bytes} depth bytes, "
            f"but found {DEPTH_FILE.stat().st_size}. "
            "Check the file and depth dimensions."
        )

    depth = np.fromfile(DEPTH_FILE, dtype="<f4").reshape(
        depth_height, depth_width
    )

    with Image.open(RGB_FILE) as image:
        image = image.convert("RGB")
        expected_rgb_size = (
            metadata["rgb_width"],
            metadata["rgb_height"],
        )
        if image.size != expected_rgb_size:
            raise ValueError(
                f"Expected RGB image size {expected_rgb_size}, "
                f"but found {image.size}."
            )

        colors = np.asarray(
            image.resize(
                (depth_width, depth_height),
                Image.Resampling.BILINEAR,
            )
        )

    # Intrinsics are stored at RGB resolution; scale them to the depth grid.
    intrinsics = np.asarray(metadata["camera_intrinsics_3x3"], dtype=np.float32)
    if intrinsics.shape != (3, 3):
        raise ValueError("camera_intrinsics_3x3 must be a 3x3 matrix.")
    scale_x = depth_width / metadata["intrinsics_reference_width"]
    scale_y = depth_height / metadata["intrinsics_reference_height"]
    fx = intrinsics[0, 0] * scale_x
    fy = intrinsics[1, 1] * scale_y
    cx = intrinsics[0, 2] * scale_x
    cy = intrinsics[1, 2] * scale_y

    u, v = np.meshgrid(
        np.arange(depth_width),
        np.arange(depth_height),
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

    print(f"Using metadata from {METADATA_FILE}")
    print(
        f"Scaled intrinsics: fx={fx:.2f}, fy={fy:.2f}, "
        f"cx={cx:.2f}, cy={cy:.2f}"
    )
    print(f"Valid points: {len(points):,}")
    print(f"Depth range: {z.min():.2f}–{z.max():.2f} meters")

    return points, point_colors


def save_ply(points, colors):
    log_splat_size = np.log(SPLAT_SIZE)
    dc_colors = (colors.astype(np.float64) / 255.0 - 0.5) / SH_C0

    with OUTPUT_FILE.open("w", encoding="ascii") as file:
        file.write(
            "ply\n"
            "format ascii 1.0\n"
            "comment Approximate calibration; Gaussian splat point cloud\n"
            "comment Coordinates: X right, Y up, Z forward\n"
            f"element vertex {len(points)}\n"
            "property float x\n"
            "property float y\n"
            "property float z\n"
            "property float scale_0\n"
            "property float scale_1\n"
            "property float scale_2\n"
            "property float rot_0\n"
            "property float rot_1\n"
            "property float rot_2\n"
            "property float rot_3\n"
            "property float f_dc_0\n"
            "property float f_dc_1\n"
            "property float f_dc_2\n"
            "property float opacity\n"
            "end_header\n"
        )

        for (x, y, z), (r, g, b) in zip(points, dc_colors):
            file.write(
                f"{x:.6f} {y:.6f} {z:.6f} "
                f"{log_splat_size:.6f} {log_splat_size:.6f} {log_splat_size:.6f} "
                "1.000000 0.000000 0.000000 0.000000 "
                f"{r:.6f} {g:.6f} {b:.6f} {SPLAT_OPACITY:.6f}\n"
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
