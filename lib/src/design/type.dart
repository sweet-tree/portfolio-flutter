/// The type scale.
///
/// Every size here is fluid — interpolated across the viewport rather than
/// stepped at a breakpoint — so type never snaps mid-resize.
///
/// TRACKING IS THE POINT. Large type at default letter-spacing reads as 2018.
/// Display sizes pull spacing negative and the ratio holds as they scale, which
/// is what makes an oversized headline look set rather than merely big.
///
/// TWO FACES, BOTH VARIABLE, both bundled — see pubspec.yaml for why each was
/// chosen and why they are subset.
///
/// ⚠️ WEIGHT IS SET THROUGH fontVariations, NOT ONLY fontWeight. A variable
/// font exposes a continuous `wght` axis, and asking for it by name is what
/// actually moves it; `fontWeight` is kept alongside so anything reasoning
/// about the style (and any fallback face) still sees the intent.
library;

import 'package:flutter/widgets.dart';
import 'package:portfolio/src/design/layout.dart';
import 'package:portfolio/src/design/tokens.dart';

/// The display face: the statement and section headings.
const String kDisplayFamily = 'Archivo';

/// The text face: nav, labels, the rail, and body copy.
const String kTextFamily = 'Inter';

/// Both a weight and the axis setting that actually applies it.
List<FontVariation> _wght(double value) => [FontVariation('wght', value)];

/// Text styles, resolved against the current viewport width.
///
/// Read them off the context (`AppType.display(context)`) rather than storing
/// them, because they change as the window resizes.
abstract final class AppType {
  /// The hero headline. Oversized, tight, and the loudest thing on the page.
  ///
  /// The size contrast against [label] is deliberate and extreme — roughly
  /// 15:1 at desktop width. That gap is most of what makes a hero read as a
  /// composition rather than as a web page with a big title.
  /// The tracking here is a placeholder: the hero solves its own, on a curve,
  /// because a single em-relative constant cannot serve a 2:1 range of sizes.
  static TextStyle display(BuildContext context) {
    final size = fluid(context.vw, min: 52, max: 184);
    return TextStyle(
      fontFamily: kDisplayFamily,
      fontSize: size,
      height: 1.02,
      letterSpacing: size * -0.014,
      fontWeight: FontWeight.w600,
      fontVariations: _wght(600),
      color: Palette.ink,
    );
  }

  /// Section headings.
  static TextStyle title(BuildContext context) {
    final size = fluid(context.vw, min: 28, max: 48);
    return TextStyle(
      fontFamily: kDisplayFamily,
      fontSize: size,
      height: 1.1,
      letterSpacing: size * -0.02,
      fontWeight: FontWeight.w600,
      fontVariations: _wght(600),
      color: Palette.ink,
    );
  }

  /// The standfirst under a hero, and any lead paragraph.
  static TextStyle lead(BuildContext context) {
    final size = fluid(context.vw, min: 18, max: 24);
    return TextStyle(
      fontFamily: kTextFamily,
      fontSize: size,
      height: 1.5,
      letterSpacing: size * -0.01,
      fontVariations: _wght(400),
      color: Palette.inkMuted,
    );
  }

  /// Body copy.
  static TextStyle body(BuildContext context) {
    final size = fluid(context.vw, min: 16, max: 18);
    return TextStyle(
      fontFamily: kTextFamily,
      fontSize: size,
      height: 1.6,
      fontVariations: _wght(400),
      color: Palette.inkMuted,
    );
  }

  /// Nav links, the wordmark and anything else in the chrome.
  static TextStyle ui(BuildContext context) => TextStyle(
    fontFamily: kTextFamily,
    fontSize: 15,
    height: 1.2,
    letterSpacing: 0,
    fontWeight: FontWeight.w500,
    fontVariations: _wght(500),
    color: Palette.ink,
  );

  /// Small all-caps labels: section numbers, the role line, the footer.
  ///
  /// Positive tracking here, unlike the display sizes — small caps need to be
  /// opened up to stay legible, which is the exact inverse of large type.
  static TextStyle label(BuildContext context) => TextStyle(
    fontFamily: kTextFamily,
    fontSize: 12,
    height: 1.2,
    letterSpacing: 1.4,
    fontWeight: FontWeight.w500,
    fontVariations: _wght(500),
    color: Palette.inkMuted,
  );
}
