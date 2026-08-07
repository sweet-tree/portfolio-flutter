/// The stops in the world, in travel order.
///
/// This list is the single source of truth for navigation: the router, the nav
/// and the camera all derive from it, so a stop cannot exist without a URL and
/// a URL cannot point at a stop that isn't there. Adding or removing a section
/// is a one-line edit here and nothing else.
///
/// ⚠️ THE BODY TEXT IS DELIBERATELY FAKE. It exists only to be long enough to
/// scroll, which is what the panel/travel arbitration is tested against. Real
/// copy comes later, from the owner — nothing here should ever read as a claim
/// about him or his work.
library;

import 'package:flutter/widgets.dart';

@immutable
class Location {
  const Location({
    required this.path,
    required this.label,
    required this.role,
    required this.titleWide,
    required this.titleCompact,
  });

  /// The real URL. Has to survive a refresh and paste into a CV.
  final String path;

  /// How it appears in the nav.
  final String label;

  /// The small line above the statement.
  final String role;

  /// The biggest thing on screen: what he BUILDS, not who he is.
  ///
  /// A visitor has about ten seconds and one question. The largest element has
  /// to answer it, and a name answers nothing — so the name is metadata in the
  /// rail and this carries the claim.
  ///
  /// ⚠️ THE LINE BREAKS ARE AUTHORED, ONE SET PER FRAME SHAPE, and they are
  /// not a formatting detail. Each line is set to the MEASURE — sized
  /// independently so it fills the column edge to edge — so a break decides
  /// how large its line ends up being. Left to wrap itself the statement broke
  /// wherever the width happened to run out, which on a phone meant five lines
  /// of small type and, at some sizes, a word split down the middle.
  final List<String> titleWide;

  /// The same statement broken for a narrow frame, where it needs more lines
  /// and each one has to stay readable.
  final List<String> titleCompact;

  /// The statement as one string — for semantics, and for anything that needs
  /// the sentence rather than its setting.
  String get title => titleWide.join(' ');

  /// Filler, sized to overflow the panel so scrolling has something to do.
  String get body => List.filled(6, _filler).join('\n\n');
}

const String _filler =
    'PLACEHOLDER. Real copy goes here later. This paragraph exists only so '
    'the panel has enough text to scroll, which is how the handoff between '
    'scrolling a panel and travelling the world gets tested.';

const List<Location> kLocations = [
  Location(
    path: '/',
    label: 'Home',
    // The keyword line. Deliberately carries "quant research", which the
    // statement below cannot: research sits in the MIDDLE of his stack
    // (raw data → research → execution → screen), and a two-endpoint
    // sentence has no room for a middle. This is what gets scanned anyway.
    // Four items, not five: at 390px the fifth orphaned "FLUTTER" onto its
    // own line. "DATA" was the one to drop — quant research already implies
    // it, so it was the least informative keyword of the set.
    role: 'QUANT RESEARCH · PYTHON · RUST · FLUTTER',
    // The claim. Answers "are they any good" without a number, and reads the
    // same to a hiring manager and to someone shopping for a website:
    // "production" means live and finished, the two endpoints give the span.
    //
    // Broken so the subject stands alone and the span follows it. The second
    // line carries more characters into the same width, so it sets smaller —
    // which is the point of setting each line to the measure rather than
    // choosing one size for the block.
    titleWide: [
      'Production Systems',
      'from raw data to the last pixel.',
    ],
    // A narrow frame needs the span split again, or the third line would be
    // set so small that the block stops reading as one statement.
    titleCompact: [
      'Production Systems',
      'from raw data',
      'to the last pixel.',
    ],
  ),
  Location(
    path: '/work',
    label: 'Work',
    role: 'PLACEHOLDER ROLE',
    titleWide: ['Section Two'],
    titleCompact: ['Section Two'],
  ),
  Location(
    path: '/about',
    label: 'About',
    role: 'PLACEHOLDER ROLE',
    titleWide: ['Section Three'],
    titleCompact: ['Section Three'],
  ),
];

int indexOfPath(String path) {
  final i = kLocations.indexWhere((l) => l.path == path);
  return i < 0 ? 0 : i;
}
