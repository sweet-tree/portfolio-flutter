/// The permanent part of the site: the scene, and the frame around it.
///
/// ⚠️ THE SCENE LIVES ABOVE THE ROUTER, AND THAT IS THE WHOLE POINT OF THIS
/// FILE. Every route used to build its own copy of the world, so navigating
/// meant tearing the scene down and standing a new one up: the shader
/// reloading, the cube's cached shading recomputed, a visible hitch on a page
/// change that should have been free. Here it is built once and never
/// rebuilt — only the CONTENT in front of it changes.
///
/// ⚠️ AND THE SECTIONS ARE A STACK OF REAL ROUTES, dragged by hand. The
/// gesture here does not trigger an animation and step back; it takes hold of
/// the route's own transition and writes to it, so a section is wherever your
/// finger has put it. See section_route.dart for how, and for why going
/// forwards is harder than going back.
///
/// ⚠️ THE PAGES MUST NOT PAINT AN OPAQUE BACKGROUND, or they cover the thing
/// they are supposed to be standing in front of. The one background colour in
/// the app is here, underneath the scene.
///
/// ⚠️ THE DOCUMENT ITSELF NEVER SCROLLS. Only content inside a card does.
/// Besides being the concept, this kills a whole class of mobile bugs:
/// Safari's URL bar only collapses on document scroll, so if the document
/// never scrolls the viewport height never changes underneath us.
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' show Material;
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:portfolio/src/chrome/nav.dart';
import 'package:portfolio/src/chrome/rail.dart';
import 'package:portfolio/src/design/tokens.dart';
import 'package:portfolio/src/query_params.dart';
import 'package:portfolio/src/world/locations.dart';
import 'package:portfolio/src/world/section_route.dart';
import 'package:portfolio/src/world/world_scene.dart';

/// `?bare=1` — the scene and nothing else: no panels, no nav, no statement.
///
/// It exists for DESIGN WORK. The layout is designed in Figma on top of a still
/// of this scene, and that still has to be free of type — otherwise the old
/// statement ghosts behind whatever is being drawn over it, and every judgement
/// about where a line can go is made against a picture of the answer we already
/// have.
///
/// It also has to be a real render rather than a flat dark rectangle: the
/// statement's legibility depends on where the bright energy actually falls,
/// so type positioned against grey would be positioned against a fiction.
final bool bareScene = qFlag('bare');

/// How far a finger must move before this counts as a swipe, in logical pixels.
///
/// ⚠️ THE PLATFORM DEFAULT IS ABOUT EIGHTEEN, AND THAT IS THE FLOOR EVERYTHING
/// ELSE SITS ON. Flutter does not report a horizontal drag at all until the
/// pointer has travelled `kTouchSlop`, so a genuinely small swipe never becomes
/// a drag and nothing downstream — projection, buffering, thresholds — can
/// rescue it.
///
/// Eighteen is chosen so that a TAP is never mistaken for a drag. There is very
/// little to tap in a section: the nav and the rail are above this and handle
/// their own taps, and a card's links will be their own recognisers. So the
/// slop can come down without costing anything.
///
/// ⚠️ AND IT IS SET ON THIS RECOGNISER ALONE, not through MediaQuery. Lowering
/// it for the subtree would make the card's own scrolling twitchy too, which is
/// a different gesture with a different reason for its threshold.
const DeviceGestureSettings _kSwipeSlop = DeviceGestureSettings(touchSlop: 1);

class WorldShell extends StatefulWidget {
  const WorldShell({required this.drag, required this.child, super.key});

  /// The hand that takes hold of a section's transition.
  final SectionDrag drag;

  /// The current route's page.
  final Widget child;

  @override
  State<WorldShell> createState() => _WorldShellState();
}

class _WorldShellState extends State<WorldShell> {
  /// Null until this drag has decided what it is doing.
  bool? _forward;

  /// Our own measurement of how fast the finger is going.
  ///
  /// ⚠️ `DragEndDetails.velocity` IS A FLING VELOCITY, NOT A VELOCITY. The
  /// recogniser asks whether the gesture qualifies as a fling — faster than
  /// about 50 px/s AND past a minimum distance — and if it does not it reports
  /// EXACTLY ZERO rather than the real number.
  ///
  /// So every swipe below that bar arrived with no velocity, the projection
  /// contributed nothing, and the outcome fell back to raw distance alone: a
  /// clear swipe measuring 0.11 of the width against a 0.3 line, returned. It
  /// was identical on every section, which is what ruled out everything else.
  ///
  /// A VelocityTracker is the same machinery without the classification: it
  /// answers how fast, and leaves what that means to us.
  VelocityTracker? _speed;

  /// ⚠️ AND IT NEEDS REAL TIMESTAMPS, WHICH THE WEB DOES NOT ALWAYS GIVE.
  /// `sourceTimeStamp` is null there, and defaulting it to zero told the
  /// tracker every sample happened at the same instant — so the estimate came
  /// back small and with an arbitrary sign: 96 pixels per second POINTING RIGHT
  /// on a swipe that went left. A velocity is a distance over a time, and with
  /// no time there is no velocity.
  ///
  /// ⚠️ AND ONE CLOCK, NEVER TWO. Taking the platform's stamp when it exists
  /// and ours when it does not puts the samples of a single gesture on two
  /// different timelines, and the estimate between them is meaningless — which
  /// is why some swipes still came back at exactly zero. Consistency matters
  /// more here than which clock it is.
  final Stopwatch _clock = Stopwatch();

  /// How far this gesture has moved while still undecided.
  ///
  /// ⚠️ THE DIRECTION COMES FROM THE MOVEMENT SO FAR, NOT FROM ONE SAMPLE, and
  /// nothing is thrown away while deciding. It used to read a single delta,
  /// which made the FIRST section behave differently from the others: at home
  /// there is nothing behind, so a sample that happened to point backwards was
  /// refused and discarded, and the swipe only began on some later sample. At
  /// work either direction is available, so no sample is ever refused and it
  /// starts at once. That is why leaving home felt heavier than anything else,
  /// and it was jitter in the first pixels rather than the size of the swipe.
  double _undecided = 0;

  /// Which section is on top.
  ///
  /// ⚠️ READ FROM THE ROUTER'S DELEGATE, AND REBUILT WITH IT. Taken from
  /// `GoRouterState.of(context)` in the shell's own build, this was the state
  /// of the SHELL's match — which does not change when a section is pushed on
  /// top of it, so the shell never rebuilt and the nav highlight and the rail's
  /// counter stayed on whatever was showing first.
  ///
  /// The delegate is a Listenable precisely so that anything outside the page
  /// stack can follow it.
  int get _index => indexOfPath(GoRouter.of(context).state.matchedLocation);

  void _start() {
    _forward = null;
    _undecided = 0;
    _speed = VelocityTracker.withKind(PointerDeviceKind.touch);
    _clock
      ..reset()
      ..start();
  }

  void _update(DragUpdateDetails details) {
    final width = context.size?.width ?? 1;
    final dx = details.delta.dx;
    _speed?.addPosition(
      _clock.elapsed,
      details.globalPosition,
    );

    // ⚠️ NO THRESHOLD OF OUR OWN. This update does not happen until Flutter's
    // recogniser has already seen kTouchSlop — about 18 logical pixels — and
    // decided the gesture is a horizontal drag. Asking for another eight on top
    // re-implemented a decision that had already been made, and pushed the dead
    // zone past twenty-five pixels: a very small swipe was consumed entirely by
    // the wait and nothing ever began.
    //
    // Direction is decided once, on the first movement, and then held. A drag
    // that wavered would otherwise flip mid-flight.
    if (_forward == null) {
      _undecided += dx;
      if (_undecided == 0) return;
      final forward = _undecided < 0;
      final index = _index;
      if (forward) {
        // Nothing after the last section: keep waiting rather than starting
        // something there is nowhere to take.
        if (index + 1 >= kLocations.length) return;
        _forward = true;
        // The destination does not exist yet. Asking for it and taking hold of
        // it are two steps — see SectionDrag.beginForward.
        widget.drag.beginForward(width);
        unawaited(context.push(kLocations[index + 1].path));
      } else {
        if (index == 0) return;
        _forward = false;
        widget.drag.beginBack(width);
      }
      // Everything moved while deciding belongs to the gesture.
      widget.drag.update(-_undecided);
      return;
    }
    widget.drag.update(-dx);
  }

  void _end(DragEndDetails details) {
    final forward = _forward;
    _forward = null;
    final measured = _speed?.getVelocity().pixelsPerSecond.dx ?? 0;
    _speed = null;
    _clock.stop();
    if (forward == null) return;
    widget.drag.release(measured, forward: forward);
  }

  /// A nav click or the rail's next link.
  void _go(int index) {
    final current = _index;
    if (index == current) return;
    if (index > current) {
      unawaited(context.push(kLocations[index].path));
    } else {
      // Going back up the stack is a pop, so the section leaves the way it
      // arrived rather than being replaced by a copy of where it came from.
      context.go(kLocations[index].path);
    }
  }

  @override
  Widget build(BuildContext context) => Material(
    color: Palette.bg,
    child: Stack(
      children: [
        // Built once for the life of the page. Nothing about routing reaches
        // it.
        const Positioned.fill(child: WorldScene()),
        if (!bareScene) ...[
          Positioned.fill(
            child: RawGestureDetector(
              gestures: <Type, GestureRecognizerFactory>{
                // Sideways only. A vertical drag belongs to whatever is under
                // it, which is the card scrolling its own text.
                HorizontalDragGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<
                      HorizontalDragGestureRecognizer
                    >(HorizontalDragGestureRecognizer.new, (recogniser) {
                      recogniser
                        ..onStart = ((_) => _start())
                        ..onUpdate = _update
                        ..onEnd = _end
                        ..gestureSettings = _kSwipeSlop;
                    }),
              },
              child: widget.child,
            ),
          ),
          // ⚠️ CHROME SITS OVER EVERYTHING AND DOES NOT MOVE. The header and
          // the rail are the frame the world is seen through — sections travel
          // between them, and their staying still is what that is measured
          // against.
          //
          // (The statement's colour layer is NOT here: it is inside the hero's
          // page, because the mask's rectangle is measured relative to that
          // panel and the two halves of the sentence have to move together.
          // See location_page.dart.)
          // Rebuilt whenever the router moves, so the highlight and the
          // counter follow a push as well as a go.
          AnimatedBuilder(
            animation: GoRouter.of(context).routerDelegate,
            builder: (context, _) => Stack(
              children: [
                WorldNav(index: _index, onGo: _go),
                WorldRail(index: _index, onGo: _go),
              ],
            ),
          ),
        ],
      ],
    ),
  );
}
