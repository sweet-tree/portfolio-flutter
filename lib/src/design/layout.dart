/// Layout primitives: the one breakpoint, and the measured content column that
/// every piece of content sits inside.
library;

import 'package:flutter/widgets.dart';
import 'package:portfolio/src/design/tokens.dart';

/// The site has exactly ONE breakpoint.
///
/// Portfolio content is a single column on a phone and a single column with
/// more air on a desktop. The only genuine change is whether paired things sit
/// side by side or stack. Multi-tier breakpoint systems belong to product UIs
/// with real density changes; here they would only be more states to get wrong.
const double kCompactBelow = 900;

extension LayoutQueries on BuildContext {
  /// True when paired content should stack rather than sit side by side.
  bool get isCompact => MediaQuery.sizeOf(this).width < kCompactBelow;

  /// The viewport width, which the fluid scale reads from.
  double get vw => MediaQuery.sizeOf(this).width;
}

/// Caps content width and centres it, with a gutter that grows with the
/// viewport.
///
/// This is the single highest-value rule in the whole layout. Text running the
/// full width of a 1440px display is the loudest amateur tell there is, so
/// nothing is allowed to be laid out without passing through here.
class ContentColumn extends StatelessWidget {
  const ContentColumn({required this.child, this.maxWidth = wide, super.key});

  /// Comfortable for prose: roughly 65–75 characters per line at body size.
  static const double prose = 720;

  /// For grids, image rows and anything that benefits from breathing sideways.
  static const double wide = 1120;

  /// Edge to edge, gutters only. For the hero, where the type is meant to run
  /// to the frame margins rather than sit inside a reading column.
  static const double frame = double.infinity;

  /// The margin every layer aligns to — nav, hero and rails alike. Read it
  /// from here rather than re-deriving it, or the frame stops lining up.
  static double gutterOf(BuildContext context) =>
      fluid(context.vw, min: Space.lg, max: Space.xxl);

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final gutter = gutterOf(context);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: gutter),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          // Content is left-aligned within the centred column. Centred text
          // blocks read as a template; a centred column of left-aligned text
          // reads as a publication.
          child: SizedBox(width: double.infinity, child: child),
        ),
      ),
    );
  }
}

/// Vertical rhythm between major sections, scaled to the viewport.
class Section extends StatelessWidget {
  const Section({
    required this.child,
    this.maxWidth = ContentColumn.wide,
    super.key,
  });

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final v = fluid(context.vw, min: Space.xl, max: Space.section);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: v),
      child: ContentColumn(maxWidth: maxWidth, child: child),
    );
  }
}
