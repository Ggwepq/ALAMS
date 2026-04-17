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

    return await openDatabase(
      path,
      version: 4, // Increased version for Phase 11 refinement
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
          
          // Seed initial department
          await db.insert('departments', {'name': 'General'});
        }
        if (oldVersion < 4) {
          await db.execute('ALTER TABLE employees ADD COLUMN email TEXT DEFAULT ""');
        }
      },
    );
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
        password TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE attendance (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        employee_id INTEGER NOT NULL,
        timestamp TEXT NOT NULL,
        type TEXT NOT NULL,
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
    
    // Exclude admins from general lists
    final result = await db.query('employees', where: 'is_admin != 1');
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
    return await db.delete('employees', where: 'id = ?', whereArgs: [id]);
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

  Future<int> insertAttendance(Attendance attendance) async {
    final db = await instance.database;
    return await db.insert('attendance', attendance.toMap());
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
        e.emp_id AS employee_code
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
      SELECT * FROM employees WHERE is_admin = 0 AND id IN (
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
      WHERE is_admin = 0 AND id NOT IN (
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
        e.name AS employee_name
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
}


