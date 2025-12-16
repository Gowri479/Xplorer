import 'dart:io';
import 'package:flutter/material.dart';
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
  late Interpreter interpreter;
  final picker = ImagePicker();
  final FlutterTts tts = FlutterTts();

  String lastResult = "No currency detected";

  @override
  void initState() {
    super.initState();
    loadModel();
    speak("Press volume up to scan currency note");

    // 🔥 NEW VOLUME WATCHER LISTENER
    VolumeController().showSystemUI = false;

  // Listen to volume changes
  VolumeController().listener((volume) {
    if (volume > lastVolume) {
      // Volume UP pressed
      scanBill();
    } else if (volume < lastVolume) {
      // Volume DOWN pressed
      speak(lastResult);
    }

    lastVolume = volume;
  });
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
    speak("Scanning currency note");

    final XFile? image =
        await picker.pickImage(source: ImageSource.camera);

    if (image == null) return;

    File file = File(image.path);
    String result = predictCurrency(file);

    lastResult = result;
    speak(result);
  }

  String predictCurrency(File imageFile) {
    img.Image original = img.decodeImage(imageFile.readAsBytesSync())!;
    img.Image resized = img.copyResize(original, width: 224, height: 224);

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

    var output = List.filled(6, 0.0).reshape([1, 6]);
    interpreter.run(input, output);

    int index = output[0].indexOf(
      output[0].reduce((a, b) => (a > b) ? a : b),
    );

    List<String> labels = ["10", "20", "50", "100", "200", "500"];
    return "₹${labels[index]} rupees note detected";
  }

  Future<void> speak(String text) async {
    await tts.setLanguage("en-IN");
    await tts.setSpeechRate(0.5);
    await tts.speak(text);
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