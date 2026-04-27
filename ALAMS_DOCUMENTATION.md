# ALAMS: Automated Logbook Attendance Monitoring System | Technical Manual

ALAMS is a high-performance, offline-first attendance solution built with Flutter. It uses on-device machine learning for biometric identity verification and provides a comprehensive administrative suite for workforce management. Attendance data is optionally synced to Supabase for multi-device support.

---

## Table of Contents
1. [System Overview](#1-system-overview)
2. [Key Features](#2-key-features)
3. [Project Structure](#3-project-structure)
4. [System Architecture](#4-system-architecture)
5. [Technology Stack](#5-technology-stack)
6. [Technical Deep Dive](#6-technical-deep-dive)
7. [Database & Persistence](#7-database--persistence)
8. [Cloud Sync (Supabase)](#8-cloud-sync-supabase)
9. [Operational Workflows](#9-operational-workflows)
10. [Design Philosophy](#10-design-philosophy)

---

## 1. System Overview

ALAMS addresses the need for secure, touchless, and privacy-focused attendance tracking. Unlike cloud-based systems, ALAMS processes all biometrics locally using TensorFlow Lite and a native NCNN neural network, ensuring face images never leave the device. It is designed for kiosk-style deployment with a focused, dark-themed UI.

Three independent security layers must all pass before any attendance record is written:
- **Active liveness challenges** — 3 randomised actions the employee must perform on command
- **Passive neural anti-spoofing** — MiniFASNet NCNN model classifying real skin vs. spoofed artifacts
- **Face recognition** — FaceNet TFLite matching against stored embeddings with a two-threshold guard

---

## 2. Key Features

### Administrator Capabilities
- **Live Metrics Dashboard** — Real-time At Work / Absent / Total Personnel counts, each tappable to a filtered employee list.
- **Personnel Management** — Full CRUD for employees including guided 5-pose face registration and duplicate enrollment detection.
- **Departmental Hierarchy** — Logical grouping of employees; tapping a department shows only that department's personnel.
- **Attendance Reports** — Filterable logs by name, type (IN/OUT), and date. Deleted employee records preserved and labeled.
- **System Settings** — Configurable work start/end times, grace period (minutes after start before absences are counted), watermark toggle, and device code.

### Employee Capabilities
- **Zero-UI Interaction** — Identity is verified by camera; employees do not log in or press buttons to identify themselves.
- **Auto IN/OUT Detection** — System determines the appropriate action from the employee's last attendance record.
- **Post-Scan Action Screen** — Employees confirm their time event and can view their personal attendance history.

---

## 3. Project Structure

The project follows a **Feature-First Architecture**:

```
lib/
├── main.dart                        # Entry point, routing, watermark overlay
├── core/
│   ├── database/database_service.dart   # SQLite singleton, all CRUD + migrations
│   ├── models/                          # Employee, Attendance, Department
│   ├── providers/
│   │   ├── database_provider.dart       # Riverpod DatabaseService provider
│   │   └── sync_refresh_provider.dart   # SyncRefreshNotifier (triggers UI re-fetch)
│   ├── services/sync_service.dart       # Supabase queue, realtime subscriptions
│   └── utils/
│       ├── crypto_utils.dart            # PBKDF2-SHA256 hashing (background isolate)
│       └── image_utils.dart             # Image helpers
└── features/
    ├── admin/
    │   ├── screens/admin_dashboard.dart          # Dashboard with metric cards
    │   ├── screens/admin_login_screen.dart        # Login with rate limiting
    │   ├── screens/department_management_screen.dart
    │   └── screens/settings_screen.dart           # Work hours, grace period, watermark
    ├── attendance/
    │   ├── providers/attendance_provider.dart     # currentlyWorking, absentToday, logs
    │   └── screens/action_screen.dart             # Post-recognition confirm screen
    ├── face_recognition/
    │   ├── services/face_recognition_service.dart # FaceNet TFLite inference + matching
    │   ├── services/liveness_service.dart         # ML Kit challenge state machine
    │   ├── services/ncnn_anti_spoof_service.dart  # NCNN MiniFASNet via JNI
    │   └── screens/camera_screen.dart             # Main scan screen
    ├── onboarding/                                # First-time admin setup
    ├── registration/
    │   ├── screens/employee_list_screen.dart      # Filterable employee list
    │   └── screens/registration_screen.dart       # 5-pose guided enrollment
    └── reports/screens/reports_screen.dart        # Attendance log viewer
```

---

## 4. System Architecture

### State Management (Riverpod)

| Provider | Type | Purpose |
|----------|------|---------|
| `employeesProvider` | `FutureProvider` | All active non-admin employees |
| `currentlyWorkingProvider` | `FutureProvider` | Employees with latest log today = IN |
| `absentTodayProvider` | `FutureProvider` | Employees with no log today (after grace period) |
| `attendanceLogsTodayProvider` | `FutureProvider` | Today's logs with employee names |
| `attendanceLogsWithNamesProvider` | `FutureProvider` | All logs with names (for reports) |
| `syncRefreshCountProvider` | `NotifierProvider<int>` | Incremented by SyncService to trigger all providers to re-fetch |
| `attendanceNotifierProvider` | `NotifierProvider` | Records attendance; invalidates related providers |
| `includeDeletedLogsProvider` | `NotifierProvider<bool>` | Toggle for deleted employee records in reports |

After every write, `ref.invalidate(provider)` forces an immediate re-fetch and UI rebuild. The `syncRefreshCountProvider` is watched by all `FutureProvider`s so that a cloud sync pull also triggers a full UI refresh.

### Routing & Guarding (RootGuardian)

`RootGuardian` is the app's entry gatekeeper:
- Calls `db.hasAdmin()` on launch.
- **No admin found** → forces navigation to `OnboardingScreen`.
- **Admin exists** → directs to `SelectionScreen` (kiosk home).

All named routes use `onGenerateRoute`. Custom transitions (`PageRouteBuilder`) explicitly pass `settings: settings` so that navigation arguments survive the custom transition and are accessible via `ModalRoute.of(context)?.settings.arguments` in the destination screen. This is required for the filtered employee list (At Work, Absent, Department tap) to function correctly.

---

## 5. Technology Stack

| Layer | Technology | Version | Purpose |
|-------|-----------|---------|---------| 
| UI Framework | Flutter + Dart | SDK ^3.10.3 | Cross-platform native UI |
| State Management | Riverpod | ^3.3.1 | Reactive, compile-safe state |
| On-Device Database | SQLite (sqflite) | ^2.4.2 | Local data store (schema v7) |
| Face Recognition | FaceNet TFLite | — | 128-dim facial embedding generation |
| ML Inference | tflite_flutter | ^0.12.1 | TFLite model execution (4 threads) |
| Face Detection | Google ML Kit | ^0.13.2 | Landmarks, euler angles, eye/smile classification |
| Passive Anti-Spoof | MiniFASNet (NCNN/JNI) | — | Native neural real-vs-spoof classifier |
| Camera | camera | ^0.12.0+1 | Front-camera streaming (YUV420) |
| Image Processing | image (Dart) | ^4.8.0 | YUV→RGB, resize to 160×160 |
| Password Hashing | custom crypto_utils | — | PBKDF2-SHA256, 10k iterations, isolate-safe |
| Cloud Sync | supabase_flutter | — | Outbound queue + realtime subscriptions |
| Connectivity | connectivity_plus | — | Network state monitoring |
| Date/Time | intl | ^0.20.2 | Date formatting in UI and reports |

---

## 6. Technical Deep Dive

### Face Recognition Pipeline

```
CameraImage (YUV420)
    → [compute() isolate] YUV→RGB, resize to 160×160
    → Normalize pixels: (value / 127.5) − 1.0 → [−1.0, 1.0]
    → FaceNet TFLite inference → float32[1, 128] embedding
    → L2 normalisation → unit hypersphere
    → [Session token verified — liveness still valid?]
    → [compute() isolate] cosineDistance vs. all stored embeddings
    → Recognised if: bestDist < 0.40 AND (secondDist − bestDist) ≥ 0.08
    → RecognitionResult { label, distance, isRecognized }
```

**Why two thresholds?** The primary threshold (0.40) ensures the match is close. The margin guard (0.08) ensures the match is unambiguous — the best candidate must be clearly better than all others. Without the margin guard, two employees with similar appearances could produce a confident but wrong match.

**Why cosine distance?** FaceNet embeddings cluster by identity in angular space. Cosine distance measures directional similarity independent of magnitude, which is the correct metric for L2-normalised embeddings.

### Liveness Detection Pipeline

```
Per-frame pipeline (LivenessService):
  1. Single-face guard — >1 face detected → reset
  2. Face size guard — too small / too large → reposition prompt
  3. Stability check — 8 stable frames required before challenges begin
  4. 3 challenges randomly selected (Random.secure() CSPRNG):
       BLINK      — both eyes < 0.43 for 4+ consecutive frames
       SMILE      — smilingProbability > 0.72 for 4+ frames
       MOUTH OPEN — lip contour gap / face height > 0.09 for 4+ frames
       TURN LEFT  — headEulerAngleY > 28° for 4+ frames
       TURN RIGHT — headEulerAngleY < −28° for 4+ frames
  5. Passive checks on every challenge frame:
       Staticness   — face area delta < 2px² → photo suspected
       Aspect ratio — bounding box too wide during turn → flat surface suspected
       Eye symmetry — |leftOpen − rightOpen| > 0.30 → unnatural asymmetry
  6. All 3 pass → LivenessState.passed + session token generated
  7. Timeout (20s) or passive fail streak (8) → LivenessState.failed + 8s cooldown
```

### Neural Anti-Spoofing (NCNN MiniFASNet)

A second, independent anti-spoofing layer runs natively via Android JNI:

```
CameraImage (YUV420)
    → Dart: YUV420 → NV21 byte array
    → MethodChannel('com.example.alams/antispoof')
    → C++ JNI: anti_spoof_jni.cpp
    → NCNN engine: MiniFASNet (model_1 + model_2 from Android assets)
    → Returns confidence float [0.0 – 1.0]
    → confidence > 0.80 → REAL | ≤ 0.80 → SPOOF (session flagged)
```

MiniFASNet is trained specifically to detect printed photos, screen-displayed images, and 3D mask attacks by analyzing skin texture and depth cues at the pixel level. The 0.80 threshold is calibrated to reduce false positives for varied skin tones.

### Guided 5-Pose Enrollment

Registration captures 5 distinct poses: **Front, Turn Left, Turn Right, Tilt Up, Blink**. Each pose generates a FaceNet embedding. All 5 are averaged into a single 128-dimensional master embedding. This averaging produces a stored profile that is more robust to pose variation and lighting differences than a single-shot capture.

Before saving, `checkDuplicateEmbedding()` compares the new embedding against all existing faces with a stricter threshold (0.35). If the new face is too similar to an existing employee, enrollment is blocked and the matching employee is identified.

### Auto IN/OUT Detection

```
ActionScreen receives recognized employee
    → db.getLastAttendanceForEmployee(id)
    → lastLog == null OR lastLog.type == 'OUT'  → suggest TIME IN
    → lastLog.type == 'IN'                       → suggest TIME OUT
```

This eliminates the need for employees to select their action, reducing errors during high-traffic periods.

### Attendance Status Classification

Status is computed at write time in `DatabaseService.insertAttendance()`:

| Status | Condition |
|--------|-----------|
| `On Time` | Time IN at or before `work_start` setting |
| `Late` | Time IN after `work_start` setting |
| `Early Out` | Time OUT before `work_end` setting |
| `Regular Out` | Time OUT at or after `work_end` setting |

Status is stored denormalized so that changing work hours in the future does not retroactively alter historical records.

---

## 7. Database & Persistence

**Schema version: 7** — SQLite `alams.db` on the device. See [DATABASE.md](./DATABASE.md) for full table definitions and migration history.

### Tables Summary

| Table | Purpose |
|-------|---------|
| `employees` | All registered persons (employees, admins, soft-deleted) |
| `attendance` | Every Time In / Time Out event |
| `departments` | Admin-managed department reference list |
| `system_settings` | Key-value config (work hours, grace period, watermark, device code, ID offset) |
| `login_attempts` | Brute-force protection audit log (device-local, not synced) |
| `sync_queue` | Outbound Supabase write buffer |

### Migration History (v1 → v7)

| Version | Key Changes |
|---------|-------------|
| v1 | Initial `employees` table (id, name, facial_embedding) |
| v2 | Added age, sex, position, emp_id, is_admin |
| v3 | Added department, username, password; created `departments` table |
| v4 | Added email to employees |
| v5 | Added is_deleted to employees; added status to attendance |
| v6 | Created `system_settings`; seeded work_start, work_end |
| v7 | Added grace_period, watermark_enabled, device_code, id_offset to settings; created `login_attempts`; created `sync_queue` |

### Key Design Decisions

**Soft deletes** — `is_deleted = 1` instead of row removal. Historical attendance logs remain joinable. Reports display `[Deleted Employee]` for deleted person records.

**Embedding stored as TEXT** — Comma-separated 128 floats. Human-readable for debugging, trivially serialized from `List<double>`. ~600 bytes per record.

**Status stored at write time** — Computed from `work_start`/`work_end` settings at the moment the record is written. Future settings changes do not alter historical records.

**`login_attempts` not synced** — Device-local security state. Syncing across devices would create race conditions in lockout counting.

---

## 8. Cloud Sync (Supabase)

### Architecture

Every write in `DatabaseService` calls `SyncService.instance.enqueue()`, which inserts a record into `sync_queue`. When connectivity is available, `SyncService.syncNow()` processes the queue in order and pushes records to Supabase.

Inbound changes from other devices are received via **Supabase Realtime** WebSocket subscriptions on all four synced tables (`employees`, `attendance`, `departments`, `system_settings`). On any change event, `pullFromSupabase()` fetches the latest data, updates the local SQLite database, and calls `SyncRefreshNotifier.refresh()` to trigger a full UI re-render.

A `Timer.periodic` fires every 30 seconds as a fallback pull for any realtime events missed during connectivity gaps.

### Offline Behavior

The app operates with full functionality when offline. All operations write to SQLite. The `sync_queue` accumulates outbound changes. When connectivity is restored (detected via `connectivity_plus`), `syncNow()` and `pullFromSupabase()` are both triggered immediately, catching up bidirectionally.

---

## 9. Operational Workflows

### Initial Setup

1. Open app → `RootGuardian` detects no admin → `OnboardingScreen`.
2. Admin fills profile form and completes 5-pose face capture.
3. Saved with `is_admin = 1`. App proceeds to kiosk home screen.
4. Admin logs in to dashboard, creates departments, and registers employees.

### Daily Attendance

1. Employee approaches kiosk → taps "Log Attendance".
2. Camera activates. ML Kit detects face. Stability check (8 frames).
3. 3 random liveness challenges issued. NCNN anti-spoof runs concurrently.
4. All checks pass → FaceNet matches employee → Action Screen.
5. Auto-detected action (IN or OUT) shown. Employee confirms.
6. Attendance record written with timestamp and status. Synced to cloud.
7. App returns to kiosk home screen.

### Admin Login Security

- Password hashed with PBKDF2-SHA256 (10,000 iterations, random 16-byte salt).
- All hashing/verification in background `compute()` isolate.
- 5 failed attempts in 15 minutes → lockout with countdown timer.
- Remaining attempts shown after each failure.
- Constant-time hash comparison (prevents timing attacks).
- Plaintext passwords from legacy accounts auto-migrated on first login.

---

## 10. Design Philosophy

**Privacy First** — Raw face images are never persisted anywhere. Only 128-number mathematical embeddings are stored. An embedding cannot be reverse-engineered into a recognizable photograph.

**Offline First** — Every feature works without network access. Cloud sync is an enhancement layer, not a dependency. The device is always the source of truth.

**Layered Security** — No single anti-spoofing technique is bulletproof. Active challenges, passive heuristics, and a neural network operate independently. Defeating all three simultaneously in real conditions is impractical.

**Kiosk Orientation** — Portrait-locked, system UI hidden, dark theme. Designed to run unattended on a dedicated mounted device.

**Data Integrity** — Soft deletes, write-time status computation, and a local sync queue ensure that no data is lost or retroactively altered regardless of network conditions or admin actions.

---

*ALAMS Technical Manual | Version 2.0*
*Last updated: April 2026*
