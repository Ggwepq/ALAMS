# ALAMS — Automated Logbook Attendance Monitoring System

## What Is This?

**ALAMS** is a mobile attendance monitoring application built with Flutter for Android. It replaces traditional punch cards and PIN-based systems with a fully automated, camera-driven workflow that verifies employee identity through real-time **face recognition**, **liveness detection**, and **neural-network anti-spoofing** before recording any attendance event.

All biometric processing — face detection, embedding generation, matching, liveness checks, and passive spoof detection — happens **entirely on-device**. Attendance data is stored locally in SQLite and optionally synced to a Supabase cloud backend for multi-device visibility.

---

## Quick Feature Summary

- **Face Recognition** — Employees are identified using a FaceNet TFLite model that generates L2-normalised 128-dimensional facial embeddings. Recognition uses a two-threshold cosine distance match (primary threshold 0.40 + margin guard 0.08) against stored embeddings.
- **Multi-Layer Anti-Spoofing** — Three independent security layers work together: (1) active liveness challenges (3 randomised actions per session drawn via CSPRNG), (2) passive frame-level heuristics (staticness, aspect ratio, eye symmetry), and (3) a native NCNN neural network (MiniFASNet) that classifies every frame as real skin vs. a spoofed artifact at the pixel level.
- **Guided Employee Registration** — A 5-pose guided capture flow (front, left, right, up, blink) collects multiple face angles and averages embeddings for robustness. Duplicate face detection at enrollment prevents the same person registering twice.
- **Attendance Logging** — Each scan records a Time In or Time Out event with automatic status classification: *On Time*, *Late*, *Early Out*, or *Regular Out* — based on configurable work hours and a configurable grace period.
- **Admin Dashboard** — Admins can view real-time present/absent/total counts (each tappable to a filtered employee list), manage employees, manage departments, configure work hours, and browse full attendance reports.
- **Department Filtering** — Employees can be browsed by department; tapping a department from the management screen shows only that department's personnel.
- **Supabase Cloud Sync** — All writes are queued and pushed to Supabase when online. Real-time Postgres change subscriptions keep all connected devices in sync. The app works fully offline; sync catches up automatically on reconnect.
- **Hashed Admin Credentials** — Admin passwords are stored as PBKDF2-SHA256 hashes with random salts. All hashing and verification runs in a background isolate — no UI thread blocking.
- **Login Rate Limiting** — Admin login is protected by a lockout mechanism: 5 failed attempts within 15 minutes triggers a timed lockout. Remaining attempts are shown to the user in real time.
- **Configurable Settings** — Work start/end time, grace period (minutes after start before absences are counted), and device code are all configurable from the admin settings screen.
- **Soft-Delete Data Preservation** — Deleting an employee marks them as deleted rather than erasing them. All their historical attendance records are preserved and visible in reports labeled `[Deleted Employee]`.

---

## Tech Stack Overview

ALAMS runs on open-source, on-device technologies. Biometrics never leave the device as raw images; only embeddings and attendance events are stored or synced.

### UI & Application Layer

**Flutter + Dart** — Single codebase compiled to native Android ARM. Real-time camera processing, ML inference, and UI all run without blocking the main thread thanks to Dart's `async`/`await` model and `compute()` isolates.

**Riverpod** — Compile-safe reactive state management. All database-backed UI state is exposed as `FutureProvider`s that automatically re-render when invalidated after a write.

### Machine Learning & Biometrics

**FaceNet (TFLite)** — Deep CNN that maps a 160×160 face crop to a L2-normalised 128-dimensional float vector. Cosine distance is used for matching. Two-threshold approach: distance < 0.40 AND margin over second-best ≥ 0.08.

**Google ML Kit Face Detection** — Real-time face detection with bounding boxes, 3D Euler angles, eye/smile probabilities, and lip contour landmarks. Powers both liveness challenge evaluation and pose guidance during registration.

**MiniFASNet (NCNN via JNI)** — A passive neural anti-spoofing model running natively via the NCNN inference framework through Android JNI. Scores each frame as real vs. spoof with a confidence threshold of 0.80. Calibrated for varied skin tones.

### Data & Cloud

**SQLite (sqflite)** — Sole local data store. Single `alams.db` file, schema version 7, with incremental migrations.

**Supabase** — Optional cloud sync backend. Writes are queued locally and pushed when connectivity is available. Realtime Postgres subscriptions trigger UI refreshes across devices.

### Summary Table

| Layer | Technology | Version |
|-------|-----------|---------| 
| UI Framework | Flutter + Dart | SDK ^3.10.3 |
| State Management | Riverpod | ^3.3.1 |
| On-Device Database | SQLite (sqflite) | ^2.4.2 |
| Face Recognition Model | FaceNet TFLite | — |
| ML Inference Runtime | tflite_flutter | ^0.12.1 |
| Face Detection & Analysis | Google ML Kit | ^0.13.2 |
| Passive Anti-Spoofing | MiniFASNet (NCNN/JNI) | — |
| Camera Access | camera | ^0.12.0+1 |
| Image Processing | image (Dart) | ^4.8.0 |
| Cloud Sync | Supabase Flutter | — |
| Connectivity Detection | connectivity_plus | — |
| Date/Time Formatting | intl | ^0.20.2 |
| File Path Resolution | path_provider | ^2.1.5 |
| Platform | Android (Kotlin + Gradle) | — |

---

## Repository Structure (Top Level)

```
alams/
├── lib/                          # All Dart source code
│   ├── main.dart                 # Entry point, routing, app bootstrap
│   ├── core/                     # Shared services, models, utilities
│   │   ├── database/             # DatabaseService singleton (SQLite)
│   │   ├── models/               # Employee, Attendance, Department
│   │   ├── providers/            # Riverpod providers (DB, sync refresh)
│   │   ├── services/             # SyncService (Supabase queue + realtime)
│   │   └── utils/                # CryptoUtils (PBKDF2), ImageUtils
│   └── features/                 # Feature modules
│       ├── admin/                # Dashboard, login, dept management, settings
│       ├── attendance/           # Camera screen, action screen, providers
│       ├── face_recognition/     # FaceNet service, NCNN anti-spoof, liveness
│       ├── onboarding/           # First-time admin setup
│       ├── registration/         # Employee registration, employee list
│       └── reports/              # Attendance log reports
├── android/                      # Android platform project
│   └── app/src/main/
│       ├── assets/live/          # MiniFASNet NCNN model files
│       └── cpp/                  # Native C++ JNI anti-spoof bridge
├── assets/models/
│   └── facenet.tflite            # On-device face recognition model
└── pubspec.yaml                  # Dart/Flutter dependencies
```

For full technical detail, see:
- **[SYSTEM.md](./SYSTEM.md)** — Architecture, pipelines, security, design rationale
- **[DATABASE.md](./DATABASE.md)** — Schema, migrations, key queries
- **[CODEBASE.md](./CODEBASE.md)** — File-by-file code reference
- **[ALAMS_DOCUMENTATION.md](./ALAMS_DOCUMENTATION.md)** — Technical manual
