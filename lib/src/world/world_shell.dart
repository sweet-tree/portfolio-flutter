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

/// What may drag a section by hand.
///
/// ⚠️ A MOUSE MAY NOT. A drag recogniser accepts EVERY device kind unless it is
/// told otherwise — `supportedDevices` null means "anything" — so holding the
/// button down and moving sideways navigated, which is not a gesture anybody
/// performs deliberately on a desktop and is one several people perform by
/// accident while selecting or reaching for something.
///
/// ⚠️ AND IT IS THE DEVICE THAT DECIDES, NOT THE SCREEN. A narrow desktop
/// window is still a mouse; an iPad in landscape is wide and is still a hand. A
/// breakpoint would get both of those wrong, and this gets both right without
/// knowing anything about the platform.
const Set<PointerDeviceKind> _kSwipeDevices = <PointerDeviceKind>{
  PointerDeviceKind.touch,
  PointerDeviceKind.stylus,
};

/// How long the scroll stream must fall silent before a burst is over.
///
/// ⚠️ THERE IS NO END-OF-GESTURE ON THE WEB, AND THIS IS WHAT STANDS IN FOR IT.
/// A trackpad swipe arrives as wheel events; nothing says when the fingers
/// lift, and macOS goes on sending decaying momentum for up to a second or two
/// after they do. The platform exposes no phase, so a momentum delta is
/// genuinely indistinguishable from a deliberate one — the engine wanted this
/// information too and could not get it, which is why it says outright that
/// pan/zoom events are not generated on web.
///
/// So the boundary is drawn in TIME rather than guessed from the deltas: one
/// burst of scrolling is one statement, and it is over when the scrolling
/// stops. That is what makes a hard fling move exactly one section, and it is
/// the one number in this file that is a judgement rather than a fact.
///
/// ⚠️ AND IT IS DELIBERATELY GENEROUS, BECAUSE SPLITTING A FLING IS THE WORSE
/// FAILURE. Events arrive about every frame while momentum runs, but its TAIL
/// goes sparse — deltas fall to a pixel or two and the browser stops bothering
/// to send them every frame. A short window ends the burst in that tail, and
/// the rest of the same fling then reads as a fresh swipe and takes a second
/// section: one throw, two pages.
///
/// ⚠️ AND AN ACCELERATING DELTA DOES NOT MEAN A NEW SWIPE. It was made to,
/// on the reasoning that momentum can only ever decay — which is true of
/// momentum and useless here, because the commit fires fourteen pixels in,
/// while the fingers are still on the surface and still speeding up. So the
/// remainder of one swipe read as a second swipe, and then a third: the
/// harder the throw, the longer it accelerated and the further it skipped.
/// The silence is the only marker of a gesture ending, and it is the only one
/// used to end a burst that nobody interrupts.
const Duration _kBurstQuiet = Duration(milliseconds: 200);

/// How far below its peak a burst must have fallen to count as coasting.
///
/// ⚠️ THIS IS WHAT MAKES A SECOND SWIPE LAND WITHOUT WAITING. Momentum decays
/// and can never rise, so a delta bigger than the one before it means a hand.
/// The trap — and the bug it caused — is that the commit fires fourteen pixels
/// in, while the fingers are still on the surface and still speeding up, so a
/// rise on its own also describes the rest of the swipe that just committed.
///
/// A quarter of the peak separates the two cleanly. While the fingers are
/// pushing, every delta IS the peak, so nothing can be a quarter below it; once
/// the throw is coasting, the series has fallen there within a few frames. Only
/// then does a rise mean anything, and then it means only one thing.
const double _kCoasting = 0.25;

/// What counts as a rise rather than the jitter of a decaying series.
const double _kRiseFactor = 1.5;
const double _kRiseFloor = 2;

/// How far a burst must travel before its axis is decided, in logical pixels.
///
/// A sideways swipe is never perfectly sideways, and a vertical one is never
/// perfectly vertical. Deciding on the first delta reads the noise; deciding on
/// the first couple of pixels reads the intent.
const double _kBurstAxis = 2;

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

  /// Closes the current scroll burst once the scrolling stops.
  Timer? _quiet;

  /// How far this burst has gone while its axis was still undecided.
  double _burstDx = 0;
  double _burstDy = 0;

  /// The direction this burst took hold in, or null before it has taken hold.
  bool? _burstForward;

  /// One clock for every scroll signal, so gaps between them are comparable.
  ///
  /// ⚠️ THE GAPS ARE THE WHOLE QUESTION. A burst ends when the scrolling stops,
  /// and whether two swipes are one burst or two depends entirely on how the
  /// silence between them compares to the silence inside a single fling's
  /// momentum. Those two numbers are properties of the hardware and the
  /// browser, not of anything we can reason out, so the app measures them.
  final Stopwatch _scrollClock = Stopwatch()..start();

  /// When the last scroll signal arrived, by that clock.
  int? _signalAt;

  /// How many signals this burst has contained, and the longest silence inside
  /// it. Reported by `?swipe=1`.
  int _burstCount = 0;
  int _burstMaxGap = 0;

  /// The biggest sideways delta this burst has seen, and the last one.
  double _burstPeak = 0;
  double _lastMagnitude = 0;

  /// This burst has already said what it had to say.
  ///
  /// ⚠️ IT IS WHAT MAKES ONE SWIPE MOVE ONE SECTION. Set the moment a burst
  /// commits — and also when a burst turns out to be vertical — and cleared
  /// only when the scrolling stops, so everything after the decision, momentum
  /// included, is refused rather than counted.
  bool _burstSpent = false;

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

  @override
  void dispose() {
    _quiet?.cancel();
    super.dispose();
  }

  void _start() {
    _forward = null;
    _undecided = 0;
    _speed = VelocityTracker.withKind(PointerDeviceKind.touch);
    _clock
      ..reset()
      ..start();
  }

  void _update(DragUpdateDetails details) {
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
      // Null means there is nothing that way: keep waiting rather than starting
      // something there is nowhere to take.
      _forward = _grab(_undecided);
      return;
    }
    widget.drag.update(-dx);
  }

  /// Takes hold of the section that [dx] points at, and moves it that far.
  ///
  /// Returns the direction taken, or null when there is nothing that way.
  ///
  /// ⚠️ SHARED BY THE FINGER AND THE TRACKPAD, because taking hold is the one
  /// part that is identical between them: only how the movement arrives, and
  /// when the decision is asked for, differ. It was written twice for an hour
  /// and the copies had already begun to disagree.
  bool? _grab(double dx) {
    final width = context.size?.width ?? 1;
    final forward = dx < 0;
    final index = _index;
    if (forward) {
      if (index + 1 >= kLocations.length) return null;
      // The destination does not exist yet. Asking for it and taking hold of it
      // are two steps — see SectionDrag.beginForward.
      widget.drag.beginForward(width);
      unawaited(context.push(kLocations[index + 1].path));
    } else {
      if (index == 0) return null;
      widget.drag.beginBack(width);
    }
    // Everything moved while deciding belongs to the gesture.
    widget.drag.update(-dx);
    return forward;
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

  /// A scroll signal has arrived somewhere over the world.
  ///
  /// ⚠️ REGISTERING IS HOW TWO THINGS AVOID ANSWERING ONE EVENT. A pointer
  /// signal is offered to everything under the pointer and the resolver hands
  /// it to the FIRST to claim it, innermost outwards — so a card that can
  /// actually scroll vertically claims a vertical swipe before this ever sees
  /// it, and lets a horizontal one through because moving by zero is not a
  /// scroll. That division is exactly the one we want and it costs nothing to
  /// get: acting without registering is what would break it.
  void _signal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (kSwipeReadout) _measure(event);
    // ⚠️ A TRACKPAD ONLY, AND THE ENGINE IS THE ONE THAT KNOWS. It classifies
    // every wheel event against properties no standard describes and gives a
    // trackpad its own device kind — so a Magic Mouse swipe and a scroll wheel
    // arrive already told apart, without us guessing from the shape of the
    // deltas. Firefox is the exception: it restricts those properties, the
    // engine declines to guess, and everything there reports as a mouse.
    if (event.kind != PointerDeviceKind.trackpad) return;
    GestureBinding.instance.pointerSignalResolver.register(event, _scroll);
  }

  /// Puts the timing of the scroll stream on screen, for `?swipe=1`.
  ///
  /// ⚠️ IT REPORTS EVERY SCROLL SIGNAL, INCLUDING ONES WE REFUSE. What has to
  /// be told apart is a swipe that arrives during another swipe's momentum from
  /// the momentum itself, and both are made of the same events — so the only
  /// thing that separates them is how long the stream goes quiet. Measuring
  /// only the events we accept would leave exactly the interesting ones out.
  ///
  /// `gap` is the silence before this signal; `max` is the longest silence
  /// inside the run of signals so far. A fling's own momentum sets `max` to the
  /// browser's event cadence; putting fingers down again mid-momentum sets it
  /// to the pause that did it, which is the number the burst window has to sit
  /// under.
  void _measure(PointerScrollEvent event) {
    final now = _scrollClock.elapsedMilliseconds;
    final since = _signalAt;
    _signalAt = now;
    final gap = since == null ? 0 : now - since;
    if (gap > _kBurstQuiet.inMilliseconds) {
      _burstCount = 0;
      _burstMaxGap = 0;
    }
    _burstCount++;
    if (gap > _burstMaxGap) _burstMaxGap = gap;
    lastSignal.value =
        '${event.kind.name}  '
        'dx ${event.scrollDelta.dx.round()}  '
        'dy ${event.scrollDelta.dy.round()}\n'
        'gap ${gap}ms  max ${_burstMaxGap}ms  n $_burstCount';
  }

  /// One delta of a trackpad swipe, claimed.
  void _scroll(PointerSignalEvent event) {
    // ⚠️ AND THE BROWSER MUST BE TOLD TO KEEP OUT. macOS maps a two-finger
    // sideways swipe to its own history back and forward, so without this the
    // page navigates twice at once: our section moves and the browser leaves.
    event.respond(allowPlatformDefault: false);

    // A scroll goes the opposite way to the hand: sending the content right is
    // the same statement as dragging it left.
    final scroll = (event as PointerScrollEvent).scrollDelta;
    final dx = -scroll.dx;
    final magnitude = dx.abs();

    // A rise, once the throw is coasting, is a hand back on the surface —
    // momentum cannot speed up. So the burst ends here rather than when the
    // scrolling stops, and this delta belongs to the next one.
    if (_burstSpent &&
        _lastMagnitude < _burstPeak * _kCoasting &&
        magnitude > _lastMagnitude * _kRiseFactor + _kRiseFloor) {
      _clearBurst();
    }
    _lastMagnitude = magnitude;
    if (magnitude > _burstPeak) _burstPeak = magnitude;

    // Every delta postpones the end of the burst, momentum included — which is
    // what keeps the rest of a fling from being read as a second swipe.
    _quiet?.cancel();
    _quiet = Timer(_kBurstQuiet, _endBurst);
    if (_burstSpent) return;

    final forward = _burstForward;

    if (forward == null) {
      _burstDx += dx;
      _burstDy += scroll.dy;
      if (_burstDx.abs() < _kBurstAxis && _burstDy.abs() < _kBurstAxis) return;
      if (_burstDy.abs() >= _burstDx.abs()) {
        // Vertical, over something that did not want it. Nothing here to do,
        // and nothing later in this burst either.
        _burstSpent = true;
        return;
      }
      final grabbed = _grab(_burstDx);
      if (grabbed == null) {
        _burstSpent = true;
        return;
      }
      _burstForward = grabbed;
      _commit(grabbed);
      return;
    }

    widget.drag.update(-dx);
    _commit(forward);
  }

  /// Finishes the journey the moment the burst has moved far enough to mean it.
  ///
  /// ⚠️ THE DECISION CANNOT WAIT FOR A RELEASE, BECAUSE THERE IS NONE. A finger
  /// is asked once, when it lifts. A scroll stream is asked after every delta,
  /// and the first one that passes the same threshold ends the gesture — the
  /// remainder of the swipe, and all of its momentum, arrive to a burst that
  /// has already spoken.
  void _commit(bool forward) {
    if (!widget.drag.meant(forward: forward)) return;
    _burstSpent = true;
    _burstForward = null;
    widget.drag.release(0, forward: forward);
  }

  /// Forgets the burst so far, so the next delta begins a new one.
  void _clearBurst() {
    _burstDx = 0;
    _burstDy = 0;
    _burstPeak = 0;
    _burstSpent = false;
  }

  /// The scrolling has stopped: whatever this burst was, it is over.
  void _endBurst() {
    _quiet = null;
    _clearBurst();
    final forward = _burstForward;
    if (forward == null) return;
    _burstForward = null;
    // It took hold and never went far enough to mean it. Letting go puts the
    // section back, exactly as lifting a finger early does.
    widget.drag.release(0, forward: forward);
  }

  /// One line of the `?swipe=1` readout.
  static Widget _readout(String line) => Text(
    line,
    style: const TextStyle(
      color: Palette.accent,
      fontSize: 13,
      fontFamily: 'monospace',
    ),
  );

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
            // A trackpad swipe never becomes a drag on the web — the engine
            // says so outright — so it arrives here instead, as a scroll.
            child: Listener(
              onPointerSignal: _signal,
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
                          ..gestureSettings = _kSwipeSlop
                          ..supportedDevices = _kSwipeDevices;
                      }),
                },
                child: widget.child,
              ),
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
          // `?swipe=1` — what the last gesture measured, for tuning against a
          // real hand rather than a description of one.
          if (kSwipeReadout)
            Positioned(
              left: 12,
              top: 96,
              child: IgnorePointer(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ValueListenableBuilder<SwipeReading?>(
                      valueListenable: lastSwipe,
                      builder: (context, reading, _) =>
                          _readout(reading?.toString() ?? 'swipe to measure'),
                    ),
                    // The kind is the one thing that cannot be reasoned out:
                    // whether a given device's sideways swipe reaches us as a
                    // trackpad or as a mouse is the engine's own judgement.
                    ValueListenableBuilder<String?>(
                      valueListenable: lastSignal,
                      builder: (context, signal, _) =>
                          _readout(signal ?? 'no scroll yet'),
                    ),
                  ],
                ),
              ),
            ),
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
