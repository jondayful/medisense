/// Base type for user-facing OCR workflow failures.
abstract class OcrCoordinatorException implements Exception {
  const OcrCoordinatorException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// ML Kit could not produce a usable result and the device has no network.
class OfflineScanUnclearException extends OcrCoordinatorException {
  const OfflineScanUnclearException()
    : super('The medicine label could not be read clearly.');
}

class CloudQuotaExceededException extends OcrCoordinatorException {
  const CloudQuotaExceededException({required this.dailyLimit})
    : super(
        'Your free plan includes $dailyLimit cloud-assisted scans per day. '
        'Try again tomorrow or upgrade your plan.',
      );

  final int dailyLimit;
}

class UnsupportedOcrSubscriptionTierException extends OcrCoordinatorException {
  const UnsupportedOcrSubscriptionTierException(String tier)
    : super('OCR is not configured for subscription tier "$tier".');
}

class OcrScanUnclearException extends OcrCoordinatorException {
  const OcrScanUnclearException()
    : super(
        'The medicine label could not be read clearly. Check the label and '
        'try another scan.',
      );
}

class CloudQuotaStorageException extends OcrCoordinatorException {
  const CloudQuotaStorageException()
    : super('Cloud scan usage could not be saved. Please try again.');
}

class MlKitOcrException extends OcrCoordinatorException {
  const MlKitOcrException() : super('On-device text recognition failed.');
}

class CloudVisionException extends OcrCoordinatorException {
  const CloudVisionException(super.message);
}

class CloudVisionConfigurationException extends CloudVisionException {
  const CloudVisionConfigurationException()
    : super(
        'Cloud Vision is not configured. Add a restricted Google Cloud Vision '
        'API key to this build.',
      );
}

class CloudVisionTimeoutException extends CloudVisionException {
  const CloudVisionTimeoutException()
    : super('Cloud Vision did not respond within four seconds.');
}

class CloudVisionImageException extends CloudVisionException {
  const CloudVisionImageException(super.message);
}
