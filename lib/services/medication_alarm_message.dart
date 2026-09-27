import 'greeting_name.dart';

String medicationAlarmMessage({
  required String? name,
  required String medicineName,
}) {
  final greeting = resolveGreetingName([name]) ?? 'kaibigan';
  return 'Hello $greeting, Inom ka na ng ${medicineName.trim()}.';
}
