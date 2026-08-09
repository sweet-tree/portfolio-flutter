/// The carved symbols, turned into a distance field once, before the first
/// frame.
///
/// ⚠️ THE LETTERS ARE THE SITE'S REAL TYPEFACE, not shapes drawn by hand. The
/// element tile is the MODERN half of this object's story — an ancient artifact
/// being read by an instrument — and that reading only lands if the symbol is
/// set in the same face as the statement below it. A hand-drawn version of Lora
/// would be a third voice on a two-typeface page.
///
/// ⚠️ AND IT IS A DISTANCE FIELD, NOT A PICTURE OF THE LETTERS. That is the
/// whole reason this is allowed to be an image at all. A bitmap of a glyph
/// stores how dark each pixel is, so drawn below its own resolution the strokes
/// fizz and crawl — the exact failure that made this project decide never to
/// texture the cube. A distance field stores how far each point is from the
/// letter's EDGE, and distance interpolates cleanly: blend two distances and
/// you get a distance, blend two coverages and you get mud. The edge is
/// recovered by comparison at whatever size it is drawn, so it stays sharp and
/// can be band limited exactly like the procedural fields beside it.
///
/// Nothing is downloaded for this. The glyphs come from a font already bundled
/// for the statement, and the field is computed on the visitor's machine in a
/// few milliseconds at startup.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:portfolio/src/design/type.dart';

/// The two symbols, in the order they are packed into the atlas.
///
/// `Di` and `Se` — Dmitry Sevryukov, and both read as plausible entries in a
/// periodic table, which is the joke and the framing at once.
const List<String> kCarvedSymbols = ['Di', 'Se'];

/// One cell of the atlas, in pixels.
///
/// ⚠️ NOT THE RESOLUTION THE LETTERS ARE DRAWN AT — the resolution their EDGE
/// is located at, which is a far weaker requirement. The shader rebuilds the
/// boundary by comparing distances, so a cell only has to locate the shape well
/// enough to measure from.
const int kCarveCell = 256;

/// How far from an edge the field still carries a usable distance, in cell
/// pixels. Past it the value saturates, which costs nothing: no one asks about
/// distances that large, and spending the eight bits on the range that matters
/// is what keeps precision high where the edge actually is.
const double kCarveSpread = 20;

abstract final class Carving {
  /// The packed distance field: one row of cells, one per symbol.
  static ui.Image? map;

  /// Builds it. Awaited in `main` before `runApp`, exactly like the shader
  /// programs.
  ///
  /// ⚠️ IT MUST BE READY BEFORE THE FIRST FRAME, and not merely for looks. The
  /// cube's shading is CACHED: the first frame's picture is kept and reused
  /// until an input changes. Arriving late would mean the cached cube is the
  /// uncarved one and stays that way — a stale-cache bug wearing the costume of
  /// a missing feature.
  static Future<void> bake() async {
    try {
      map = await _bake();
    } on Object catch (error, stack) {
      // A missing carving must not cost the visitor the page: the shader binds
      // a placeholder and the cube is simply uncarved.
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'portfolio',
          context: ErrorDescription('baking the carved symbols'),
        ),
      );
    }
  }

  static Future<ui.Image> _bake() async {
    final width = kCarveCell * kCarvedSymbols.length;
    const height = kCarveCell;

    // ── 1. Draw the glyphs, white on black ──────────────────────────────────
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder)
      ..drawRect(
        ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        ui.Paint()..color = const ui.Color(0xFF000000),
      );

    for (var i = 0; i < kCarvedSymbols.length; i++) {
      final paragraph = _symbol(kCarvedSymbols[i]);
      // Roughly placed. It is centred EXACTLY further down, on the ink itself.
      canvas.drawParagraph(
        paragraph,
        ui.Offset(i * kCarveCell.toDouble(), kCarveCell * 0.12),
      );
    }

    final picture = recorder.endRecording();
    final drawn = picture.toImageSync(width, height);
    picture.dispose();
    final raw = await drawn.toByteData();
    drawn.dispose();
    if (raw == null) throw StateError('the glyph raster returned no bytes');

    // ── 2. Coverage → signed distance ───────────────────────────────────────
    final bytes = raw.buffer.asUint8List();
    final count = width * height;
    final coverage = Float32List(count);
    for (var i = 0; i < count; i++) {
      coverage[i] = bytes[i * 4] / 255.0;
    }

    final inside = _distanceTo(coverage, width, height, invert: false);
    final outside = _distanceTo(coverage, width, height, invert: true);

    final signed = Float32List(count);
    for (var i = 0; i < count; i++) {
      // Positive outside the letter, negative inside — the same convention the
      // shader's own distance functions use, so the two combine with a plain
      // min() and need no special case.
      var s = outside[i] - inside[i];

      // ⚠️ SUB-PIXEL REFINEMENT FROM THE ANTIALIASING, and it is what makes a
      // 256-pixel cell enough. A distance transform can only answer in whole
      // pixels, because it measures between pixel centres — so a straight edge
      // comes back as a staircase and a letter's diagonals acquire a faint
      // ripple. But the rasteriser already measured that edge far more
      // precisely and wrote the answer into the coverage: a pixel 30% covered
      // has its centre about 0.2 of a pixel outside the edge. Where coverage is
      // strictly between empty and full, that beats the transform, so it wins.
      final c = coverage[i];
      if (c > 0.02 && c < 0.98) s = 0.5 - c;
      signed[i] = s;
    }

    // ── 3. Centre each cell on its own INK ──────────────────────────────────
    //
    // ⚠️ ON THE INK, NOT ON THE LINE BOX. A line box carries the face's full
    // ascent and descent whatever the string contains, so centring on it sits
    // `Di` and `Se` at visibly different heights — they use different parts of
    // it. `D` and `S` are capitals, `i` carries a dot above the x-height, `e`
    // sits entirely below it. This project has already paid for the difference
    // between a line box and a bounding box, on the statement's descenders.
    //
    // Shifting the finished FIELD rather than redrawing is exact: distance is
    // translation invariant, so sliding the values slides the letter.
    final shifts = _inkShifts(coverage, width, height);

    final out = Uint8List(count * 4);
    for (var cell = 0; cell < kCarvedSymbols.length; cell++) {
      final x0 = cell * kCarveCell;
      final shift = shifts[cell];
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < kCarveCell; x++) {
          // Clamped at the cell's own edges. The field saturates long before
          // there, so a clamp cannot smear anything carrying information.
          final sx = (x - shift.dx).round().clamp(0, kCarveCell - 1) + x0;
          final sy = (y - shift.dy).round().clamp(0, height - 1);
          final s = signed[sy * width + sx];

          final encoded = (0.5 + s / (2.0 * kCarveSpread)).clamp(0.0, 1.0);
          final v = (encoded * 255.0).round();
          final o = (y * width + x0 + x) * 4;
          // ⚠️ NEVER IN THE ALPHA CHANNEL. Flutter's images are premultiplied,
          // so a value stored there is not data the backend has agreed to leave
          // alone — it is transparency, and it is entitled to scale the colour
          // channels by it. Alpha stays opaque; the distance lives in colour.
          out[o] = v;
          out[o + 1] = v;
          out[o + 2] = v;
          out[o + 3] = 255;
        }
      }
    }

    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      out,
      width,
      height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  /// How far each cell's ink is from being centred in it.
  static List<ui.Offset> _inkShifts(
    Float32List coverage,
    int width,
    int height,
  ) {
    final shifts = <ui.Offset>[];
    for (var cell = 0; cell < kCarvedSymbols.length; cell++) {
      final x0 = cell * kCarveCell;
      var minX = kCarveCell;
      var maxX = -1;
      var minY = height;
      var maxY = -1;
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < kCarveCell; x++) {
          if (coverage[y * width + x0 + x] < 0.5) continue;
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
      }
      if (maxX < 0) {
        shifts.add(ui.Offset.zero);
        continue;
      }
      shifts.add(
        ui.Offset(
          (kCarveCell - 1) / 2 - (minX + maxX) / 2,
          (height - 1) / 2 - (minY + maxY) / 2,
        ),
      );
    }
    return shifts;
  }

  static ui.Paragraph _symbol(String text) {
    // ⚠️ SET AT THE WEIGHT IT WILL BE CUT AT, and the two must agree. Naming a
    // weight twice — once as `fontWeight` and once on the `wght` axis — and
    // having them disagree leaves the axis inert, because `fontWeight` wins
    // silently. Here the weight decides how much stone the groove removes, so a
    // stroke lighter than intended is a carving that will not read on a phone.
    const size = kCarveCell * 0.62;
    final style = ui.TextStyle(
      color: const ui.Color(0xFFFFFFFF),
      fontFamily: kDisplayFamily,
      fontSize: size,
      fontWeight: ui.FontWeight.w500,
      fontVariations: const [ui.FontVariation('wght', 500)],
    );
    return (ui.ParagraphBuilder(
            ui.ParagraphStyle(
              fontFamily: kDisplayFamily,
              fontSize: size,
              height: 1,
              textAlign: ui.TextAlign.center,
            ),
          )
          ..pushStyle(style)
          ..addText(text))
        .build()
      ..layout(ui.ParagraphConstraints(width: kCarveCell.toDouble()));
  }

  /// Euclidean distance, in pixels, from every point to the nearest point on
  /// the other side of the edge.
  ///
  /// ⚠️ THE EXACT TRANSFORM, NOT AN APPROXIMATION, and it is worth the forty
  /// lines. The usual shortcut — spreading distances outward with a small
  /// kernel over a couple of passes — is cheap and wrong in a way that shows:
  /// its error grows with distance and is not the same in every direction, so a
  /// diagonal stroke ends up with a subtly different apparent weight from a
  /// vertical one. On letterforms that reads as a face which is not quite the
  /// face you chose.
  ///
  /// Felzenszwalb and Huttenlocher's method runs an exact one-dimensional
  /// transform along every row, then along every column of that result, which
  /// composes to the exact two-dimensional answer in linear time.
  static Float32List _distanceTo(
    Float32List coverage,
    int width,
    int height, {
    required bool invert,
  }) {
    const inf = 1e20;
    final grid = Float32List(width * height);
    for (var i = 0; i < grid.length; i++) {
      final solid = invert ? coverage[i] >= 0.5 : coverage[i] < 0.5;
      grid[i] = solid ? 0.0 : inf;
    }

    final longest = math.max(width, height);
    final f = Float32List(longest);
    final d = Float32List(longest);
    final v = Int32List(longest);
    final z = Float32List(longest + 1);

    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        f[x] = grid[y * width + x];
      }
      _transform1d(f, d, v, z, width);
      for (var x = 0; x < width; x++) {
        grid[y * width + x] = d[x];
      }
    }

    for (var x = 0; x < width; x++) {
      for (var y = 0; y < height; y++) {
        f[y] = grid[y * width + x];
      }
      _transform1d(f, d, v, z, height);
      for (var y = 0; y < height; y++) {
        grid[y * width + x] = d[y];
      }
    }

    for (var i = 0; i < grid.length; i++) {
      grid[i] = math.sqrt(grid[i]);
    }
    return grid;
  }

  /// The exact one-dimensional squared distance transform of [f] into [d].
  ///
  /// Each pixel contributes a parabola opening upward from its current value;
  /// the transform is the lower envelope of all of them. [v] holds which
  /// parabola is lowest in each region and [z] the boundaries between those
  /// regions — both scratch, passed in so the passes above do not allocate per
  /// row and per column.
  static void _transform1d(
    Float32List f,
    Float32List d,
    Int32List v,
    Float32List z,
    int n,
  ) {
    const inf = 1e20;
    var k = 0;
    v[0] = 0;
    z[0] = -inf;
    z[1] = inf;
    for (var q = 1; q < n; q++) {
      // Where this parabola crosses the one currently lowest at the right end.
      var s = ((f[q] + q * q) - (f[v[k]] + v[k] * v[k])) / (2 * q - 2 * v[k]);
      // Any parabola whose region this one swallows is dropped.
      while (s <= z[k]) {
        k--;
        s = ((f[q] + q * q) - (f[v[k]] + v[k] * v[k])) / (2 * q - 2 * v[k]);
      }
      k++;
      v[k] = q;
      z[k] = s;
      z[k + 1] = inf;
    }

    k = 0;
    for (var q = 0; q < n; q++) {
      while (z[k + 1] < q) {
        k++;
      }
      final dx = (q - v[k]).toDouble();
      d[q] = dx * dx + f[v[k]];
    }
  }
}
