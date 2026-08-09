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

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:portfolio/src/design/layout.dart';
import 'package:portfolio/src/design/tokens.dart';
import 'package:portfolio/src/query_params.dart';

/// The display face: the statement and section headings.
///
/// ⚠️ CHOSEN ON A PHONE AGAINST THE MOVING SCENE, and that method is the point.
/// Archivo, Cinzel, Playfair, Marcellus, Forum and Cormorant were each built
/// and looked at as still frames first — and the still frames were wrong twice.
/// Cinzel won every comparison on the canvas and lost the moment it was live;
/// Playfair measured best on paper and read as a fairy tale on screen. Nothing
/// about a typeface on this site can be settled without the energy behind it.
///
/// ⚠️ THE DECIDING CRITERION WAS THE MECHANISM, not the letterforms. The
/// statement is rasterised into a mask and a shader fills it PER PIXEL, so a
/// stroke shows the energy travelling through it only if it is wide enough to
/// hold more than one sample of the field. A hairline takes a single colour and
/// reads as tinted; a fat stroke shows the flow. Measured across the shortlist,
/// Lora puts the most ink on the page — 0.102em thick strokes against Cinzel's
/// 0.075 — and its thinnest stroke is 6.4 device pixels on a phone where
/// Playfair's is 3.6 and Cormorant's 3.2. That is the whole argument.
///
/// It is also the only CONTEMPORARY face that was tested — not a revival of a
/// historical model — so it brings no period with it. Deliberate: the ancient
/// half of the concept belongs to the cube, and the sentence has to stay
/// readable as an engineering claim rather than as an inscription.
const String kDisplayFamily = 'Lora';

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
/// ⚠️ NOT LIMITED TO THE NAMED INSTANCES. Lora is listed as Regular, Medium,
/// SemiBold and Bold, and design tools only offer those four — but the bundled
/// file is variable across `wght` 400-600, and asking for the axis by number
/// gets any value in between. 450 and 520 are real settings that no font menu
/// will show you.
///
/// That range is where the last open question lives. Light type on a dark
/// ground bleeds into the background in the eye — irradiation — and thin
/// strokes lose the most, so a phone may want more weight than a desktop. But
/// the statement also has to sit behind the cube rather than compete with it,
/// and weight is what makes it compete. The answer is a number, and the honest
/// way to find it is on a real phone against the moving scene.
///
/// So: `?w=450`, and hand back whichever value wins.
final double kDisplayWeight = qDouble('w', 400).clamp(400, 600);

/// The SUBJECT's weight — heavier than the qualifier that follows it.
///
/// ⚠️ WEIGHT IS THE HIERARCHY DEVICE HERE, and it was chosen over tone for a
/// reason specific to this page: weight is PHYSICAL. A lighter line has less
/// ink, so there is less area for the energy to fill, and it stays subordinate
/// even when fully lit. Tone is a brightness claim, and brightness is exactly
/// what the shader overwrites — a statically dimmed line would be dimmed AND
/// tinted, and the two would argue every frame.
///
/// This is the value for a LARGE frame. Overridable as `?ws=`.
final double kSubjectWeight = qDouble('ws', 500).clamp(400, 600);

/// How much heavier the subject goes on the smallest frames, in axis units.
///
/// ⚠️ A WEIGHT STEP IS ONLY AS VISIBLE AS THE STROKE IT LIVES IN. 500 against
/// 400 is roughly 0.02em of extra stem — 3.8px at the 190px the desktop sets,
/// and 0.9px at the 46px a phone sets. The same typographic decision, a quarter
/// of the effect, which is why the hierarchy read clearly on a desktop and
/// barely at all on a phone.
///
/// So the step is not a constant: it grows as the frame shrinks, the same way
/// an optical size axis compensates for size rather than pretending one drawing
/// suits every size. Overridable as `?wsc=` to find the right amount.
final double kSubjectWeightBoost = qDouble('wsc', 100).clamp(0, 200);

/// The subject's weight for a given frame.
///
/// Keyed on the viewport's SHORTEST side rather than on the type's size, which
/// matters: the size is what the fitting is still solving for, so depending on
/// it would make the measurement circular — and measuring at the wrong weight
/// is what wrapped the statement earlier today.
double subjectWeightFor(Size viewport) {
  final shortest = math.min(viewport.width, viewport.height);
  final t = ((720 - shortest) / (720 - 380)).clamp(0.0, 1.0);
  return (kSubjectWeight + kSubjectWeightBoost * t).clamp(400.0, 600.0);
}

/// Every axis the display face has, driven by the size actually being set.
///
/// ⚠️ `opsz` IS THE WHOLE ARGUMENT FOR PLAYFAIR, so it has to be driven or the
/// argument is worthless. A face with an optical size axis holds several
/// designs: sturdier, lower-contrast letterforms for small sizes and finer,
/// higher-contrast ones for large. Leaving the axis at its default picks one of
/// those designs and uses it everywhere, which is exactly the failure mode that
/// makes a text face look generic at 150px and a display face look brittle at
/// 40. Clamped to the range the file was trimmed to.
///
/// Asking for `wdth` and `opsz` on a face that has neither — Cinzel — is
/// harmless; unknown axes are ignored.
List<FontVariation> displayAxes(double size, {double? weight}) => [
  FontVariation('wght', weight ?? kDisplayWeight),
  const FontVariation('wdth', 100),
  FontVariation('opsz', size.clamp(24.0, 144.0)),
];

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
      fontVariations: displayAxes(size),
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
