import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'camera_stream_service.dart';

/// Streams real MJPEG frames from an ESP32 camera's
/// `multipart/x-mixed-replace` HTTP endpoint (see the device firmware's
/// `/stream` handler: each part is `--frame` + a `Content-Type`/
/// `Content-Length` header block + that many bytes of JPEG data). Frames are
/// sliced out of the incoming byte stream using the boundary + Content-Length
/// header, which is exact (unlike scanning for JPEG SOI/EOI markers).
class HttpMjpegCameraStreamService implements CameraStreamService {
  HttpMjpegCameraStreamService(this.uri) {
    _connect();
  }

  final Uri uri;

  final _controller = StreamController<Uint8List>.broadcast();
  final _buffer = BytesBuilder(copy: false);
  http.Client? _client;
  StreamSubscription<List<int>>? _subscription;

  static final _contentLengthPattern = RegExp(r'Content-Length:\s*(\d+)', caseSensitive: false);

  @override
  Stream<Uint8List> get frames => _controller.stream;

  Future<void> _connect() async {
    try {
      final client = http.Client();
      _client = client;
      final response = await client.send(http.Request('GET', uri));
      if (response.statusCode != 200) {
        _controller.addError('HTTP ${response.statusCode}');
        return;
      }
      _subscription = response.stream.listen(
        _onData,
        onError: (Object error) => _controller.addError(error),
        onDone: () => _controller.close(),
        cancelOnError: true,
      );
    } catch (error) {
      _controller.addError(error);
    }
  }

  void _onData(List<int> chunk) {
    _buffer.add(chunk);
    _drainBuffer();
  }

  void _drainBuffer() {
    while (true) {
      final bytes = _buffer.toBytes();
      final boundaryIndex = _indexOf(bytes, _boundaryBytes);
      if (boundaryIndex == -1) return;

      final headerStart = boundaryIndex + _boundaryBytes.length;
      final headerEnd = _indexOf(bytes, _crlfcrlf, headerStart);
      if (headerEnd == -1) return; // headers haven't fully arrived yet

      final headerText = String.fromCharCodes(bytes, headerStart, headerEnd);
      final match = _contentLengthPattern.firstMatch(headerText);
      if (match == null) {
        // Not a real frame part (or malformed) — drop up to here and retry.
        _resetBufferFrom(bytes, headerEnd);
        continue;
      }

      final length = int.parse(match.group(1)!);
      final frameStart = headerEnd + _crlfcrlf.length;
      final frameEnd = frameStart + length;
      if (bytes.length < frameEnd) return; // frame body hasn't fully arrived yet

      _controller.add(Uint8List.fromList(bytes.sublist(frameStart, frameEnd)));
      _resetBufferFrom(bytes, frameEnd);
    }
  }

  void _resetBufferFrom(Uint8List bytes, int index) {
    _buffer.clear();
    _buffer.add(bytes.sublist(index));
  }

  static final _boundaryBytes = '--frame'.codeUnits;
  static const _crlfcrlf = [13, 10, 13, 10];

  int _indexOf(List<int> haystack, List<int> needle, [int start = 0]) {
    for (var i = start; i <= haystack.length - needle.length; i++) {
      var match = true;
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) {
          match = false;
          break;
        }
      }
      if (match) return i;
    }
    return -1;
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _client?.close();
    _controller.close();
  }
}
