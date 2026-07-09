import 'dart:typed_data';

/// Source of camera frames for the live view. The concrete implementation
/// ([HttpMjpegCameraStreamService]) parses an MJPEG multipart HTTP stream from
/// the ESP32 camera and pushes each JPEG frame through this `Stream<Uint8List>`
/// contract, so the UI never has to know where the frames come from.
abstract class CameraStreamService {
  Stream<Uint8List> get frames;

  void dispose();
}
