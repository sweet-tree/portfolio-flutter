/// The type scale.
///
/// Every size here is fluid — interpolated across the viewport rather than
/// stepped at a breakpoint — so type never snaps mid-resize.
///
/// TRACKING IS THE POINT. Large type at default letter-spacing reads as 2018.
/// Display sizes pull spacing negative and the ratio holds as they scale, which
/// is what makes an oversized headline look set rather than merely big.
///
/// ⚠️ NO CUSTOM FONT IS BUNDLED YET, so this currently renders in Flutter's
/// embedded Roboto. The scale and rhythm are right; the voice is not. Picking
/// and bundling one variable font is the next design decision.
library;

import 'package:flutter/widgets.dart';
import 'package:portfolio/src/design/layout.dart';
import 'package:portfolio/src/design/tokens.dart';

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
  static TextStyle display(BuildContext context) {
    final size = fluid(context.vw, min: 52, max: 184);
    return TextStyle(
      fontSize: size,
      height: 1.02,
      // Scales with the size so the optical tightness stays constant.
      letterSpacing: size * -0.035,
      fontWeight: FontWeight.w600,
      color: Palette.ink,
    );
  }

  /// Section headings.
  static TextStyle title(BuildContext context) {
    final size = fluid(context.vw, min: 28, max: 48);
    return TextStyle(
      fontSize: size,
      height: 1.1,
      letterSpacing: size * -0.025,
      fontWeight: FontWeight.w600,
      color: Palette.ink,
    );
  }

  /// The standfirst under a hero, and any lead paragraph.
  static TextStyle lead(BuildContext context) {
    final size = fluid(context.vw, min: 18, max: 24);
    return TextStyle(
      fontSize: size,
      height: 1.5,
      letterSpacing: size * -0.01,
      color: Palette.inkMuted,
    );
  }

  /// Body copy.
  static TextStyle body(BuildContext context) {
    final size = fluid(context.vw, min: 16, max: 18);
    return TextStyle(fontSize: size, height: 1.6, color: Palette.inkMuted);
  }

  /// Nav links, the wordmark and anything else in the chrome.
  static TextStyle ui(BuildContext context) => const TextStyle(
    fontSize: 15,
    height: 1.2,
    letterSpacing: 0,
    fontWeight: FontWeight.w500,
    color: Palette.ink,
  );

  /// Small all-caps labels: section numbers, the role line, the footer.
  ///
  /// Positive tracking here, unlike the display sizes — small caps need to be
  /// opened up to stay legible, which is the exact inverse of large type.
  static TextStyle label(BuildContext context) => const TextStyle(
    fontSize: 12,
    height: 1.2,
    letterSpacing: 1.4,
    fontWeight: FontWeight.w500,
    color: Palette.inkMuted,
  );
}
