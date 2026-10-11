# Inward

**Inward** is a sensor-to-reconstruction project for capturing indoor spaces with an iPhone and turning the resulting RGB-D data into 3D representations and room-level annotations.

The repository brings together an iOS LiDAR capture app, a Python receiver and processing utilities, and notebooks for experimenting with 3D reconstruction and room-number detection.

## What it does

- Captures synchronized RGB images, LiDAR depth, camera intrinsics, and device pose from an iPhone.
- Streams captured frames over Wi-Fi to a Python server.
- Saves each frame with its image, depth map, and metadata for downstream processing.
- Includes workflows for visualizing point clouds, training a 3D Gaussian Splatting scene, and detecting room numbers in captured images.

## Repository contents

| Path | Purpose |
| --- | --- |
| `iLiDAR/` | iOS app, setup notes, and full tutorial |
| `iLiDAR/Server/` | TCP receiver, data utilities, and point-cloud preview tools |
| `3DReconstructionPipeline.ipynb` | Notebook for the reconstruction / training workflow |
| `RoomAnnotationPipeline.ipynb` | Notebook for room-number image annotation |
| `preview_point_cloud.py` | Point-cloud preview helper |
| `ios_driver.py` | Root-level receiver script used by an alternate capture workflow |

The repository contains both current and experimental scripts. Check the script or notebook configuration before running it; some paths, datasets, model choices, and output directories may need to be adjusted for your environment.

## Requirements

### iPhone app

- macOS with Xcode and CocoaPods to build the iOS app.
- A physical iPhone or iPad with a LiDAR scanner. The iOS Simulator does not provide the required LiDAR sensor.
- iPhone and receiving computer connected to the same local Wi-Fi network.

### Python receiver and processing

- Python 3.10 is used in the documented server setup.
- Dependencies for the iLiDAR server are listed in `iLiDAR/Server/requirements.txt` (NumPy, SciPy, Matplotlib, and Pillow).
- Reconstruction and annotation notebooks may require additional packages, model weights, GPU access, or external datasets; follow the installation cells and configuration in each notebook.

## Capture quick start

### 1. Build and run the iOS app

Open `iLiDAR/iLiDAR.xcworkspace` in Xcode, configure your Apple development team, and build to a LiDAR-equipped device. Allow the app to use the camera and access devices on the local network when prompted.

For the app-specific instructions, see [iLiDAR/README.md](iLiDAR/README.md) and the [full tutorial](iLiDAR/full_tutorial.md).

### 2. Start the receiver

From the repository root:

```bash
cd iLiDAR/Server
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
python ios_driver.py
```

The receiver listens on `0.0.0.0:5678` by default and saves frames under `iLiDAR/Server/uploads/`. You can override the address, port, and output directory:

```bash
python ios_driver.py --host 0.0.0.0 --port 5678 --output ./uploads
```

Allow inbound connections to port `5678` in the computer's firewall if needed.

### 3. Connect and capture

In the app, enter the receiving computer's local IP address, connect, and enable network transfer. Keep both devices on the same network.

Each saved frame is placed in a recording folder and contains:

- `rgb.jpg`: color image
- `depth.bin`: little-endian Float32 depth values in meters
- `metadata.json`: frame dimensions, timestamps, camera intrinsics, camera pose, and tracking state
- `confidence.bin`: optional per-pixel depth confidence data

The receiver validates frame metadata and payload sizes before saving. Review the capture app's instructions for its matching network protocol; the repository includes other receiver scripts for separate or legacy workflows.

## Processing and exploration

- Use the server utilities to inspect depth data and preview point clouds.
- Explore `3DReconstructionPipeline.ipynb` for the RGB-D reconstruction and training workflow. Its configuration references local datasets and output directories that you must supply.
- Explore `RoomAnnotationPipeline.ipynb` for room-number detection and annotation from captured RGB frames. The notebook may require a compatible vision model, model access, and GPU resources.
- Use the notebooks' own setup and configuration sections as the source of truth for their specific inputs and dependencies.

## Contributors

- [Shatakshi Dixit](https://github.com/shatakshii1) ([@shatakshii1](https://github.com/shatakshii1))
- [Rishi Patel](https://github.com/riship2907) ([@riship2907](https://github.com/riship2907))
- [Arpan Bansal](https://github.com/bansalarpan) ([@bansalarpan](https://github.com/bansalarpan))

## Acknowledgments

This project uses and builds on work from these open-source repositories:

- [diff-gaussian-rasterization](https://github.com/graphdeco-inria/diff-gaussian-rasterization) by Graphdeco-Inria, used for differentiable Gaussian rasterization in the 3D reconstruction workflow.
- [iLiDAR](https://github.com/Galaxywalk/iLiDAR) by Galaxywalk, which provides the iPhone LiDAR capture app and related streaming foundation.

The iLiDAR project also builds on Apple's [LiDAR depth capture example](https://developer.apple.com/documentation/avfoundation/additional_data_capture/capturing_depth_using_the_lidar_camera). Please consult each upstream repository's license and notices for its terms.

## License

The iLiDAR subproject documents an MIT License in `iLiDAR/LICENSE.txt`. Check the license files and terms associated with each component, model, or dataset before reuse.
