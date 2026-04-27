# SYSTEM.md — ALAMS System Design & Architecture

## Table of Contents

1. [Problem Statement](#1-problem-statement)
2. [System Goals & Design Philosophy](#2-system-goals--design-philosophy)
3. [Architecture Overview](#3-architecture-overview)
4. [User Roles](#4-user-roles)
5. [User Flows](#5-user-flows)
6. [Feature Breakdown](#6-feature-breakdown)
7. [Face Recognition Pipeline](#7-face-recognition-pipeline)
8. [Liveness Detection Pipeline](#8-liveness-detection-pipeline)
9. [Neural Anti-Spoofing (NCNN MiniFASNet)](#9-neural-anti-spoofing-ncnn-minifasnet)
10. [Cloud Sync Architecture (Supabase)](#10-cloud-sync-architecture-supabase)
11. [State Management Architecture](#11-state-management-architecture)
12. [Tech Stack & Dependencies](#12-tech-stack--dependencies)
13. [Security Considerations](#13-security-considerations)

---

## 1. Problem Statement

Traditional attendance systems — biometric fingerprint scanners, PIN pads, RFID cards — are vulnerable to **buddy punching**: a practice where an employee marks a coworker as present when they are actually absent.

The root cause is that most systems authenticate *credentials* (a card, a PIN, a fingerprint template on an insecure reader) rather than verifying a *living person* in real time. A photograph held up to a camera, or a rubber fingerprint replica, can defeat many consumer-grade biometric systems.

ALAMS addresses this by combining:

- **Face recognition** — Who is this person?
- **Active liveness detection** — Are they physically present and performing actions on command?
- **Passive neural anti-spoofing** — Is this a real human face or a spoofed artifact?

All three checks must pass independently before any attendance record is written.

---

## 2. System Goals & Design Philosophy

**Primary goal:** Prevent fraudulent attendance entries by requiring a verified living face at every check-in and check-out event.

**Secondary goals:**
- Provide accurate, timestamped attendance records with automatic status classification.
- Give administrators actionable dashboards, filtered lists, and full reports.
- Operate entirely offline; no reliance on external APIs for core functionality.
- Support optional cloud sync for multi-device deployments.
- Preserve data integrity even when employees leave (soft deletes).

**Design philosophy — Privacy First:** Facial embeddings (128-dimensional float vectors) are stored in the local SQLite database. Raw face images are never persisted at any point. Even if the device is physically compromised, a facial embedding cannot be trivially reverse-engineered into a photograph of the employee.

**Design philosophy — Kiosk Orientation:** The app forces portrait-only orientation at launch and hides system UI overlays for a clean kiosk feel. It is designed to run on a dedicated Android device mounted at an entrance.

**Design philosophy — Offline First, Sync Later:** Every feature — registration, scanning, reports, admin controls — works fully without network access. Cloud sync (Supabase) is a layer on top that pushes local changes and subscribes to remote changes, providing multi-device consistency without creating a network dependency.

---

## 3. Architecture Overview

ALAMS follows a **feature-first layered architecture** within a monorepo Flutter project.

```
┌─────────────────────────────────────────────────────────────┐
│                        PRESENTATION                          │
│   Screens (StatefulWidget / ConsumerWidget)                  │
│   Feature-scoped Providers (Riverpod FutureProvider)         │
└─────────────────────────────────┬───────────────────────────┘
                                  │
┌─────────────────────────────────▼───────────────────────────┐
│                         DOMAIN / SERVICES                     │
│   FaceRecognitionService  (TFLite inference, cosine match)   │
│   LivenessService         (ML Kit challenges, passive checks) │
│   NcnnAntiSpoofService    (Native NCNN MiniFASNet, JNI)      │
│   SyncService             (Supabase queue + realtime)        │
│   DatabaseService         (singleton, SQLite CRUD)           │
└─────────────────────────────────┬───────────────────────────┘
                                  │
┌─────────────────────────────────▼───────────────────────────┐
│                           DATA LAYER                          │
│   SQLite (sqflite) — alams.db (schema v7)                    │
│   Tables: employees, attendance, departments,                 │
│           system_settings, login_attempts, sync_queue        │
│   Models: Employee, Attendance, Department                   │
│   Cloud mirror: Supabase (optional)                          │
└─────────────────────────────────────────────────────────────┘
```

**No repository layer** is used between the service and the database — `DatabaseService` is a singleton that acts as both the repository and the data access object.

**Routing** is name-based via `onGenerateRoute` in `MaterialApp`. Arguments are passed as typed maps or model instances through `settings.arguments`. `PageRouteBuilder` routes must explicitly pass `settings:` to preserve arguments through the custom transition.

---

## 4. User Roles

### Employee (Anonymous Kiosk User)

Employees interact with the system purely through the camera. They do not log in. The system identifies *them* — they do not identify themselves.

### Administrator

Admins log in via username/password on the `AdminLoginScreen`. Admin status is stored as `is_admin = 1` on the `employees` table. The first registration in the system is automatically granted admin rights, enforced by `RootGuardian`.

Admins can:
- Register new employees (guided 5-pose facial capture)
- Edit / soft-delete employees
- View employees filtered by status (At Work, Absent) or department
- View and manage departments
- View full attendance logs and reports (filterable by name, type, date)
- View individual employee attendance history
- Configure work start/end hours, grace period, and watermark toggle

---

## 5. User Flows

### 5.1 First-Time Setup

```
App Launch
    ↓
RootGuardian checks: hasAdmin() in DB?
    ↓ NO
OnboardingScreen
    → "Setup System Admin" button
    ↓
RegistrationScreen (isFirstAdmin = true)
    → Fill profile form
    → Guided 5-pose face capture
    → Employee saved with is_admin = 1
    ↓
SelectionScreen (kiosk home)
```

### 5.2 Employee Attendance (Normal Flow)

```
SelectionScreen
    → "Log Attendance" tap
    ↓
CameraScreen (mode: SCAN)
    → Front camera activates
    → Frame stream begins (throttled to 400ms intervals)
    ↓
Per-Frame Pipeline (runs in parallel):
    ── THREAD A: LivenessService ──────────────────────────────
    1. Google ML Kit detects face in frame
    2. Single-face guard — multiple faces → reset
    3. Face size guard — too small/large → prompt to reposition
    4. Stability check (8 stable frames required)
    5. 3 random challenges issued (CSPRNG-shuffled pool)
       (blink / smile / mouth open / turn left / turn right)
    6. Passive spoof checks every challenge frame
       (staticness, aspect ratio, eye symmetry)
    7. All 3 challenges pass → LivenessState.passed + session token
    8. Timeout (20s) or passive fail streak (8) → LivenessState.failed
       → 8s cooldown enforced

    ── THREAD B: NcnnAntiSpoofService ────────────────────────
    1. Each frame converted YUV420 → NV21 byte array
    2. Sent to native NCNN engine via MethodChannel JNI
    3. MiniFASNet scores frame: confidence float [0.0 – 1.0]
    4. confidence < 0.80 → spoof flag incremented
    5. Spoof flags accumulate → hard fail on repeated detection
    ──────────────────────────────────────────────────────────

    ↓ (both pass)
    FaceRecognitionService (session token verified):
    a. YUV420 → RGB conversion (compute isolate)
    b. Resize to 160×160, L2-normalise embedding
    c. FaceNet inference → 128-dim embedding vector
    d. Two-threshold cosine distance match:
       primary threshold 0.40 + margin guard 0.08
    e. Match found → RecognitionResult
    ↓
ActionScreen (employee identified)
    → Auto-detects TIME IN or TIME OUT based on last log
    → Employee confirms (or changes action)
    → Attendance record written with status classification
    → SyncService.enqueue() called for cloud push
    ↓
Return to CameraScreen (ready for next employee)
```

### 5.3 Admin Login Flow

```
SelectionScreen
    → "Administrator Login" tap
    ↓
AdminLoginScreen
    → username + password submitted
    → validateAdmin():
        1. Check login_attempts table — locked out? → show lockout + wait time
        2. Fetch admin row by username only
        3. PBKDF2-SHA256 verification in background isolate
        4. Record attempt in login_attempts (success or failure)
        5. 5 failures in 15 min → 15-minute lockout enforced
    ↓ (success)
AdminDashboard
    → At Work count (tap → filtered employee list)
    → Absent count (tap → filtered employee list)
    → Total Personnel (tap → full employee list)
    → Quick Actions: Register Employee, Edit Admin Profile
    → Menu: Employees, Reports, Departments, Settings
```

### 5.4 Employee Registration (Admin-Initiated)

```
AdminDashboard → Register Employee
    ↓
RegistrationScreen
    Step 1: Enter Profile
        Name, Employee ID (auto-generated or custom), Age, Sex,
        Position, Department (dropdown from departments table), Email
    Step 2: Guided Face Capture
        Pose 1: Front (look straight)
        Pose 2: Turn Left
        Pose 3: Turn Right
        Pose 4: Tilt Up
        Pose 5: Blink
        → Each pose captures frame, generates FaceNet embedding
        → Duplicate check against all existing faces (threshold 0.35)
        → All 5 embeddings averaged → single master embedding stored
    Step 3: Save to DB
        → SyncService.enqueue() → Supabase push when online
    ↓
EmployeeListScreen (providers invalidated → auto-refresh)
```

### 5.5 Dashboard Filtered Navigation

```
AdminDashboard
    → Tap "At Work" card
        → Navigator.pushNamed('/employee_list',
            arguments: {'status': 'working'})
        → EmployeeListScreen reads arguments via
            ModalRoute.of(context)?.settings.arguments
        → Filters employee list to only those with latest log = IN today

    → Tap "Absent" card
        → arguments: {'status': 'absent'}
        → Filters to employees with no log today (after grace period)

    → Tap department in DepartmentManagementScreen
        → arguments: {'department': dept.name}
        → Filters to employees in that department only

    [Note: PageRouteBuilder for /employee_list must pass
     settings: settings to preserve arguments through the
     custom slide transition. This is the fix applied in main.dart.]
```

---

## 6. Feature Breakdown

### 6.1 Kiosk Home Screen (SelectionScreen)

The default entry point after setup. Displays the current date and two action buttons. No employee credentials are required here — identity is established by the camera.

### 6.2 Admin Dashboard

The dashboard (`AdminDashboard`) provides three real-time metrics queried from the database:

- **At Work** — Employees whose latest attendance log today is `IN`
- **Absent** — Employees with zero attendance logs today, after the grace period has elapsed
- **Total Personnel** — Active (non-deleted, non-admin) employees

Each metric card is tappable and navigates to a **filtered** `EmployeeListScreen`. Arguments are passed through `Navigator.pushNamed` and read from `ModalRoute.of(context)?.settings.arguments`.

The filtering is performed client-side in `EmployeeListScreen` by combining `employeesProvider` (all employees) with `attendanceLogsTodayProvider` (today's logs) and computing working/absent sets locally.

### 6.3 Employee List Screen (EmployeeListScreen)

A unified screen for browsing employees. Supports:
- **Real-time search** by name
- **Status filter** (`working` or `absent`) passed via navigation arguments
- **Department filter** passed via navigation arguments
- **Clear filters** button when any filter is active
- **Pull to refresh** (invalidates `employeesProvider` and `attendanceLogsTodayProvider`)
- **Delete** employee (with confirmation dialog; invalidates all affected providers immediately)

### 6.4 Reports Screen

`ReportsScreen` shows all attendance logs joined with employee names. Supports:
- Search by employee name
- Filter by type (All, IN, OUT)
- Filter by date (date picker, defaults to today)
- Logs from deleted employees retained and labeled `[Deleted Employee]`

### 6.5 Department Management

`DepartmentManagementScreen` supports full CRUD on departments. Tapping a department navigates to `EmployeeListScreen` with a department filter argument. Deleting a department does not cascade-delete employees assigned to it.

### 6.6 Employee Registration with Multi-Pose Embedding

5-pose guided capture with real-time ML Kit feedback. Each pose generates a FaceNet embedding. All 5 are averaged into a single 128-dimensional master embedding. The duplicate guard checks the new embedding against all existing faces (threshold 0.35) before saving.

### 6.7 Soft Delete

Setting `is_deleted = 1` rather than removing the row. All active queries filter `WHERE is_deleted = 0`. Reports use `LEFT JOIN` and include a `is_deleted` column so the UI can display `[Deleted Employee]` for historical records.

### 6.8 PBKDF2 Password Hashing

Passwords stored as `pbkdf2$10000$<base64salt>$<base64hash>`. All crypto runs in `compute()` isolates. Existing plaintext passwords auto-migrated on first login via `Future.microtask()`.

### 6.9 Admin Login Rate Limiting

Every attempt recorded in `login_attempts` with timestamp and success flag. Five failures in 15 minutes → lockout. Remaining attempts displayed. Lockout timer shown. Constant-time comparison used to prevent timing attacks.

### 6.10 Duplicate Face Enrollment Guard

`checkDuplicateEmbedding()` called before saving any new registration. Uses threshold 0.35 (stricter than live recognition at 0.40). Returns the matching employee name if a duplicate is found, allowing the admin to identify the conflict.

### 6.11 Configurable System Settings

| Setting Key | Default | Description |
|-------------|---------|-------------|
| `work_start` | `08:00` | Work start time for On Time / Late classification |
| `work_end` | `17:00` | Work end time for Early Out / Regular Out classification |
| `grace_period` | `60` | Minutes after `work_start` before absent count begins |
| `watermark_enabled` | `1` | Toggle device-code watermark overlay |
| `device_code` | Random 4-char | Human-readable kiosk identifier |
| `id_offset` | Random int | Offset applied to auto-generated employee IDs for uniqueness across devices |


---

## 7. Face Recognition Pipeline

```
CameraImage (YUV420)
        ↓
[FaceRecognitionService.preprocessCameraImage()]  ← runs in compute() isolate
  YUV → RGB conversion (per-pixel YUV-to-RGB formula)
  img.copyResize() → 160×160 pixels
        ↓
[FaceRecognitionService.generateEmbedding()]
  Pixel normalization: (value / 127.5) - 1.0 → range [-1.0, 1.0]
  TFLite inference: FaceNet model (4 threads)
  Output: float32[1, 128] embedding vector
  L2 normalisation applied → unit hypersphere projection
        ↓
[Session token verified — liveness session still valid?]
        ↓ YES
[FaceRecognitionService.findBestMatch()]  ← runs in compute() isolate
  For each stored employee embedding:
    cosineDistance(liveEmbedding, storedEmbedding)
  Track best AND second-best distances
  Recognised only if:
    bestDist < 0.40   (primary threshold)
    AND (secondDist - bestDist) ≥ 0.08  (margin guard)
        ↓
RecognitionResult { label, distance, isRecognized }
```

**Why cosine distance?** Invariant to embedding vector magnitude; measures directional similarity. FaceNet embeddings cluster by identity in angular space.

**Why L2 normalisation?** Projects all embeddings onto the unit hypersphere, making cosine distance equal to Euclidean distance and ensuring consistent behaviour regardless of inference output magnitude variation.

**Why the margin guard?** Prevents ambiguous boundary matches — both the best match must be close *and* clearly better than all alternatives.

**Why 0.40 primary threshold?** Tighter than earlier versions (was 0.45). Reduces false positives. Combined with L2 normalisation and margin guard, precision is maintained without meaningfully increasing false rejections.

**Frame throttling:** Processed at most once every 400ms to balance responsiveness with performance on lower-end devices.

---

## 8. Liveness Detection Pipeline

```
Input: raw InputImage from camera stream
        ↓
[Single-face guard]
  faces.length > 1 → reset to waiting
        ↓
[Face size guard]
  face area / frame area < 4% → "move closer"
  face area / frame area > 80% → suspected macro-spoof
        ↓
FaceDetector (ML Kit, fast mode)
  enableClassification: true  (eye open, smiling probabilities)
  enableLandmarks: true
  enableContours: true        (lip geometry for mouth-open detection)
  enableTracking: true
        ↓
LivenessService.processFrame()

  State Machine:
  ┌─────────┐   face appears   ┌──────────────┐
  │ waiting │─────────────────→│ lookStraight │
  └─────────┘                  └──────┬───────┘
                             8 stable frames
                                      ↓
                         ┌────────────────────────┐
                         │   performingChallenge   │
                         │  (3 from CSPRNG pool)   │
                         │  + passive checks every │
                         │    frame                │
                         └────────────┬───────────┘
                       all 3 pass ↓       timeout/passive fail streak ↓
                    ┌───────────┐              ┌──────────┐
                    │  passed   │              │  failed  │
                    └───────────┘              └──────────┘
                    session token              8s cooldown
                    generated               before retry

  Challenge pool (3 randomly selected via Random.secure() per session):
  ├─ BLINK      — BOTH eyes < 0.43 probability for 4+ consecutive frames
  ├─ MOUTH OPEN — lip contour gap / face height > 0.09 for 4+ frames
  ├─ TURN LEFT  — headEulerAngleY > 28° for 4+ frames
  ├─ TURN RIGHT — headEulerAngleY < -28° for 4+ frames
  └─ SMILE      — smilingProbability > 0.72 for 4+ frames

  Passive checks (run every challenge frame, fail streak → hard fail at 8):
  ├─ Staticness:      face area delta < 2px² → photo/frozen frame suspected
  ├─ Aspect ratio:    bounding box too wide during head turn → flat surface suspected
  └─ Eye symmetry:    |leftOpen - rightOpen| > 0.30 → unnatural asymmetry suspected
```

**Why 3 challenges (up from 2)?** Each additional challenge exponentially increases difficulty for a pre-recorded spoof.

**Why `Random.secure()`?** OS cryptographically secure PRNG. Challenge order cannot be predicted from any prior session.

**Why a session token?** 16-character random token generated at challenge start and captured at pass-time. Verified before recognition runs. Protects against race conditions between liveness pass and recognition.

**Why 20-second timeout?** Prevents indefinite replay attacks.

**Why hard-fail with 8s cooldown?** Makes automated video-replay scanning slower by enforcing a mandatory wait after passive fail streak.

---

## 9. Neural Anti-Spoofing (NCNN MiniFASNet)

A second, independent anti-spoofing mechanism runs at the native C++ level via the NCNN inference framework.

```
CameraImage (YUV420)
        ↓
NcnnAntiSpoofService.detectSpoof()
  YUV420 → NV21 byte array (Dart)
  Face bounding box coordinates extracted from ML Kit result
  Coordinates clamped and validated
        ↓
MethodChannel('com.example.alams/antispoof')
  → Android JNI: anti_spoof_jni.cpp
  → NCNN engine: MiniFASNet (model_1 + model_2)
  → Inference on face crop
  → Returns confidence float [0.0 – 1.0]
        ↓
  confidence > 0.80 → isReal = true
  confidence ≤ 0.80 → isReal = false (SPOOF)
```

**MiniFASNet** is a lightweight binary classification model trained to distinguish real skin texture from spoofed artifacts (printed photos, screen surfaces). Two NCNN model files (`model_1.bin/.param` and `model_2.bin/.param`) are bundled as Android assets.

**Why 0.80 threshold?** Calibrated empirically to reduce false positives for varied skin tones while maintaining strong rejection of obvious spoofs. Lower thresholds produced false rejections for darker skin tones; higher thresholds allowed some screen-held images to pass.

**Why native NCNN instead of TFLite?** MiniFASNet's reference implementation uses NCNN. Running it via JNI in its native framework avoids conversion artifacts and maintains accuracy parity with the reference. The NCNN C++ runtime is also lower-latency than the TFLite runtime for this model size.

**Interaction with LivenessService:** Both run concurrently on every camera frame. NCNN anti-spoof runs during the liveness challenge phase. A spoof detection does not need to happen simultaneously with a liveness failure — either is sufficient to reject the session.

---

## 10. Cloud Sync Architecture (Supabase)

### 10.1 Architecture

```
┌──────────────────────────────────────────────────────┐
│                  Android Device (SQLite)              │
│                                                      │
│  DatabaseService ──write──→ sync_queue table         │
│                                  │                   │
│              SyncService.enqueue()                   │
│                     │                                │
│         (connectivity restored)                      │
│                     │                                │
│              SyncService.syncNow()                   │
│                     ↓                                │
└──────────────────────────────────────────────────────┘
                       │  HTTPS
                       ↓
┌──────────────────────────────────────────────────────┐
│                    Supabase                          │
│  Tables: employees, attendance, departments,         │
│          system_settings                             │
│                                                      │
│  Realtime channels (PostgresChangeEvent.all)         │
│  → employees, attendance, departments, system_settings│
└──────────────────────────────────────────────────────┘
                       │  WebSocket (realtime)
                       ↓
┌──────────────────────────────────────────────────────┐
│             Other Connected Devices                  │
│  pullFromSupabase() → update local SQLite            │
│  SyncRefreshNotifier.refresh() → UI providers refetch│
└──────────────────────────────────────────────────────┘
```

### 10.2 Outbound Sync (Device → Supabase)

Every write in `DatabaseService` calls `SyncService.instance.enqueue()` with:
- `tableName` — which table was affected
- `operation` — `INSERT`, `UPDATE`, or `DELETE`
- `recordId` — the local SQLite row ID
- `payload` — the full record as JSON

These are stored in `sync_queue`. `SyncService.syncNow()` processes the queue in order when connectivity is available. Processed entries are deleted from the queue.

### 10.3 Inbound Sync (Supabase → Device)

`SyncService._subscribeRealtime()` opens one Supabase Realtime channel per table (`employees`, `attendance`, `departments`, `system_settings`). On any Postgres change event, `pullFromSupabase()` is called to fetch the latest data and update the local SQLite database.

After a pull, `SyncRefreshNotifier.refresh()` increments `syncRefreshCountProvider`, which all `FutureProvider`s watch. This triggers a full UI refresh across all screens.

### 10.4 Periodic Sync

A `Timer.periodic` fires every 30 seconds and calls `pullFromSupabase()` as a fallback for cases where realtime events may have been missed (e.g., after a connectivity gap).

### 10.5 Connectivity Monitoring

`connectivity_plus` monitors network state. On `ConnectivityResult != none`: `syncNow()` (push queue) and `pullFromSupabase()` (pull latest) are both triggered immediately.

---

## 11. State Management Architecture

ALAMS uses **Riverpod 3** as its state management solution.

| Provider | Type | Purpose |
|----------|------|---------|
| `employeesProvider` | `FutureProvider` | List of all active (non-deleted, non-admin) employees |
| `attendanceLogsProvider` | `FutureProvider` | All attendance logs |
| `attendanceLogsWithNamesProvider` | `FutureProvider` | Logs joined with employee names |
| `attendanceLogsTodayProvider` | `FutureProvider` | Today's logs with employee names |
| `currentlyWorkingProvider` | `FutureProvider` | Employees currently checked in (latest log today = IN) |
| `absentTodayProvider` | `FutureProvider` | Employees absent today (no log after grace period) |
| `syncRefreshCountProvider` | `NotifierProvider<int>` | Incremented by SyncService to trigger re-fetch across all providers |
| `faceRecognitionProvider` | `AsyncNotifierProvider` | FR model load state |
| `includeDeletedLogsProvider` | `NotifierProvider<bool>` | Toggle for showing deleted employee logs in reports |
| `attendanceNotifierProvider` | `NotifierProvider` | Handles recording attendance and invalidating related providers |

All `FutureProvider`s watch `syncRefreshCountProvider` via `ref.watch(syncRefreshCountProvider)`. This means any call to `SyncRefreshNotifier.refresh()` (from SyncService after a cloud pull) causes all providers to re-run their database queries.

After local writes, `ref.invalidate(provider)` is used directly for immediate UI refresh without waiting for the sync cycle.

---

## 12. Tech Stack & Dependencies

| Layer | Technology | Version | Purpose |
|-------|-----------|---------|---------| 
| **UI Framework** | Flutter + Dart | SDK ^3.10.3 | Cross-platform native UI, app lifecycle |
| **State Management** | Riverpod | ^3.3.1 | Reactive, compile-safe state across screens |
| **On-Device Database** | SQLite (sqflite) | ^2.4.2 | Persistent local data store (schema v7) |
| **Face Recognition Model** | FaceNet TFLite | — | L2-normalised 128-dim facial embedding generation |
| **ML Inference Runtime** | tflite_flutter | ^0.12.1 | On-device TFLite model execution |
| **Face Detection & Analysis** | Google ML Kit | ^0.13.2 | Face detection, landmarks, euler angles, eye/smile classification |
| **Passive Anti-Spoofing** | MiniFASNet (NCNN/JNI) | — | Native neural network for real vs. spoof classification |
| **Camera Access** | camera | ^0.12.0+1 | Front-camera streaming (YUV420) |
| **Image Processing** | image (Dart) | ^4.8.0 | YUV→RGB conversion, resize to 160×160 |
| **Password Hashing** | custom crypto_utils.dart | — | Pure-Dart PBKDF2-SHA256, 10k iterations, isolate-safe |
| **Cloud Sync** | supabase_flutter | — | Supabase client, realtime subscriptions, REST writes |
| **Connectivity** | connectivity_plus | — | Network state monitoring for sync triggers |
| **Date/Time Formatting** | intl | ^0.20.2 | Locale-aware date display in UI and reports |
| **File Path Resolution** | path_provider | ^2.1.5 | Platform-safe DB file path |
| **Path Utilities** | path | ^1.9.1 | File path joining |
| **Platform** | Android (Kotlin + C++) | — | Host platform, Camera2 API, ML Kit native, NCNN JNI |

---

## 13. Security Considerations

### 13.1 Threat Model & Mitigations

| Threat | Mitigation |
|--------|-----------| 
| Buddy punching (human proxy) | Face recognition requires biometric match |
| Photo spoof attack | 3 randomised liveness challenges + NCNN passive neural spoof detection |
| Video replay attack | CSPRNG challenge selection (order unknown); session token; 20s timeout; NCNN skin/depth analysis |
| Pre-recorded all-challenges video | Only 3 of 5 challenges selected per session in random order — must predict exact combination |
| Multi-face injection | Single-face guard resets session on >1 detected face |
| Flat-surface / screen spoof | Aspect ratio check during head turns; NCNN screen artifact detection |
| Frozen frame / static image | Passive face area delta check (< 2px² → fail streak) |
| Brute-force liveness | Hard-fail state + 8s cooldown after 8 passive failures |
| Admin password compromise | PBKDF2-SHA256, 10k iterations, 16-byte random salt per account |
| Brute-force admin login | Lockout after 5 failures in 15 minutes; remaining attempts shown |
| Timing-based password inference | Constant-time hash comparison |
| User enumeration via login | Failed attempts recorded even for unknown usernames |
| Duplicate identity enrollment | `checkDuplicateEmbedding()` at registration with 0.35 threshold |
| Ambiguous face match | Two-threshold matching: primary 0.40 + margin guard 0.08 |
| Session token replay (race condition) | Liveness session token verified before recognition is consumed |
| SQL injection | All queries use parameterised placeholders |
| FK integrity violation | `PRAGMA foreign_keys = ON` on every DB connection |
| Data exfiltration via device theft | Embeddings only (no raw images stored); PBKDF2-hashed credentials |
| Employee record tampering | Soft deletes preserve full audit trail |
| Stale count after employee delete | `ref.invalidate()` called on all affected providers immediately after delete |
| Filter bypass on navigation | `settings:` explicitly passed to `PageRouteBuilder` so arguments survive custom transitions |

### 13.2 PBKDF2 Iteration Count Rationale

10,000 iterations is a deliberate trade-off for mobile kiosk hardware. 100,000 iterations takes 800ms–1,200ms on a mid-range Android CPU; 10,000 iterations takes 80–120ms, imperceptible when run in a `compute()` isolate. A 16-byte random salt ensures rainbow tables are useless regardless of iteration count. An attacker needs physical device access to even read the SQLite database, at which point 10,000 iterations still makes dictionary attacks computationally expensive.

### 13.3 Off-Thread Crypto

All cryptographic operations use `compute()`:
- `hashPassword()` — admin registration and password change
- `verifyPassword()` — every login attempt
- `_migratePasswordsToHashed()` — once via `Future.microtask()` after DB open, off critical path
