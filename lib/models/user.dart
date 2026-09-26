enum UserRole { patient, guardian }

extension UserRoleX on UserRole {
  String get label => this == UserRole.guardian ? 'Guardian' : 'Patient';
  String get filipinoLabel =>
      this == UserRole.guardian ? 'Tagapag-alaga' : 'Pasyente';

  static UserRole fromString(String value) {
    return value == 'guardian' ? UserRole.guardian : UserRole.patient;
  }
}

enum PairingStatus { pending, accepted, rejected }

class PairingRecord {
  final String id;
  final String guardianId;
  final String guardianEmail;
  final String patientId;
  final String patientEmail;
  final String pairingCode;
  final PairingStatus status;
  final DateTime createdAt;

  const PairingRecord({
    required this.id,
    required this.guardianId,
    required this.guardianEmail,
    required this.patientId,
    required this.patientEmail,
    required this.pairingCode,
    required this.status,
    required this.createdAt,
  });

  Map<String, dynamic> toFirestore() => {
    'guardianId': guardianId,
    'guardianEmail': guardianEmail,
    'patientId': patientId,
    'patientEmail': patientEmail,
    'pairingCode': pairingCode,
    'status': status.name,
    'createdAt': createdAt.millisecondsSinceEpoch,
  };

  factory PairingRecord.fromFirestore(String id, Map<String, dynamic> data) {
    return PairingRecord(
      id: id,
      guardianId: data['guardianId'] ?? '',
      guardianEmail: data['guardianEmail'] ?? '',
      patientId: data['patientId'] ?? '',
      patientEmail: data['patientEmail'] ?? '',
      pairingCode: data['pairingCode'] ?? '',
      status: PairingStatus.values.firstWhere(
        (s) => s.name == (data['status'] ?? 'pending'),
        orElse: () => PairingStatus.pending,
      ),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (data['createdAt'] ?? DateTime.now().millisecondsSinceEpoch) as int,
      ),
    );
  }

  Map<String, dynamic> toDb() => {
    'id': id,
    'guardian_id': guardianId,
    'guardian_email': guardianEmail,
    'patient_id': patientId,
    'patient_email': patientEmail,
    'pairing_code': pairingCode,
    'status': status.name,
    'created_at': createdAt.toUtc().toIso8601String(),
  };

  factory PairingRecord.fromDb(Map<String, dynamic> data) {
    return PairingRecord(
      id: data['id'] as String,
      guardianId: data['guardian_id'] as String,
      guardianEmail: data['guardian_email'] as String,
      patientId: data['patient_id'] as String,
      patientEmail: data['patient_email'] as String,
      pairingCode: data['pairing_code'] as String,
      status: PairingStatus.values.firstWhere(
        (s) => s.name == (data['status'] ?? 'pending'),
        orElse: () => PairingStatus.pending,
      ),
      createdAt: _parseDate(data['created_at']),
    );
  }

  static DateTime _parseDate(dynamic value) {
    if (value is DateTime) return value;
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    return DateTime.tryParse(value?.toString() ?? '') ?? DateTime.now();
  }
}
