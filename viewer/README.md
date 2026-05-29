# Orbbec Test Viewer

Native macOS viewer for the connected Orbbec/OpenNI camera.

See the project README one directory up for dependency setup.

## Build

```bash
viewer/build_viewer.sh
```

The app bundle is created at:

```text
build/OrbbecViewer.app
```

## Run

```bash
open build/OrbbecViewer.app
```

Captures are saved to:

```text
outputs/viewer_captures
```

The RGB stream uses AVFoundation because this camera exposes RGB as a UVC camera on macOS. Depth and point cloud use OrbbecSDK v1.
