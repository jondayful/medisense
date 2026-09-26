import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:pointycastle/export.dart';

/// Salted PBKDF2-HMAC-SHA256 password/reset-code hashing.
///
/// Stored format: `<tag>$<iterations>$<saltB64>$<hashB64>`.
/// `tag` separates namespaces so a reset-code hash can never verify as a
/// password. Legacy pre-PBKDF2 hashes (unsalted 8-hex) verify via
/// [legacyHash] so existing accounts keep working; callers rehash them on
/// the next successful login.
const String passwordTag = 'pbkdf2';
const String resetTag = 'reset';
const int _iterations = 100000;
const int _saltLength = 16;
const int _keyLength = 32;

String pbkdf2Hash(String input, {required String tag}) {
  final random = Random.secure();
  final salt = Uint8List(_saltLength);
  for (var i = 0; i < _saltLength; i++) {
    salt[i] = random.nextInt(256);
  }
  final hash = _derive(input, tag, salt, _iterations);
  return '$tag\$$_iterations\$${base64Encode(salt)}\$${base64Encode(hash)}';
}

bool verifyPbkdf2(String input, String stored) {
  final parts = stored.split(r'$');
  if (parts.length != 4) return false;
  final iterations = int.tryParse(parts[1]);
  if (iterations == null) return false;
  final List<int> salt, expected;
  try {
    salt = base64Decode(parts[2]);
    expected = base64Decode(parts[3]);
  } on FormatException {
    return false;
  }
  return _constantTimeEquals(
    _derive(input, parts[0], salt, iterations),
    expected,
  );
}

/// Password hash (new format). Same function name as the pre-upgrade helper,
/// now backed by PBKDF2.
String hashPassword(String password) => pbkdf2Hash(password, tag: passwordTag);

/// Verifies a password against a stored hash of either format.
bool verifyPassword(String password, String storedHash) {
  if (storedHash.startsWith('$passwordTag\$')) {
    return verifyPbkdf2(password, storedHash);
  }
  return legacyHash(password) == storedHash;
}

bool isLegacyFormat(String storedHash) =>
    !storedHash.startsWith('$passwordTag\$');

/// The original pre-PBKDF2 hash, kept only to verify hashes stored before
/// the upgrade. Unsalted and weak; rehash on next successful login.
String legacyHash(String input) {
  var h = 0x7A3F9B1C;
  final combined = 'medisense^salt^v2^$input';
  for (var round = 0; round < 10000; round++) {
    for (var i = 0; i < combined.length; i++) {
      h = ((h << 5) + h) ^ combined.codeUnitAt(i);
      h &= 0xFFFFFFFF;
    }
  }
  return h.toRadixString(16).padLeft(8, '0');
}

List<int> _derive(String input, String tag, List<int> salt, int iterations) {
  final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
    ..init(Pbkdf2Parameters(Uint8List.fromList(salt), iterations, _keyLength));
  return derivator.process(Uint8List.fromList(utf8.encode('$tag:$input')));
}

bool _constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
