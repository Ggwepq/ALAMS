class Department {
  final int? id;
  final String name;

  Department({this.id, required this.name});

  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      'name': name,
    };
    if (id != null) map['id'] = id;
    return map;
  }

  factory Department.fromMap(Map<String, dynamic> map) {
    return Department(
      id: map['id'] as int?,
      name: map['name'] as String,
    );
  }
}
