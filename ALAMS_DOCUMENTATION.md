# ALAMS: Attendance Logging and Management System | Technical Manual

ALAMS is a high-performance, offline-first attendance solution built with Flutter. It utilizes on-device machine learning for biometric identity verification and provides a comprehensive administrative suite for workforce management.

---

## Table of Contents
1.  [System Overview](#1-system-overview)
2.  [Key Features](#2-key-features)
    -   [Administrator Capabilities](#administrator-capabilities)
    -   [Employee Capabilities](#employee-capabilities)
3.  [Project Structure](#3-project-structure)
    -   [Directory Manifest](#directory-manifest)
4.  [System Architecture](#4-system-architecture)
    -   [State Management Hierarchy](#state-management-hierarchy)
    -   [Routing & Guarding (RootGuardian)](#routing--guarding-rootguardian)
5.  [Technology Stack](#5-technology-stack)
    -   [Core Frameworks](#core-frameworks)
    -   [Machine Learning Integration](#machine-learning-integration)
6.  [Technical Deep Dive](#6-technical-deep-dive)
    -   [Face Recognition Pipeline (4 Stages)](#face-recognition-pipeline-4-stages)
    -   [Guided Pose Enrollment](#guided-pose-enrollment)
    -   [Suggestive Attendance Logic](#suggestive-attendance-logic)
7.  [Database & Persistence](#7-database--persistence)
    -   [Schema Definitions](#schema-definitions)
    -   [Migration History (v1 - v4)](#migration-history-v1---v4)
8.  [Design Philosophy](#8-design-philosophy)

---

## 1. System Overview
ALAMS addresses the need for secure, touchless, and privacy-focused attendance tracking. Unlike cloud-based systems, ALAMS processes all biometrics locally using TensorFlow Lite, ensuring data never leaves the device. It is designed for kiosk-style deployment with a premium, focused UI.

## 2. Key Features

### Administrator Capabilities
*   **Live Metrics Dashboard**: Real-time visualization of workforce state using reactive providers.
*   **Personnel Management**: Full CRUD operations for employees, including text-based credentials for admins and biometric profiles for staff.
*   **Departmental Hierarchy**: Logical grouping of employees to facilitate organizational reporting.
*   **Audit-Ready Logs**: Filterable attendance reports with automatic Time-In/Time-Out pairing.

### Employee Capabilities
*   **Zero-UI Interaction**: Upon facial recognition, the system automatically determines the appropriate attendance action.
*   **Post-Scan Action Dashboard**: A dedicated space for employees to confirm their logs, view personal history, and check their profile status without administrative access.
*   **Guided Feedback**: High-granularity instructions during registration and haptic confirmation during daily use.

## 3. Project Structure

### Directory Manifest
The project follows a **Feature-First Architecture** to ensure scalability:
*   `lib/core/`: Shared infrastructure.
    *   `database/`: SQLite implementation and migrations.
    *   `models/`: Data entities (Employee, Attendance, Dept).
    *   `utils/`: Image processing and validation helpers.
*   `lib/features/`: domain-specific logic.
    *   `admin/`: Dashboard, Login, and Department management.
    *   `attendance/`: Home screen, Camera interface, and Action screen.
    *   `face_recognition/`: TFLite services and preprocessing logic.
    *   `registration/`: Multi-step enrollment flow and employee lists.
    *   `reports/`: Administrative log viewing and filtering.
    *   `onboarding/`: Initial system administrator setup.

## 4. System Architecture

### State Management Hierarchy
ALAMS uses **Riverpod** for a unidirectional data flow:
1.  **Repository Level**: `DatabaseService` provides raw data.
2.  **Provider Level**: 
    *   `employeesProvider`: Global list of non-admin personnel.
    *   `attendanceLogsWithNamesProvider`: Joined dataset of logs and names.
    *   `currentlyWorkingProvider`: Filtered list of employees whose last log is 'IN'.
3.  **UI Level**: Screens watch these providers and rebuild only when relevant data changes (e.g., adding a new log instantly updates the dashboard metrics).

### Routing & Guarding (RootGuardian)
The `RootGuardian` acts as the application's entry gatekeeper:
*   **State check**: Queries `db.hasAdmin()`.
*   **Branch A (New System)**: If no administrator exists, forces navigation to `OnboardingScreen`.
*   **Branch B (Initialized System)**: Directs to `SelectionScreen` (the standard day-to-day homepage).
*   **Logic**: This ensures the system cannot be used for attendance until a manager is registered.

## 5. Technology Stack

### Core Frameworks
*   **Flutter**: Cross-platform engine for high-performance rendering.
*   **Sqflite**: persistent storage with SQL support.
*   **ML Kit (Face Detection)**: Google's high-speed on-device face detection.
*   **TensorFlow Lite**: Execution engine for custom deep learning models.

### Machine Learning Integration
*   **FaceNet (TFLite)**: Generates 128-dimensional mathematical embeddings from facial images.
*   **Input Size**: 160x160 px (RGB).
*   **Performance**: ~100ms inference time on modern mobile hardware.

## 6. Technical Deep Dive

### Face Recognition Pipeline (5 Stages)
1.  **Face Detection**: ML Kit identifies a face and head orientation. The system waits for a "stable" face before proceeding.
2.  **Liveness & Anti-Spoofing (Multi-Challenge)**:
    *   **Stricter Blink**: Requires eyes to be closed for 3+ consecutive frames to prevent accidental triggers.
    *   **Mouth Opening**: Mandatory mouth-opening challenge to prevent static photo/video attacks.
    *   **Active Illumination**: A brief cyan flash used to detect diffuse skin reflection vs. mirror-like screen reflections.
3.  **Preprocessing**:
    *   **Colorspace Conversion**: The `CameraImage` (YUV420) is converted to RGB.
    *   **Normalization**: Pixel values are normalized to `[-1, 1]` for the model.
4.  **Embedding Generation**: The 160x160 image produces a unique 128-float vector.
5.  **Matching (Cosine Similarity)**:
    *   Uses **Cosine Distance** to account for variations in lighting intensity.
    *   **Formula**: `1.0 - (A · B / (||A|| * ||B||))`.
    *   **Threshold**: `0.6` for recognition.

### Guided Pose Enrollment
To build a robust profile, employees must provide 5 poses:
*   **Front View**: Baseline embedding.
*   **Turn Left/Right**: Captures lateral features.
*   **Tilt Up**: Captures structure for different kiosk heights.
*   **Blink**: Provides a "Liveness" check to ensure a real human is present.
*   **Result**: The system calculates the arithmetic mean of these 5 vectors to store a highly resilient "Master Embedding".

### Suggestive Attendance Logic
ALAMS eliminates the "Time In vs Time Out" button confusion:
1.  System retrieves the `lastAttendance` for the recognized user.
2.  **Toggle Logic**: 
    *   If `lastLog == null` OR `lastLog == 'OUT'` -> **Suggest TIME IN**.
    *   If `lastLog == 'IN'` -> **Suggest TIME OUT**.
3.  This automation minimizes human error and speeds up line-ups during shift changes.

## 7. Database & Persistence

### Schema Definitions
*   **employees**: Primary registry. Includes `facial_embedding` (stored as a comma-separated string of 128 floats), `is_admin` flag, and credential fields.
*   **attendance**: Time logs. Uses `employee_id` as a foreign key with an `INDEX` on `timestamp` for performance.
*   **departments**: Dynamic categories managed by the administrator.

### Migration History (v1 - v4)
*   **v1**: Initial schema (ID, Name, Embedding).
*   **v2**: Expanded profiles (Age, Sex, Position, Employee ID) and introduced the `is_admin` flag for role separation.
*   **v3**: Added **Department Management** and raw text credentials (`username`/`password`) for administrative logins.
*   **v4**: Integrated **Email Support** and refined administrative logic to fix registry filtering.

## 8. Operational Workflows

### Initial Setup (Default Seeding)
To ensure immediate usability, ALAMS automatically seeds an administrative account if none exists in the database.
*   **Default Username**: `admin`
*   **Default Password**: `admin`
*   **Role**: System Administrator (`is_admin = 1`).
*   **Recommendation**: Administrators should update these credentials via the Dashboard immediately after login.

### Daily Attendance Workflow
1.  **Orientation**: User positions face within the guide.
2.  **Verification**: System cycles through the Liveness Challenge (Cyan Flash -> Blink -> Mouth Open).
3.  **Auto-Action**: System determines if the user should "Time In" or "Time Out" based on their last recorded log.

## 9. Design Philosophy
*   **Professional UX**: A focused, dark-themed interface that feels like a dedicated hardware appliance.
*   **Accessibility**: High-contrast text, clear iconography, and large touch targets for industrial environments.
*   **Zero-Maintenance**: Automated metric reconciliation and log management mean the administrator only needs to focus on managing personnel, not the technology.

---
*ALAMS Technical Manual | Version 1.2 (Security Update)*
