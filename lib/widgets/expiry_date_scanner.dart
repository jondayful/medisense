import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../models/accessibility_mode.dart';
import '../providers/app_state_provider.dart';
import '../services/medicine_expiry_parser.dart';
import '../theme/app_theme.dart';

/// Opens an on-device camera OCR flow for a printed expiration date.
class ExpiryDateScannerScreen extends StatefulWidget {
  const ExpiryDateScannerScreen({super.key});

  static Future<MedicineExpiryInfo?> open(BuildContext context) {
    return Navigator.of(context).push<MedicineExpiryInfo>(
      MaterialPageRoute<MedicineExpiryInfo>(
        builder: (_) => const ExpiryDateScannerScreen(),
        fullscreenDialog: true,
      ),
    );
  }

  @override
  State<ExpiryDateScannerScreen> createState() =>
      _ExpiryDateScannerScreenState();
}

class _ExpiryDateScannerScreenState extends State<ExpiryDateScannerScreen> {
  final TextRecognizer _recognizer = TextRecognizer(
    script: TextRecognitionScript.latin,
  );
  CameraController? _camera;
  bool _loading = true;
  bool _scanning = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_initializeCamera());
  }

  @override
  void dispose() {
    final camera = _camera;
    if (camera != null) unawaited(camera.dispose());
    unawaited(_recognizer.close());
    super.dispose();
  }

  Future<void> _initializeCamera() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      var permission = await Permission.camera.status;
      if (!permission.isGranted) permission = await Permission.camera.request();
      if (!permission.isGranted) {
        throw const _ExpiryScanException(
          'Camera permission is needed to scan.',
        );
      }
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw const _ExpiryScanException('No camera is available.');
      }
      final camera = CameraController(
        cameras.firstWhere(
          (camera) => camera.lensDirection == CameraLensDirection.back,
          orElse: () => cameras.first,
        ),
        ResolutionPreset.high,
        enableAudio: false,
      );
      await camera.initialize();
      if (!mounted) {
        await camera.dispose();
        return;
      }
      _camera = camera;
      setState(() => _loading = false);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error is _ExpiryScanException
            ? error.message
            : 'The camera could not be opened.';
      });
    }
  }

  Future<void> _captureAndRead() async {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized || _scanning) return;
    setState(() {
      _scanning = true;
      _error = null;
    });
    String? imagePath;
    try {
      final image = await camera.takePicture();
      imagePath = image.path;
      final recognized = await _recognizer.processImage(
        InputImage.fromFilePath(image.path),
      );
      final candidates = MedicineExpiryParser.scanCandidates(recognized.text);
      if (!mounted) return;
      if (candidates.isEmpty) {
        setState(() {
          _scanning = false;
          _error =
              'No clear month and year found. Center only the expiration date and try again.';
        });
        return;
      }
      if (candidates.length > 1) {
        setState(() {
          _scanning = false;
          _error =
              'Several dates were found. Center only the expiration date and scan again.';
        });
        return;
      }
      final candidate = candidates.single;
      final large = context
          .read<AppStateProvider>()
          .accessibilityMode
          .usesLargeText;
      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Confirm expiration date'),
          content: Text(
            '${candidate.hasExpiryLabel ? 'The EXP date' : 'The date "${candidate.recognizedText}"'} '
            'looks like ${MedicineExpiryParser.format(candidate.info)}. '
            'Is this the expiration date printed on the medicine? '
            'Check that it is not a manufacturing or lot date.',
            style: TextStyle(fontSize: large ? 20 : 16, height: 1.35),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Scan again'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Use date'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (confirmed == true) {
        Navigator.of(context).pop(candidate.info);
      } else {
        setState(() => _scanning = false);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _scanning = false;
          _error =
              'I could not read that image. Adjust the label and try again.';
        });
      }
    } finally {
      if (imagePath != null) {
        try {
          await File(imagePath).delete();
        } catch (_) {}
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final large = context.select<AppStateProvider, bool>(
      (state) => state.accessibilityMode.usesLargeText,
    );
    final foreground = isDark ? AppTheme.darkTextPrimary : AppTheme.inkText;
    final accent = isDark ? AppTheme.darkAccentGreen : AppTheme.ink;
    final camera = _camera;

    return Scaffold(
      appBar: AppBar(title: const Text('Scan expiration date')),
      body: Column(
        children: [
          Expanded(
            child: ColoredBox(
              color: Colors.black,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (camera?.value.isInitialized == true)
                    Center(child: CameraPreview(camera!))
                  else if (_loading)
                    const Center(child: CircularProgressIndicator())
                  else
                    _CameraUnavailable(
                      message: _error ?? 'Camera unavailable.',
                      onRetry: _initializeCamera,
                    ),
                  if (camera?.value.isInitialized == true) ...[
                    IgnorePointer(
                      child: Center(
                        child: Container(
                          width: MediaQuery.sizeOf(context).width * .82,
                          height: 150,
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.white, width: 2),
                            borderRadius: BorderRadius.circular(18),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 20,
                      right: 20,
                      bottom: 20,
                      child: Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: .68),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Text(
                          'Center the expiration month and year. EXP text is optional.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: large ? 20 : 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_error != null && camera?.value.isInitialized == true)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: large ? 18 : 14,
                      ),
                    ),
                  ),
                FilledButton.icon(
                  onPressed: camera?.value.isInitialized == true && !_scanning
                      ? _captureAndRead
                      : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: accent,
                    foregroundColor: Colors.white,
                    minimumSize: Size.fromHeight(large ? 64 : 56),
                  ),
                  icon: _scanning
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.camera_alt_outlined),
                  label: Text(
                    _scanning ? 'Reading date…' : 'Scan expiration date',
                    style: TextStyle(fontSize: large ? 20 : 16),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Dates without EXP can be scanned. Confirm the result before saving.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: foreground,
                    fontSize: large ? 16 : 13,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CameraUnavailable extends StatelessWidget {
  const _CameraUnavailable({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 18),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Try again'),
            style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
          ),
        ],
      ),
    ),
  );
}

class _ExpiryScanException implements Exception {
  const _ExpiryScanException(this.message);

  final String message;
}
