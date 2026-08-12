/// Sections as real routes, with their transitions driven by your hand.
///
/// ⚠️ THE GESTURE OWNS THE ROUTE'S ANIMATION. It does not trigger a clip and
/// wait. This is the pattern Flutter itself ships for the iOS back-swipe: a
/// [PageRoute] exposes the [AnimationController] behind its transition, and a
/// drag writes to it directly, so the section is wherever your finger has put
/// it and letting go either finishes the journey or returns it.
///
/// That is the only way to have BOTH — routes owning the pages, so the address
/// bar, the back button and deep links are the router's job rather than
/// bookkeeping we maintain, AND movement that follows a finger. A route
/// transition alone is time-based: a gesture can start it and nothing more.
///
/// ⚠️ AND A FORWARD SWIPE IS HARDER THAN A BACK SWIPE, which is why the
/// framework only ships the latter. Going back drives a route that already
/// exists underneath, so the drag can take it the instant the finger moves.
/// Going forward, the destination does not exist yet: it has to be pushed
/// first, and a route's controller is not born until it is installed. So the
/// first movement is BUFFERED and applied the moment the new route attaches.
/// One frame, and the alternative is a gesture that does nothing until the
/// route happens to be ready.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:portfolio/src/query_params.dart';
import 'package:portfolio/src/world/location_page.dart';
import 'package:portfolio/src/world/locations.dart';

/// How long a section takes when nothing is holding it — a nav click, or the
/// remainder of a throw.
const Duration kSectionTravel = Duration(milliseconds: 320);

/// How far a section must have moved for the swipe to be meant, in pixels.
///
/// ⚠️ A SWIPE STATES INTENT — IT DOES NOT POSITION ANYTHING. That is the whole
/// model, and getting it wrong is what made this feel broken for an afternoon.
///
/// A DRAG is continuous positioning: you move the thing, and where you release
/// decides. Under that model a slow, short, deliberate drag correctly returns,
/// because you did not take it far — and the only way to make it commit is to
/// put the point of no return a few percent from the edge, at which point every
/// accidental sideways movement navigates.
///
/// A SWIPE is a statement: direction is the message, and distance only has to
/// show you meant it. Twenty-odd pixels is past any twitch and nowhere near a
/// deliberate movement, so a slow small swipe and a fast one both land — which
/// is what a person doing it expects.
///
/// Dragging back to where you started still returns, because the section has
/// not moved: cancelling is expressed by putting it back, not by falling short.
const double _kMeantIt = 14;

/// How the remainder settles once a finger lets go.
const Curve _kSettle = Curves.easeOut;

/// A flick this fast means it even if it barely moved.
///
/// Not a second threshold arguing with the first — a different way of meaning
/// the same thing. A short sharp flick moves almost nothing and is unmistakably
/// deliberate.
const double _kFlick = 150;

/// The route a section is shown by.
class SectionPage extends Page<void> {
  const SectionPage({
    required this.location,
    required this.drag,
    required super.key,
  });

  final Location location;

  /// The hand that may take hold of this route's transition.
  final SectionDrag drag;

  @override
  Route<void> createRoute(BuildContext context) => SectionRoute(page: this);
}

class SectionRoute extends PageRoute<void> {
  SectionRoute({required SectionPage page}) : super(settings: page);

  SectionPage get _page => settings as SectionPage;

  @override
  Duration get transitionDuration => kSectionTravel;

  /// ⚠️ OPAQUE, DESPITE THE PAGE BEING TRANSPARENT. The scene is painted by the
  /// shell, underneath the whole navigator, so nothing here needs to see the
  /// route below once it has arrived — and NOT dropping it would leave the
  /// previous section built, drawing its own statement in the margins around
  /// the one on top.
  @override
  bool get opaque => true;

  @override
  bool get maintainState => true;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  /// The controller behind this route's transition, exposed so a drag can write
  /// to it.
  ///
  /// ⚠️ NOT A FIELD OF OUR OWN. [TransitionRoute] already has `controller`, and
  /// declaring another would shadow it — two names for one thing, with only one
  /// of them known to the framework. This hands out the real one, which is how
  /// Cupertino's back-swipe reaches it too.
  AnimationController? get transition => controller;

  @override
  AnimationController createAnimationController() {
    final made = super.createAnimationController();
    // Early, and only for a push a finger is already waiting on: the drag
    // needs the controller the moment it exists, which is before the route is
    // pushed.
    _page.drag.attachExpected(this);
    return made;
  }

  /// ⚠️ WHICH SECTION IS ON TOP IS A LIFECYCLE FACT, NOT A CREATION FACT.
  ///
  /// It was recorded when a route was built, which is right exactly once. Come
  /// back down the stack — home, work, about, then back to work — and work is
  /// on top again without being created again, so nothing said so and the back
  /// swipe had nothing to take hold of. Going home from there did nothing at
  /// all, and only after a full circle, which is what made it look mysterious.
  ///
  /// A route is told when it is pushed and when the one above it pops. Those
  /// are the two ways to arrive at the top, and together they are complete.
  @override
  TickerFuture didPush() {
    _page.drag.onTop = this;
    return super.didPush();
  }

  @override
  void didPopNext(Route<dynamic> nextRoute) {
    _page.drag.onTop = this;
    super.didPopNext(nextRoute);
  }

  @override
  void dispose() {
    _page.drag.detach(this);
    super.dispose();
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => LocationPage(location: _page.location);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // ⚠️ LINEAR WHILE A FINGER IS ON IT. A curve applied to a dragged value
    // makes the content move at a different speed from the hand holding it,
    // which is the single thing that stops a gesture feeling attached. The
    // curve is only for the part nobody is touching.
    final arriving = _page.drag.isDriving(this)
        ? animation
        : CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
    final leaving = CurvedAnimation(
      parent: secondaryAnimation,
      curve: Curves.easeOutCubic,
    );

    return SlideTransition(
      // The section being covered gives way, moving a short distance rather
      // than the full width: it is being left behind, not thrown out.
      position: Tween<Offset>(
        begin: Offset.zero,
        end: const Offset(-0.25, 0),
      ).animate(leaving),
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(arriving),
        child: child,
      ),
    );
  }
}

/// `?swipe=1` — puts the last gesture's numbers on screen.
///
/// ⚠️ IT EXISTS BECAUSE FEELING IS NOT A MEASUREMENT. Four hypotheses about why
/// swipes were failing were all wrong, and it only broke open when the gesture
/// reported what it had actually measured: a velocity of exactly zero can mean
/// one thing, where "feels sticky" could have meant five.
final bool kSwipeReadout = qFlag('swipe');

/// What the last gesture measured. Only written when [kSwipeReadout] is on.
class SwipeReading {
  const SwipeReading({
    required this.moved,
    required this.velocity,
    required this.went,
    required this.forward,
  });

  /// How far the section actually travelled, in logical pixels.
  final double moved;

  /// How fast the finger was going when it let go, in pixels per second.
  final double velocity;

  final bool went;
  final bool forward;

  @override
  String toString() =>
      '${forward ? "fwd" : "back"}  moved ${moved.round()}px  '
      'v ${velocity.round()}  ${went ? "WENT" : "returned"}';
}

/// The last gesture's numbers, or null until one has been made.
final ValueNotifier<SwipeReading?> lastSwipe = ValueNotifier<SwipeReading?>(
  null,
);

/// The last scroll signal to arrive, described. Only written when
/// [kSwipeReadout] is on.
///
/// ⚠️ IT REPORTS THE KIND, WHICH IS THE ONE THING THAT CANNOT BE REASONED OUT.
/// Whether a given pointing device's sideways swipe reaches us as a TRACKPAD
/// scroll or as a mouse wheel is decided by a heuristic inside the engine,
/// against properties the browser does not standardise — so the only way to
/// know what a particular mouse on a particular browser produces is to swipe it
/// and read the answer.
final ValueNotifier<String?> lastSignal = ValueNotifier<String?>(null);

/// The hand on the transition.
///
/// Holds whichever section route is currently on top, so a drag can drive it,
/// and buffers movement that arrives before a freshly pushed route exists.
class SectionDrag {
  /// The section currently on top, and the one a back swipe takes hold of.
  ///
  /// ⚠️ MAINTAINED FROM ROUTE LIFECYCLE, NOT FROM CREATION. See
  /// [SectionRoute.didPopNext].
  SectionRoute? onTop;

  /// The one a finger is driving.
  SectionRoute? _driven;

  /// True between asking for a push and the route existing.
  bool _awaitingPush = false;

  /// Movement that arrived before there was anything to apply it to.
  double _pending = 0;

  /// ⚠️ A GESTURE CAN FINISH BEFORE ITS ROUTE EXISTS, and the short ones do.
  ///
  /// A forward swipe asks for a push, and the route's controller is not built
  /// until the frame after. A quick flick is over by then, so the release found
  /// nothing to settle and threw the whole gesture away — which is why LITTLE
  /// swipes did nothing while longer ones, which last long enough for the route
  /// to arrive, worked.
  ///
  /// So the release is buffered exactly as the movement is, and applied the
  /// moment there is something to apply it to.
  bool _releasedEarly = false;
  double _releasedAt = 0;
  bool _releasedForward = false;

  double _width = 1;

  /// A route has just been built. If a finger is waiting for it, hand it over
  /// along with the movement that happened while it was being created.
  void attachExpected(SectionRoute route) {
    if (!_awaitingPush) return;
    _awaitingPush = false;
    _driven = route;
    _advance(_pending);
    _pending = 0;
    if (!_releasedEarly) return;
    _releasedEarly = false;
    _settle(route, _releasedAt, forward: _releasedForward);
    _driven = null;
  }

  void detach(SectionRoute route) {
    if (identical(onTop, route)) onTop = null;
    if (identical(_driven, route)) _driven = null;
  }

  bool isDriving(SectionRoute route) => identical(_driven, route);

  /// How far the section being driven has actually moved, in logical pixels.
  ///
  /// ⚠️ IT COUNTS MOVEMENT BUFFERED BEFORE THE ROUTE EXISTED. A forward swipe
  /// asks for a push, and the controller is not born until the frame after — so
  /// a decision taken in those first events would measure zero and nothing
  /// would ever commit.
  double travelled({required bool forward}) {
    final transition = _driven?.transition;
    if (transition == null) return _awaitingPush ? _pending * _width : 0;
    return _travel(transition.value, _width, forward: forward);
  }

  /// True once the section has moved far enough that the swipe was meant.
  ///
  /// ⚠️ THE SAME STATEMENT OF INTENT A FINGER MAKES, ASKED CONTINUOUSLY. A
  /// finger has a release to be asked at; a scroll stream has none, so the
  /// question is put after every delta instead. It is the same threshold and
  /// the same meaning — only the moment of asking differs.
  bool meant({required bool forward}) =>
      travelled(forward: forward) >= _kMeantIt;

  /// How far a section has travelled, given where its transition stands.
  ///
  /// The two directions run to opposite ends: driving one IN completes at 1,
  /// driving one OUT completes at 0.
  static double _travel(double value, double width, {required bool forward}) =>
      forward ? value * width : width - value * width;

  /// Takes hold of the section already on top, to drive it BACKWARDS. This is
  /// the framework's own back-swipe: the route exists, so the finger owns it
  /// from the first pixel.
  void beginBack(double width) {
    _width = width <= 0 ? 1 : width;
    _pending = 0;
    _awaitingPush = false;
    _driven = onTop;
    onTop?.navigator?.didStartUserGesture();
  }

  /// Takes hold of a section that is about to be pushed, to drive it FORWARDS.
  ///
  /// Its controller does not exist yet — a route builds one when it is
  /// installed — so movement is stored and applied by [attachExpected].
  void beginForward(double width) {
    _width = width <= 0 ? 1 : width;
    _pending = 0;
    _awaitingPush = true;
    _driven = null;
    onTop?.navigator?.didStartUserGesture();
  }

  /// Moves the section by [dx] logical pixels of finger.
  void update(double dx) {
    final progress = dx / _width;
    if (_driven?.transition == null) {
      if (_awaitingPush) _pending += progress;
      return;
    }
    _advance(progress);
  }

  void _advance(double progress) {
    final transition = _driven?.transition;
    if (transition == null) return;
    transition.value = (transition.value + progress).clamp(0.0, 1.0);
  }

  /// Lets go, and either finishes the journey or takes it back.
  ///
  /// A throw decides on its own; otherwise how far through it got decides, so
  /// a slow drag past the point of no return still lands.
  ///
  /// ⚠️ THE TWO DIRECTIONS SETTLE TO OPPOSITE ENDS. Driving a section IN, the
  /// journey completes at 1. Driving one OUT — a back swipe — the journey
  /// completes at 0, and the route is then gone. Both are the same controller
  /// moving; only which end means "done" differs.
  void release(double velocity, {required bool forward}) {
    final route = _driven;
    onTop?.navigator?.didStopUserGesture();

    // The route has been asked for but does not exist yet. Keep the decision;
    // attachExpected will carry it out.
    if (route == null && _awaitingPush) {
      _releasedEarly = true;
      _releasedAt = velocity;
      _releasedForward = forward;
      return;
    }

    _driven = null;
    _awaitingPush = false;
    _pending = 0;
    if (route == null) return;
    _settle(route, velocity, forward: forward);
  }

  /// Finishes the journey or takes it back.
  ///
  /// ⚠️ DECIDED BY WHERE IT WOULD LAND, NOT BY TWO SEPARATE THRESHOLDS. It used
  /// to ask "did it travel far enough?" OR "was it thrown hard enough?", and a
  /// small quick swipe falls between the two: not far, not fast, so it rolled
  /// back even though every part of it said forward. Projecting the release
  /// velocity forward and asking whether THAT is past halfway is one continuous
  /// test that both kinds of gesture pass.
  void _settle(SectionRoute route, double velocity, {required bool forward}) {
    final transition = route.transition;
    if (transition == null) return;

    // Did this say anything? Either it moved far enough to be meant, or it was
    // flicked hard enough to be meant. Both are the same statement.
    final travelled = _travel(transition.value, _width, forward: forward);
    // Forwards is a leftward throw; backwards is a rightward one.
    final flicked = forward ? velocity < -_kFlick : velocity > _kFlick;
    final complete = travelled >= _kMeantIt || flicked;

    if (kSwipeReadout) {
      lastSwipe.value = SwipeReading(
        moved: travelled,
        velocity: velocity,
        went: complete,
        forward: forward,
      );
    }

    if (forward == complete) {
      unawaited(
        transition.animateTo(1, duration: kSectionTravel, curve: _kSettle),
      );
      return;
    }

    // ⚠️ POP IT — DO NOT REMOVE IT, AND DO NOT ANIMATE IT OUT BY HAND.
    //
    // The pages are declarative: the router owns the list and the Navigator
    // renders it. Taking a route out of the Navigator directly leaves the
    // router still holding it, so the address bar and the nav went on saying
    // "about" while the screen showed Work — and with the two stacks
    // disagreeing, nothing navigated afterwards.
    //
    // A pop is the one action both understand. The Navigator animates the route
    // out from wherever the finger left it, using this same controller, and the
    // router sees the page go and writes the address to match.
    route.navigator?.pop();
  }
}
