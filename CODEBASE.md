# CODEBASE.md — File & Folder Structure

## Top-Level Structure

```
alams/
├── lib/                        # All Dart/Flutter source code
├── assets/
│   └── models/
│       ├── facenet.tflite      # On-device face recognition model
│       └── README.md           # Model specification notes
├── android/                    # Android platform project
├── test/                       # Widget tests
├── pubspec.yaml                # Dependency manifest
├── pubspec.lock                # Locked dependency versions
├── analysis_options.yaml       # Dart linting rules
├── .metadata                   # Flutter project metadata
└── .flutter-plugins-dependencies
```

---

## `lib/` — Source Code Root

```
lib/
├── main.dart
├── core/
│   ├── database/
│   │   └── database_service.dart
│   ├── models/
│   │   ├── employee.dart
│   │   ├── attendance.dart
│   │   └── department.dart
│   ├── providers/
│   │   └── database_provider.dart
│   └── utils/
│       ├── image_utils.dart
│       └── crypto_utils.dart
└── features/
    ├── admin/
    │   └── screens/
    │       ├── admin_dashboard.dart
    │       ├── admin_login_screen.dart
    │       ├── department_management_screen.dart
    │       └── settings_screen.dart
    ├── attendance/
    │   ├── providers/
    │   │   └── attendance_provider.dart
    │   └── screens/
    │       ├── action_screen.dart
    │       ├── attendance_history_screen.dart
    │       └── selection_screen.dart
    ├── face_recognition/
    │   ├── providers/
    │   │   └── face_recognition_provider.dart
    │   ├── screens/
    │   │   └── camera_screen.dart
    │   └── services/
    │       ├── face_recognition_service.dart
    │       └── liveness_service.dart
    ├── onboarding/
    │   └── screens/
    │       └── onboarding_screen.dart
    ├── registration/
    │   ├── providers/
    │   │   └── employee_provider.dart
    │   └── screens/
    │       ├── employee_list_screen.dart
    │       └── registration_screen.dart
    └── reports/
        └── screens/
            └── reports_screen.dart
```

---

## File Descriptions

### `lib/main.dart`

**Entry point and application root.**

Responsibilities:
- Calls `WidgetsFlutterBinding.ensureInitialized()` before anything else.
- Forces portrait-only orientation via `SystemChrome.setPreferredOrientations`.
- Sets transparent status bar for immersive kiosk UI.
- Wraps the app in `ProviderScope` (Riverpod requirement).
- Defines the global `RouteObserver<ModalRoute<void>> routeObserver` — shared across screens so `CameraScreen` can detect when it regains focus after a route pop and re-initialize the camera.
- Declares all named routes via `onGenerateRoute`, handling typed argument passing and page transition animations (slide-up, slide-right, slide-left).
- Contains `RootGuardian` — a `StatefulWidget` that checks `DatabaseService.hasAdmin()` on startup. If no admin exists, routes to `OnboardingScreen`; otherwise routes to `SelectionScreen`.

---

### `lib/core/database/database_service.dart`

**The central data access layer. Singleton.**

This is the most critical infrastructure file in the project. It manages the full lifecycle of the SQLite database and exposes all CRUD operations.

Key design decisions:
- **Singleton pattern** via `DatabaseService.instance` — guarantees a single `Database` object shared across the app.
- **Schema versioning** — database is at version 7. All migrations are handled in `onUpgrade`, with version guards (`if (oldVersion < N)`), enabling safe upgrades from any prior version.
- **Lazy initialization** — the `database` getter opens the DB on first access and caches it.
- **`PRAGMA foreign_keys = ON`** — enforced in both `onOpen` and `onUpgrade` so SQLite actually applies the declared foreign key constraint between `attendance.employee_id` and `employees.id`.
- **Background password migration** — `_migratePasswordsToHashed()` runs via `Future.microtask()` after DB open, completely off the launch critical path. It detects any remaining plaintext passwords and hashes them in a `compute()` isolate, with no impact on startup time.
- **All crypto off the main thread** — every call to `CryptoUtils.hashPassword` and `CryptoUtils.verifyPassword` goes through `await compute(...)`, keeping the UI thread free during login and registration saves.

Methods grouped by concern:

*Employees:* `insertEmployee`, `getAllEmployees`, `getAdmin`, `deleteEmployee` (soft), `updateEmployee`, `hasAdmin`, `getEmployeeCount`

*Attendance:* `insertAttendance` (with automatic status classification), `getAttendanceLogs`, `getAttendanceLogsWithNamesToday`, `getCurrentlyAtWork`, `getAbsentToday`, `getLastAttendanceForEmployee`, `getAttendanceLogsWithNames`, `getAttendanceLogsForEmployee`

*Admin Security:* `validateAdmin` (PBKDF2 verification in isolate, rate-limited by `login_attempts` table), `_recentFailedAttempts`, `_recordLoginAttempt`

*Departments:* `insertDepartment`, `getAllDepartments`, `deleteDepartment`, `updateDepartment`

*Settings:* `getSetting`, `updateSetting`

Also defines the `AdminLoginResult` value class and `AdminLoginStatus` enum, returned by `validateAdmin()` to communicate success, failure (with attempts remaining), or lockout (with wait time) to the UI without leaking internal details.

---

### `lib/core/models/employee.dart`

**Data model representing a person in the system** (both employees and admins).

Fields: `id`, `name`, `age`, `sex`, `position`, `department`, `empId`, `email`, `isAdmin`, `facialEmbedding` (List\<double\>), `username`, `password`, `isDeleted`

The `facialEmbedding` is stored as a comma-separated string in SQLite (`TEXT`) and parsed back to `List<double>` in `fromMap()`. This avoids binary BLOB handling while keeping the model simple.

---

### `lib/core/models/attendance.dart`

**Data model for a single attendance event.**

Fields: `id`, `employeeId`, `timestamp` (ISO 8601 string), `type` (`'IN'` or `'OUT'`), `status` (`'On Time'`, `'Late'`, `'Early Out'`, `'Regular Out'`, `'Normal'`)

The `status` field is computed by `DatabaseService.insertAttendance()` at write time, not by the UI. The model itself accepts `'Normal'` as a default to represent unclassified legacy records.

---

### `lib/core/models/department.dart`

**Minimal data model for a department.**

Fields: `id`, `name`. Departments are used as a reference list for the employee registration form's dropdown selector.

---

### `lib/core/providers/database_provider.dart`

**Thin Riverpod provider wrapper** exposing the `DatabaseService` instance to the provider graph. Enables the database service to be referenced via Riverpod's `ref.read()` / `ref.watch()` in providers that need it, keeping service access consistent with the rest of the state layer.

---

### `lib/core/utils/image_utils.dart`

**Image conversion utilities.**

Provides helper functions for converting between `CameraImage` (raw YUV420 from the camera stream) and the formats required by ML Kit and TFLite. Used by both the registration screen and the camera screen when preparing face images for detection and embedding generation.

---

### `lib/core/utils/crypto_utils.dart`

**Pure-Dart PBKDF2-SHA256 password hashing. No external dependencies.**

Implements the full PBKDF2-HMAC-SHA256 key derivation function from scratch using only `dart:convert`, `dart:math`, and `dart:typed_data`. This avoids adding a native crypto package to the project while providing a cryptographically sound hashing solution.

Key details:
- **10,000 iterations** — calibrated for ~80–120ms on a background isolate on mid-range Android, imperceptible to users while still being meaningfully expensive for offline brute-force attacks.
- **16-byte random salt** from `Random.secure()` — ensures each stored hash is unique even if two admins choose the same password.
- **Self-describing format** — `"pbkdf2$10000$<base64salt>$<base64hash>"` embeds the iteration count, allowing future iteration count upgrades without breaking existing hash verification.
- **Constant-time equality** (`_constantTimeEqual`) — all hash comparisons use XOR-accumulation over the full length rather than short-circuiting, preventing timing-based side-channel attacks.
- **Isolate-safe entry points** — `hashPasswordIsolate(String)` and `verifyPasswordIsolate(List<String>)` are shaped as single-argument static functions compatible with Flutter's `compute()` API.
- `isHashed(String)` — detects legacy plaintext values so the database service can migrate them transparently on first use.

---

### `lib/features/face_recognition/services/face_recognition_service.dart`

**Core face recognition logic. Singleton.**

Responsibilities:
- Loads the `facenet.tflite` model from Flutter assets via `tflite_flutter`.
- `preprocessCameraImage()` — converts raw `CameraImage` (YUV420 planes) to a 160×160 RGB `img.Image` using the standard YUV-to-RGB conversion formula. This is a static method so it can be run in a compute isolate.
- `generateEmbedding()` — normalizes pixel values to `[-1, 1]`, runs TFLite inference, and returns the output embedding vector. Dynamically reads the output tensor's last dimension to support both 128-dim and 512-dim FaceNet variants.
- `cosineDistance()` — computes cosine distance between two embedding vectors. Static and pure, no model required.
- `findBestMatch()` — iterates through all registered face embeddings, finds the minimum cosine distance, and returns a `RecognitionResult` indicating whether the distance falls below the 0.45 threshold.

The `RecognitionResult` value object carries `label` (employee name), `distance`, and `isRecognized`.

---

### `lib/features/face_recognition/services/liveness_service.dart`

**Anti-spoofing liveness detection logic.**

Uses ML Kit `FaceDetector` with classification (eye open, smiling probabilities), landmarks, and contours enabled.

Manages a state machine with four states: `waiting → lookStraight → performingChallenge → passed`.

Challenges (5 in pool, 2 randomly selected each session):
- `blink` — Checks average eye open probability drops below 0.50 for 3+ consecutive frames.
- `mouthOpen` — Computes gap between upper lip bottom and lower lip top contour points relative to face height.
- `turnLeft` — `headEulerAngleY > 25°`
- `turnRight` — `headEulerAngleY < -25°`
- `smile` — `smilingProbability > 0.70`

Passive check `_checkPassiveLiveness()` detects suspicious staticness (face area not changing) which is characteristic of printed photos or paused video.

Public methods: `processFrame()`, `reset()`, `dispose()`

---

### `lib/features/face_recognition/screens/camera_screen.dart`

**The main camera view for attendance scanning. The most complex screen.**

This is a `ConsumerStatefulWidget` that:
- Initializes the front-facing camera in `initState` using the `camera` package.
- Subscribes to `routeObserver` via `RouteAware.didPopNext` to re-initialize the camera when the user returns from `ActionScreen`. This is necessary because releasing the camera hardware for `ActionScreen` prevents conflicts.
- Starts an `imageStream` on the `CameraController`. Each incoming frame is checked against a 400ms throttle (`_processingInterval`) before being processed.
- Per-frame: runs `LivenessService.processFrame()`, then (only if liveness has passed) calls `FaceRecognitionService.generateEmbedding()` and `findBestMatch()`.
- On successful recognition, stops the image stream, applies a brief screen flash effect, and navigates to `ActionScreen` passing the recognized `Employee` object.
- Displays live UI overlays: current liveness instruction text, challenge name, pass indicator.

Mode parameter (`mode: 'SCAN'`, `'IN'`, `'OUT'`) is passed in as a named route argument, allowing the camera to be used for both attendance scanning and admin-initiated specific action types.

---

### `lib/features/face_recognition/providers/face_recognition_provider.dart`

**Riverpod provider for the `FaceRecognitionService` loading state.**

Exposes an `AsyncNotifierProvider` that calls `FaceRecognitionService.instance.loadModel()`. Screens can watch this provider to display a loading indicator while the TFLite model is being initialized from assets.

---

### `lib/features/attendance/screens/selection_screen.dart`

**The kiosk home screen. First screen employees see.**

A stateless, minimal screen with:
- Current date displayed at the top.
- A large "Log Attendance" button that navigates to `CameraScreen`.
- A "Administrator Login" text button at the bottom.
- Version identifier footer.

Designed to be unambiguous for employees: one primary action, clearly labeled.

---

### `lib/features/attendance/screens/action_screen.dart`

**Post-recognition confirmation and attendance recording screen.**

Receives the recognized `Employee` object and an optional `presetAction` (`'IN'` or `'OUT'`). If no preset, queries the DB for the employee's last attendance record and auto-selects the opposite action.

Displays employee name, employee ID, and current time. The employee can switch between IN and OUT before confirming. On confirmation, calls `DatabaseService.insertAttendance()`, which applies status classification and writes the record. The screen then displays the returned status and auto-dismisses after a brief delay, returning the user to the camera for the next scan.

---

### `lib/features/attendance/screens/attendance_history_screen.dart`

**Per-employee attendance history view.**

Receives an `Employee` object and displays all their historical attendance logs in reverse-chronological order. Shows timestamp, type (IN/OUT), and status badge color-coded by type. Accessible from both the admin employee list and reports.

---

### `lib/features/attendance/providers/attendance_provider.dart`

**All attendance-related Riverpod providers.**

Defines:
- `attendanceLogsProvider` — all logs
- `attendanceLogsWithNamesProvider` — logs joined with employee names (for reports)
- `attendanceLogsWithNamesTodayProvider` — today's logs joined with names (for dashboard)
- `currentlyWorkingProvider` — employees currently clocked in
- `absentTodayProvider` — employees with no logs today

All are `FutureProvider` wrapping database queries. Invalidated after write operations in `ActionScreen`.

---

### `lib/features/admin/screens/admin_dashboard.dart`

**Main admin hub screen.**

Displays three metric cards (At Work, Absent, Total Personnel) sourced from Riverpod providers. Provides a quick-action row (Open Camera, Register Employee) and a menu list navigating to: Employee List, Attendance Logs, Department Management, Reports, Settings.

---

### `lib/features/admin/screens/admin_login_screen.dart`

**Credential gate for admin access.**

A username/password form that calls `DatabaseService.validateAdmin()`. On success, navigates to `AdminDashboard`. On failure, shows an error snackbar. Uses a `TextEditingController` for each field and has password visibility toggle.

---

### `lib/features/admin/screens/department_management_screen.dart`

**CRUD interface for departments.**

Lists all departments with edit and delete buttons. A floating action button opens an inline dialog for adding a new department name. Deletion is hard (removes the row from `departments` table) but does not cascade to employees — existing employees retain their department string.

---

### `lib/features/admin/screens/settings_screen.dart`

**Work hours configuration screen.**

Presents two time pickers (Work Start, Work End) that read from and write to `system_settings` via `DatabaseService.getSetting()` / `updateSetting()`. These values control the On Time / Late / Early Out / Regular Out classification logic in `insertAttendance()`.

---

### `lib/features/registration/screens/registration_screen.dart`

**Employee registration and profile editing screen. The most feature-dense form screen.**

A two-step flow: (1) profile form entry, (2) guided 5-pose face capture.

Step 1 — Form fields: name, email, employee ID, age, sex (dropdown), department (dropdown loaded from DB), position, username (admin only), password (admin only). Validated via `Form` / `GlobalKey<FormState>`.

Step 2 — Guided face capture:
- `RegistrationPose` enum defines sequence: `front → left → right → up → blink → done`
- For each pose, the camera stream processes frames through `FaceDetector` to confirm face presence.
- On `blink` pose: checks `leftEyeOpenProbability` for a deliberate eye-close event.
- Each successful pose capture calls `FaceRecognitionService.generateEmbedding()`.
- After all 5 poses, embeddings are averaged element-wise into one master embedding vector.
- The completed `Employee` model is upserted into the database.

If `editEmployee` is provided (edit mode), the form is pre-filled and the existing DB record is updated.

---

### `lib/features/registration/screens/employee_list_screen.dart`

**Scrollable list of all registered employees (admin view).**

Displays each employee's name, ID, department, and position. Tapping an employee navigates to `AttendanceHistoryScreen`. A long-press or dedicated edit icon navigates to `RegistrationScreen` in edit mode. Delete performs a soft delete with a confirmation dialog.

---

### `lib/features/registration/providers/employee_provider.dart`

**Riverpod provider for the employees list.**

`employeesProvider` is a `FutureProvider` returning `DatabaseService.getAllEmployees()`. Invalidated after any insert, update, or delete operation.

---

### `lib/features/reports/screens/reports_screen.dart`

**Full attendance log viewer with filtering.**

Fetches all attendance logs joined with employee names. Supports live search (by employee name), filter by type (All / IN / OUT), and date picker filter. Displays each log row with color-coded IN/OUT badge, timestamp, employee name and ID, and status label. Shows summary metrics (At Work count, Absent count) at the top for quick situational awareness.

---

### `lib/features/onboarding/screens/onboarding_screen.dart`

**First-launch screen shown only when no admin exists.**

A single-purpose screen with app branding, a brief feature highlight list, and a "Setup System Admin" button that navigates to `RegistrationScreen`. The first employee registered through this flow automatically receives `is_admin = true`, enforced in `RegistrationScreen._loadInitialData()`.

---

## `assets/`

### `assets/models/facenet.tflite`

The bundled TFLite model file (~23MB). This is a FaceNet model converted to TensorFlow Lite flat buffer format. Input tensor: `[1, 160, 160, 3]` (normalized float32). Output tensor: `[1, 128]` (float32 embedding).

The large file size is a trade-off for on-device, offline-capable face recognition with reasonable accuracy.

### `assets/models/README.md`

Developer notes on the expected model I/O specification and where to obtain alternative FaceNet TFLite weights.

---

## `android/`

Standard Flutter Android host project. Key files:

`android/app/src/main/AndroidManifest.xml` — declares required permissions: `CAMERA` (for face scanning), `WRITE_EXTERNAL_STORAGE` / `READ_EXTERNAL_STORAGE` (for DB path resolution on older Android). Also declares the `MainActivity` as the launch activity.

`android/app/src/main/kotlin/com/example/alams/MainActivity.kt` — minimal Kotlin `MainActivity` subclassing `FlutterActivity`. No custom platform channel code.

`android/app/build.gradle.kts` — defines `minSdk`, `targetSdk`, and build configuration for the app.

---

## `test/`

### `test/widget_test.dart`

Default Flutter-generated widget test stub. Verifies the app loads without crashing. No custom test logic has been added at this stage.