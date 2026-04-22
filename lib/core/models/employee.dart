class Employee {
  final int? id;
  final String name;
  final int age;
  final String sex;
  final String position;
  final String department;
  final String empId;
  final String email;
  final bool isAdmin;
  final List<double> facialEmbedding;
  final String? username;
  final String? password;
  final bool isDeleted;

  Employee({
    this.id,
    required this.name,
    required this.age,
    required this.sex,
    required this.position,
    required this.department,
    required this.empId,
    this.email = '',
    this.isAdmin = false,
    required this.facialEmbedding,
    this.username,
    this.password,
    this.isDeleted = false,
  });

  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      'name':             name,
      'age':              age,
      'sex':              sex,
      'position':         position,
      'department':       department,
      'emp_id':           empId,
      'email':            email,
      'is_admin':         isAdmin ? 1 : 0,
      'facial_embedding': facialEmbedding.join(','),
      'username':         username,
      'password':         password,
      'is_deleted':       isDeleted ? 1 : 0,
    };
    if (id != null) map['id'] = id;
    return map;
  }

  factory Employee.fromMap(Map<String, dynamic> map) {
    // Safely parse facial_embedding — empty or null returns empty list
    List<double> parseFacialEmbedding(dynamic raw) {
      if (raw == null) return [];
      final str = raw as String;
      if (str.trim().isEmpty) return [];
      try {
        return str
            .split(',')
            .where((e) => e.trim().isNotEmpty)
            .map((e) => double.parse(e.trim()))
            .toList();
      } catch (_) {
        return [];
      }
    }

    return Employee(
      id:               map['id'] as int?,
      name:             map['name'] as String,
      age:              map['age'] as int? ?? 0,
      sex:              map['sex'] as String? ?? 'Other',
      position:         map['position'] as String? ?? 'Staff',
      department:       map['department'] as String? ?? 'General',
      empId:            map['emp_id'] as String? ?? 'EMP-XXX',
      email:            map['email'] as String? ?? '',
      isAdmin:          (map['is_admin'] as int? ?? 0) == 1,
      username:         map['username'] as String?,
      password:         map['password'] as String?,
      isDeleted:        (map['is_deleted'] as int? ?? 0) == 1,
      facialEmbedding:  parseFacialEmbedding(map['facial_embedding']),
    );
  }
}