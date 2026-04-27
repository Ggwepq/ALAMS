# DATABASE.md — Database Design & Reference

## Overview

ALAMS uses **SQLite** as its sole local data store, accessed via the `sqflite` Flutter package. The database file is named `alams.db` and resides in the platform's designated databases directory (resolved by `getDatabasesPath()`).

**Current schema version: 7**

All data lives entirely on the device. Optionally, records are mirrored to a Supabase cloud backend through the `SyncService`, but the SQLite database is always the source of truth for the local device.

---

## Entity-Relationship Diagram

```
┌─────────────────────────────────────┐
│            employees                │
├─────────────────────────────────────┤
│ PK  id               INTEGER        │
│     name             TEXT           │
│     age              INTEGER        │
│     sex              TEXT           │
│     position         TEXT           │
│     department       TEXT  ─────────┼── (loose ref) ──┐
│     emp_id           TEXT           │                  │
│     email            TEXT           │                  ▼
│     is_admin         INTEGER        │  ┌───────────────────────┐
│     facial_embedding TEXT           │  │      departments      │
│     username         TEXT           │  ├───────────────────────┤
│     password         TEXT           │  │ PK  id    INTEGER     │
│     is_deleted       INTEGER        │  │     name  TEXT UNIQUE │
└──────────────┬──────────────────────┘  └───────────────────────┘
               │ id (1)
               │
               │ (N)
┌──────────────▼──────────────────────┐
│           attendance                │
├─────────────────────────────────────┤
│ PK  id           INTEGER            │
│ FK  employee_id  INTEGER            │
│     timestamp    TEXT               │
│     type         TEXT               │
│     status       TEXT               │
└─────────────────────────────────────┘

┌─────────────────────────────────────┐
│         system_settings             │
├─────────────────────────────────────┤
│ PK  key    TEXT                     │
│     value  TEXT                     │
└─────────────────────────────────────┘

┌─────────────────────────────────────┐
│          login_attempts             │
├─────────────────────────────────────┤
│ PK  id         INTEGER              │
│     username   TEXT                 │
│     timestamp  TEXT                 │
│     succeeded  INTEGER              │
└─────────────────────────────────────┘

┌─────────────────────────────────────┐
│           sync_queue                │
├─────────────────────────────────────┤
│ PK  id          INTEGER             │
│     table_name  TEXT                │
│     operation   TEXT                │
│     record_id   INTEGER             │
│     payload     TEXT (JSON)         │
│     created_at  TEXT                │
└─────────────────────────────────────┘
```

---

## Table Definitions

### `employees`

Stores all registered persons: employees, administrators, and soft-deleted former employees.

```sql
CREATE TABLE employees (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  name              TEXT    NOT NULL,
  age               INTEGER NOT NULL,
  sex               TEXT    NOT NULL,
  position          TEXT    NOT NULL,
  department        TEXT    NOT NULL,
  emp_id            TEXT    NOT NULL,
  email             TEXT    NOT NULL DEFAULT "",
  is_admin          INTEGER NOT NULL,
  facial_embedding  TEXT    NOT NULL,
  username          TEXT,
  password          TEXT,
  is_deleted        INTEGER NOT NULL DEFAULT 0
);
```

| Column | Type | Description |
|--------|------|-------------|
| `id` | INTEGER PK | Internal surrogate key |
| `name` | TEXT | Full display name |
| `age` | INTEGER | Age in years |
| `sex` | TEXT | `'Male'`, `'Female'`, or `'Other'` |
| `position` | TEXT | Job title or role label |
| `department` | TEXT | Department name string (denormalized) |
| `emp_id` | TEXT | Human-readable code (e.g., `DEV-001`) |
| `email` | TEXT | Employee email address |
| `is_admin` | INTEGER | `1` = administrator, `0` = employee |
| `facial_embedding` | TEXT | Comma-separated 128 floats (the averaged 5-pose master embedding) |
| `username` | TEXT | Login username; only populated for admins |
| `password` | TEXT | PBKDF2-SHA256 hash string (`pbkdf2$10000$<salt>$<hash>`) |
| `is_deleted` | INTEGER | `1` = soft-deleted; excluded from active queries |

**Notes:**
- `facial_embedding` is stored as a delimited string, parsed back to `List<double>` in `Employee.fromMap()`.
- `username` / `password` are only populated for `is_admin = 1` employees.
- `is_deleted = 1` rows are excluded from `getAllEmployees()` and all dashboard counts, but are joined via `LEFT JOIN` in reports.
- Passwords are stored as PBKDF2 hashes. Legacy plaintext passwords are migrated automatically on first login.

---

### `attendance`

Records every individual attendance event.

```sql
CREATE TABLE attendance (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  employee_id  INTEGER NOT NULL,
  timestamp    TEXT    NOT NULL,
  type         TEXT    NOT NULL,
  status       TEXT    NOT NULL DEFAULT 'Normal',
  FOREIGN KEY (employee_id) REFERENCES employees (id)
);
```

| Column | Type | Description |
|--------|------|-------------|
| `id` | INTEGER PK | Surrogate key |
| `employee_id` | INTEGER FK | References `employees.id` |
| `timestamp` | TEXT | ISO 8601 datetime string (e.g., `2026-04-28T08:02:44.123`) |
| `type` | TEXT | `'IN'` or `'OUT'` |
| `status` | TEXT | Computed classification at write time (see below) |

**Status value domain:**

| Status | Condition |
|--------|-----------|
| `'On Time'` | `type = 'IN'` and time ≤ `work_start` setting |
| `'Late'` | `type = 'IN'` and time > `work_start` setting |
| `'Early Out'` | `type = 'OUT'` and time < `work_end` setting |
| `'Regular Out'` | `type = 'OUT'` and time ≥ `work_end` setting |
| `'Normal'` | Default / legacy records before status feature (schema v5) |

Status is **computed at write time** inside `DatabaseService.insertAttendance()`. This ensures changing work hours settings in the future does not retroactively alter historical records.

---

### `departments`

Reference list of department names.

```sql
CREATE TABLE departments (
  id    INTEGER PRIMARY KEY AUTOINCREMENT,
  name  TEXT    NOT NULL UNIQUE
);
```

Seeded with `'General'` at schema creation. Department names are referenced by string in `employees.department` (not by FK) so that department renames/deletions don't break historical employee records.

---

### `system_settings`

Key-value store for configurable system parameters.

```sql
CREATE TABLE system_settings (
  key    TEXT PRIMARY KEY,
  value  TEXT NOT NULL
);
```

**All settings and defaults:**

| Key | Default | Description |
|-----|---------|-------------|
| `work_start` | `08:00` | Work start time (HH:mm 24-hour). Determines On Time vs. Late. |
| `work_end` | `17:00` | Work end time (HH:mm 24-hour). Determines Early Out vs. Regular Out. |
| `grace_period` | `60` | Minutes after `work_start` before employees are counted as Absent on the dashboard. |
| `device_code` | Random 4-char | Kiosk identifier used as prefix for auto-generated `emp_id`. |
| `id_offset` | Random int | Numeric offset applied to auto-generated employee IDs to prevent ID collisions across multiple kiosk devices. |

Settings are read via `DatabaseService.getSetting(key, defaultValue)` and written via `updateSetting(key, value)` using `ConflictAlgorithm.replace` (UPSERT). All settings changes are also enqueued to `sync_queue` for cloud propagation.

---

### `login_attempts`

Audit table for admin login brute-force protection.

```sql
CREATE TABLE login_attempts (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  username   TEXT    NOT NULL,
  timestamp  TEXT    NOT NULL,
  succeeded  INTEGER NOT NULL DEFAULT 0
);
```

| Column | Description |
|--------|-------------|
| `username` | The username that was attempted |
| `timestamp` | ISO 8601 datetime of the attempt |
| `succeeded` | `1` = successful login, `0` = failed |

**Logic:** Before verifying any password, `validateAdmin()` counts rows where `succeeded = 0` and `timestamp > (now - 15 minutes)` for the given username. If count ≥ 5, login is rejected without attempting password verification. Every attempt (success or failure) inserts a new row regardless.

This table is **not synced to Supabase** — it is device-local security state only.

---

### `sync_queue`

Outbound sync buffer for Supabase writes.

```sql
CREATE TABLE sync_queue (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  table_name  TEXT    NOT NULL,
  operation   TEXT    NOT NULL,
  record_id   INTEGER NOT NULL,
  payload     TEXT    NOT NULL,
  created_at  TEXT    NOT NULL
);
```

| Column | Description |
|--------|-------------|
| `table_name` | Target Supabase table (e.g., `'employees'`, `'attendance'`) |
| `operation` | `'INSERT'`, `'UPDATE'`, or `'DELETE'` |
| `record_id` | Local SQLite row ID of the affected record |
| `payload` | Full record as JSON string |
| `created_at` | ISO 8601 timestamp of when the operation was enqueued |

`SyncService.syncNow()` processes rows in ascending `id` order. Successfully synced rows are deleted. On connectivity restore, the queue is replayed in order, preserving causality.

---

## Schema Migration History

| Version | Changes |
|---------|---------|
| 1 (initial) | `employees` table: `id`, `name`, `facial_embedding` |
| 2 | Added to `employees`: `age`, `sex`, `position`, `emp_id`, `is_admin` |
| 3 | Added to `employees`: `department`, `username`, `password`. Created `departments` table, seeded `'General'` |
| 4 | Added to `employees`: `email` (DEFAULT `""`) |
| 5 | Added to `employees`: `is_deleted` (DEFAULT `0`). Added to `attendance`: `status` (DEFAULT `'Normal'`) |
| 6 | Created `system_settings` table. Seeded `work_start = "08:00"` and `work_end = "17:00"` |
| 7 | Added `grace_period`, `device_code`, `id_offset` to `system_settings`. Created `login_attempts` table. Created `sync_queue` table. |

All migrations are forward-only.

---

## Key Queries

### Get employees currently at work (latest log today is IN)

```sql
SELECT * FROM employees
WHERE (is_admin != 1 OR is_admin IS NULL)
  AND (is_deleted = 0 OR is_deleted IS NULL)
  AND id IN (
    SELECT a.employee_id
    FROM attendance a
    INNER JOIN (
      SELECT employee_id, MAX(timestamp) AS max_ts
      FROM attendance WHERE timestamp LIKE '2026-04-28%'
      GROUP BY employee_id
    ) latest
    ON a.employee_id = latest.employee_id
    AND a.timestamp = latest.max_ts
    WHERE a.type = 'IN'
  );
```

### Get employees absent today (after grace period)

```sql
-- Only runs if NOW > work_start + grace_period (checked in Dart before executing)
SELECT * FROM employees
WHERE (is_admin != 1 OR is_admin IS NULL)
  AND (is_deleted = 0 OR is_deleted IS NULL)
  AND id NOT IN (
    SELECT DISTINCT employee_id FROM attendance
    WHERE timestamp LIKE '2026-04-28%'
  );
```

### Get today's attendance logs with employee names

```sql
SELECT
  a.id,
  a.employee_id,
  a.timestamp,
  a.type,
  a.status,
  e.name       AS employee_name,
  e.emp_id     AS employee_code,
  e.is_deleted AS employee_deleted
FROM attendance a
LEFT JOIN employees e ON a.employee_id = e.id
WHERE a.timestamp LIKE '2026-04-28%'
ORDER BY a.timestamp DESC;
```

`LEFT JOIN` ensures records from soft-deleted employees are still returned; `is_deleted` is checked in Dart to render `[Deleted Employee]`.

### Get last attendance record for an employee (auto IN/OUT detection)

```sql
SELECT * FROM attendance
WHERE employee_id = ?
ORDER BY timestamp DESC
LIMIT 1;
```

### Count recent failed login attempts (brute-force check)

```sql
SELECT COUNT(*) FROM login_attempts
WHERE username = ? AND succeeded = 0 AND timestamp > ?;
-- second ? = (now - 15 minutes) as ISO 8601 string
```

### Insert attendance with status classification (computed in Dart before insert)

```dart
// Status computed in DatabaseService.insertAttendance():
final workStart = await getSetting('work_start', '08:00');
final workEnd   = await getSetting('work_end', '17:00');
final now       = DateTime.now();
String status;

if (attendance.type == 'IN') {
  status = now.isAfter(workStartDateTime) ? 'Late' : 'On Time';
} else {
  status = now.isBefore(workEndDateTime) ? 'Early Out' : 'Regular Out';
}
// Then insert with computed status value
```

---

## Data Integrity Design Decisions

**Why soft deletes?**
Hard-deleting an employee would orphan their `attendance` records. Soft deletes preserve the full audit trail. The `is_deleted` flag is filtered at the query level in all active employee queries.

**Why store `facial_embedding` as TEXT?**
Comma-separated float strings are human-readable for debugging, trivially serializable from Dart's `List<double>`, and fast enough for 128 floats (~600 bytes per record).

**Why is `department` a string in `employees` rather than a FK?**
Department renames and deletions are safe without cascading updates. Historical records accurately reflect the department name at time of registration.

**Why is `timestamp` stored as TEXT?**
ISO 8601 strings sort lexicographically (enabling `LIKE '2026-04-28%'` date filtering), map directly to Dart's `DateTime.toIso8601String()`, and are human-readable.

**Why is `status` computed and stored at write time?**
If status were computed on read from current `work_start`/`work_end` settings, changing those settings would retroactively alter all historical records. Write-time computation captures the policy in effect at the time of each scan.

**Why is `login_attempts` not synced?**
Login attempts are device-local security state. Syncing them would create race conditions in lockout counting across devices and could allow an attacker to reset attempts by triggering a sync from another device.

**Why a `sync_queue` instead of syncing directly on write?**
Direct sync fails silently when offline. A queue provides durability — operations survive connectivity loss, device sleep, and app restarts. Queue processing in ascending ID order preserves the causal ordering of operations (e.g., an employee must be inserted before their attendance records can be synced).
