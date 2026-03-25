# Shelf Monitor App

A Flutter application for retail shelf price monitoring. Sales agents use it on the field to capture a full shelf as a single panorama image using either photo-by-photo scanning or video recording. The panorama is stitched on-device using OpenCV — no server required.

---

## What It Does

| Step | Description |
|------|-------------|
| 1 | Sales agent opens the app and stands 1–1.5 m from the shelf |
| 2 | Captures the shelf using **Photo Scan** or **Video Scan** |
| 3 | OpenCV stitches the frames into a single wide panorama |
| 4 | Agent reviews the panorama and saves it to the gallery |

The panorama output is the foundation for downstream tasks such as price tag OCR, product detection (YOLO), and planogram compliance checks.

---

## Capture Modes

### Photo Scan
The camera stays live while the agent pans left to right. Two sub-modes are available:

- **Auto mode** — tap **Auto** to start. The gyroscope detects rotation and automatically snaps a frame every 15°. No tapping while moving. Tap **Stop** when done, then tap **Stitch**.
- **Manual mode** — tap the shutter button yourself at each position. Useful when you need to pause and re-aim.

A dot guide at the bottom of the screen tracks rotation progress across 7 checkpoints (~20° each). The dots turn green as you pass them.

### Video Scan
Record a short video while panning:

1. Tap **Video Scan** on the home screen.
2. Point at the left end of the shelf, tap the **Record** button.
3. Pan slowly and steadily to the right, keeping the shelf centred on the guide line.
4. Tap **Stop** — the app automatically extracts ~22 evenly-spaced frames and stitches them.

The first and last 8% of the video are skipped to discard camera shake at the start and stop of the recording.

---

## Architecture

```
shelf_monitor_app/
├── lib/
│   ├── main.dart                        # App entry point, dark theme
│   ├── screens/
│   │   ├── home_screen.dart             # Landing page, mode selection
│   │   ├── capture_screen.dart          # Photo Scan with gyro auto-capture
│   │   ├── video_capture_screen.dart    # Video Scan with recording timer
│   │   └── panorama_screen.dart         # Result viewer (pinch-to-zoom, save)
│   ├── services/
│   │   ├── stitch_service.dart          # Public API: stitch() and stitchVideo()
│   │   ├── stitch_isolate.dart          # OpenCV Stitcher for photo frames
│   │   └── video_stitch_isolate.dart    # VideoCapture frame extraction + stitch
│   └── widgets/
│       └── dot_guide.dart               # Gyroscope-driven progress indicator
├── android/
│   └── app/src/main/AndroidManifest.xml # Camera + storage permissions
└── pubspec.yaml
```

### Stitching Pipeline

```
Photo Scan                          Video Scan
──────────                          ──────────
Camera frames (1080p JPEG)          Camera video (720p MP4)
       │                                   │
       ▼                                   ▼
List<String> file paths             OpenCV VideoCapture
       │                            Extract ~22 frames (skip first/last 8%)
       │                                   │
       └──────────────┬────────────────────┘
                      ▼
          compute() → background isolate
                      │
          OpenCV Stitcher (PANORAMA mode)
          - registrationResol: 0.6
          - seamEstimationResol: 0.1
          - waveCorrection: true
          - panoConfidenceThresh: 1.0
                      │
          JPEG written to app documents dir
                      │
          PanoramaScreen ← file path
```

All stitching runs in a Dart isolate via `compute()` so the UI thread stays responsive during processing.

---

## Key Dependencies

| Package | Purpose |
|---------|---------|
| `camera` | Live camera preview, photo capture, video recording |
| `flutter_panorama` | Bundles OpenCV (`opencv_dart`) for on-device stitching |
| `opencv_dart` | OpenCV bindings — `Stitcher`, `VideoCapture`, `Mat` |
| `sensors_plus` | Gyroscope events for rotation tracking |
| `gal` | Save panorama image to device gallery |
| `path_provider` | Temp and documents directory paths |

---

## Setup & Build

### Prerequisites

- Flutter SDK (3.x)
- Android Studio with Android SDK (API 21+)
- A physical Android device with USB debugging enabled (the camera does not work on emulators)

### Steps

```bash
# 1. Clone the repo
git clone https://github.com/Comgen21/ImageStitching.git
cd ImageStitching

# 2. Install dependencies
flutter pub get

# 3. Connect your Android device via USB, then build and install
flutter build apk --debug
flutter install --debug
```

> The first build downloads the NDK and OpenCV native libraries (~300 MB). Subsequent builds are fast.

### Android Permissions

Declared in `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.CAMERA"/>
<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="29"/>
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE"  android:maxSdkVersion="32"/>
```

---

## Field Usage Guide

### Photo Scan — step by step

1. Stand **1–1.5 m** from the shelf, camera at shelf height.
2. Tap **Photo Scan** on the home screen.
3. Tap **Auto** to start auto-capture mode — the badge turns red.
4. Pan the phone **smoothly left to right**. You will hear/see a flash each time a frame is captured.
5. Watch the dot guide at the bottom — all 7 dots should turn green.
6. Tap the green **Stitch Panorama** button when you reach the right end.
7. Wait for OpenCV to process (10–30 seconds depending on frame count).
8. Review the panorama. Tap **Save** to keep it in the gallery.

### Video Scan — step by step

1. Stand **1–1.5 m** from the shelf, camera at shelf height.
2. Tap **Video Scan** on the home screen.
3. Point at the **left end** of the shelf.
4. Tap the red circle to **start recording**.
5. Pan **slowly and steadily** to the right — aim for 5–8 seconds total.
6. Keep the shelf centred on the horizontal guide line.
7. Tap the button again to **stop**. Processing starts automatically.
8. Review and save the panorama.

### Tips for Best Results

| Do | Avoid |
|----|-------|
| Pan at a slow, steady pace | Rushing — fast movement reduces frame overlap |
| Keep the camera level | Tilting up or down mid-pan |
| Ensure good shelf lighting | Dark aisles or harsh direct glare |
| Overlap consecutive shots by ~30% | Skipping large sections of the shelf |
| Hold the phone with both hands | One-handed shaky capture |

---

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| "Not enough overlapping features" | Frames do not overlap enough | Pan more slowly; use Photo Scan manual mode for tricky shelves |
| "Cannot match frames" | Too little texture / too much blur | Ensure good lighting; avoid motion blur by moving slower |
| Panorama has a wavy curve | Wave correction is on by default | Usually fixed automatically; try with more frames if it persists |
| App crashes on camera init | Missing camera permission | Go to Settings → Apps → Shelf Monitor → Permissions → Allow Camera |
| Stitching takes very long | Too many frames or high resolution | The first run after install is slower; subsequent runs are faster |

---

## Planned Features

- Price tag OCR on the stitched panorama
- YOLOv8 product detection and bounding box overlay
- Planogram compliance check (compare expected vs. actual shelf layout)
- Export panorama + metadata as a report PDF
- Multi-shelf session management
