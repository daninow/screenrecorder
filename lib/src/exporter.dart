import 'dart:ui' as ui show ImageByteFormat;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as image;
import 'package:screen_recorder/src/frame.dart';

class Exporter {
  final List<Frame> _frames = [];

  void onNewFrame(Frame frame) {
    _frames.add(frame);
  }

  void clear() {
    _frames.clear();
  }

  bool get hasFrames => _frames.isNotEmpty;

  Future<List<RawFrame>?> exportFrames({int frameDurationInMillis = 16}) async {
    if (_frames.isEmpty) {
      return null;
    }
    final bytesImages = <RawFrame>[];
    for (final frame in _frames) {
      final bytesImage =
          await frame.image.toByteData(format: ui.ImageByteFormat.png);
      if (bytesImage != null) {
        bytesImages.add(RawFrame(frameDurationInMillis, bytesImage));
      } else {
        print('Skipped frame while encoding');
      }
    }
    return bytesImages;
  }

  /// Animated GIF. Opaque, or 1-bit transparency at most.
  Future<List<int>?> exportGif({int frameDurationInMillis = 16}) async {
    final frames =
        await exportFrames(frameDurationInMillis: frameDurationInMillis);
    if (frames == null) {
      return null;
    }
    return compute(_exportGif, frames);
  }

  /// Animated PNG (APNG), full 8-bit alpha per pixel. Use this instead of
  /// [exportGif] when the [ScreenRecorder] was recorded with a transparent
  /// background (sticker-style export), so edges stay clean instead of
  /// jagged.
  Future<List<int>?> exportApng({int frameDurationInMillis = 16}) async {
    final frames =
        await exportFrames(frameDurationInMillis: frameDurationInMillis);
    if (frames == null) {
      return null;
    }
    return compute(_exportApng, frames);
  }

  static image.Image? _buildAnimatedImage(List<RawFrame> frames) {
    image.Image? anim;
    for (final frame in frames) {
      final decoded = image.decodePng(frame.image.buffer.asUint8List());
      if (decoded == null) {
        print('Skipped frame while encoding');
        continue;
      }
      decoded.frameDuration = frame.durationInMillis;
      if (anim == null) {
        anim = decoded;
        anim.frameType = image.FrameType.animation;
      } else {
        anim.addFrame(decoded);
      }
    }
    return anim;
  }

  static List<int>? _exportGif(List<RawFrame> frames) {
    final anim = _buildAnimatedImage(frames);
    if (anim == null) return null;
    return image.encodeGif(anim);
  }

  static List<int>? _exportApng(List<RawFrame> frames) {
    final anim = _buildAnimatedImage(frames);
    if (anim == null) return null;
    return image.encodePng(anim);
  }
}

class RawFrame {
  RawFrame(this.durationInMillis, this.image);

  final int durationInMillis;
  final ByteData image;
}
