import AVFoundation
import Flutter
import Speech

/// Keeps voice commands on the device and emits the same partial/final text
/// events consumed by the Android Vosk command dispatcher in Dart.
final class IOSSpeechBridge {
  private let channel: FlutterMethodChannel
  private let audioEngine = AVAudioEngine()
  private var recognizer: SFSpeechRecognizer?
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var generation = 0
  private var listening = false
  private var tapInstalled = false

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "medisense/ios_speech", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "UNAVAILABLE", message: "Speech bridge was released", details: nil))
        return
      }
      switch call.method {
      case "prepare":
        self.prepare(result: result)
      case "start":
        let args = call.arguments as? [String: Any]
        self.start(locale: args?["locale"] as? String ?? "en-PH", result: result)
      case "stop":
        self.stop()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func prepare(result: @escaping FlutterResult) {
    SFSpeechRecognizer.requestAuthorization { status in
      guard status == .authorized else {
        DispatchQueue.main.async {
          result(FlutterError(code: "SPEECH_PERMISSION", message: "Allow Speech Recognition in Settings to use voice commands.", details: nil))
        }
        return
      }
      AVAudioSession.sharedInstance().requestRecordPermission { allowed in
        DispatchQueue.main.async {
          if allowed {
            result(nil)
          } else {
            result(FlutterError(code: "MICROPHONE_PERMISSION", message: "Allow microphone access in Settings to use voice commands.", details: nil))
          }
        }
      }
    }
  }

  private func start(locale: String, result: @escaping FlutterResult) {
    guard SFSpeechRecognizer.authorizationStatus() == .authorized,
          AVAudioSession.sharedInstance().recordPermission == .granted else {
      result(FlutterError(code: "PERMISSION", message: "Microphone and Speech Recognition access are required.", details: nil))
      return
    }
    stop()

    // Filipino on-device recognition depends on the iOS language assets on the
    // phone. Never silently switch a Filipino command to English recognition.
    let candidates = locale == "fil-PH" ? ["fil-PH", "tl-PH"] : ["en-PH", "en-US"]
    guard let selected = candidates.compactMap({ SFSpeechRecognizer(locale: Locale(identifier: $0)) })
      .first(where: { $0.isAvailable && $0.supportsOnDeviceRecognition }) else {
      result(FlutterError(code: "LANGUAGE_UNAVAILABLE", message: "On-device speech recognition is unavailable for this language on this iPhone.", details: nil))
      return
    }
    recognizer = selected
    let audioSession = AVAudioSession.sharedInstance()
    do {
      try audioSession.setCategory(.record, mode: .measurement)
      try audioSession.setActive(true)
      let request = SFSpeechAudioBufferRecognitionRequest()
      request.shouldReportPartialResults = true
      request.requiresOnDeviceRecognition = true
      request.taskHint = .dictation
      self.request = request

      let input = audioEngine.inputNode
      let format = input.outputFormat(forBus: 0)
      input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
        request.append(buffer)
      }
      tapInstalled = true
      audioEngine.prepare()
      try audioEngine.start()
      listening = true
      generation += 1
      let currentGeneration = generation
      task = selected.recognitionTask(with: request) { [weak self] recognition, error in
        DispatchQueue.main.async {
          guard let self = self, self.listening, self.generation == currentGeneration else { return }
          if let recognition = recognition {
            let text = recognition.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
              self.channel.invokeMethod(recognition.isFinal ? "result" : "partial", arguments: text)
            }
          }
          if let error = error {
            self.channel.invokeMethod("error", arguments: error.localizedDescription)
            self.stop()
          } else if recognition?.isFinal == true {
            self.stop()
          }
        }
      }
      result(nil)
    } catch {
      stop()
      result(FlutterError(code: "AUDIO_START", message: error.localizedDescription, details: nil))
    }
  }

  private func stop() {
    generation += 1
    listening = false
    if audioEngine.isRunning { audioEngine.stop() }
    if tapInstalled {
      audioEngine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }
    request?.endAudio()
    task?.cancel()
    task = nil
    request = nil
    recognizer = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }
}
