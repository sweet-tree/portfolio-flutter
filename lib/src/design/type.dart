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
import 'package:portfolio/src/query_params.dart';

/// The display face: the statement and section headings.
///
/// ⚠️ CINZEL IS AN INSCRIPTIONAL FACE AND BEHAVES LIKE ONE. Its lowercase
/// glyphs are SMALL CAPITALS — that is the design, since Roman inscriptions had
/// no lowercase — so most of a Title-case line sits at roughly 70% of cap
/// height and the statement reads smaller than its font size implies. It also
/// has no width axis. Both facts are load-bearing in hero_panel.dart.
const String kDisplayFamily = 'Cinzel';

/// The text face: nav, labels, the rail, and body copy.
const String kTextFamily = 'Inter';

/// Both a weight and the axis setting that actually applies it.
List<FontVariation> _wght(double value) => [FontVariation('wght', value)];

/// Weight, plus the optical size axis driven by the size actually being set.
///
/// ⚠️ THE POINT OF CHOOSING INTER. An optical-size axis is the typeface's own
/// answer to what a hand-written tracking curve approximates badly: as the
/// size grows it tightens the spacing and refines the detail, and as it
/// shrinks it opens up and thickens. Leaving the axis parked at its default
/// throws away the reason the face was picked. Clamped to the axis's range.
List<FontVariation> _textAxes(double weight, double size) => [
  FontVariation('wght', weight),
  FontVariation('opsz', size.clamp(14.0, 32.0)),
];

/// Display weight — CONTINUOUS, and overridable live with `?w=`.
///
/// ⚠️ NOT LIMITED TO THE NAMED INSTANCES. Cinzel ships as Regular, Bold and
/// Black, and design tools only offer those three — but the file is variable
/// with `wght` 400-900, and asking for the axis by number gets any value in
/// between. 450 and 500 are real settings that no font menu will show you.
///
/// That range is exactly where this decision lives. Regular can go fragile on
/// a dark ground at phone size, because light type on dark bleeds into the
/// background in the eye (irradiation) and thin strokes lose the most. Bold is
/// too heavy for a statement that has to sit behind the cube rather than
/// compete with it. The answer is a number between them, and the honest way to
/// find it is on a real phone against the real scene rather than by argument.
///
/// So: `?w=450` on the deployed site, and hand back whichever value wins.
double get kDisplayWeight => qDouble('w', 400);

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
  /// ⚠️ NO letterSpacing. The hand-written tracking curve is gone: it was
  /// applied ON TOP of the typeface's own kerning, eating the adjustment the
  /// designer had already made for each pair — which is why the tightest pair
  /// in the sentence collided first. Archivo's spacing at this weight is
  /// already display spacing; the hero varies WIDTH to fit, not letter gaps.
  static TextStyle display(BuildContext context) {
    final size = fluid(context.vw, min: 52, max: 184);
    return TextStyle(
      fontFamily: kDisplayFamily,
      fontSize: size,
      height: 1.02,
      fontWeight: FontWeight.w600,
      fontVariations: _wght(kDisplayWeight),
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
      fontVariations: _textAxes(400, size),
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
      fontVariations: _textAxes(400, size),
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
    fontVariations: _textAxes(500, 15),
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
    // Positive tracking survives the move to an optical axis: opsz opens the
    // face up for small sizes, but ALL-CAPS needs more than lowercase does,
    // and no axis knows the text is set in capitals.
    letterSpacing: 1.4,
    fontWeight: FontWeight.w500,
    fontVariations: _textAxes(500, 12),
    color: Palette.inkMuted,
  );
}
