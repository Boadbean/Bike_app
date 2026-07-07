import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Displays the latest frame from a `Stream<Uint8List>` of encoded images.
/// Works the same whether the bytes come from a mock generator or a real
/// MJPEG source, since both hand it standalone image bytes.
class MjpegView extends StatefulWidget {
  const MjpegView({super.key, required this.frames});

  final Stream<Uint8List> frames;

  @override
  State<MjpegView> createState() => _MjpegViewState();
}

class _MjpegViewState extends State<MjpegView> {
  Uint8List? _latestFrame;
  StreamSubscription<Uint8List>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(covariant MjpegView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.frames != widget.frames) {
      _subscription?.cancel();
      _subscribe();
    }
  }

  void _subscribe() {
    _subscription = widget.frames.listen((frame) {
      if (mounted) {
        setState(() => _latestFrame = frame);
      }
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final frame = _latestFrame;
    if (frame == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Image.memory(
      frame,
      gaplessPlayback: true,
      fit: BoxFit.contain,
    );
  }
}
