/// The same requirements are used when creating, resetting, or changing a
/// password. Symbols match the characters accepted by Supabase Auth.
class PasswordRules {
  const PasswordRules._();

  static final RegExp _symbol = RegExp(
    r'''[!@#$%^&*()_+\-=\[\]{};'":|<>?,./`~]''',
  );

  static bool hasLength(String value) => value.length >= 8;
  static bool hasUppercase(String value) => RegExp(r'[A-Z]').hasMatch(value);
  static bool hasLowercase(String value) => RegExp(r'[a-z]').hasMatch(value);
  static bool hasNumber(String value) => RegExp(r'[0-9]').hasMatch(value);
  static bool hasSymbol(String value) => _symbol.hasMatch(value);

  static bool isValid(String value) =>
      hasLength(value) &&
      hasUppercase(value) &&
      hasLowercase(value) &&
      hasNumber(value) &&
      hasSymbol(value);
}
