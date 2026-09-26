import 'package:flutter/material.dart';
import '../models/user.dart';

class AuthProvider extends ChangeNotifier {
  bool _isLoggedIn = false;
  String? _userId;
  String? _userName;
  String? _userEmail;
  String _tier = 'Free';
  UserRole _role = UserRole.patient;

  String? _pairedPatientId;
  String? _pairedPatientName;

  static const String guestUserId = 'guest';

  bool get isLoggedIn => _isLoggedIn;
  String get userId => _userId ?? guestUserId;
  String get userName => _userName ?? 'Guest';
  String get userEmail => _userEmail ?? '';
  String get tier => _tier;
  UserRole get role => _role;
  bool get isGuardian => _role == UserRole.guardian;
  bool get isPatient => _role == UserRole.patient;

  String? get pairedPatientId => _pairedPatientId;
  String? get pairedPatientName => _pairedPatientName;
  bool get hasPairedPatient => _pairedPatientId != null;

  void login(
    String id,
    String name,
    String email, {
    String tier = 'Free',
    String role = 'patient',
  }) {
    _isLoggedIn = true;
    _userId = id;
    _userName = name;
    _userEmail = email;
    _tier = tier;
    _role = UserRoleX.fromString(role);
    notifyListeners();
  }

  void setPairedPatient(String patientId, String patientName) {
    _pairedPatientId = patientId;
    _pairedPatientName = patientName;
    notifyListeners();
  }

  void clearPairedPatient() {
    _pairedPatientId = null;
    _pairedPatientName = null;
    notifyListeners();
  }

  void updateEmail(String newEmail) {
    _userEmail = newEmail;
    notifyListeners();
  }

  void updateName(String newName) {
    _userName = newName;
    notifyListeners();
  }

  void updateTier(String newTier) {
    _tier = newTier;
    notifyListeners();
  }

  void logout() {
    _isLoggedIn = false;
    _userId = null;
    _userName = null;
    _userEmail = null;
    _tier = 'Free';
    _role = UserRole.patient;
    _pairedPatientId = null;
    _pairedPatientName = null;
    notifyListeners();
  }
}
