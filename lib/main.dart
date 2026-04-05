import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:typed_data';
import 'package:image_picker/image_picker.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:image/image.dart' as img;
import 'package:volume_controller/volume_controller.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:camera/camera.dart'; 
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'camera_screen.dart';     // ← add this line at top

void main() {
  runApp(const CurrencyApp());
}

class CurrencyApp extends StatelessWidget {
  const CurrencyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: CurrencyHome(),
    );
  }
}

class CurrencyHome extends StatefulWidget {
  const CurrencyHome({super.key});

  @override
  State<CurrencyHome> createState() => _CurrencyHomeState();
}

class _CurrencyHomeState extends State<CurrencyHome> {
  // ==================== CONSTANTS ====================
  static const int modelInputSize = 640;
  static const double ttsSpeechRate = 0.5;
  static const String ttsLanguage = "en-IN";

  // BLE Constants (must match Arduino code)
  static const String deviceName = "Umbrella_Locator";
  static const String serviceUuid = "12345678-1234-1234-1234-123456789abc";
  static const String characteristicUuid = "abcd1234-5678-1234-5678-abcdef123456";

  static const String apiUrl = "http://192.168.1.8:8000/detect"; // ← your IP

  // ==================== STATE VARIABLES ====================
  double lastVolume = 0.5;
  bool _isInitialized = false;
  bool _isScanning = false;
  Interpreter? interpreter;
  final picker = ImagePicker();
  final FlutterTts tts = FlutterTts();
  final VolumeController volumeController = VolumeController.instance;
  CameraController? _cameraController;  // ← ADD
  bool _showCamera = false;              // ← ADD
  int _countdown = 3;                    // ← ADD
  bool _captured = false;                // ← ADD

  // BLE related
  BluetoothDevice? _bleDevice;
  bool _isConnecting = false;
  bool _isConnected = false;
  Timer? _buzzerOffTimer;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;

  // Processing flag
  bool _isProcessingVolume = false;

  String lastResult = "No currency detected";
  double lastConfidence = 0.0;

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  // ==================== INITIALIZATION ====================
  Future<void> _initializeApp() async {
    await loadModel();
    await _requestPermissions();
    await _initBle();
    await speak("Currency detector ready. Press volume up to scan note. Volume down activates buzzer.");

    volumeController.showSystemUI = false;
    lastVolume = await volumeController.getVolume();

    volumeController.addListener((double volume) async {
      if (!_isInitialized || !mounted || _isProcessingVolume) return;
      _isProcessingVolume = true;
      try {
        double currentVolume = volume;
        if (currentVolume > lastVolume) {
          await scanCurrency();
        } else if (currentVolume < lastVolume) {
          await _activateBuzzer();
        }
        lastVolume = currentVolume;
      } finally {
        _isProcessingVolume = false;
      }
    });

    _isInitialized = true;
  }

  // ==================== PERMISSIONS ====================
  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      await [
        Permission.bluetooth,
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();
    } else if (Platform.isIOS) {
      await Permission.bluetooth.request();
    }
  }

  // ==================== BLE INITIALIZATION ====================
  Future<void> _initBle() async {
    if (Platform.isAndroid) {
      await FlutterBluePlus.turnOn();
    }
  }

  // ==================== CONNECT TO ESP32 AND SEND "ON" ====================
  Future<void> _activateBuzzer() async {
    if (_isConnecting) {
      await speak("Already connecting, please wait");
      return;
    }

    _buzzerOffTimer?.cancel();

    if (_isConnected && _bleDevice != null) {
      await _sendBleCommand("ON");
      _buzzerOffTimer = Timer(const Duration(seconds: 2), () {
        _sendBleCommand("OFF");
      });
      return;
    }

    setState(() { _isConnecting = true; });
    await speak("Connecting to buzzer");

    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));

      BluetoothDevice? targetDevice;
      bool deviceFound = false;

      await for (var scanResults in FlutterBluePlus.scanResults) {
        for (ScanResult result in scanResults) {
          if (result.device.platformName == deviceName) {
            targetDevice = result.device;
            deviceFound = true;
            break;
          }
        }
        if (deviceFound) break;
      }

      await FlutterBluePlus.stopScan();

      if (targetDevice == null) {
        await speak("Buzzer device not found. Make sure ESP32 is powered on.");
        setState(() { _isConnecting = false; });
        return;
      }

      _connectionSubscription = targetDevice.connectionState.listen((state) {
        if (mounted) {
          setState(() {
            if (state == BluetoothConnectionState.connected) {
              _isConnected = true;
              _bleDevice = targetDevice;
              debugPrint("✅ Connected to ${targetDevice!.platformName}");
            } else if (state == BluetoothConnectionState.disconnected) {
              _isConnected = false;
              _bleDevice = null;
              debugPrint("❌ Disconnected");
            }
          });
        }
      });

      await targetDevice.connect();
      await targetDevice.discoverServices();

      setState(() {
        _bleDevice = targetDevice;
        _isConnected = true;
        _isConnecting = false;
      });

      await speak("Connected to buzzer");
      await _sendBleCommand("ON");

      _buzzerOffTimer = Timer(const Duration(seconds: 2), () {
        _sendBleCommand("OFF");
      });

    } catch (e) {
      debugPrint("BLE connection error: $e");
      await speak("Failed to connect to buzzer");
      setState(() { _isConnecting = false; });
    }
  }

  // ==================== SEND BLE COMMAND ====================
  Future<void> _sendBleCommand(String command) async {
    if (_bleDevice == null) {
      debugPrint("No BLE device");
      return;
    }
    try {
      BluetoothCharacteristic? targetChar;
      for (var service in _bleDevice!.servicesList) {
        if (service.uuid.toString().toLowerCase() == serviceUuid.toLowerCase()) {
          for (var char in service.characteristics) {
            if (char.uuid.toString().toLowerCase() == characteristicUuid.toLowerCase()) {
              targetChar = char;
              break;
            }
          }
        }
      }

      if (targetChar == null) {
        debugPrint("Characteristic not found");
        await speak("Buzzer service error");
        return;
      }

      await targetChar.write(command.codeUnits, withoutResponse: false);
      debugPrint("BLE command '$command' sent");
    } catch (e) {
      debugPrint("Error sending BLE command: $e");
    }
  }

  // ==================== LOAD MODEL ====================
  Future<void> loadModel() async {
    try {
      // CPU only — avoids GPU/NNAPI delegate crashes on most Android devices
      final options = InterpreterOptions()..threads = 4;
      interpreter = await Interpreter.fromAsset(
        'assets/final_model.tflite',
        options: options,
      );
      debugPrint("✅ Model loaded!");
      debugPrint("Input shape:  ${interpreter!.getInputTensor(0).shape}");
      debugPrint("Output shape: ${interpreter!.getOutputTensor(0).shape}");
    } catch (e) {
      debugPrint("❌ Load failed: $e");
      await speak("Model loading failed");
    }
  }
  //URL Launcher

  Future<void> _openStreamlit() async {
    final Uri url = Uri.parse(
      'https://testedcurrencydetection-nzrz4dz6auuzhp8n9trp7t.streamlit.app'
    );
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      await speak("Could not open website");
    }
  }
  // ==================== SCAN CURRENCY ====================
 /* Future<void> scanCurrency() async {
  if (_isScanning) {
    await speak("Already scanning, please wait");
    return;
  }
  setState(() { _isScanning = true; });

  try {
    // 1. Get cameras
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      await speak("No camera found");
      setState(() { _isScanning = false; });
      return;
    }

    // 2. Initialize camera
    _cameraController = CameraController(
      cameras[0],
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    await _cameraController!.initialize();

    // Auto flash
    try {
      await _cameraController!.setFlashMode(FlashMode.auto);
    } catch (e) {
      debugPrint("Flash not supported: $e");
    }

    // 3. Show camera overlay on screen
    setState(() {
      _showCamera = true;
      _countdown = 3;
      _captured = false;
    });

    // 4. Audio + countdown
    await speak("Hold note flat under camera");

    for (int i = 3; i >= 1; i--) {
      if (!mounted) return;
      setState(() => _countdown = i);
      await speak("$i");
      await Future.delayed(const Duration(milliseconds: 300));
    }

    // 5. Capture
    if (!mounted) return;
    setState(() => _captured = true);
    await speak("Capturing");
    await Future.delayed(const Duration(milliseconds: 300));

    final XFile image = await _cameraController!.takePicture();

    // 6. Hide camera
    setState(() => _showCamera = false);
    await _cameraController!.dispose();
    _cameraController = null;

    await speak("Processing");

    // 7. Send to FastAPI
    final request = http.MultipartRequest(
      'POST', Uri.parse(apiUrl),
    );
    request.files.add(
      await http.MultipartFile.fromPath('file', image.path)
    );

    final response = await request.send().timeout(
      const Duration(seconds: 15),
      onTimeout: () => throw Exception("Server timeout"),
    );

    final body = await response.stream.bytesToString();
    final json = jsonDecode(body);

    final message    = json['message']    ?? "No currency detected";
    final confidence = (json['confidence'] ?? 0.0).toDouble();

    setState(() {
      lastResult = message;
      lastConfidence = confidence;
    });

    await speak(message);

  } catch (e) {
    debugPrint("❌ Error: $e");
    setState(() => _showCamera = false);
    await _cameraController?.dispose();
    _cameraController = null;
    await speak("Scanning failed. Please try again.");
  } finally {
    if (mounted) setState(() { _isScanning = false; });
  }
}*/
  Future<void> scanCurrency() async {
    if (_isScanning) {
      await speak("Already scanning, please wait");
      return;
    }
    setState(() { _isScanning = true; });

    try {
      await speak("Hold note steady");

      // Open camera screen with countdown
      final XFile? image = await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => const CameraCountdownScreen(),
        ),
      );

      if (image == null) {
        await speak("Cancelled");
        setState(() { _isScanning = false; });
        return;
      }

      await speak("Processing");

      // Send to FastAPI
      final request = http.MultipartRequest(
        'POST',
        Uri.parse(apiUrl),
      );
      request.files.add(
        await http.MultipartFile.fromPath('file', image.path)
      );

      final response = await request.send().timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw Exception("Server timeout"),
      );

      final body = await response.stream.bytesToString();
      final json = jsonDecode(body);

      final message    = json['message']    ?? "No currency detected";
      final confidence = (json['confidence'] ?? 0.0).toDouble();

      setState(() {
        lastResult = message;
        lastConfidence = confidence;
      });

      await speak(message);

    } catch (e) {
      debugPrint("❌ Error: $e");
      await speak("Scanning failed. Please try again.");
    } finally {
      if (mounted) setState(() { _isScanning = false; });
    }
  }
  // ==================== PREDICT ====================
  Future<DetectionResult> predictCurrency(File imageFile) async {
    if (interpreter == null) {
      return DetectionResult("Model not loaded", 0.0, -1, "Error");
    }
    try {
      // 1. Decode image
      final imageBytes = await imageFile.readAsBytes();
      final decodedImage = img.decodeImage(imageBytes);
      if (decodedImage == null) {
        return DetectionResult("Failed to decode image", 0.0, -1, "Error");
      }

      // 2. Resize to 640x640 — matches Python: Image.open().resize((640, 640))
      const int inputSize = 640;
      final resized = img.copyResize(decodedImage, width: inputSize, height: inputSize);

      // 3. Build input buffer in CHW order [1, 3, 640, 640]
      //    Matches Python: np.transpose(input_data, (2, 0, 1)) → CHW
      final inputBuffer = Float32List(1 * 3 * inputSize * inputSize);
      int idx = 0;
      for (int c = 0; c < 3; c++) {
        for (int y = 0; y < inputSize; y++) {
          for (int x = 0; x < inputSize; x++) {
            final pixel = resized.getPixel(x, y);
            // Matches Python: input_data / 255.0
            inputBuffer[idx++] = (c == 0
                ? pixel.r
                : c == 1
                    ? pixel.g
                    : pixel.b) /
                255.0;
          }
        }
      }

      // 4. Read output tensor shape dynamically
      //    Python confirms shape is [1, 12, 8400] → numChannels=12, numPredictions=8400
      final outputShape = interpreter!.getOutputTensor(0).shape;
      debugPrint("Output shape: $outputShape");

      if (outputShape.length != 3) {
        return DetectionResult("Unexpected output shape", 0.0, -1, "Error");
      }

      final int numChannels    = outputShape[1]; // 12  (4 bbox + 8 classes)
      final int numPredictions = outputShape[2]; // 8400
      final int numClasses     = numChannels - 4; // 8

      // 5. Allocate output buffer and run inference
      //    IMPORTANT: reshape input to match [1, 3, 640, 640] as nested structure
      //    tflite_flutter accepts Float32List directly when shapes match
      final outputBuffer = Float32List(1 * numChannels * numPredictions);

      interpreter!.run(inputBuffer.buffer, outputBuffer.buffer);

      final startTime = DateTime.now().millisecondsSinceEpoch;
      final inferenceTime = DateTime.now().millisecondsSinceEpoch - startTime;

      // 6. Parse detections — mirrors Python logic:
      //    preds = output[0].T  →  iterate i across 8400, c across classes
      //    score = pred[4 + c]  →  output[(4+c) * numPredictions + i]
      double bestConfidence = 0.0;
      int bestClassIndex = -1;
      const double detectionThreshold = 0.92; // same as Python: if conf > 0.92

      for (int i = 0; i < numPredictions; i++) {
        double maxScore = 0.0;
        int maxClass = -1;

        for (int c = 0; c < numClasses; c++) {
          final double score = outputBuffer[(4 + c) * numPredictions + i];
          if (score > maxScore) {
            maxScore = score;
            maxClass = c;
          }
        }

        if (maxScore > detectionThreshold && maxScore > bestConfidence) {
          bestConfidence = maxScore;
          bestClassIndex = maxClass;
        }
      }

      // 7. Class names — must match Python CLASSES list order exactly:
      //    ["₹10","₹20","₹50","₹100","₹200","₹500","₹2000","not_currency"]
      const List<String> classNames = [
        "10", "20", "50", "100", "200", "500", "2000", "not_currency"
      ];

      final String denomination = (bestClassIndex >= 0 && bestClassIndex < classNames.length)
          ? classNames[bestClassIndex]
          : "unknown";

      // 8. Spoken message — mirrors Python confidence check logic
      String spokenMessage;
      if (bestClassIndex < 0 || bestClassIndex >= classNames.length) {
        // Nothing passed detectionThreshold — same as Python "No currency detected"
        spokenMessage = "No currency detected";
      } else if (bestClassIndex == classNames.length - 1) {
        // Last class is not_currency (index 7)
        spokenMessage = "This does not appear to be a currency note";
      } else if (bestConfidence > 0.8) {
        switch (denomination) {
          case "2000": spokenMessage = "Two thousand rupees detected"; break;
          case "500":  spokenMessage = "Five hundred rupees detected"; break;
          case "200":  spokenMessage = "Two hundred rupees detected"; break;
          case "100":  spokenMessage = "One hundred rupees detected"; break;
          case "50":   spokenMessage = "Fifty rupees detected"; break;
          case "20":   spokenMessage = "Twenty rupees detected"; break;
          case "10":   spokenMessage = "Ten rupees detected"; break;
          default:     spokenMessage = "₹$denomination detected";
        }
      } else if (bestConfidence > 0.6) {
        spokenMessage = "I think this is ₹$denomination";
      } else {
        spokenMessage = "Please try again with better lighting";
      }

      debugPrint("📊 Prediction (${inferenceTime}ms): $denomination "
          "${(bestConfidence * 100).toStringAsFixed(1)}%");

      return DetectionResult(
        spokenMessage,
        bestConfidence,
        bestClassIndex,
        denomination,
        inferenceTime: inferenceTime,
      );

    } catch (e) {
      debugPrint("❌ Prediction error: $e");
      return DetectionResult("Error detecting currency", 0.0, -1, "Error",
          errorMessage: e.toString());
    }
  }

  // ==================== TEXT-TO-SPEECH ====================
  Future<void> speak(String text) async {
    try {
      await tts.setLanguage(ttsLanguage);
      await tts.setSpeechRate(ttsSpeechRate);
      await tts.setVolume(1.0);
      await tts.speak(text);
      debugPrint("🗣️ TTS: $text");
    } catch (e) {
      debugPrint("❌ TTS error: $e");
    }
  }

  // ==================== CLEANUP ====================
  @override
  void dispose() {
    _buzzerOffTimer?.cancel();
    _connectionSubscription?.cancel();
    volumeController.removeListener();
    interpreter?.close();
    tts.stop();
    super.dispose();
  }

  // ==================== UI ====================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Currency Identifier",
            style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.green,
        foregroundColor: Colors.white,
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.green.shade50, Colors.white],
          ),
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                      color: Colors.green.shade100, shape: BoxShape.circle),
                  child: const Icon(Icons.currency_rupee,
                      size: 64, color: Colors.green),
                ),
                const SizedBox(height: 40),
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                          color: Colors.grey.withValues(alpha: 0.2),
                          spreadRadius: 2,
                          blurRadius: 8)
                    ],
                  ),
                  child: Column(
                    children: [
                      const Text("Volume Controls",
                          style: TextStyle(
                              fontSize: 20, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 16),
                      _buildInstructionRow(Icons.volume_up, "Press Volume Up",
                          "Scan currency note"),
                      const Divider(height: 24),
                      _buildInstructionRow(Icons.volume_down,
                          "Press Volume Down", "Activate buzzer (BLE)"),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: _isConnected
                        ? Colors.green.shade100
                        : Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.bluetooth,
                        size: 16,
                        color: _isConnected ? Colors.green : Colors.grey),
                    const SizedBox(width: 4),
                    Text(
                      _isConnected
                          ? "Buzzer Connected"
                          : "Buzzer Not Connected",
                      style: TextStyle(
                          fontSize: 12,
                          color: _isConnected ? Colors.green : Colors.grey),
                    ),
                  ]),
                ),
                const SizedBox(height: 20),
                if (lastResult != "No currency detected")
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.green.shade50,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.green.shade200),
                    ),
                    child: Column(children: [
                      const Text("Last Detection",
                          style:
                              TextStyle(fontSize: 14, color: Colors.grey)),
                      const SizedBox(height: 8),
                      Text(lastResult,
                          style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.green),
                          textAlign: TextAlign.center),
                      if (lastConfidence > 0)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            "${(lastConfidence * 100).toStringAsFixed(1)}% confidence",
                            style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey.shade600),
                          ),
                        ),
                    ]),
                  ),
                const SizedBox(height: 20),
                if (_isScanning || _isConnecting)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 12),
                    decoration: BoxDecoration(
                        color: Colors.green,
                        borderRadius: BorderRadius.circular(30)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2)),
                      const SizedBox(width: 12),
                      Text(
                        _isConnecting ? "Connecting..." : "Scanning...",
                        style: const TextStyle(
                            color: Colors.white, fontSize: 16),
                      ),
                    ]),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInstructionRow(IconData icon, String title, String subtitle) {
    return Row(children: [
      Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
            color: Colors.green.shade100,
            borderRadius: BorderRadius.circular(8)),
        child: Icon(icon, color: Colors.green),
      ),
      const SizedBox(width: 16),
      Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title,
            style: const TextStyle(
                fontSize: 16, fontWeight: FontWeight.w500)),
        Text(subtitle,
            style: TextStyle(fontSize: 14, color: Colors.grey.shade600)),
      ])),
    ]);
  }
}

class DetectionResult {
  final String message;
  final double confidence;
  final int index;
  final String denomination;
  final int inferenceTime;
  final List<double> allProbabilities;
  final String? errorMessage;

  DetectionResult(this.message, this.confidence, this.index, this.denomination,
      {this.inferenceTime = 0,
      this.allProbabilities = const [],
      this.errorMessage});

  bool get isConfident => confidence >= 0.7;
  bool get isError => errorMessage != null;
}