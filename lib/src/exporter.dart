import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui show ImageByteFormat;

import 'package:ffmpeg_kit_flutter_new_video/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_video/return_code.dart';
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

  /// Animated GIF, encoded by the bundled FFmpeg (`ffmpeg_kit_flutter_new_video`,
  /// LGPL-3.0, no GPL codecs) instead of `package:image`'s pure-Dart NeuQuant
  /// quantizer, which could throw `RangeError (length): ... 0..256` on some
  /// clips. Frames are dumped as PNGs to a temp dir and muxed with a
  /// two-pass palettegen/paletteuse filter graph, which also looks better
  /// than a single fixed 256-color table (per-clip palette + dithering).
  Future<List<int>?> exportGif({int frameDurationInMillis = 16}) async {
    final frames =
        await exportFrames(frameDurationInMillis: frameDurationInMillis);
    if (frames == null || frames.isEmpty) {
      return null;
    }

    final dir = await Directory.systemTemp.createTemp('sr_gif_');
    try {
      final framePattern = await _writeFramePattern(dir, frames);
      final fps = _fpsArg(frameDurationInMillis);
      final palettePath = '${dir.path}/palette.png';
      final outPath = '${dir.path}/out.gif';

      // Pass 1: build a palette tailored to this specific clip.
      await _execFfmpeg([
        '-y',
        '-framerate', fps,
        '-i', framePattern,
        '-vf', 'palettegen=stats_mode=full',
        palettePath,
      ]);
      // Pass 2: encode against that palette with dithering, looped forever.
      await _execFfmpeg([
        '-y',
        '-framerate', fps,
        '-i', framePattern,
        '-i', palettePath,
        '-lavfi', 'paletteuse=dither=sierra2_4a',
        '-loop', '0',
        outPath,
      ]);

      final bytes = await File(outPath).readAsBytes();
      return bytes;
    } finally {
      await dir.delete(recursive: true);
    }
  }

  /// Animated PNG (APNG), full 8-bit alpha per pixel. Kept for cases that
  /// want a generically shareable transparent animated image; WhatsApp does
  /// not recognize this as an animated sticker, so the sticker flow in
  /// animtext uses [exportWebp] instead. Still uses `package:image` — this
  /// path isn't currently wired up in animtext and hasn't shown the
  /// `RangeError` seen in [exportGif]/[exportWebp].
  Future<List<int>?> exportApng({int frameDurationInMillis = 16}) async {
    final frames =
        await exportFrames(frameDurationInMillis: frameDurationInMillis);
    if (frames == null) {
      return null;
    }
    return compute(_exportApng, frames);
  }

  /// Animated WebP, lossless per frame (full 8-bit alpha). This is the
  /// format WhatsApp-style "sticker" pickers actually expect for an animated
  /// sticker — GIF only has 1-bit transparency and APNG isn't recognized as
  /// an animated sticker by WhatsApp.
  ///
  /// Encoded via FFmpeg's `libwebp` encoder (`-lossless 1`), the same way
  /// [exportGif] now goes through FFmpeg instead of `package:image`'s
  /// hand-rolled VP8L encoder + RIFF muxer, which could throw on some
  /// inputs.
  Future<List<int>?> exportWebp({int frameDurationInMillis = 16}) async {
    final frames =
        await exportFrames(frameDurationInMillis: frameDurationInMillis);
    if (frames == null || frames.isEmpty) {
      return null;
    }

    final dir = await Directory.systemTemp.createTemp('sr_webp_');
    try {
      final framePattern = await _writeFramePattern(dir, frames);
      final fps = _fpsArg(frameDurationInMillis);
      final outPath = '${dir.path}/out.webp';

      await _execFfmpeg([
        '-y',
        '-framerate', fps,
        '-i', framePattern,
        '-c:v', 'libwebp',
        '-lossless', '1',
        '-loop', '0',
        '-an',
        outPath,
      ]);

      final bytes = await File(outPath).readAsBytes();
      return bytes;
    } finally {
      await dir.delete(recursive: true);
    }
  }

  /// Writes every captured frame as a zero-padded PNG (`frame_00000.png`,
  /// `frame_00001.png`, ...) into [dir] and returns the `image2` glob
  /// pattern FFmpeg needs to read them back in order as a sequence.
  static Future<String> _writeFramePattern(
    Directory dir,
    List<RawFrame> frames,
  ) async {
    for (var i = 0; i < frames.length; i++) {
      final path = '${dir.path}/frame_${i.toString().padLeft(5, '0')}.png';
      await File(path).writeAsBytes(
        frames[i].image.buffer.asUint8List(),
        flush: true,
      );
    }
    return '${dir.path}/frame_%05d.png';
  }

  /// All frames in a single `exportGif`/`exportWebp` call share the same
  /// capture cadence (see `RecorderScreen.endRecording`, which computes one
  /// `frameDurationInMillis` for the whole export up front), so a constant
  /// `-framerate` input is enough — no need for a per-frame duration list.
  static String _fpsArg(int frameDurationInMillis) {
    final ms = frameDurationInMillis > 0 ? frameDurationInMillis : 16;
    return (1000 / ms).toStringAsFixed(4);
  }

  static Future<void> _execFfmpeg(List<String> arguments) async {
    final session = await FFmpegKit.executeWithArguments(arguments);
    final returnCode = await session.getReturnCode();
    if (!ReturnCode.isSuccess(returnCode)) {
      final output = await session.getOutput();
      throw StateError(
        'ffmpeg failed (${returnCode?.getValue()}) for '
        '${arguments.join(' ')}: $output',
      );
    }
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
