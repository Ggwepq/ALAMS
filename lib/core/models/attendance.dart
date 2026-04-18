class Attendance {
  final int? id;
  final int employeeId;
  final String timestamp;
  final String type; // 'IN' or 'OUT'
  final String status; // 'On Time', 'Late', 'Early Out', 'Regular Out'

  Attendance({
    this.id,
    required this.employeeId,
    required this.timestamp,
    required this.type,
    this.status = 'Normal',
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'employee_id': employeeId,
      'timestamp': timestamp,
      'type': type,
      'status': status,
    };
  }

  factory Attendance.fromMap(Map<String, dynamic> map) {
    return Attendance(
      id: map['id'] as int?,
      employeeId: map['employee_id'] as int,
      timestamp: map['timestamp'] as String,
      type: map['type'] as String,
      status: map['status'] as String? ?? 'Normal',
    );
  }
}
