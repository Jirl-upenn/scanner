
# Data Specification

This document describes the data format recorded by the app.

The collected datasets are each contained in a folder, named after a random hash, for example `71de12f9`. A dataset folder has the following directory structure:

```
camera_matrix.csv
odometry.csv
poses.csv
imu.csv
clock.csv
events.csv
planes.json
metadata.json
depth/
  - 000000.png
  - 000001.png
  - ...
confidence/
  - 000000.png
  - 000001.png
  - ...
distortion/          (optional, present when lens distortion data is available)
  - 000000.bin
  - 000001.bin
  - ...
rgb.mp4
```

`rgb.mp4` is an HEVC encoded video, which contains the recorded data from the iPhone's camera.

The `depth/` directory contains the depth maps. One `.png` file per rgb frame. Each of these is a 16 bit grayscale png image. They have a height of 192 elements and width of 256 elements. The values are the measured depth in millimeters, for that pixel position. In [OpenCV](https://docs.opencv.org/4.5.5/), these can be read with `cv2.imread(depth_frame_path, -1)`.

The `confidence/` directory contains confidence maps corresponding to each depth map. They are grayscale png files encoding 192 x 256 element matrices. The values are either 0, 1 or 2. A higher value means a higher confidence.

The `camera_matrix.csv` is a 3 x 3 matrix containing the [camera intrinsic parameters](https://en.wikipedia.org/wiki/Camera_resectioning#Intrinsic_parameters) from the final recorded frame. This file is kept for backwards compatibility; for per-frame intrinsics use the `fx`, `fy`, `cx`, `cy` columns in `odometry.csv`.

The `odometry.csv` file contains the camera pose and intrinsics for each frame. The first line is a header. The meaning of the fields are:

| Field | <div style="width: 500px">Meaning</div> |
|---|---|
| timestamp | Timestamp in seconds |
| frame | Frame number to which this pose corresponds to e.g. `000005` |
| x | x coordinate in meters from when the session was started |
| y | y coordinate in meters from when the session was started |
| z | z coordinate in meters from when the session was started |
| qx | x component of quaternion representing camera pose rotation |
| qy | y component of quaternion representing camera pose rotation |
| qz | z component of quaternion representing camera pose rotation |
| qw | w component of quaternion representing camera pose rotation |
| fx | Horizontal focal length in pixels |
| fy | Vertical focal length in pixels |
| cx | Principal point x coordinate in pixels |
| cy | Principal point y coordinate in pixels |
| distortion_center_x | x coordinate of the lens distortion center in pixels (empty if unavailable) |
| distortion_center_y | y coordinate of the lens distortion center in pixels (empty if unavailable) |

The `distortion/` directory contains per-frame lens distortion lookup tables, present only when the device exposes calibration data. Each `.bin` file is a raw array of little-endian `float32` values mapping radial distance from the distortion center to a correction factor. The number of entries is `file_size_in_bytes / 4`. The filenames correspond to the `frame` field in `odometry.csv`.

The `imu.csv` file contains timestamps, linear acceleration readings and angular rotation readings. The first line is a header. The meaning of the fields are:

| Field | <div style="width: 500px">Meaning</div> |
|---|---|
| timestamp | Timestamp in seconds |
| a\_x | Acceleration in g in x direction |
| a\_y | Acceleration in g in y direction |
| a\_z | Acceleration in g in z direction |
| alpha\_x | Rotation in rad/s around the x-axis |
| alpha\_y | Rotation in rad/s around the y-axis |
| alpha\_z | Rotation in rad/s around the z-axis |

All timestamps (in `odometry.csv`, `poses.csv`, `imu.csv` and `events.csv`) are in seconds since the phone booted (`ProcessInfo.systemUptime`, the clock of `ARFrame.timestamp` and Core Motion).

The `poses.csv` file contains the camera pose of every frame ARKit delivered, including frames whose images were not saved (because of the fps setting, or because encoding fell behind). Poses use the same convention as `odometry.csv`. The fields are:

| Field | <div style="width: 500px">Meaning</div> |
|---|---|
| timestamp | Timestamp in seconds |
| x, y, z | Camera position in meters, as in `odometry.csv` |
| qx, qy, qz, qw | Camera rotation quaternion, as in `odometry.csv` |
| tracking\_state | `normal`, `limited` or `not_available` |
| tracking\_reason | When limited: `initializing`, `relocalizing`, `excessive_motion` or `insufficient_features` |
| world\_mapping\_status | `not_available`, `limited`, `extending` or `mapped` |

The `clock.csv` file relates timestamps to wall clock time. Each row is a reading of the uptime clock and the Unix time clock taken back to back: one when recording starts, one per second while recording and one when it stops. Unix time of a timestamp `t` is `t + (unix - uptime)`; take the median over rows, or interpolate if the wall clock was corrected during the recording.

| Field | <div style="width: 500px">Meaning</div> |
|---|---|
| uptime | Uptime in seconds |
| unix | Unix time in seconds |
| window | Uptime elapsed around the Unix time read, in seconds: a bound on the pairing error |

The `events.csv` file lists things that explain gaps or bad stretches in a recording: `tracking_state` changes, `frame_dropped` (encoding fell behind, so the frame's images were not saved; its pose is still in `poses.csv`), `thermal_state` (at start, on change and at stop), `memory_warning`, `app_will_resign_active`, `session_interrupted`, `session_interruption_ended` and `session_failed`. The fields are `timestamp`, `event` and `detail`.

The `planes.json` file contains the horizontal planes ARKit detected, as of the end of the recording. Each has a `classification` (`floor`, `table`, `seat`, ... or `none`), a column-major 4 x 4 `transform` from plane to world (ARKit's world frame), a `center` and an `extent` (meters along the plane's x and z axes), both in the plane's frame.

The `metadata.json` file describes the recording: app version, device model, iOS version, video resolution, fps divider, frame counts (`ar_frames`, `saved_frames`, `dropped_frames`), the start time in both clocks, the pose, timestamp and IMU conventions, and `wearer_height_m`: the wearer's standing height in meters as entered in the app (null if none was set).
