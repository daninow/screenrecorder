import 'dart:typed_data';
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

  /// Animated PNG (APNG), full 8-bit alpha per pixel. Kept for cases that
  /// want a generically shareable transparent animated image; WhatsApp does
  /// not recognize this as an animated sticker, so the sticker flow in
  /// animtext uses [exportWebp] instead.
  Future<List<int>?> exportApng({int frameDurationInMillis = 16}) async {
    final frames =
        await exportFrames(frameDurationInMillis: frameDurationInMillis);
    if (frames == null) {
      return null;
    }
    return compute(_exportApng, frames);
  }

  /// Animated WebP, lossless VP8L per frame (full 8-bit alpha). This is the
  /// format WhatsApp-style "sticker" pickers actually expect for an animated
  /// sticker — GIF only has 1-bit transparency and APNG isn't recognized as
  /// an animated sticker by WhatsApp.
  ///
  /// `image` 4.x's own `WebPEncoder` only encodes a single still frame —
  /// its `encode(image, {singleFrame})` parameter is effectively a no-op for
  /// animation (verified by reading its source directly: it always calls
  /// `_encodeVP8L` once on the whole `image`, never touches `image.frames`).
  /// It cannot build an animated container by itself. So this reuses that
  /// single-frame encoder per frame — already correct and tested for the
  /// hard part, the VP8L bitstream — and hand-assembles the surrounding
  /// RIFF/VP8X/ANIM/ANMF container, which is a much simpler, well documented
  /// binary layout: https://developers.google.com/speed/webp/docs/riff_container
  Future<List<int>?> exportWebp({int frameDurationInMillis = 16}) async {
    final frames =
        await exportFrames(frameDurationInMillis: frameDurationInMillis);
    if (frames == null) {
      return null;
    }
    return compute(_exportWebp, frames);
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

  static List<int>? _exportWebp(List<RawFrame> frames) {
    image.Image? first;
    final frameChunks = <Uint8List>[];
    var durationMs = 16;
    for (final frame in frames) {
      final decoded = image.decodePng(frame.image.buffer.asUint8List());
      if (decoded == null) {
        print('Skipped frame while encoding');
        continue;
      }
      // All screen_recorder frames share the same canvas size, so every
      // ANMF sub-frame can safely reuse (0, 0) + this width/height.
      first ??= decoded;
      durationMs = frame.durationInMillis;
      // encodeWebP() returns a full standalone file: a 12-byte
      // 'RIFF'/size/'WEBP' header followed by a 'VP8L' chunk (fourcc +
      // size + data [+ pad byte]). An ANMF sub-frame wants exactly that
      // trailing 'VP8L' chunk, without the outer RIFF/WEBP header — hence
      // the `.sublist(12)` via the zero-copy view below.
      final singleFrameWebp = image.encodeWebP(decoded);
      frameChunks.add(Uint8List.sublistView(singleFrameWebp, 12));
    }
    if (first == null || frameChunks.isEmpty) return null;
    return _muxAnimatedWebp(
      width: first.width,
      height: first.height,
      frameChunks: frameChunks,
      frameDurationMs: durationMs,
    );
  }

  /// Hand-rolled RIFF/WebP animation muxer — no native/FFmpeg dependency,
  /// just byte-level chunk writing per the spec linked on [exportWebp].
  /// Every frame is written at (0, 0) covering the full canvas, with
  /// "do not blend" (see the 0x02 flag byte below) so each frame fully
  /// replaces the previous one instead of alpha-compositing over it —
  /// avoids ghosting if a frame has partial transparency.
  static List<int> _muxAnimatedWebp({
    required int width,
    required int height,
    required List<Uint8List> frameChunks,
    required int frameDurationMs,
  }) {
    final body = BytesBuilder();

    void writeChunk(String fourCC, List<int> payload) {
      body.add(fourCC.codeUnits);
      body.add(_uint32le(payload.length));
      body.add(payload);
      if (payload.length.isOdd) body.addByte(0);
    }

    // VP8X: declares the extended format's animation + alpha flags plus
    // the canvas size (both stored as "value minus one").
    final vp8x = BytesBuilder()
      ..addByte(0x12) // bit4 Alpha=1, bit1 Animation=1, rest reserved=0
      ..add([0, 0, 0]) // reserved
      ..add(_uint24le(width - 1))
      ..add(_uint24le(height - 1));
    writeChunk('VP8X', vp8x.takeBytes());

    // ANIM: fully transparent black background, loop forever.
    final anim = BytesBuilder()
      ..add([0, 0, 0, 0]) // background color, byte order is B G R A
      ..add(_uint16le(0)); // loop count, 0 = infinite
    writeChunk('ANIM', anim.takeBytes());

    // One ANMF per captured frame, all at (0, 0) with the full canvas size.
    for (final frameData in frameChunks) {
      final anmf = BytesBuilder()
        ..add(_uint24le(0)) // Frame X, in units of 2px
        ..add(_uint24le(0)) // Frame Y, in units of 2px
        ..add(_uint24le(width - 1))
        ..add(_uint24le(height - 1))
        ..add(_uint24le(frameDurationMs))
        ..addByte(0x02) // reserved=0, blend=1 (no blend), dispose=0 (none)
        ..add(frameData);
      writeChunk('ANMF', anmf.takeBytes());
    }

    final chunks = body.takeBytes();
    final out = BytesBuilder()
      ..add('RIFF'.codeUnits)
      ..add(_uint32le(4 + chunks.length)) // 'WEBP' fourcc + all chunks
      ..add('WEBP'.codeUnits)
      ..add(chunks);
    return out.takeBytes();
  }

  static List<int> _uint16le(int v) => [v & 0xff, (v >> 8) & 0xff];

  static List<int> _uint24le(int v) =>
      [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff];

  static List<int> _uint32le(int v) => [
        v & 0xff,
        (v >> 8) & 0xff,
        (v >> 16) & 0xff,
        (v >> 24) & 0xff,
      ];
}

class RawFrame {
  RawFrame(this.durationInMillis, this.image);

  final int durationInMillis;
  final ByteData image;
}
