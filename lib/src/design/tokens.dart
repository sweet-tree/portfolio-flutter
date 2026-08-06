/// The design system's constants: colour, spacing, and the fluid scale that
/// everything sizes against.
///
/// Values live here and nowhere else. Anything hard-coded in a widget is a bug
/// waiting to become an inconsistency.
library;

import 'dart:ui' show lerpDouble;

import 'package:flutter/widgets.dart';

/// Near-black with one saturated accent.
///
/// Pure white text on a dark background is harsh and reads as unconsidered, so
/// the primary text tone is warmed and pulled slightly off 0xFFFFFFFF.
abstract final class Palette {
  /// The page background. Must stay in sync with the `background` in
  /// `web/index.html`, which paints before Flutter boots.
  static const Color bg = Color(0xFF0B0B0F);

  /// Headlines and anything that should read as primary.
  static const Color ink = Color(0xFFEDEDF0);

  /// Body copy and de-emphasised labels.
  static const Color inkMuted = Color(0xFF8C8C99);

  /// Hairlines and dividers. Deliberately barely visible.
  static const Color line = Color(0x1AFFFFFF);

  /// The single accent. One colour, used sparingly, is what keeps a dark site
  /// from looking like a template.
  static const Color accent = Color(0xFFFF5A36);

  /// The nav bar's backdrop once the page has scrolled under it.
  static const Color scrim = Color(0xE60B0B0F);
}

/// The spacing scale. Multiples of 4, named rather than numeric so that
/// "one step more space" is a decision instead of a guess.
abstract final class Space {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 40;
  static const double xxl = 64;
  static const double section = 120;
}

/// Interpolates a value across the viewport width instead of stepping it at a
/// breakpoint.
///
/// Continuous scaling is most of why a modern site feels modern: nothing ever
/// snaps mid-resize. [from] and [to] bracket the range over which the value
/// travels — below and above that it is clamped, so a 320px phone and a 2560px
/// display both get a sane number.
double fluid(
  double width, {
  required double min,
  required double max,
  double from = 380,
  double to = 1280,
}) {
  final t = ((width - from) / (to - from)).clamp(0.0, 1.0);
  return lerpDouble(min, max, t)!;
}
