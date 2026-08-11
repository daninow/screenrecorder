## [0.3.1]

* `exportGif`/`exportWebp` take an optional `quality` parameter (`ExportQuality`: `high`/`medium`/`low`, default `high` — same behavior as before this existed). Controls GIF palette size + dithering and GIF/WebP lossless-vs-lossy, independent of the resolution frames were captured at. See `Exporter.exportGif`/`exportWebp` doc comments for the exact ffmpeg flags per tier.

## [0.3.0]

* `exportGif` and `exportWebp` now encode via FFmpeg (`ffmpeg_kit_flutter_new_video`, LGPL-3.0) instead of `package:image`'s pure-Dart encoders, which could throw a `RangeError` on some clips. `exportGif` uses a two-pass palettegen/paletteuse filter graph; `exportWebp` uses `libwebp -lossless 1`. Public API (`Exporter.exportGif`/`exportWebp`, return type `Future<List<int>?>`) is unchanged.
* Requires Android API 24+ (raised by `ffmpeg_kit_flutter_new_video`).
* `exportApng` is unchanged and still uses `package:image`.

## [0.2.0]

* `Exporter` class exposes now `exportGif` and `exportFrames`.
* Updated the example project using an AnimatedContainer to have a more heavy output.

## [0.1.1]

* Fix [#11](https://github.com/ueman/screenrecorder/issues/11)
* Custom exporters can actually be used

## [0.1.0]

* require at least Flutter >=3.4.0-34.1.pre
* use `toImageSync` instead of async `toImage`
* Add ability to use different `Exporter` to export the recording in different formats. For now, only `gif`s are supported.

## [0.0.3]

* fix background color
* update example

## [0.0.2]

* Better Readme
* Some more configuration options


## [0.0.1]

* Initial draft. Pretty WIP and highly experimental
