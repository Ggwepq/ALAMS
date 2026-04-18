import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/employee.dart';
import '../models/attendance.dart';
import '../models/department.dart';

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
    final path = join(dbPath, filePath);

    final db = await openDatabase(
      path,
      version: 6, 
      onCreate: _createDB,
      onUpgrade: (db, oldVersion, newVersion) async {
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
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              name TEXT NOT NULL UNIQUE
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
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL
            )
          ''');
          await db.insert('system_settings', {'key': 'work_start', 'value': '08:00'});
          await db.insert('system_settings', {'key': 'work_end', 'value': '17:00'});
        }
      },
    );

    // Seed default admin if none exists
    await _seedDefaultAdmin(db);
    
    return db;
  }

  Future<void> _seedDefaultAdmin(Database db) async {
    final result = await db.rawQuery('SELECT COUNT(*) FROM employees WHERE is_admin = 1');
    final count = Sqflite.firstIntValue(result) ?? 0;
    
    if (count == 0) {
      await db.insert('employees', {
        'name': 'System Admin',
        'age': 0,
        'sex': 'Other',
        'position': 'Administrator',
        'department': 'General',
        'emp_id': 'ADMIN-001',
        'email': 'admin@alams.com',
        'is_admin': 1,
        'facial_embedding': List.filled(128, 0.0).join(','),
        'username': 'admin',
        'password': 'admin',
      });
      print('[Database] Default admin seeded: admin/admin');
    }
  }

  Future _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE employees (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        age INTEGER NOT NULL,
        sex TEXT NOT NULL,
        position TEXT NOT NULL,
        department TEXT NOT NULL,
        emp_id TEXT NOT NULL,
        email TEXT NOT NULL DEFAULT "",
        is_admin INTEGER NOT NULL,
        facial_embedding TEXT NOT NULL,
        username TEXT,
        password TEXT,
        is_deleted INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE attendance (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        employee_id INTEGER NOT NULL,
        timestamp TEXT NOT NULL,
        type TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT "Normal",
        FOREIGN KEY (employee_id) REFERENCES employees (id)
      )
    ''');

    await db.execute('''
      CREATE TABLE departments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE
      )
    ''');
    
    await db.insert('departments', {'name': 'General'});

    await db.execute('''
      CREATE TABLE system_settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');

    await db.insert('system_settings', {'key': 'work_start', 'value': '08:00'});
    await db.insert('system_settings', {'key': 'work_end', 'value': '17:00'});
  }

  Future<int> getEmployeeCount() async {
    final db = await instance.database;
    final result = await db.rawQuery('SELECT COUNT(*) FROM employees WHERE is_admin = 0');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  // ─── Employees ─────────────────────────────────────────────────────────────

  Future<int> insertEmployee(Employee employee) async {
    final db = await instance.database;
    return await db.insert('employees', employee.toMap());
  }

  Future<List<Employee>> getAllEmployees() async {
    final db = await instance.database;
    // Potentially fix NULL values from old migrations
    await db.execute('UPDATE employees SET is_admin = 0 WHERE is_admin IS NULL');
    
    // Exclude admins and deleted employees from general lists
    final result = await db.query('employees', where: 'is_admin != 1 AND is_deleted = 0');
    return result.map((json) => Employee.fromMap(json)).toList();
  }

  Future<Employee?> getAdmin() async {
    final db = await instance.database;
    final result = await db.query('employees', where: 'is_admin = 1', limit: 1);
    if (result.isEmpty) return null;
    return Employee.fromMap(result.first);
  }

  Future<int> deleteEmployee(int id) async {
    final db = await instance.database;
    // Perform SOFT DELETE instead of hard delete
    return await db.update(
      'employees', 
      {'is_deleted': 1}, 
      where: 'id = ?', 
      whereArgs: [id]
    );
  }

  Future<int> updateEmployee(Employee employee) async {
    final db = await instance.database;
    return await db.update(
      'employees',
      employee.toMap(),
      where: 'id = ?',
      whereArgs: [employee.id],
    );
  }

  /// Checks if any employee with administrative privileges exists.
  Future<bool> hasAdmin() async {
    final db = await instance.database;
    final result = await db.rawQuery('SELECT COUNT(*) FROM employees WHERE is_admin = 1');
    final count = Sqflite.firstIntValue(result) ?? 0;
    return count > 0;
  }

  // ─── Attendance ─────────────────────────────────────────────────────────────

  Future<String> insertAttendance(Attendance attendance) async {
    final db = await instance.database;
    
    // FETCH WORK HOURS
    final startRes = await db.query('system_settings', where: 'key = ?', whereArgs: ['work_start']);
    final endRes = await db.query('system_settings', where: 'key = ?', whereArgs: ['work_end']);
    
    final workStartStr = startRes.isNotEmpty ? startRes.first['value'] as String : '08:00';
    final workEndStr = endRes.isNotEmpty ? endRes.first['value'] as String : '17:00';
    
    final partsStart = workStartStr.split(':');
    final startH = int.parse(partsStart[0]);
    final startM = int.parse(partsStart[1]);
    
    final partsEnd = workEndStr.split(':');
    final endH = int.parse(partsEnd[0]);
    final endM = int.parse(partsEnd[1]);

    final now = DateTime.now();
    final int hour = now.hour;
    final int minute = now.minute;
    
    String finalStatus = attendance.status;
    
    if (attendance.type == 'IN') {
      if (hour < startH || (hour == startH && minute <= startM)) {
        finalStatus = 'On Time';
      } else {
        finalStatus = 'Late';
      }
    } else if (attendance.type == 'OUT') {
      if (hour < endH || (hour == endH && minute < endM)) {
        finalStatus = 'Early Out';
      } else {
        finalStatus = 'Regular Out';
      }
    }
    
    final finalAttendance = Attendance(
      id: attendance.id,
      employeeId: attendance.employeeId,
      timestamp: attendance.timestamp,
      type: attendance.type,
      status: finalStatus,
    );

    await db.insert('attendance', finalAttendance.toMap());
    return finalStatus;
  }

  Future<List<Attendance>> getAttendanceLogs() async {
    final db = await instance.database;
    final result = await db.query('attendance', orderBy: 'timestamp DESC');
    return result.map((json) => Attendance.fromMap(json)).toList();
  }

  /// Returns all attendance logs recorded today (local date).
  Future<List<Map<String, dynamic>>> getAttendanceLogsWithNamesToday() async {
    final db = await instance.database;
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final result = await db.rawQuery('''
      SELECT
        a.id,
        a.employee_id,
        a.timestamp,
        a.type,
        e.name AS employee_name,
        e.emp_id AS employee_code,
        e.is_deleted AS employee_deleted
      FROM attendance a
      LEFT JOIN employees e ON a.employee_id = e.id
      WHERE a.timestamp LIKE '$today%'
      ORDER BY a.timestamp DESC
    ''');
    return result;
  }

  /// Returns employees who are currently "At Work" (last log today is 'IN').
  Future<List<Employee>> getCurrentlyAtWork() async {
    final db = await instance.database;
    final today = DateTime.now().toIso8601String().substring(0, 10);
    
    // Subquery to find the latest log ID for each employee today
    final result = await db.rawQuery('''
      SELECT * FROM employees WHERE is_admin = 0 AND is_deleted = 0 AND id IN (
        SELECT a.employee_id 
        FROM attendance a
        INNER JOIN (
          SELECT employee_id, MAX(timestamp) as max_ts
          FROM attendance
          WHERE timestamp LIKE '$today%'
          GROUP BY employee_id
        ) latest ON a.employee_id = latest.employee_id AND a.timestamp = latest.max_ts
        WHERE a.type = 'IN'
      )
    ''');
    
    return result.map((json) => Employee.fromMap(json)).toList();
  }

  /// Returns employees who have zero logs today.
  Future<List<Employee>> getAbsentToday() async {
    final db = await instance.database;
    final today = DateTime.now().toIso8601String().substring(0, 10);
    
    final result = await db.rawQuery('''
      SELECT * FROM employees 
      WHERE is_admin = 0 AND is_deleted = 0 AND id NOT IN (
        SELECT DISTINCT employee_id 
        FROM attendance 
        WHERE timestamp LIKE '$today%'
      )
    ''');
    
    return result.map((json) => Employee.fromMap(json)).toList();
  }

  /// Returns the last attendance record for a given employee so we can suggest
  /// Time In vs Time Out based on their last action.
  Future<Attendance?> getLastAttendanceForEmployee(int employeeId) async {
    final db = await instance.database;
    final result = await db.query(
      'attendance',
      where: 'employee_id = ?',
      whereArgs: [employeeId],
      orderBy: 'timestamp DESC',
      limit: 1,
    );
    if (result.isEmpty) return null;
    return Attendance.fromMap(result.first);
  }

  /// Returns attendance logs joined with the employee name.
  /// Each map has all attendance fields plus 'employee_name'.
  Future<List<Map<String, dynamic>>> getAttendanceLogsWithNames() async {
    final db = await instance.database;
    final result = await db.rawQuery('''
      SELECT
        a.id,
        a.employee_id,
        a.timestamp,
        a.type,
        a.status,
        e.name AS employee_name,
        e.is_deleted AS employee_deleted
      FROM attendance a
      LEFT JOIN employees e ON a.employee_id = e.id
      ORDER BY a.timestamp DESC
    ''');
    return result;
  }

  /// Returns all attendance logs for a specific employee.
  Future<List<Map<String, dynamic>>> getAttendanceLogsForEmployee(int employeeId) async {
    final db = await instance.database;
    final result = await db.rawQuery('''
      SELECT 
        a.id, 
        a.employee_id, 
        a.timestamp, 
        a.type, 
        e.name AS employee_name
      FROM attendance a
      LEFT JOIN employees e ON a.employee_id = e.id
      WHERE a.employee_id = ?
      ORDER BY a.timestamp DESC
    ''', [employeeId]);
    return result;
  }

  /// Same as above but filtered to the current calendar day.
  
  // ─── Admin Security ──────────────────────────────────────────────────────────

  Future<Employee?> validateAdmin(String username, String password) async {
    final db = await instance.database;
    final result = await db.query(
      'employees',
      where: 'username = ? AND password = ? AND is_admin = 1',
      whereArgs: [username, password],
      limit: 1,
    );
    if (result.isEmpty) return null;
    return Employee.fromMap(result.first);
  }

  // ─── Departments ───────────────────────────────────────────────────────────

  Future<int> insertDepartment(Department dept) async {
    final db = await instance.database;
    return await db.insert('departments', dept.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Department>> getAllDepartments() async {
    final db = await instance.database;
    final result = await db.query('departments');
    return result.map((json) => Department.fromMap(json)).toList();
  }

  Future<int> deleteDepartment(int id) async {
    final db = await instance.database;
    return await db.delete('departments', where: 'id = ?', whereArgs: [id]);
  }

  Future<int> updateDepartment(Department dept) async {
    final db = await instance.database;
    return await db.update(
      'departments',
      dept.toMap(),
      where: 'id = ?',
      whereArgs: [dept.id],
    );
  }
  // ─── Settings ─────────────────────────────────────────────────────────────

  Future<String> getSetting(String key, String defaultValue) async {
    final db = await instance.database;
    final res = await db.query('system_settings', where: 'key = ?', whereArgs: [key]);
    if (res.isEmpty) return defaultValue;
    return res.first['value'] as String;
  }

  Future<void> updateSetting(String key, String value) async {
    final db = await instance.database;
    await db.insert(
      'system_settings',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}


