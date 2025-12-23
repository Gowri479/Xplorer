import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:image/image.dart' as img;
import 'package:volume_controller/volume_controller.dart';

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
  double lastVolume = 0.5;
  bool _isInitialized = false;
  bool _isScanning = false;
  Interpreter? interpreter;
  final picker = ImagePicker();
  final FlutterTts tts = FlutterTts();
  final VolumeController volumeController = VolumeController();
  List<String> labels = [];

  String lastResult = "No currency detected";

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    await loadLabels();
    await loadModel();
    await speak("Press volume up to scan currency note");

    // Initialize volume controller
    volumeController.showSystemUI = false;
    
    // Get initial volume to prevent immediate trigger
    lastVolume = await volumeController.getVolume();

    // Listen to volume changes
    volumeController.listener((volume) {
      if (!_isInitialized || !mounted) return;
      
      if (volume > lastVolume) {
        // Volume UP pressed
        scanBill();
      } else if (volume < lastVolume) {
        // Volume DOWN pressed
        speak(lastResult); // Fire and forget for repeat
      }

      lastVolume = volume;
    });
    
    _isInitialized = true;
  }

  Future<void> loadLabels() async {
    try {
      final String labelsText = await rootBundle.loadString('assets/labels.txt');
      labels = labelsText
          .split('\n')
          .where((line) => line.trim().isNotEmpty)
          .map((line) => line.trim().replaceAll(' rupees', ''))
          .toList();
      debugPrint("✅ Labels loaded: $labels");
    } catch (e) {
      debugPrint("❌ Failed to load labels: $e");
      // Fallback to default labels matching labels.txt order
      labels = ["2000", "500", "200", "100", "50"];
    }
  }

  Future<void> loadModel() async {
    try {
      interpreter = await Interpreter.fromAsset(
        'assets/model_unquant.tflite',
      );

      debugPrint("✅ TFLite model loaded");
      await speak("Model loaded successfully");
    } catch (e) {
      debugPrint("❌ Model load failed: $e");
      await speak("Model loading failed");
    }
  }


  Future<void> scanBill() async {
    if (_isScanning) return; // Prevent multiple simultaneous scans
    
    setState(() {
      _isScanning = true;
    });

    try {
      await speak("Scanning currency note");

      final XFile? image =
          await picker.pickImage(source: ImageSource.camera);

      if (image == null) {
        setState(() {
          _isScanning = false;
        });
        return;
      }

      File file = File(image.path);
      String result = predictCurrency(file);

      lastResult = result;
      await speak(result);
    } catch (e) {
      debugPrint("❌ Scan error: $e");
    } finally {
      if (mounted) {
        setState(() {
          _isScanning = false;
        });
      }
    }
  }

  String predictCurrency(File imageFile) {
    try {
      if (interpreter == null) {
        return "Model not loaded";
      }

      final imageBytes = imageFile.readAsBytesSync();
      final decodedImage = img.decodeImage(imageBytes);
      
      if (decodedImage == null) {
        return "Failed to decode image";
      }

      img.Image resized = img.copyResize(decodedImage, width: 224, height: 224);

      var input = List.generate(
          1,
          (_) => List.generate(
              224,
              (_) => List.generate(
                  224, (_) => List.generate(3, (_) => 0.0))));

      for (int y = 0; y < 224; y++) {
        for (int x = 0; x < 224; x++) {
          final pixel = resized.getPixel(x, y);
          input[0][y][x][0] = pixel.r / 255.0;
          input[0][y][x][1] = pixel.g / 255.0;
          input[0][y][x][2] = pixel.b / 255.0;
        }
      }

      var output = List.filled(5, 0.0).reshape([1, 5]);
      interpreter!.run(input, output);

      int index = output[0].indexOf(
        output[0].reduce((a, b) => (a > b) ? a : b),
      );

      if (index >= 0 && index < labels.length) {
        return "₹${labels[index]} rupees note detected";
      } else {
        return "Currency detection failed";
      }
    } catch (e) {
      debugPrint("❌ Prediction error: $e");
      return "Error detecting currency";
    }
  }

  Future<void> speak(String text) async {
    await tts.setLanguage("en-IN");
    await tts.setSpeechRate(0.5);
    await tts.speak(text);
  }

  @override
  void dispose() {
    // Clean up volume controller listener
    try {
      volumeController.removeListener();
    } catch (e) {
      debugPrint("Error removing volume listener: $e");
    }
    // Close TFLite interpreter
    try {
      interpreter?.close();
    } catch (e) {
      debugPrint("Error closing interpreter: $e");
    }
    // Stop TTS
    try {
      tts.stop();
    } catch (e) {
      debugPrint("Error stopping TTS: $e");
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Currency Identifier"),
        backgroundColor: Colors.green,
      ),
      body: const Center(
        child: Text(
          "Volume Up → Scan Currency\nVolume Down → Repeat Result",
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 20),
        ),
      ),
    );
  }
}