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
9. [State Management Architecture](#9-state-management-architecture)
10. [Tech Stack & Dependencies](#10-tech-stack--dependencies)
11. [Security Considerations](#11-security-considerations)

---

## 1. Problem Statement

Traditional attendance systems — biometric fingerprint scanners, PIN pads, RFID cards — are vulnerable to **buddy punching**: a practice where an employee marks a coworker as present when they are actually absent. Research (The New Indian Express, 2024) documents how this lack of anti-spoofing measures results in substantial financial losses for organizations.

The root cause is that most systems authenticate *credentials* (a card, a PIN, a fingerprint template on an insecure reader) rather than verifying a *living person* in real time. A photograph held up to a camera, or a rubber fingerprint replica, can defeat many consumer-grade biometric systems.

ALAMS addresses this by combining:

- **Face recognition** — Who is this person?
- **Liveness detection** — Are they physically present, alive, and not a spoofed artifact?

Both checks must pass before any attendance record is written.

---

## 2. System Goals & Design Philosophy

**Primary goal:** Prevent fraudulent attendance entries by requiring a verified living face at every check-in and check-out event.

**Secondary goals:**
- Provide accurate, timestamped attendance records with status classification.
- Give administrators actionable dashboards and reports.
- Operate entirely offline; no reliance on external APIs or cloud services.
- Preserve data integrity even when employees leave (soft deletes).

**Design philosophy — Privacy First:** Facial embeddings (128-dimensional float vectors) are stored in the local SQLite database. The raw face images are never persisted. Even if the device is physically compromised, a facial embedding cannot be trivially reverse-engineered into a photograph of the employee.

**Design philosophy — Kiosk Orientation:** The app forces portrait-only orientation at launch (`SystemChrome.setPreferredOrientations`) and hides system UI overlays for a clean kiosk feel. It is designed to run on a dedicated Android device mounted at an entrance, not as a general-purpose personal app.

---

## 3. Architecture Overview

ALAMS follows a **feature-first layered architecture** within a monorepo Flutter project.

```
┌─────────────────────────────────────────────────────────────┐
│                        PRESENTATION                          │
│   Screens (StatefulWidget / ConsumerWidget)                  │
│   Feature-scoped Providers (Riverpod AsyncNotifierProvider)  │
└─────────────────────────────────┬───────────────────────────┘
                                  │
┌─────────────────────────────────▼───────────────────────────┐
│                         DOMAIN / SERVICES                     │
│   FaceRecognitionService  (TFLite inference, cosine match)   │
│   LivenessService         (ML Kit challenges, passive checks) │
│   DatabaseService         (singleton, SQLite CRUD)           │
└─────────────────────────────────┬───────────────────────────┘
                                  │
┌─────────────────────────────────▼───────────────────────────┐
│                           DATA LAYER                          │
│   SQLite (sqflite) — alams.db                                │
│   Tables: employees, attendance, departments, system_settings│
│   Models: Employee, Attendance, Department                   │
└─────────────────────────────────────────────────────────────┘
```

**No repository layer** is used between the service and the database — `DatabaseService` is a singleton that acts as both the repository and the data access object. This is pragmatic for the project's scope and avoids unnecessary abstraction overhead for a local-only app.

**No dependency injection framework** — services are either singletons (`DatabaseService.instance`, `FaceRecognitionService.instance`) or created locally inside screen `State` objects that own their lifecycle (`LivenessService`, `FaceDetector`, `CameraController`).

**Routing** is name-based via `onGenerateRoute` in `MaterialApp`. Arguments are passed as typed maps or model instances through `settings.arguments`.

---

## 4. User Roles

### Employee (Anonymous Kiosk User)

Employees interact with the system purely through the camera. They do not log in. The system identifies *them* — they do not identify themselves. The kiosk home screen (`SelectionScreen`) is the default entry point after setup.

### Administrator

Admins log in via username/password on the `AdminLoginScreen`. Admin status is stored as a flag (`is_admin = 1`) on the `employees` table. The first registration in the system is automatically granted admin rights, enforced by `RootGuardian`.

Admins can:
- Register new employees (with facial capture)
- Edit / soft-delete employees
- View and manage departments
- View all attendance logs and reports
- Configure work start/end hours
- View individual employee attendance history

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
Per-Frame Pipeline:
    1. Google ML Kit detects face in frame
    2. LivenessService processes frame:
       a. Single-face guard — multiple faces → reset
       b. Face size guard — too small or too large → prompt to reposition
       c. Stability check (8 stable frames required)
       d. 3 random challenges issued from CSPRNG-shuffled pool
          (e.g., blink → turn left → smile)
       e. Passive spoof checks run every challenge frame
          (staticness, aspect ratio, eye symmetry)
       f. Challenges pass → LivenessState.passed (session token captured)
       g. Timeout (20s) or passive fail streak (8) → LivenessState.failed
    3. FaceRecognitionService (session token verified before proceeding):
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
        1. Check login_attempts table — locked out? → show lockout message
        2. Fetch admin row by username only
        3. PBKDF2-SHA256 verification in background isolate
        4. Record attempt in login_attempts
        5. 5 failures in 15 min → 15-minute lockout
    ↓ (success)
AdminDashboard
    → At Work count, Absent count, Total Personnel
    → Quick Actions: Camera, Register Employee
    → Menu: Employees, Attendance Logs, Departments, Reports, Settings
```

### 5.4 Employee Registration (Admin-Initiated)

```
AdminDashboard → Register Employee
    ↓
RegistrationScreen
    Step 1: Enter Profile (name, ID, age, sex, department, position, email)
    Step 2: Guided Face Capture
        Pose 1: Front (look straight)
        Pose 2: Turn Left
        Pose 3: Turn Right
        Pose 4: Tilt Up
        Pose 5: Blink
        → Each pose captures a face frame, generates embedding
        → All 5 embeddings averaged → single master embedding stored
    Step 3: Save to DB
    ↓
EmployeeListScreen (refreshed)
```

### 5.5 Editing an Employee

Admin can tap any employee in `EmployeeListScreen` to navigate to `RegistrationScreen` with the `editEmployee` pre-filled. The pose capture flow re-runs to capture a fresh embedding. The existing DB record is updated (not replaced).

---

## 6. Feature Breakdown

### 6.1 Automated Time In / Time Out

The system auto-detects whether the employee should be clocking IN or OUT by querying `getLastAttendanceForEmployee()`. If their last record was an `IN`, the system defaults to `OUT`, and vice versa. The employee can override this on the `ActionScreen`.

**Status classification** is applied at write time in `DatabaseService.insertAttendance()`:

| Event | Condition | Status |
|-------|-----------|--------|
| Time IN | Before or at work_start time | On Time |
| Time IN | After work_start time | Late |
| Time OUT | Before work_end time | Early Out |
| Time OUT | At or after work_end time | Regular Out |

Work start/end hours are configurable by admins from the `SettingsScreen` and stored in the `system_settings` table.

### 6.2 Admin Dashboard

The dashboard (`AdminDashboard`) provides three real-time metrics queried from the database:

- **At Work** — Employees whose latest attendance log today is `IN`
- **Absent** — Employees with zero attendance logs today
- **Total Personnel** — Active (non-deleted, non-admin) employees

These are exposed as Riverpod providers (`currentlyWorkingProvider`, `absentTodayProvider`, `employeesProvider`) so they refresh reactively.

### 6.3 Reports Screen

`ReportsScreen` shows all attendance logs joined with employee names. It supports:

- **Search** by employee name
- **Filter** by type (All, IN, OUT)
- **Filter** by date (picker or default to today)

Logs from deleted employees are retained and labeled `[Deleted Employee]` to preserve historical accuracy.

### 6.4 Department Management

`DepartmentManagementScreen` allows full CRUD on departments. Departments are referenced by name string in the `employees` table (denormalized for simplicity). Deleting a department does not cascade-delete employees assigned to it.

### 6.5 Employee Registration with Multi-Pose Embedding

The registration flow guides the employee through 5 distinct poses using the front camera and ML Kit face detection:

1. **Front** — Baseline, full-face embedding
2. **Turn Left** — Captures left-angle facial features
3. **Turn Right** — Captures right-angle features
4. **Tilt Up** — Captures upward-angle features
5. **Blink** — Verifies eye openness classification

Each pose generates a FaceNet embedding. All embeddings are averaged into a single 128-dimensional vector that is more robust to pose variation than a single front-facing capture.

### 6.6 Soft Delete

Deleting an employee via the admin panel sets `is_deleted = 1` rather than removing the row. This ensures:

- Historical attendance logs remain fully joinable and interpretable.
- Reports can still display the employee name against their historical records.
- Accidental deletions can be recovered at the database level.

### 6.7 PBKDF2 Password Hashing

Admin passwords are never stored as plaintext. When an admin account is created or edited, the password is hashed using **PBKDF2-HMAC-SHA256** with a randomly generated 16-byte salt and 10,000 iterations. The resulting hash is stored in the format `pbkdf2$10000$<base64salt>$<base64hash>`.

The iteration count and salt are embedded in the stored string, making the format self-describing. If the iteration count is increased in a future version, existing hashes remain verifiable using the count they were created with.

All hashing and verification operations run inside a **background Dart isolate** via `compute()`. This keeps the UI thread free — login verification takes ~80–120ms on device but appears instant because the loading indicator renders without interruption.

**Existing plaintext passwords** (e.g., accounts created before this feature was introduced) are detected on first login and automatically migrated to a PBKDF2 hash in the background, with no action required from the admin.

### 6.8 Admin Login Rate Limiting

To prevent brute-force attacks on admin credentials, every login attempt — successful or failed — is recorded in the `login_attempts` table with a timestamp and outcome flag.

Before verifying any password, `validateAdmin()` counts failed attempts for that username within the past 15 minutes. If 5 or more failures are found, the login is rejected immediately with a lockout message — no password comparison is performed.

The `AdminLoginScreen` surfaces this state clearly: remaining attempts are displayed on each failure ("3 attempts remaining before lockout"), and on lockout the form and button are disabled and the remaining wait time is shown. The lockout lifts automatically when the 15-minute window expires.

**Constant-time comparison** is used when verifying hashes — the comparison always takes the same number of operations regardless of where a mismatch occurs, preventing timing-based attacks that could otherwise reveal information about the stored hash byte-by-byte.

### 6.9 Duplicate Face Enrollment Guard

During employee registration, the system checks the new embedding against all existing registered faces before saving. This uses a dedicated `checkDuplicateEmbedding()` method with a stricter distance threshold (0.35) than the live recognition threshold (0.40), reducing the risk of the same person being enrolled under multiple identities.

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

**Why cosine distance?** Cosine distance is invariant to the magnitude of the embedding vector, measuring only directional similarity. FaceNet is trained to produce embeddings where identities cluster in angular space, making cosine distance a natural and effective similarity metric.

**Why L2 normalisation?** Projecting all embeddings onto the unit hypersphere makes cosine distance equal to Euclidean distance, ensuring consistent behaviour across embeddings regardless of how the model's output magnitude varies between inference calls.

**Why the margin guard?** A single threshold allows a face that is slightly closer to employee A than employee B to be recognised as A even if both are far from certain. The margin guard rejects these ambiguous boundary cases — both the best match must be close *and* clearly better than all alternatives.

**Why 0.40 threshold (down from 0.45)?** The tighter threshold reduces false-positive matches. Combined with L2 normalisation and the margin guard, the recognition system is more precise without meaningfully increasing false rejections for legitimate employees in normal lighting.

**Frame throttling:** The camera image stream is processed at most once every 400ms to balance responsiveness with performance on lower-end Android devices. Frames arriving during a processing window are discarded.

---

## 8. Liveness Detection Pipeline

Liveness detection prevents spoofing via photographs, printed faces, replay video attacks, and screen-held images.

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
                              all 3 pass ↓    timeout/passive fail streak ↓
                         ┌───────────┐           ┌──────────┐
                         │  passed   │           │  failed  │
                         └───────────┘           └──────────┘
                         session token                8s cooldown
                         generated                  before retry

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

**Why 3 challenges (up from 2)?** Each additional challenge multiplies the difficulty of preparing a spoofing video. A would-be attacker must now record and synchronise three specific actions in the exact sequence demanded by the system — which is randomised fresh every session.

**Why `Random.secure()` for challenge selection?** Uses the OS cryptographically secure random number generator rather than a seeded RNG. Challenge order cannot be predicted from any prior session observation.

**Why a session token?** A 16-character random token is generated when challenges start and captured at pass-time by `camera_screen`. Before recognition runs, the token is re-checked against the live service — if liveness was reset between passing and recognition (e.g., via a race condition), the stale result is discarded.

**Why a 20-second challenge timeout?** Prevents an attacker from holding a device in front of a pre-recorded video indefinitely while waiting for the right moment. If the session is not completed within 20 seconds, the check hard-fails.

**Why the hard-fail state with cooldown?** When the passive fail streak reaches 8, the state machine enters `LivenessState.failed` and the camera screen enforces an 8-second cooldown before another attempt. This makes automated video-replay scanning meaningfully slower.

**Blink threshold set to 0.43:** Values above 0.50 are too lenient (partial squints register as blinks). Values at or below 0.40 are too strict (require pronounced, exaggerated blinks). 0.43 matches natural everyday blinking behaviour on the tested device range.

---

## 9. State Management Architecture

ALAMS uses **Riverpod 3** as its state management solution.

Providers are defined in `providers/` files within each feature:

| Provider | Type | Purpose |
|----------|------|---------|
| `employeesProvider` | `FutureProvider` | List of all active employees |
| `attendanceLogsProvider` | `FutureProvider` | All attendance logs |
| `attendanceLogsWithNamesProvider` | `FutureProvider` | Logs joined with employee names |
| `attendanceLogsWithNamesTodayProvider` | `FutureProvider` | Today's logs joined with names |
| `currentlyWorkingProvider` | `FutureProvider` | Employees currently checked in |
| `absentTodayProvider` | `FutureProvider` | Employees absent today |
| `faceRecognitionProvider` | `AsyncNotifierProvider` | FR model load status |

After a write operation (e.g., recording attendance), the relevant providers are invalidated via `ref.invalidate(provider)` to trigger a fresh database read and re-render downstream widgets.

**Why Riverpod over other solutions?** Riverpod's compile-safe providers, lack of `BuildContext` dependency for reading state, and clean `AsyncValue` handling for database futures made it well-suited for this data-heavy app. Its `ConsumerWidget` / `ConsumerStatefulWidget` pattern integrates cleanly with Flutter's widget tree.

---

## 10. Tech Stack & Dependencies

This section covers every technology, framework, package, and ML asset used in ALAMS — what each one is, why it was chosen, and how it contributes to the system.

---

### 10.1 Core Platform

#### Flutter (SDK ^3.10.3) + Dart
Flutter is Google's open-source UI toolkit for building natively compiled applications from a single codebase. ALAMS targets Android as its primary platform, but the codebase is structured to remain cross-platform compatible.

**Why Flutter?**
- A single Dart codebase compiles to native Android ARM code, giving near-native performance — important for real-time camera processing and ML inference.
- Flutter's widget system makes it straightforward to build the custom kiosk UI (full-screen camera overlays, animated state transitions) without platform-specific UI code.
- The package ecosystem has mature, well-maintained plugins for camera access, ML Kit integration, and TFLite — all critical dependencies for this project.

**Why Dart?**
Dart is Flutter's companion language. Its `async`/`await` model is well-suited to the app's heavy use of asynchronous operations: camera streams, database queries, and TFLite inference all run asynchronously without blocking the UI thread.

---

### 10.2 Machine Learning & Computer Vision

#### FaceNet (TFLite, `facenet.tflite`)
FaceNet is a deep convolutional neural network architecture developed by Google Research (Schroff et al., 2015) that maps face images directly to a compact Euclidean embedding space. Faces of the same person cluster close together in this space; faces of different people are far apart.

The model bundled in ALAMS is a FaceNet variant converted to TensorFlow Lite flat buffer format for on-device inference.

| Property | Value |
|----------|-------|
| Input tensor | `[1, 160, 160, 3]` float32 |
| Input normalization | `(pixel / 127.5) − 1.0` → range `[−1.0, 1.0]` |
| Output tensor | `[1, 128]` float32 embedding vector |
| Model file size | ~23 MB |
| Inference threads | 4 (configured via `InterpreterOptions`) |

**Why FaceNet over simpler approaches (e.g., Eigenfaces, LBPH)?**
FaceNet's deep embedding approach is significantly more robust to lighting variation, minor pose changes, and aging compared to classical methods. Because embeddings are fixed-length float vectors, matching is a simple distance computation — fast enough to run per-frame on mid-range Android hardware.

#### `tflite_flutter` (^0.12.1)
The official Flutter plugin for TensorFlow Lite. Provides a Dart API to load `.tflite` model files from assets, run inference with typed input/output tensors, and manage interpreter lifecycle.

ALAMS uses it to load `facenet.tflite` once at startup via `FaceRecognitionService.loadModel()` and reuse the interpreter across the app's lifetime. The interpreter is configured to use 4 threads to parallelize convolution operations on multi-core mobile CPUs.

#### Google ML Kit Face Detection (`google_mlkit_face_detection` ^0.13.2)
Google's on-device ML SDK for Android and iOS. The face detection component runs a fast face detector that returns, for each detected face:

- **Bounding box** — position and size of the face in the frame
- **3D Euler angles** — `headEulerAngleX` (tilt), `headEulerAngleY` (turn), `headEulerAngleZ` (roll)
- **Classification probabilities** — `leftEyeOpenProbability`, `rightEyeOpenProbability`, `smilingProbability`
- **Facial contours** — landmark point arrays for lips, eyes, nose, face oval

ALAMS uses ML Kit for two distinct purposes: liveness challenge evaluation in `LivenessService` (all of the above) and face presence detection during guided registration in `RegistrationScreen` (bounding box + eye open probability).

**Why ML Kit instead of TFLite for detection?**
ML Kit abstracts the face detection pipeline completely — developers don't need to manage a separate detection model, handle input format conversion, or parse raw tensor outputs into landmark coordinates. For a pose/expression challenge system, ML Kit's high-level API (euler angles as floats, eye-open as 0.0–1.0 probability) is far more productive than building this from raw tensors.

#### `image` (^4.8.0)
A pure-Dart image manipulation library. ALAMS uses it specifically for:
- YUV420 → RGB conversion: the `camera` plugin delivers frames in YUV420 format (the native Android camera format). The `image` package provides pixel-level operations to reconstruct an RGB image from the Y, U, and V planes.
- `img.copyResize()` — resizes the converted RGB image to 160×160 pixels to match FaceNet's input tensor shape.

Being pure Dart means it runs without any native code or FFI — important for isolate compatibility if the preprocessing is ever moved off the main thread via `compute()`.

---

### 10.3 Camera

#### `camera` (^0.12.0+1)
The official Flutter camera plugin. Provides a `CameraController` that abstracts Android's Camera2 API. ALAMS uses it to:
- Enumerate available cameras and select the front-facing camera (`CameraLensDirection.front`).
- Initialize a live preview at `ResolutionPreset.medium` in `ImageFormatGroup.yuv420`.
- Start an `imageStream` that delivers raw `CameraImage` frames to a Dart callback for real-time processing.
- Dispose and re-acquire the camera when navigating between screens (required to release the hardware lock).

**Why `ResolutionPreset.medium`?** Higher resolutions deliver larger frames that take longer to process through YUV→RGB conversion and ML Kit. Medium resolution (~720p on most devices) provides sufficient image quality for FaceNet while keeping per-frame processing time manageable.

---

### 10.4 Database & Persistence

#### SQLite via `sqflite` (^2.4.2)
SQLite is an embedded relational database engine. `sqflite` is the Flutter plugin that wraps the native SQLite library available on Android and iOS. ALAMS stores all data — employees, attendance records, departments, and settings — in a single `alams.db` SQLite file on the device.

**Why SQLite / sqflite?**
- Fully offline — no server, no sync, no network dependency.
- Relational queries (JOINs for attendance logs with employee names, subqueries for "currently at work" logic) are more expressive and maintainable than document or key-value approaches.
- `sqflite` supports versioned schema migrations via `onUpgrade`, enabling safe schema evolution across app updates.
- Data survives app restarts, device reboots, and app updates.

#### `path_provider` (^2.1.5)
Provides platform-safe directory paths. ALAMS calls `getDatabasesPath()` (provided by sqflite, which internally uses path_provider) to resolve the correct location to store `alams.db` on both Android and iOS without hardcoding a filesystem path.

#### `path` (^1.9.1)
A utility library for constructing file system paths. Used specifically in `DatabaseService._initDB()` to join the database directory path with the filename: `join(dbPath, 'alams.db')`.

---

### 10.5 State Management

#### Riverpod (`flutter_riverpod` ^3.3.1 + `riverpod_annotation` ^4.0.2)
Riverpod is a compile-safe, testable reactive state management library for Flutter. It is a spiritual successor to the `provider` package, removing its key limitations: no `BuildContext` required to read state, providers can be accessed anywhere, and there are no accidental overrides.

ALAMS uses Riverpod's `FutureProvider` for all database-backed state (employee lists, attendance logs, dashboard metrics) and `AsyncNotifierProvider` for the face recognition model's load state.

**Why Riverpod over alternatives?**

| Alternative | Why Not Chosen |
|-------------|---------------|
| `setState` | Does not scale across screens; rebuilds too broadly |
| `provider` | Context-dependent; can cause runtime errors at the call site |
| `BLoC` | Higher boilerplate for a project of this scope |
| `GetX` | Opinionated global state can make data flow harder to trace |

Riverpod's `ref.invalidate(provider)` pattern is central to ALAMS — after every write (attendance recorded, employee registered), the relevant provider is invalidated, which triggers a fresh database read and automatically re-renders all widgets watching that provider.

---

### 10.6 Utilities & Formatting

#### `intl` (^0.20.2)
The Dart internationalization and localization package. ALAMS uses `DateFormat` from this package to format timestamps and dates throughout the UI — for example, `DateFormat('EEEE, MMMM d').format(now)` on the kiosk home screen, and date-based grouping in the reports screen.

---

### 10.7 Development & Build Tools

#### Flutter Lints (`flutter_lints` ^6.0.0)
The official Flutter lint rule set, activated via `analysis_options.yaml`. Enforces consistent Dart code style and catches common mistakes at static analysis time. Configured at the project level.

#### Android Gradle Build System
The Android platform project uses Kotlin DSL (`build.gradle.kts`) for its Gradle build scripts. The build targets:
- `minSdk`: configured in `android/app/build.gradle.kts` (compatible with Android devices that support Camera2 API and ML Kit)
- `targetSdk`: latest stable Android SDK
- Gradle wrapper version: 8.14

---

### 10.8 Summary Table

| Layer | Technology | Version | Purpose |
|-------|-----------|---------|---------|
| **UI Framework** | Flutter + Dart | SDK ^3.10.3 | Cross-platform native UI, app lifecycle |
| **State Management** | Riverpod | ^3.3.1 | Reactive, compile-safe state across screens |
| **On-Device Database** | SQLite (sqflite) | ^2.4.2 | Persistent local data store (schema v7) |
| **Face Recognition Model** | FaceNet TFLite | — | L2-normalised 128-dim facial embedding generation |
| **ML Inference Runtime** | tflite_flutter | ^0.12.1 | On-device TFLite model execution |
| **Face Detection & Analysis** | Google ML Kit | ^0.13.2 | Face detection, landmarks, euler angles, eye/smile classification |
| **Camera Access** | camera | ^0.12.0+1 | Front-camera streaming (YUV420) |
| **Image Processing** | image (Dart) | ^4.8.0 | YUV→RGB conversion, resize to 160×160 |
| **Password Hashing** | crypto_utils.dart (custom) | — | Pure-Dart PBKDF2-SHA256, 10k iterations, isolate-safe |
| **Date/Time Formatting** | intl | ^0.20.2 | Locale-aware date display in UI and reports |
| **File Path Resolution** | path_provider | ^2.1.5 | Platform-safe DB file path |
| **Path Utilities** | path | ^1.9.1 | File path joining |
| **Platform** | Android (Kotlin) | — | Host platform, Camera2 API, ML Kit native |

---

## 11. Security Considerations

### 11.1 Threat Model & Mitigations

| Threat | Mitigation |
|--------|-----------|
| Buddy punching (human proxy) | Face recognition requires a biometric match |
| Photo spoof attack | 3 randomised liveness challenges; passive staticness check |
| Video replay attack | CSPRNG challenge selection; session token; 20s timeout |
| Multi-face injection | Single-face guard rejects any frame with >1 detected face |
| Flat-surface (screen) spoof | Aspect ratio check during head turns; eye symmetry check |
| Frozen frame / static image | Passive face area delta check (< 2px² → fail streak) |
| Brute-force liveness | Hard-fail state + 8s cooldown after 8 passive failures |
| Admin password compromise | PBKDF2-SHA256, 10k iterations, 16-byte random salt per account |
| Brute-force admin login | Lockout after 5 failures in 15 minutes; remaining attempts shown |
| Timing-based password inference | Constant-time hash comparison; password never compared in SQL |
| User enumeration via login | Failed attempts recorded even for unknown usernames |
| Duplicate identity enrollment | `checkDuplicateEmbedding()` at registration with 0.35 threshold |
| Ambiguous face match | Two-threshold matching: primary 0.40 + margin guard 0.08 |
| Session token replay (race condition) | Liveness session token verified before recognition is consumed |
| SQL injection | All queries use parameterised placeholders; no string interpolation |
| FK integrity violation | `PRAGMA foreign_keys = ON` set on every DB connection open |
| Data exfiltration via device theft | Embeddings only (no raw images stored); PBKDF2-hashed credentials |
| Employee record tampering | Soft deletes preserve full audit trail |

### 11.2 PBKDF2 Iteration Count Rationale

The implementation uses **10,000 iterations** rather than the more commonly cited 100,000. This is a deliberate, reasoned trade-off for a mobile kiosk context:

100,000 iterations of pure-Dart PBKDF2 takes approximately 800ms–1,200ms on a mid-range Android CPU. Even when offloaded to a background isolate this causes a perceptible delay on login. More critically, when run on the main thread (which was the original bug) it produces a visible black screen on launch and a hard hang on every login attempt.

10,000 iterations takes approximately 80–120ms on the same hardware — imperceptible when run in a `compute()` isolate. The security trade-off is acceptable for this threat model: an attacker must have physical access to the device to read the SQLite database at all. The 16-byte random salt ensures precomputed rainbow tables are useless regardless of iteration count. If the device is stolen and the database extracted, 10,000 iterations still requires roughly 10,000× more compute per guess than plaintext, making offline dictionary attacks costly without sacrificing runtime usability.

### 11.3 Off-Thread Crypto — No UI Blocking

All cryptographic operations use Flutter's `compute()` function to run in a separate Dart isolate:

- `hashPassword()` — called during admin registration and password change
- `verifyPassword()` — called on every login attempt
- `_migratePasswordsToHashed()` — called once via `Future.microtask()` after DB open, completely off the critical path

The `crypto_utils.dart` exposes dedicated static entry points (`hashPasswordIsolate`, `verifyPasswordIsolate`) shaped as single-argument functions to match `compute()`'s API requirements.