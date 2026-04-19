# ALAMS — Automated Logbook Attendance Monitoring System

## What Is This?

**ALAMS** is a mobile attendance monitoring application built with Flutter for Android. It replaces traditional punch cards and PIN-based systems with a fully automated, camera-driven workflow that verifies employee identity through real-time **face recognition** and **liveness detection** before recording any attendance event.

All processing — face detection, embedding generation, matching, liveness checks, and data storage — happens **entirely on-device**. No internet connection or cloud service is required.

---

## Quick Feature Summary

- **Face Recognition** — Employees are identified using a FaceNet TFLite model that generates L2-normalised 128-dimensional facial embeddings. Recognition uses a two-threshold cosine distance match (primary threshold + margin guard) against stored embeddings.
- **Anti-Spoofing Liveness Detection** — Before recognition is accepted, employees must pass 3 randomised challenges (blink, smile, open mouth, turn left/right) drawn from a cryptographically shuffled pool, confirmed by multi-frame sustained action checks and passive spoof heuristics. A hard-fail state with cooldown is enforced on suspected spoofing.
- **Attendance Logging** — Each scan records a Time In or Time Out event with automatic status classification: *On Time*, *Late*, *Early Out*, or *Regular Out* — based on configurable work hours.
- **Admin Dashboard** — Admins can view real-time present/absent counts, manage employees, manage departments, configure work hours, and browse full attendance reports.
- **Guided Employee Registration** — A 5-pose guided capture flow (front, left, right, up, blink) collects multiple face angles and averages embeddings for robustness. Duplicate face detection at enrollment prevents the same person registering twice.
- **Hashed Admin Credentials** — Admin passwords are stored as PBKDF2-SHA256 hashes with random salts. All hashing and verification runs in a background isolate — no UI thread blocking.
- **Login Rate Limiting** — Admin login is protected by a lockout mechanism: 5 failed attempts within 15 minutes triggers a timed lockout. Remaining attempts are shown to the user in real time.
- **Fully Offline** — SQLite (via sqflite) is the sole data store. Zero external API calls are made during normal operation.

---

## Tech Stack Overview

ALAMS is built entirely on open-source, on-device technologies. No cloud services, no external APIs — everything runs on the Android device.

### UI & Application Layer

**Flutter + Dart** is the core framework. Flutter compiles to native Android ARM code, giving the app near-native performance for real-time camera processing. A single Dart codebase handles all UI, business logic, and ML inference. Dart's `async`/`await` model keeps the camera stream, database queries, and TFLite inference non-blocking.

**Riverpod** handles state management. It provides compile-safe, context-free reactive providers. All database-backed UI state (employee lists, attendance logs, dashboard counts) is exposed as `FutureProvider`s that automatically re-render when invalidated after a write operation.

### Machine Learning & Biometrics

**FaceNet (TFLite)** is the face recognition model. It is a deep convolutional neural network that maps a 160×160 face image to a L2-normalised 128-dimensional float vector (embedding). Employees' faces are recognised by measuring the cosine distance between a live embedding and stored embeddings. A two-threshold approach is used: the distance must be below 0.40, and the gap between the best and second-best match must be at least 0.08 — preventing ambiguous boundary matches from producing false positives.

**Google ML Kit Face Detection** handles real-time face detection, landmark extraction, and facial attribute classification (eye open probability, smiling probability, head euler angles). It powers both the liveness challenge evaluation and face guidance during registration.

### Data & Storage

**SQLite via `sqflite`** is the sole data store. A single `alams.db` file on the device holds all employees, attendance records, departments, and system settings. The schema is versioned (currently v6) with incremental migrations.

### Summary Table

| Layer | Technology | Version |
|-------|-----------|---------|
| UI Framework | Flutter + Dart | SDK ^3.10.3 |
| State Management | Riverpod | ^3.3.1 |
| On-Device Database | SQLite (sqflite) | ^2.4.2 |
| Face Recognition Model | FaceNet TFLite | — |
| ML Inference Runtime | tflite_flutter | ^0.12.1 |
| Face Detection & Analysis | Google ML Kit | ^0.13.2 |
| Camera Access | camera | ^0.12.0+1 |
| Image Processing | image (Dart) | ^4.8.0 |
| Date/Time Formatting | intl | ^0.20.2 |
| File Path Resolution | path_provider | ^2.1.5 |
| Platform | Android (Kotlin + Gradle) | — |

For full detail on each technology — including design rationale and configuration specifics — see **[SYSTEM.md § 10 Tech Stack & Dependencies](./SYSTEM.md)**.

---

## Repository Structure (Top Level)

```
alams/
├── lib/                    # All Dart source code
│   ├── main.dart           # Entry point, routing, app bootstrap
│   ├── core/               # Shared services, models, utilities
│   └── features/           # Feature modules (attendance, admin, etc.)
├── assets/
│   └── models/
│       └── facenet.tflite  # On-device face recognition model
├── android/                # Android platform project
├── pubspec.yaml            # Dart/Flutter dependencies
└── docs/                   # This documentation
```