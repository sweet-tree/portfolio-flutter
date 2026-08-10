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
    required this.statement,
    this.payoff = const [],
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
  /// ⚠️ EVERY ARRANGEMENT THE STATEMENT MAY TAKE. The layout picks; the copy
  /// only says which breaks are ALLOWED.
  ///
  /// Three levels, and each means something:
  ///   · the outer list is the candidate ARRANGEMENTS — two lines, three, four
  ///   · each arrangement is a list of PARTS — the subject, then the qualifier
  ///   · each part is a list of authored LINES
  ///
  /// The parts are the sentence's own structure, and they are not decoration:
  /// the layout sets them in different weights with air between them, so the
  /// eye reads one claim plus its qualification rather than four equal lines.
  ///
  /// The lines are authored rather than wrapped because each one is set to the
  /// MEASURE, so a break decides how large its line ends up. Left to wrap
  /// itself the statement broke wherever the width ran out — five lines of
  /// small type on a phone and, at some sizes, a word split down the middle.
  ///
  /// ⚠️ AND THERE IS NO "WIDE" OR "COMPACT" VERSION ANY MORE. A width
  /// breakpoint cannot tell a phone in landscape (852 wide, 393 tall) from a
  /// tablet in portrait (834 wide, 1194 tall), and those two want opposite
  /// settings. The layout solves every arrangement against the actual frame and
  /// takes the one that sets the largest leading line; see hero_panel.dart.
  final List<List<List<String>>> statement;

  /// The statement as one string — for semantics, and for anything that needs
  /// the sentence rather than its setting.
  String get title =>
      statement.first.expand((part) => part).join(' ');

  /// THE WORDS THE ENERGY ANSWERS TO — any number of them, or none.
  ///
  /// ⚠️ NAMED IN THE COPY, NOT FOUND BY THE RENDERER, because which words carry
  /// the claim is an authoring decision and nothing else knows it. The
  /// statement is set to a different arrangement on every frame shape, so
  /// nothing about where a word LANDS can be written down — only which word it
  /// is. The layout finds the rectangles afterwards.
  ///
  /// ⚠️ A LIST, AND PHRASES ARE ALLOWED, because the sentence does not divide
  /// into one special word and the rest. The energy is meant to CHANGE as it
  /// crosses — neutral through the claim, raw through "raw data", full acid by
  /// "the last pixel" — and that is several regions, in order, not a single
  /// highlight. Empty means the whole statement is treated as one region, which
  /// is exactly what it does today.
  ///
  /// Each entry is matched on WORD BOUNDARIES so a stem cannot be claimed by a
  /// longer word, and every occurrence is taken. A phrase falling across a line
  /// break yields one rectangle per line rather than one box spanning both,
  /// because the space between them belongs to other words.
  final List<String> payoff;

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
    // SUBJECT, then QUALIFIER, in every arrangement. The subject sets heavier
    // and the qualifier lighter, with a small gap between them, so the eye
    // reads one claim and its qualification rather than four equal lines.
    //
    // The qualifier carries more characters into the same width, so it sets
    // smaller on its own — that contrast is free, and is the point of setting
    // each line to the measure rather than choosing one size for the block.
    //
    // ⚠️ THE FOUR-LINE VERSION BREAKS "Production Systems" BETWEEN ITS TWO
    // WORDS, which is a break between words and not inside one — the thing
    // that must never happen is "Produc-tion". It exists because the size is
    // set by the LONGEST line, so adding a line only buys size if it shortens
    // that line; splitting the subject does, splitting the span does not.
    statement: [
      [
        ['Production Systems'],
        ['from raw data to the last pixel.'],
      ],
      [
        ['Production Systems'],
        ['from raw data', 'to the last pixel.'],
      ],
      [
        ['Production', 'Systems'],
        ['from raw data', 'to the last pixel.'],
      ],
    ],
    // ⚠️ ONE WORD, AND IT IS THE END OF THE CLAIM. "from raw data to the last
    // pixel" is a journey, and the energy arriving at its destination is the
    // whole point — lighting both ends says they matter equally, which is not
    // what the sentence says. His call, made on the running page against the
    // two-word version.
    payoff: ['pixel'],
  ),
  Location(
    path: '/work',
    label: 'Work',
    role: 'PLACEHOLDER ROLE',
    statement: [
      [
        ['Section Two'],
      ],
    ],
  ),
  Location(
    path: '/about',
    label: 'About',
    role: 'PLACEHOLDER ROLE',
    statement: [
      [
        ['Section Three'],
      ],
    ],
  ),
];

int indexOfPath(String path) {
  final i = kLocations.indexWhere((l) => l.path == path);
  return i < 0 ? 0 : i;
}
