import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_state_provider.dart';
import '../providers/voice_navigation_provider.dart';
import '../services/vosk_model_store.dart';
import 'model_download_dialog.dart';

/// Prepares system speech on iOS or the offline Vosk model on Android.
Future<bool> showModelDownloadSheet(BuildContext context) async {
  if (!context.read<AppStateProvider>().voiceNavigationEnabled) return false;
  final voice = context.read<VoiceNavigationProvider>();
  if (voice.isVoskInitialized) return true;
  try {
    if (Platform.isIOS) {
      // iOS has no Vosk download or download sheet. The listener uses Apple's
      // installed on-device speech recognizer for the selected language.
      await voice.initializeVosk(VoskModelStore.iosSystemSpeechPath);
      return true;
    }
    // Validate persistent storage before building a route. Opening the modal
    // first caused a one-frame "Downloading" flash on every fresh app launch,
    // even though prepare() immediately found the existing model.
    final installedPath = await voice.voskModelStore.installedModelPath();
    if (installedPath != null) {
      await voice.initializeVosk(installedPath);
      return true;
    }
    if (!context.mounted) return false;
    final modelPath = await showModelDownloadDialog(
      context,
      store: voice.voskModelStore,
    );
    if (modelPath == null) return false;
    await voice.initializeVosk(modelPath);
    return true;
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not start offline voice. Please try again.'),
        ),
      );
    }
    return false;
  }
}
