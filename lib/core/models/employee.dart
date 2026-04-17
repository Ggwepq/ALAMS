class Employee {
  final int? id;
  final String name;
  final int age;
  final String sex;
  final String position;
  final String empId; // Auto-generated ID (e.g. EMP-001)
  final bool isAdmin;
  final List<double> facialEmbedding;

  Employee({
    this.id,
    required this.name,
    required this.age,
    required this.sex,
    required this.position,
    required this.empId,
    this.isAdmin = false,
    required this.facialEmbedding,
  });

  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      'name': name,
      'age': age,
      'sex': sex,
      'position': position,
      'emp_id': empId,
      'is_admin': isAdmin ? 1 : 0,
      'facial_embedding': facialEmbedding.join(','),
    };
    if (id != null) map['id'] = id;
    return map;
  }

  factory Employee.fromMap(Map<String, dynamic> map) {
    return Employee(
      id: map['id'] as int?,
      name: map['name'] as String,
      age: map['age'] as int? ?? 0,
      sex: map['sex'] as String? ?? 'Other',
      position: map['position'] as String? ?? 'Staff',
      empId: map['emp_id'] as String? ?? 'EMP-XXX',
      isAdmin: (map['is_admin'] as int? ?? 0) == 1,
      facialEmbedding: (map['facial_embedding'] as String)
          .split(',')
          .map((e) => double.parse(e))
          .toList(),
    );
  }
}
