import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/employee.dart';
import '../models/attendance.dart';

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
      version: 2, // Increased version for migration
      onCreate: _createDB,
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE employees ADD COLUMN age INTEGER DEFAULT 0');
          await db.execute('ALTER TABLE employees ADD COLUMN sex TEXT DEFAULT "Other"');
          await db.execute('ALTER TABLE employees ADD COLUMN position TEXT DEFAULT "Staff"');
          await db.execute('ALTER TABLE employees ADD COLUMN emp_id TEXT DEFAULT "EMP-XXX"');
          await db.execute('ALTER TABLE employees ADD COLUMN is_admin INTEGER DEFAULT 0');
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
        emp_id TEXT NOT NULL,
        is_admin INTEGER NOT NULL,
        facial_embedding TEXT NOT NULL
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
  }

  Future<int> getEmployeeCount() async {
    final db = await instance.database;
    final result = await db.rawQuery('SELECT COUNT(*) FROM employees');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  // ─── Employees ─────────────────────────────────────────────────────────────

  Future<int> insertEmployee(Employee employee) async {
    final db = await instance.database;
    return await db.insert('employees', employee.toMap());
  }

  Future<List<Employee>> getAllEmployees() async {
    final db = await instance.database;
    final result = await db.query('employees');
    return result.map((json) => Employee.fromMap(json)).toList();
  }

  Future<int> deleteEmployee(int id) async {
    final db = await instance.database;
    return await db.delete('employees', where: 'id = ?', whereArgs: [id]);
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
  Future<List<Attendance>> getAttendanceLogsToday() async {
    final db = await instance.database;
    final today = DateTime.now().toIso8601String().substring(0, 10); // "YYYY-MM-DD"
    final result = await db.query(
      'attendance',
      where: "timestamp LIKE ?",
      whereArgs: ['$today%'],
      orderBy: 'timestamp DESC',
    );
    return result.map((json) => Attendance.fromMap(json)).toList();
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
  Future<List<Map<String, dynamic>>> getAttendanceLogsWithNamesToday() async {
    final db = await instance.database;
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final result = await db.rawQuery('''
      SELECT
        a.id,
        a.employee_id,
        a.timestamp,
        a.type,
        e.name AS employee_name
      FROM attendance a
      LEFT JOIN employees e ON a.employee_id = e.id
      WHERE a.timestamp LIKE '$today%'
      ORDER BY a.timestamp DESC
    ''');
    return result;
  }
}


