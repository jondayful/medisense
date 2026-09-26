import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'ocr_coordinator_exceptions.dart';

/// Sends a captured image to the Google Cloud Vision REST API.
///
/// Supply `CLOUD_VISION_API_KEY_ANDROID` and `CLOUD_VISION_API_KEY_IOS` with
/// `--dart-define` at build time. Google API keys in a mobile app are
/// extractable: create separate keys, restrict each to the Vision API, then
/// apply Android package/signing-certificate or iOS bundle-ID restrictions.
/// Never put service-account credentials in the app.
class CloudVisionService {
  CloudVisionService({
    http.Client? client,
    String? apiKey,
    this.timeout = const Duration(seconds: 4),
    this.maxImageBytes = 10 * 1024 * 1024,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _apiKey = (apiKey ?? _buildTimeApiKey).trim() {
    if (timeout <= Duration.zero || maxImageBytes <= 0) {
      throw ArgumentError(
        'Cloud Vision timeout and image limit must be positive.',
      );
    }
  }

  final http.Client _client;
  final bool _ownsClient;
  final String _apiKey;
  final Duration timeout;
  final int maxImageBytes;
  bool _disposed = false;

  static String get _buildTimeApiKey {
    if (Platform.isAndroid) {
      const androidKey = String.fromEnvironment('CLOUD_VISION_API_KEY_ANDROID');
      if (androidKey.isNotEmpty) return androidKey;
    } else if (Platform.isIOS) {
      const iosKey = String.fromEnvironment('CLOUD_VISION_API_KEY_IOS');
      if (iosKey.isNotEmpty) return iosKey;
    }
    return const String.fromEnvironment('CLOUD_VISION_API_KEY');
  }

  bool get isConfigured => _apiKey.isNotEmpty && !_disposed;

  /// Performs DOCUMENT_TEXT_DETECTION directly from the captured file bytes.
  /// The response contains recognized text only; API errors never include the
  /// request URL or key in their exception messages.
  Future<String> recognizeDocument(String imagePath) async {
    if (_disposed) throw StateError('Cloud Vision service is disposed.');
    if (_apiKey.isEmpty) throw const CloudVisionConfigurationException();

    final imageFile = File(imagePath);
    late final int imageLength;
    try {
      if (!await imageFile.exists()) {
        throw const CloudVisionImageException('The captured image is missing.');
      }
      imageLength = await imageFile.length();
    } on CloudVisionImageException {
      rethrow;
    } on FileSystemException {
      throw const CloudVisionImageException(
        'The captured image is unavailable.',
      );
    }
    if (imageLength <= 0) {
      throw const CloudVisionImageException('The captured image is empty.');
    }
    if (imageLength > maxImageBytes) {
      throw CloudVisionImageException(
        'The captured image is larger than ${maxImageBytes ~/ (1024 * 1024)} MB.',
      );
    }

    late final List<int> imageBytes;
    try {
      imageBytes = await imageFile.readAsBytes();
    } on FileSystemException {
      throw const CloudVisionImageException(
        'The captured image is unavailable.',
      );
    }

    final uri = Uri.https('vision.googleapis.com', '/v1/images:annotate', {
      'key': _apiKey,
    });
    final body = jsonEncode({
      'requests': [
        {
          'image': {'content': base64Encode(imageBytes)},
          'features': [
            {'type': 'DOCUMENT_TEXT_DETECTION'},
          ],
        },
      ],
    });

    late final http.Response response;
    try {
      response = await _client
          .post(
            uri,
            headers: const {'Content-Type': 'application/json'},
            body: body,
          )
          .timeout(timeout);
    } on TimeoutException {
      throw const CloudVisionTimeoutException();
    } on http.ClientException {
      throw const CloudVisionException('Cloud Vision could not be reached.');
    } on SocketException {
      throw const CloudVisionException('Cloud Vision could not be reached.');
    }

    final decoded = _decodeResponse(response);
    final responses = decoded['responses'];
    if (responses is! List || responses.isEmpty || responses.first is! Map) {
      throw const CloudVisionException(
        'Cloud Vision returned an invalid response.',
      );
    }
    final result = Map<String, dynamic>.from(responses.first as Map);
    final apiError = result['error'];
    if (apiError is Map) {
      final code = apiError['code'];
      throw CloudVisionException(
        code is int
            ? 'Cloud Vision rejected the scan (error $code).'
            : 'Cloud Vision rejected the scan.',
      );
    }
    final annotation = result['fullTextAnnotation'];
    if (annotation is! Map || annotation['text'] is! String) return '';
    return (annotation['text'] as String).trim();
  }

  Map<String, dynamic> _decodeResponse(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw CloudVisionException(
        'Cloud Vision request failed (HTTP ${response.statusCode}).',
      );
    }
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException {
      // Report a stable, non-sensitive error below.
    }
    throw const CloudVisionException('Cloud Vision returned invalid JSON.');
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_ownsClient) _client.close();
  }
}
