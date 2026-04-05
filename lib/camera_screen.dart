import 'package:flutter/material.dart';
import 'package:camera/camera.dart';

class CameraCountdownScreen extends StatefulWidget {
  const CameraCountdownScreen({super.key});

  @override
  State<CameraCountdownScreen> createState() => _CameraCountdownScreenState();
}

class _CameraCountdownScreenState extends State<CameraCountdownScreen> {
  CameraController? _controller;
  int _countdown = 3;
  bool _captured = false;
  String _status = "Hold note steady";

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      if (mounted) Navigator.pop(context, null);
      return;
    }

    _controller = CameraController(
      cameras[0],
      ResolutionPreset.high,
      enableAudio: false,
    );

    await _controller!.initialize();

    // Auto flash based on exposure
    try {
      await _controller!.setFlashMode(FlashMode.auto);
    } catch (e) {
      debugPrint("Flash not supported: $e");
    }

    if (mounted) {
      setState(() {});
      _startCountdown();
    }
  }

  Future<void> _startCountdown() async {
    for (int i = 3; i >= 1; i--) {
      if (!mounted) return;
      setState(() {
        _countdown = i;
        _status = "Hold note steady";
      });
      await Future.delayed(const Duration(seconds: 1));
    }

    if (!mounted) return;
    setState(() {
      _captured = true;
      _status = "Capturing...";
    });

    await Future.delayed(const Duration(milliseconds: 300));

    try {
      final XFile image = await _controller!.takePicture();

      // ✅ Pop FIRST while camera is still alive (no flicker)
      if (mounted) Navigator.pop(context, image);

      // ✅ Dispose AFTER pop — prevents the red frame
      await Future.delayed(const Duration(milliseconds: 150));
      await _controller?.dispose();
      _controller = null;

    } catch (e) {
      debugPrint("Capture error: $e");
      if (mounted) Navigator.pop(context, null);
    }
  }

  @override
  void dispose() {
    // Only dispose if not already disposed by _startCountdown
    if (_controller != null && _controller!.value.isInitialized) {
      _controller!.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null || !_controller!.value.isInitialized) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Live camera preview
          CameraPreview(_controller!),

          // Dark overlay
          Container(
            color: Colors.black.withOpacity(0.3),
          ),  

          // Countdown circle
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Container(
                  width: 100,
                  height: 100,
                  margin: const EdgeInsets.only(bottom: 60),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _captured
                        ? Colors.green.withOpacity(0.9)
                        : Colors.black.withOpacity(0.6),
                    border: Border.all(
                      color: Colors.transparent,
                      width: 3,
                    ),
                  ),
                  child: Center(
                    child: _captured
                        ? const Icon(Icons.check,
                            color: Colors.white, size: 50)
                        : Text(
                            "$_countdown",
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 48,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                  ),
                ),

                // Status text
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 8),
                  margin: const EdgeInsets.only(bottom: 40),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.6),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    _status,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Flash indicator top right
          Positioned(
            top: 50,
            right: 20,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.6),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.flash_auto,
                color: Colors.yellow,
                size: 24,
              ),
            ),
          ),

          // Cancel button
          Positioned(
            top: 50,
            left: 20,
            child: GestureDetector(
              onTap: () {
                _controller?.dispose();
                Navigator.pop(context, null);
              },
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.6),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.close,
                  color: Colors.white,
                  size: 24,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}