class Employee {
  final int? id;
  final String name;
  final List<double> facialEmbedding;

  Employee({
    this.id,
    required this.name,
    required this.facialEmbedding,
  });

  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      'name': name,
      'facial_embedding': facialEmbedding.join(','),
    };
    if (id != null) map['id'] = id;
    return map;
  }

  factory Employee.fromMap(Map<String, dynamic> map) {
    return Employee(
      id: map['id'] as int?,
      name: map['name'] as String,
      facialEmbedding: (map['facial_embedding'] as String)
          .split(',')
          .map((e) => double.parse(e))
          .toList(),
    );
  }
}
