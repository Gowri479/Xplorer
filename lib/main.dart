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
  // ==================== CONSTANTS ====================
  static const int modelInputSize = 224;
  static const int numClasses = 6;
  static const double confidenceThreshold = 0.8;
  static const double ttsSpeechRate = 0.5;
  static const String ttsLanguage = "en-IN";
  
  // ==================== STATE VARIABLES ====================
  double lastVolume = 0.5;
  bool _isInitialized = false;
  bool _isScanning = false;
  Interpreter? interpreter;
  final picker = ImagePicker();
  final FlutterTts tts = FlutterTts();
 
  final VolumeController volumeController = VolumeController.instance;
  
  // Processing flag to prevent multiple rapid triggers
  bool _isProcessingVolume = false;
  
  // Labels will be loaded from file
  List<String> labels = [];
  
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
    await speak("Currency detector ready. Press volume up to scan note.");
    
    // Initialize volume controller
    volumeController.showSystemUI = false;
    
    // Get initial volume to prevent immediate trigger
    lastVolume = await volumeController.getVolume();

    // Listener for volume buttons
    volumeController.addListener((double volume) async {
      if (!_isInitialized || !mounted || _isProcessingVolume) return;
      
      _isProcessingVolume = true;
      
      try {
        double currentVolume = volume;
        
        if (currentVolume > lastVolume) {
          // Volume UP pressed - Scan currency
          await scanCurrency();
        } else if (currentVolume < lastVolume) {
          // Volume DOWN pressed - Repeat last result
          await speak(lastResult);
        }

        lastVolume = currentVolume;
      } finally {
        _isProcessingVolume = false;
      }
    });
    
    _isInitialized = true;
  }

  // ==================== LOAD HIGH ACCURACY MODEL ====================
  Future<void> loadModel() async {
    try {
      // Load the new 99.8% accuracy model
      interpreter = await Interpreter.fromAsset('assets/currency_model_99.8.tflite');
      
      // Load labels for the model
      final String labelsText = await rootBundle.loadString('assets/labels_new.txt');
      labels = labelsText
          .split('\n')
          .where((line) => line.trim().isNotEmpty)
          .map((line) => line.trim())
          .toList();
      
      final inputShape = interpreter!.getInputTensor(0).shape;
      final outputShape = interpreter!.getOutputTensor(0).shape;
      
      debugPrint("✅ HIGH ACCURACY MODEL LOADED SUCCESSFULLY!");
      debugPrint("📊 Input shape: $inputShape");
      debugPrint("📊 Output shape: $outputShape");
      debugPrint("📊 Labels: $labels");
      
      await speak("High accuracy model loaded successfully");
      
    } catch (e) {
      debugPrint("❌ Model failed to load: $e");
      await speak("Model loading failed. Please restart app.");
      
      // Show error to user
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Failed to load AI model. Check assets."),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // ==================== SCAN CURRENCY USING CAMERA ====================
  Future<void> scanCurrency() async {
    if (_isScanning) {
      await speak("Already scanning, please wait");
      return;
    }
    
    setState(() {
      _isScanning = true;
    });

    try {
      await speak("Scanning currency note");

      final XFile? image = await picker.pickImage(
        source: ImageSource.camera,
        maxWidth: modelInputSize * 2,
        maxHeight: modelInputSize * 2,
        imageQuality: 90,
      );

      if (image == null) {
        setState(() { _isScanning = false; });
        return;
      }

      final result = await predictCurrency(File(image.path));
      
      setState(() {
        lastResult = result.message;
        lastConfidence = result.confidence;
      });
      
      await speak(result.message);
      
      debugPrint("✅ Detection: ${result.message} (${(result.confidence * 100).toStringAsFixed(1)}%)");
      
    } catch (e) {
      debugPrint("❌ Scan error: $e");
      await speak("Scanning failed, please try again");
    } finally {
      if (mounted) {
        setState(() { _isScanning = false; });
      }
    }
  }

  // ==================== PREDICT CURRENCY DENOMINATION ====================
  Future<DetectionResult> predictCurrency(File imageFile) async {
    if (interpreter == null) {
      return DetectionResult(
        "Model not loaded", 
        0.0, 
        -1, 
        "Error: Model not loaded"
      );
    }

    try {
      final imageBytes = await imageFile.readAsBytes();
      final decodedImage = img.decodeImage(imageBytes);
      
      if (decodedImage == null) {
        return DetectionResult(
          "Failed to decode image", 
          0.0, 
          -1, 
          "Image decoding failed"
        );
      }

      img.Image resized = img.copyResize(
        decodedImage, 
        width: modelInputSize, 
        height: modelInputSize
      );

      var input = List.generate(
        1,
        (_) => List.generate(
          modelInputSize,
          (_) => List.generate(
            modelInputSize, 
            (_) => List.generate(3, (_) => 0.0)
          )
        )
      );

      for (int y = 0; y < modelInputSize; y++) {
        for (int x = 0; x < modelInputSize; x++) {
          final pixel = resized.getPixel(x, y);
          input[0][y][x][0] = pixel.r / 255.0;
          input[0][y][x][1] = pixel.g / 255.0;
          input[0][y][x][2] = pixel.b / 255.0;
        }
      }

      var output = List.filled(numClasses, 0.0).reshape([1, numClasses]);
      
      final startTime = DateTime.now().millisecondsSinceEpoch;
      interpreter!.run(input, output);
      final inferenceTime = DateTime.now().millisecondsSinceEpoch - startTime;

      List<double> probabilities = output[0].cast<double>();
      
      double maxConfidence = probabilities.reduce((a, b) => a > b ? a : b);
      int predictedIndex = probabilities.indexOf(maxConfidence);
      
      // Get denomination from loaded labels
      String denomination = predictedIndex >= 0 && predictedIndex < labels.length 
          ? labels[predictedIndex] 
          : "Unknown";
      
      // Generate spoken message based on denomination
      String spokenMessage;
      if (maxConfidence < 0.6) {
        spokenMessage = "I'm not sure, please try again with better lighting";
      } else if (maxConfidence < confidenceThreshold) {
        spokenMessage = "I think this is ₹$denomination";
      } else {
        // Handle different denomination spoken formats
        switch (denomination) {
          case "2000":
            spokenMessage = "Two thousand rupees detected";
            break;
          case "500":
            spokenMessage = "Five hundred rupees detected";
            break;
          case "200":
            spokenMessage = "Two hundred rupees detected";
            break;
          case "100":
            spokenMessage = "One hundred rupees detected";
            break;
          case "50":
            spokenMessage = "Fifty rupees detected";
            break;
          case "20":
            spokenMessage = "Twenty rupees detected";
            break;
          case "10":
            spokenMessage = "Ten rupees detected";
            break;
          default:
            spokenMessage = "₹$denomination rupees detected";
        }
      }

      debugPrint("\n📊 Prediction Results (Inference: ${inferenceTime}ms):");
      debugPrint("   Using HIGH ACCURACY MODEL (99.8%)");
      for (int i = 0; i < probabilities.length; i++) {
        String label = i < labels.length ? labels[i] : "Class $i";
        debugPrint("   ₹$label: ${(probabilities[i] * 100).toStringAsFixed(1)}%");
      }
      debugPrint("🎯 Selected: ₹$denomination (${(maxConfidence * 100).toStringAsFixed(1)}%)\n");

      return DetectionResult(
        spokenMessage,
        maxConfidence,
        predictedIndex,
        denomination,
        inferenceTime: inferenceTime,
        allProbabilities: probabilities,
      );

    } catch (e) {
      debugPrint("❌ Prediction error: $e");
      return DetectionResult(
        "Error detecting currency", 
        0.0, 
        -1, 
        "Error",
        errorMessage: e.toString()
      );
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
    try {
      volumeController.removeListener();
    } catch (e) {
      debugPrint("Error removing volume listener: $e");
    }
    
    try {
      interpreter?.close();
    } catch (e) {
      debugPrint("Error closing interpreter: $e");
    }
    
    try {
      tts.stop();
    } catch (e) {
      debugPrint("Error stopping TTS: $e");
    }
    
    super.dispose();
  }

  // ==================== UI BUILD ====================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          "Currency Identifier",
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.green,
        foregroundColor: Colors.white,
        elevation: 0,
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
                    color: Colors.green.shade100,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.currency_rupee,
                    size: 64,
                    color: Colors.green,
                  ),
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
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      const Text(
                        "Volume Controls",
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 16),
                      _buildInstructionRow(
                        Icons.volume_up,
                        "Press Volume Up",
                        "Scan currency note",
                      ),
                      const Divider(height: 24),
                      _buildInstructionRow(
                        Icons.volume_down,
                        "Press Volume Down",
                        "Repeat last result",
                      ),
                    ],
                  ),
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
                    child: Column(
                      children: [
                        const Text(
                          "Last Detection",
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          lastResult,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.green,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        if (lastConfidence > 0)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              "${(lastConfidence * 100).toStringAsFixed(1)}% confidence",
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey.shade600,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                
                const SizedBox(height: 20),
                
                if (_isScanning)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.green,
                      borderRadius: BorderRadius.circular(30),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        ),
                        SizedBox(width: 12),
                        Text(
                          "Scanning...",
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInstructionRow(IconData icon, String title, String subtitle) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.green.shade100,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: Colors.green),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey.shade600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ==================== DATA CLASS ====================
class DetectionResult {
  final String message;
  final double confidence;
  final int index;
  final String denomination;
  final int inferenceTime;
  final List<double> allProbabilities;
  final String? errorMessage;

  DetectionResult(
    this.message,
    this.confidence,
    this.index,
    this.denomination, {
    this.inferenceTime = 0,
    this.allProbabilities = const [],
    this.errorMessage,
  });

  bool get isConfident => confidence >= 0.7;
  bool get isError => errorMessage != null;
}