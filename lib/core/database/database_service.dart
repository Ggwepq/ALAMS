import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/employee.dart';
import '../models/attendance.dart';
import '../models/department.dart';
import '../utils/crypto_utils.dart';
import 'package:alams/core/services/sync_service.dart';

class DatabaseService {
  static final DatabaseService instance = DatabaseService._init();
  static Database? _database;

  DatabaseService._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('alams.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path   = join(dbPath, filePath);

    final db = await openDatabase(
      path,
      version: 9,
      onCreate: _createDB,
      onOpen: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        await db.execute('PRAGMA foreign_keys = ON');
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE employees ADD COLUMN age INTEGER DEFAULT 0');
          await db.execute('ALTER TABLE employees ADD COLUMN sex TEXT DEFAULT "Other"');
          await db.execute('ALTER TABLE employees ADD COLUMN position TEXT DEFAULT "Staff"');
          await db.execute('ALTER TABLE employees ADD COLUMN emp_id TEXT DEFAULT "EMP-XXX"');
          await db.execute('ALTER TABLE employees ADD COLUMN is_admin INTEGER DEFAULT 0');
        }
        if (oldVersion < 3) {
          await db.execute('ALTER TABLE employees ADD COLUMN department TEXT DEFAULT "General"');
          await db.execute('ALTER TABLE employees ADD COLUMN username TEXT');
          await db.execute('ALTER TABLE employees ADD COLUMN password TEXT');
          await db.execute('''
            CREATE TABLE departments (
              id   INTEGER PRIMARY KEY AUTOINCREMENT,
              name TEXT    NOT NULL UNIQUE
            )
          ''');
          await db.insert('departments', {'name': 'General'});
        }
        if (oldVersion < 4) {
          await db.execute('ALTER TABLE employees ADD COLUMN email TEXT DEFAULT ""');
        }
        if (oldVersion < 5) {
          await db.execute('ALTER TABLE employees ADD COLUMN is_deleted INTEGER DEFAULT 0');
          await db.execute('ALTER TABLE attendance ADD COLUMN status TEXT DEFAULT "Normal"');
        }
        if (oldVersion < 6) {
          await db.execute('''
            CREATE TABLE system_settings (
              key   TEXT PRIMARY KEY,
              value TEXT NOT NULL
            )
          ''');
          await db.insert('system_settings', {'key': 'work_start', 'value': '08:00'});
          await db.insert('system_settings', {'key': 'work_end',   'value': '17:00'});
        }
        if (oldVersion < 7) {
          await _migratePasswordsToHashed(db);
          await db.execute('''
            CREATE TABLE IF NOT EXISTS login_attempts (
              id        INTEGER PRIMARY KEY AUTOINCREMENT,
              username  TEXT    NOT NULL,
              timestamp TEXT    NOT NULL,
              succeeded INTEGER NOT NULL DEFAULT 0
            )
          ''');
        }
        if (oldVersion < 8) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS sync_queue (
              id         INTEGER PRIMARY KEY AUTOINCREMENT,
              table_name TEXT    NOT NULL,
              operation  TEXT    NOT NULL,
              record_id  INTEGER NOT NULL,
              payload    TEXT    NOT NULL,
              created_at TEXT    NOT NULL
            )
          ''');
        }
        if (oldVersion < 9) {
          await db.insert('system_settings', {'key': 'grace_period', 'value': '60'},
              conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      },
    );
    return db;
  }

  /// Laravel-style database refresh. Wipes everything and re-seeds the admin.
  Future<void> refreshDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'alams.db');
    
    // Close existing connection
    if (_database != null) {
      await _database!.close();
      _database = null;
    }

    // Delete the file
    await deleteDatabase(path);
    print('[DatabaseService] 🗑️ Database file deleted.');

    // Re-initialize and Seed
    _database = await _initDB('alams.db');
    await ensureStaticAdmin();
    print('[DatabaseService] 🌱 Database refreshed and seeded.');
  }

  // ─── Schema Creation ────────────────────────────────────────────────────────

  Future<void> _createDB(Database db, int version) async {
    await db.execute('PRAGMA foreign_keys = ON');

    await db.execute('''
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
      )
    ''');

    await db.execute('''
      CREATE TABLE attendance (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        employee_id INTEGER NOT NULL,
        timestamp   TEXT    NOT NULL,
        type        TEXT    NOT NULL,
        status      TEXT    NOT NULL DEFAULT "Normal",
        FOREIGN KEY (employee_id) REFERENCES employees (id)
      )
    ''');

    await db.execute('''
      CREATE TABLE departments (
        id   INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE
      )
    ''');
    await db.insert('departments', {'name': 'General'});

    await db.execute('''
      CREATE TABLE system_settings (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    await db.insert('system_settings', {'key': 'work_start', 'value': '08:00'});
    await db.insert('system_settings', {'key': 'work_end',   'value': '17:00'});
    await db.insert('system_settings', {'key': 'grace_period', 'value': '60'});
    await db.insert('system_settings', {'key': 'watermark_enabled', 'value': '1'});

    await db.execute('''
      CREATE TABLE login_attempts (
        id        INTEGER PRIMARY KEY AUTOINCREMENT,
        username  TEXT    NOT NULL,
        timestamp TEXT    NOT NULL,
        succeeded INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE sync_queue (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        table_name TEXT    NOT NULL,
        operation  TEXT    NOT NULL,
        record_id  INTEGER NOT NULL,
        payload    TEXT    NOT NULL,
        created_at TEXT    NOT NULL
      )
    ''');
  }

  // ─── Password migration helper ──────────────────────────────────────────────

  static Future<void> _migratePasswordsToHashed(Database db) async {
    final admins = await db.query(
      'employees',
      where: 'is_admin = 1 AND password IS NOT NULL',
    );
    for (final row in admins) {
      final raw = row['password'] as String? ?? '';
      if (raw.isEmpty || CryptoUtils.isHashed(raw)) continue;
      final hashed = await CryptoUtils.hashPasswordAsync(raw);
      await db.update(
        'employees',
        {'password': hashed},
        where:     'id = ?',
        whereArgs: [row['id']],
      );
    }
  }

  // ─── Static Admin ────────────────────────────────────────────────────────────

  Future<void> ensureStaticAdmin() async {
    final db = await instance.database;

    // 🛡️ Check if ANY administrator already exists in the database
    final existingAdmins = await db.query(
      'employees',
      where: 'is_admin = 1',
      limit: 1,
    );

    // If an admin already exists, we do nothing.
    if (existingAdmins.isNotEmpty) {
      print('[DatabaseService] ✅ Admin account already exists. Skipping seed.');
      return;
    }

    // Final safety check: Only insert if the table is truly empty of admins
    final hashedPassword = await CryptoUtils.hashPasswordAsync('Admin1234.');

    await db.insert('employees', {
      'name':             'System Administrator',
      'age':              0,
      'sex':              'Other',
      'position':         'Admin',
      'department':       'General',
      'emp_id':           'ADMIN-001',
      'email':            'admin@alams.com',
      'is_admin':         1,
      'is_deleted':       0,
      'username':         'admin',
      'password':         hashedPassword,
      'facial_embedding': '',
    });
    print('[DatabaseService] 🌱 Initial Master Admin seeded to local database.');
  }

  // ─── Employees ──────────────────────────────────────────────────────────────

  Future<int> insertEmployee(Employee employee) async {
    final db  = await instance.database;
    final map = employee.toMap();
    
    // ✅ Secure Admin Passwords before insertion
    if (employee.isAdmin && employee.password != null && employee.password!.isNotEmpty) {
      if (!CryptoUtils.isHashed(employee.password!)) {
        map['password'] = await CryptoUtils.hashPasswordAsync(employee.password!);
      }
    }

    final newId = await db.insert('employees', map);

    // ✅ facial_embedding is now included in sync
    final syncMap = Map<String, dynamic>.from(map)..['id'] = newId;

    await SyncService.instance.enqueue(
      tableName: 'employees',
      operation: 'INSERT',
      recordId:  newId,
      payload:   syncMap,
    );

    return newId;
  }

  Future<List<Employee>> getAllEmployees() async {
    final db = await instance.database;
    await db.execute('UPDATE employees SET is_admin = 0 WHERE is_admin IS NULL');
    final result = await db.query(
      'employees',
      where: 'is_admin != 1 AND is_deleted = 0',
    );
    return result.map((json) => Employee.fromMap(json)).toList();
  }

  Future<Employee?> getAdmin() async {
    final db     = await instance.database;
    final result = await db.query('employees',
        where: 'is_admin = 1', limit: 1);
    if (result.isEmpty) return null;
    return Employee.fromMap(result.first);
  }


  /// Calculates the next available Employee ID (e.g. EMP-005)
  Future<String> getNextEmployeeId(String prefix) async {
    final db = await instance.database;
    final result = await db.rawQuery('''
      SELECT emp_id FROM employees 
      WHERE emp_id LIKE ? 
      ORDER BY id DESC LIMIT 1
    ''', ['$prefix-%']);

    if (result.isEmpty) return '$prefix-001';

    try {
      final lastId = result.first['emp_id'] as String;
      final parts = lastId.split('-');
      if (parts.length < 2) return '$prefix-001';
      
      final currentNum = int.tryParse(parts.last) ?? 0;
      final nextNum = currentNum + 1;
      return '$prefix-${nextNum.toString().padLeft(3, '0')}';
    } catch (e) {
      return '$prefix-001';
    }
  }

  Future<int> deleteEmployee(int id) async {
    final db     = await instance.database;
    final result = await db.update(
      'employees',
      {'is_deleted': 1},
      where:     'id = ?',
      whereArgs: [id],
    );

    await SyncService.instance.enqueue(
      tableName: 'employees',
      operation: 'DELETE',
      recordId:  id,
      payload:   {'id': id, 'is_deleted': 1},
    );

    return result;
  }

  Future<int> updateEmployee(Employee employee) async {
    final db  = await instance.database;
    final map = employee.toMap();
    if (employee.isAdmin && employee.password != null && employee.password!.isNotEmpty) {
      if (!CryptoUtils.isHashed(employee.password!)) {
        map['password'] = await CryptoUtils.hashPasswordAsync(employee.password!);
      }
    }
    final result = await db.update(
      'employees',
      map,
      where:     'id = ?',
      whereArgs: [employee.id],
    );

    // ✅ facial_embedding is now included in sync
    final syncMap = Map<String, dynamic>.from(map);

    await SyncService.instance.enqueue(
      tableName: 'employees',
      operation: 'UPDATE',
      recordId:  employee.id!,
      payload:   syncMap,
    );

    return result;
  }

  Future<bool> hasAdmin() async {
    final db     = await instance.database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) FROM employees WHERE is_admin = 1',
    );
    return (Sqflite.firstIntValue(result) ?? 0) > 0;
  }

  Future<int> getEmployeeCount() async {
    final db     = await instance.database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) FROM employees WHERE is_admin = 0 AND is_deleted = 0',
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  // ─── Admin Login with Rate Limiting ─────────────────────────────────────────

  static const int _maxFailedAttempts    = 5;
  static const int _lockoutWindowMinutes = 15;

  Future<int> _recentFailedAttempts(Database db, String username) async {
    final cutoff = DateTime.now()
        .subtract(const Duration(minutes: _lockoutWindowMinutes))
        .toIso8601String();
    final result = await db.rawQuery(
      'SELECT COUNT(*) FROM login_attempts WHERE username = ? AND succeeded = 0 AND timestamp > ?',
      [username.toLowerCase(), cutoff],
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<void> _recordLoginAttempt(
      Database db, String username, bool succeeded) async {
    await db.insert('login_attempts', {
      'username':  username.toLowerCase(),
      'timestamp': DateTime.now().toIso8601String(),
      'succeeded': succeeded ? 1 : 0,
    });
  }

  Future<AdminLoginResult> validateAdmin(
      String username, String password) async {
    final db = await instance.database;

    print('[LOGIN] Attempting login for username: $username');

    final failCount = await _recentFailedAttempts(db, username);
    print('[LOGIN] Recent failed attempts: $failCount');

    if (failCount >= _maxFailedAttempts) {
      print('[LOGIN] Account locked out');
      return AdminLoginResult.lockedOut(
          remainingMinutes: _lockoutWindowMinutes);
    }

    final rows = await db.query(
      'employees',
      where:     'username = ? AND is_admin = 1 AND is_deleted = 0',
      whereArgs: [username.toLowerCase()],
      limit:     1,
    );

    print('[LOGIN] Matching rows found: ${rows.length}');

    if (rows.isEmpty) {
      await _recordLoginAttempt(db, username, false);
      print('[LOGIN] No matching admin user found');
      return AdminLoginResult.failure();
    }

    final row            = rows.first;
    final storedPassword = row['password'] as String? ?? '';
    print('[LOGIN] Stored password is hashed: ${CryptoUtils.isHashed(storedPassword)}');
    print('[LOGIN] Stored password is empty: ${storedPassword.isEmpty}');

    bool match;
    if (CryptoUtils.isHashed(storedPassword)) {
      match = await CryptoUtils.verifyPasswordAsync(password, storedPassword);
    } else {
      match = (password == storedPassword);
      if (match) {
        final hashed = await CryptoUtils.hashPasswordAsync(password);
        await db.update(
          'employees',
          {'password': hashed},
          where:     'id = ?',
          whereArgs: [row['id']],
        );
      }
    }

    print('[LOGIN] Password match: $match');

    if (!match) {
      await _recordLoginAttempt(db, username, false);
      final remaining = _maxFailedAttempts - (failCount + 1);
      return AdminLoginResult.failure(
          attemptsRemaining: remaining < 0 ? 0 : remaining);
    }

    await _recordLoginAttempt(db, username, true);
    print('[LOGIN] ✅ Login successful');
    return AdminLoginResult.success(Employee.fromMap(row));
  }

  // ─── Attendance ─────────────────────────────────────────────────────────────

  Future<String> insertAttendance(Attendance attendance) async {
    final db = await instance.database;

    final startRes = await db.query('system_settings',
        where: 'key = ?', whereArgs: ['work_start']);
    final endRes = await db.query('system_settings',
        where: 'key = ?', whereArgs: ['work_end']);

    final workStartStr =
        startRes.isNotEmpty ? startRes.first['value'] as String : '08:00';
    final workEndStr =
        endRes.isNotEmpty ? endRes.first['value'] as String : '17:00';

    final ps     = workStartStr.split(':');
    final pe     = workEndStr.split(':');
    final startH = int.parse(ps[0]), startM = int.parse(ps[1]);
    final endH   = int.parse(pe[0]), endM   = int.parse(pe[1]);

    final now          = DateTime.now();
    String finalStatus = attendance.status;

    if (attendance.type == 'IN') {
      finalStatus =
          (now.hour < startH || (now.hour == startH && now.minute <= startM))
              ? 'On Time'
              : 'Late';
    } else if (attendance.type == 'OUT') {
      finalStatus =
          (now.hour < endH || (now.hour == endH && now.minute < endM))
              ? 'Early Out'
              : 'Regular Out';
    }

    final finalAttendance = Attendance(
      id:         attendance.id,
      employeeId: attendance.employeeId,
      timestamp:  attendance.timestamp,
      type:       attendance.type,
      status:     finalStatus,
    );

    final newId = await db.insert('attendance', finalAttendance.toMap());

    await SyncService.instance.enqueue(
      tableName: 'attendance',
      operation: 'INSERT',
      recordId:  newId,
      payload:   {...finalAttendance.toMap(), 'id': newId},
    );

    return finalStatus;
  }

  Future<List<Attendance>> getAttendanceLogs() async {
    final db     = await instance.database;
    final result = await db.query('attendance', orderBy: 'timestamp DESC');
    return result.map((json) => Attendance.fromMap(json)).toList();
  }

  Future<List<Map<String, dynamic>>>
      getAttendanceLogsWithNamesToday() async {
    final db    = await instance.database;
    final today = DateTime.now().toIso8601String().substring(0, 10);
    return await db.rawQuery('''
      SELECT a.id, a.employee_id, a.timestamp, a.type,
             e.name AS employee_name, e.emp_id AS employee_code,
             e.is_deleted AS employee_deleted
      FROM attendance a
      LEFT JOIN employees e ON a.employee_id = e.id
      WHERE a.timestamp LIKE ?
      ORDER BY a.timestamp DESC
    ''', ['$today%']);
  }

  Future<List<Employee>> getCurrentlyAtWork() async {
    final db    = await instance.database;
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final result = await db.rawQuery('''
      SELECT * FROM employees WHERE is_admin = 0 AND is_deleted = 0 AND id IN (
        SELECT a.employee_id FROM attendance a
        INNER JOIN (
          SELECT employee_id, MAX(timestamp) AS max_ts
          FROM attendance WHERE timestamp LIKE ?
          GROUP BY employee_id
        ) latest ON a.employee_id = latest.employee_id AND a.timestamp = latest.max_ts
        WHERE a.type = 'IN'
      )
    ''', ['$today%']);
    return result.map((json) => Employee.fromMap(json)).toList();
  }

  Future<List<Employee>> getAbsentToday() async {
    final db    = await instance.database;
    final today = DateTime.now();
    final todayStr = today.toIso8601String().substring(0, 10);

    // Fetch settings
    final workStartStr  = await getSetting('work_start', '08:00');
    final gracePeriodStr = await getSetting('grace_period', '60');
    
    final int graceMinutes = int.tryParse(gracePeriodStr) ?? 60;
    final List<String> timeParts = workStartStr.split(':');
    final int startHour = int.parse(timeParts[0]);
    final int startMin  = int.parse(timeParts[1]);

    // Create threshold time
    final DateTime threshold = DateTime(
      today.year,
      today.month,
      today.day,
      startHour,
      startMin,
    ).add(Duration(minutes: graceMinutes));

    // If current time is BEFORE work_start + grace_period, 
    // technically nobody is "officially" absent yet for the day's record (optional design choice).
    // The user requested: "The absent card should show employees who havent timed in 1 hr after the check in time."
    if (today.isBefore(threshold)) {
      return [];
    }

    final result = await db.rawQuery('''
      SELECT * FROM employees
      WHERE is_admin = 0 AND is_deleted = 0
        AND id NOT IN (
          SELECT DISTINCT employee_id FROM attendance WHERE timestamp LIKE ?
        )
    ''', ['$todayStr%']);
    return result.map((json) => Employee.fromMap(json)).toList();
  }

  Future<Attendance?> getLastAttendanceForEmployee(int employeeId) async {
    final db     = await instance.database;
    final result = await db.query('attendance',
        where:     'employee_id = ?',
        whereArgs: [employeeId],
        orderBy:   'timestamp DESC',
        limit:     1);
    if (result.isEmpty) return null;
    return Attendance.fromMap(result.first);
  }

  Future<List<Map<String, dynamic>>> getAttendanceLogsWithNames({bool includeDeleted = false}) async {
    final db = await instance.database;
    String whereClause = includeDeleted ? '' : 'WHERE e.is_deleted = 0 OR e.is_deleted IS NULL';
    
    return await db.rawQuery('''
      SELECT a.id, a.employee_id, a.timestamp, a.type, a.status,
             e.name AS employee_name, e.emp_id AS employee_code, e.is_deleted AS employee_deleted
      FROM attendance a
      LEFT JOIN employees e ON a.employee_id = e.id
      $whereClause
      ORDER BY a.timestamp DESC
    ''');
  }

  Future<List<Map<String, dynamic>>> getAttendanceLogsForEmployee(
      int employeeId) async {
    final db = await instance.database;
    return await db.rawQuery('''
      SELECT a.id, a.employee_id, a.timestamp, a.type, e.name AS employee_name
      FROM attendance a
      LEFT JOIN employees e ON a.employee_id = e.id
      WHERE a.employee_id = ?
      ORDER BY a.timestamp DESC
    ''', [employeeId]);
  }

  // ─── Departments ────────────────────────────────────────────────────────────

  Future<int> insertDepartment(Department dept) async {
    final db    = await instance.database;
    final newId = await db.insert('departments', dept.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);

    await SyncService.instance.enqueue(
      tableName: 'departments',
      operation: 'INSERT',
      recordId:  newId,
      payload:   {...dept.toMap(), 'id': newId},
    );

    return newId;
  }

  Future<List<Department>> getAllDepartments() async {
    final db = await instance.database;
    return (await db.query('departments'))
        .map((j) => Department.fromMap(j))
        .toList();
  }

  Future<int> deleteDepartment(int id) async {
    final db     = await instance.database;
    final result = await db.delete('departments',
        where: 'id = ?', whereArgs: [id]);

    await SyncService.instance.enqueue(
      tableName: 'departments',
      operation: 'DELETE',
      recordId:  id,
      payload:   {'id': id},
    );

    return result;
  }

  Future<int> updateDepartment(Department dept) async {
    final db     = await instance.database;
    final result = await db.update('departments', dept.toMap(),
        where: 'id = ?', whereArgs: [dept.id]);

    await SyncService.instance.enqueue(
      tableName: 'departments',
      operation: 'UPDATE',
      recordId:  dept.id!,
      payload:   dept.toMap(),
    );

    return result;
  }

  // ─── Settings ───────────────────────────────────────────────────────────────

  Future<String> getSetting(String key, String defaultValue) async {
    final db  = await instance.database;
    final res = await db.query('system_settings',
        where: 'key = ?', whereArgs: [key]);
    if (res.isEmpty) return defaultValue;
    return res.first['value'] as String;
  }

  Future<void> updateSetting(String key, String value) async {
    final db = await instance.database;
    await db.insert('system_settings', {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);

    await SyncService.instance.enqueue(
      tableName: 'system_settings',
      operation: 'UPDATE',
      recordId:  0,
      payload:   {'key': key, 'value': value},
    );
  }
}

// ─── Login Result ────────────────────────────────────────────────────────────

enum AdminLoginStatus { success, failure, lockedOut }

class AdminLoginResult {
  final AdminLoginStatus status;
  final Employee?        employee;
  final int?             attemptsRemaining;
  final int?             remainingMinutes;

  const AdminLoginResult._({
    required this.status,
    this.employee,
    this.attemptsRemaining,
    this.remainingMinutes,
  });

  factory AdminLoginResult.success(Employee e) =>
      AdminLoginResult._(status: AdminLoginStatus.success, employee: e);

  factory AdminLoginResult.failure({int? attemptsRemaining}) =>
      AdminLoginResult._(
          status:            AdminLoginStatus.failure,
          attemptsRemaining: attemptsRemaining);

  factory AdminLoginResult.lockedOut({required int remainingMinutes}) =>
      AdminLoginResult._(
          status:           AdminLoginStatus.lockedOut,
          remainingMinutes: remainingMinutes);

  bool get isSuccess => status == AdminLoginStatus.success;
}