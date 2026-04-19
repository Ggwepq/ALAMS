# DATABASE.md — Database Design & Reference

## Overview

ALAMS uses **SQLite** as its sole data store, accessed via the `sqflite` Flutter package. The database file is named `alams.db` and resides in the platform's designated databases directory (resolved by `getDatabasesPath()`). There is no remote database, no synchronization, and no network dependency — all data lives entirely on the device.

**Current schema version: 6**

The database is initialized with `openDatabase(..., version: 6, onCreate: _createDB, onUpgrade: ...)`. All schema changes are tracked through incremental version migrations.

---

## Entity-Relationship Diagram

```
┌─────────────────────────────────┐
│           employees             │
├─────────────────────────────────┤
│ PK  id              INTEGER     │
│     name            TEXT        │
│     age             INTEGER     │
│     sex             TEXT        │
│     position        TEXT        │
│     department      TEXT  ──────┼──── (loose ref, not FK) ──┐
│     emp_id          TEXT        │                            │
│     email           TEXT        │                            │
│     is_admin        INTEGER     │                            ▼
│     facial_embedding TEXT       │     ┌───────────────────────┐
│     username        TEXT        │     │      departments       │
│     password        TEXT        │     ├───────────────────────┤
│     is_deleted      INTEGER     │     │ PK  id    INTEGER      │
└───────────┬─────────────────────┘     │     name  TEXT UNIQUE  │
            │ id                        └───────────────────────┘
            │ 1
            │
            │ N
┌───────────▼─────────────────────┐
│           attendance            │
├─────────────────────────────────┤
│ PK  id              INTEGER     │
│ FK  employee_id     INTEGER     │
│     timestamp       TEXT        │
│     type            TEXT        │
│     status          TEXT        │
└─────────────────────────────────┘

┌─────────────────────────────────┐
│         system_settings         │
├─────────────────────────────────┤
│ PK  key             TEXT        │
│     value           TEXT        │
└─────────────────────────────────┘
```

**Relationships:**
- `attendance.employee_id` → `employees.id` (declared `FOREIGN KEY`, cascade behavior not explicitly set — SQLite enforces this only when `PRAGMA foreign_keys = ON` is active)
- `employees.department` → `departments.name` (loose string reference, not a true FK — intentional for simplicity and to allow historical records to survive department renames/deletions)

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

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | INTEGER | PK, AUTOINCREMENT | Internal surrogate key |
| `name` | TEXT | NOT NULL | Full display name |
| `age` | INTEGER | NOT NULL | Age in years |
| `sex` | TEXT | NOT NULL | `'Male'`, `'Female'`, or `'Other'` |
| `position` | TEXT | NOT NULL | Job title or role label |
| `department` | TEXT | NOT NULL | Department name string |
| `emp_id` | TEXT | NOT NULL | Human-readable employee code (e.g., `EMP-001`) |
| `email` | TEXT | NOT NULL, DEFAULT `""` | Employee email address |
| `is_admin` | INTEGER | NOT NULL | `1` = administrator, `0` = regular employee |
| `facial_embedding` | TEXT | NOT NULL | Comma-separated 128-dim float vector (e.g., `"0.123,0.456,..."`) |
| `username` | TEXT | nullable | Login username; only meaningful for admins |
| `password` | TEXT | nullable | Login password (plaintext — see security note) |
| `is_deleted` | INTEGER | NOT NULL, DEFAULT `0` | `1` = soft-deleted, excluded from normal queries |

**Notes:**
- `facial_embedding` is stored as a delimited string rather than a BLOB for simplicity. On read, it is parsed back to `List<double>` in `Employee.fromMap()`.
- The `username` and `password` fields are only populated for employees with `is_admin = 1`. Regular employees authenticate by face, not credentials.
- `is_deleted = 1` records are excluded from `getAllEmployees()` and `getEmployeeCount()` but are preserved for attendance history integrity.
- **Security note:** Passwords are stored as plaintext. A production deployment should use a hashing algorithm (e.g., SHA-256 with per-record salt) before storing credentials.

---

### `attendance`

Records every individual attendance event (time in and time out).

```sql
CREATE TABLE attendance (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  employee_id  INTEGER NOT NULL,
  timestamp    TEXT    NOT NULL,
  type         TEXT    NOT NULL,
  status       TEXT    NOT NULL DEFAULT "Normal",
  FOREIGN KEY (employee_id) REFERENCES employees (id)
);
```

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | INTEGER | PK, AUTOINCREMENT | Surrogate key |
| `employee_id` | INTEGER | NOT NULL, FK → employees.id | The employee this event belongs to |
| `timestamp` | TEXT | NOT NULL | ISO 8601 datetime string (e.g., `"2026-04-19T08:02:44.123"`) |
| `type` | TEXT | NOT NULL | `'IN'` or `'OUT'` |
| `status` | TEXT | NOT NULL, DEFAULT `"Normal"` | Computed classification (see below) |

**Status value domain:**

| Status | Set When |
|--------|---------|
| `'On Time'` | `type = 'IN'` and current time ≤ `work_start` setting |
| `'Late'` | `type = 'IN'` and current time > `work_start` setting |
| `'Early Out'` | `type = 'OUT'` and current time < `work_end` setting |
| `'Regular Out'` | `type = 'OUT'` and current time ≥ `work_end` setting |
| `'Normal'` | Default / legacy records before status feature was added (schema v5) |

Status is **computed at write time** inside `DatabaseService.insertAttendance()`, not in the UI layer.

**Design note:** Storing status as a denormalized field rather than computing it on read avoids the need to re-evaluate historical records if work hours settings change. The status captured reflects the policy in effect at the time the record was written.

---

### `departments`

A reference list of valid department names used in the employee registration form.

```sql
CREATE TABLE departments (
  id    INTEGER PRIMARY KEY AUTOINCREMENT,
  name  TEXT    NOT NULL UNIQUE
);
```

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | INTEGER | PK, AUTOINCREMENT | Surrogate key |
| `name` | TEXT | NOT NULL, UNIQUE | Department display name |

**Seed data:** A single `'General'` department is inserted at schema creation time and on `onUpgrade` when the `departments` table is first added (v3).

**Design note:** Departments are referenced by name string in `employees.department`, not by foreign key ID. This is a deliberate trade-off: it avoids cascading update complexity and allows the department record to be renamed or deleted without breaking existing employee records. The employee retains whatever department name string they had at registration time.

---

### `system_settings`

A key-value store for application-level configuration.

```sql
CREATE TABLE system_settings (
  key    TEXT PRIMARY KEY,
  value  TEXT NOT NULL
);
```

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `key` | TEXT | PK | Setting identifier string |
| `value` | TEXT | NOT NULL | Setting value as string |

**Seed data (inserted at schema creation and v6 migration):**

| Key | Default Value | Meaning |
|-----|--------------|---------|
| `work_start` | `"08:00"` | Work start time in `HH:mm` 24-hour format |
| `work_end` | `"17:00"` | Work end time in `HH:mm` 24-hour format |

Settings are read by `DatabaseService.getSetting(key, defaultValue)` and written by `updateSetting(key, value)`, using `ConflictAlgorithm.replace` (UPSERT behavior).

---

## Schema Migration History

| Version | Changes |
|---------|---------|
| 1 (initial) | `employees` table: `id`, `name`, `facial_embedding` |
| 2 | Added to `employees`: `age`, `sex`, `position`, `emp_id`, `is_admin` |
| 3 | Added to `employees`: `department`, `username`, `password`. Created `departments` table, seeded `'General'` |
| 4 | Added to `employees`: `email` (DEFAULT `""`) |
| 5 | Added to `employees`: `is_deleted` (DEFAULT `0`). Added to `attendance`: `status` (DEFAULT `"Normal"`) |
| 6 | Created `system_settings` table. Seeded `work_start = "08:00"` and `work_end = "17:00"` |

All migrations are forward-only. Downgrade is not supported — this is standard for SQLite-based mobile apps.

---

## Key Queries

### Get employees currently at work (latest log today is IN)

```sql
SELECT * FROM employees
WHERE is_admin = 0 AND is_deleted = 0
AND id IN (
  SELECT a.employee_id
  FROM attendance a
  INNER JOIN (
    SELECT employee_id, MAX(timestamp) AS max_ts
    FROM attendance
    WHERE timestamp LIKE '2026-04-19%'
    GROUP BY employee_id
  ) latest
  ON a.employee_id = latest.employee_id
  AND a.timestamp = latest.max_ts
  WHERE a.type = 'IN'
);
```

### Get employees absent today (zero logs today)

```sql
SELECT * FROM employees
WHERE is_admin = 0 AND is_deleted = 0
AND id NOT IN (
  SELECT DISTINCT employee_id
  FROM attendance
  WHERE timestamp LIKE '2026-04-19%'
);
```

### Get today's attendance logs with employee names

```sql
SELECT
  a.id,
  a.employee_id,
  a.timestamp,
  a.type,
  e.name     AS employee_name,
  e.emp_id   AS employee_code,
  e.is_deleted AS employee_deleted
FROM attendance a
LEFT JOIN employees e ON a.employee_id = e.id
WHERE a.timestamp LIKE '2026-04-19%'
ORDER BY a.timestamp DESC;
```

Note: `LEFT JOIN` (not `INNER JOIN`) is used so that attendance records from soft-deleted employees are still returned. `is_deleted` is included in the projection so the UI can display `[Deleted Employee]` labels appropriately.

### Get the last attendance record for an employee (for auto IN/OUT detection)

```sql
SELECT * FROM attendance
WHERE employee_id = ?
ORDER BY timestamp DESC
LIMIT 1;
```

### Validate admin credentials

```sql
SELECT * FROM employees
WHERE username = ? AND password = ? AND is_admin = 1
LIMIT 1;
```

---

## Data Integrity Design Decisions

**Why soft deletes?**
Hard-deleting an employee row would orphan all their `attendance` records (FK violation or dangling employee_id). Soft deletes preserve the full audit trail while excluding the employee from active lists. The `is_deleted` flag is filtered at the query level in `getAllEmployees()`.

**Why store `facial_embedding` as TEXT?**
SQLite supports BLOB columns, but handling binary float arrays as BLOBs in Dart/sqflite adds complexity (byte packing/unpacking). Storing as comma-separated string is human-readable for debugging, trivially serializable/deserializable, and fast enough for 128 floats. The tradeoff is slightly larger storage per record (~600 bytes vs ~512 bytes as binary float32).

**Why is `department` a string in `employees` rather than a FK to `departments.id`?**
This makes department renames and deletions safe without cascading updates to all employees. The `departments` table serves as a reference picker in the UI, not a strict relational constraint. Historical records accurately reflect the department name at time of registration.

**Why is `timestamp` stored as TEXT?**
SQLite has no native datetime type — all date/time values are stored as TEXT (ISO 8601), REAL (Julian Day), or INTEGER (Unix epoch). ISO 8601 strings are human-readable, sort lexicographically (allowing `LIKE '2026-04-19%'` date filtering), and map directly to Dart's `DateTime.toIso8601String()` without conversion overhead.

**Why is `status` computed and stored at write time?**
If status were computed at read time from the current `work_start`/`work_end` settings, changing those settings would retroactively alter the meaning of all historical records. Storing status at write time captures the policy in effect when the attendance was recorded, providing an accurate and immutable historical record.