/// The scene: field and cube in one shader, one pass.
///
/// Replaces the old pair of stacked shaders. They could not affect each other,
/// so the cube read as pasted on and a drawn ring stood in for light. Here the
/// cube's position is a uniform of the same program that draws the field, so
/// the field can actually be lit by it.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:portfolio/src/design/tokens.dart';
import 'package:portfolio/src/query_params.dart';
import 'package:portfolio/src/world/carving.dart';
import 'package:portfolio/src/world/shaders.dart';
import 'package:portfolio/src/world/world_camera.dart';

/// Where the cube sits inside its own location, as a fraction of the viewport.
///
/// It travels WITH its section: at camera position 1 the hero is one screen to
/// the left, so the cube is too. That falls out of the maths below rather than
/// needing to be animated.
const double kCubeX = 0.5;
const double kCubeY = 0.34;

/// The cube's own size in the world: its half-width, in the units the table is
/// built in. The ledge runs from z = -0.95 in front to 3.1 behind.
///
/// ⚠️ THIS IS THE OBJECT. [kCubeSize] below is the CAMERA — it keeps every
/// proportion identical and merely crops the view, which is the wrong lever for
/// "make the cube bigger" and was tried first.
///
/// ⚠️ AND THE SURFACE DOES NOT CHANGE WITH IT: the material is defined on a
/// cube of fixed size and scaled, so a larger cube is the same stone, larger —
/// same blocks per face, each covering more pixels. That is the point of it on
/// a phone.
///
/// ⚠️ THE LAYOUT IS DELIBERATELY UNTOUCHED. The statement is held clear of the
/// cube's BASE, and the base rests on the table at any size — growing the cube
/// extends it upward, away from the type. The energy does not move either; it
/// spreads from the world origin rather than from the cube's surface. An
/// earlier attempt "fixed" the layout to track this and was pure added risk.
///
/// Clamped below 0.95, where the ledge ends in front; larger and the cube would
/// hang over the edge. `?cube=`.
///
/// 0.80 is his, chosen together with [kCubeZ] rather than on its own: standing
/// the object further back shrinks it, so the two were settled as one
/// composition — bigger stone, further away.
final double kCubeHalf = qDouble('cube', 0.80).clamp(0.30, 0.90);

/// How far back the cube sits from where it used to, in world units.
///
/// The cube stood at the world origin, which left **0.25 units of glass in
/// front of it and 2.4 behind** — parked at the lip of a ledge with all of its
/// room on the far side. This slides it into that room. Positive is away from
/// the camera; 0 is exactly where it was.
///
/// ⚠️ FURTHER BACK IS ALSO SMALLER, because this is an honest camera rather
/// than a composition trick. For further back AND as massive, pair it with
/// `?cube=` — that is what having both is for.
///
/// The clamp keeps the object on the sheet at the largest cube the size knob
/// allows: the ledge runs from -0.95 in front to 3.1 behind, so 1.8 plus a
/// half width of 0.9 still lands clear of the back edge. `?depth=`.
///
/// 0.5 is his. With the 0.80 cube that puts the front face 0.65 units clear of
/// the lip instead of 0.25 — the object standing ON the ledge rather than
/// balanced at the end of it — while staying close enough that the statement
/// below still sits in the light it takes its colour from.
final double kCubeZ = qDouble('depth', 0.5).clamp(0.0, 1.8);

/// The cube's resting pose, in DEGREES about the vertical axis.
///
/// ⚠️ A POSE, NOT A SPIN. Choosing where the object sits, not animating it.
///
/// It is a composition control: the camera stands about 55 degrees off the
/// cube's axes, so an unturned cube presents its two visible faces at the same
/// incidence. Turning it squares one face to the eye and lays the other down.
/// Degrees rather than radians because that is what anyone has an opinion in.
///
/// 75 is his choice, made on the running scene. It is close to a quarter turn,
/// so it is very nearly the unturned pose again — but 15 degrees short of it,
/// which is what keeps the two visible faces at clearly different incidences
/// instead of the matched pair at 0 and the near-square face at 90. `?spin=`.
final double kSpin = qDouble('spin', 75);

/// The pose as (cos, sin), turned once here rather than once per pass.
final double kSpinCos = math.cos(kSpin * math.pi / 180.0);
final double kSpinSin = math.sin(kSpin * math.pi / 180.0);
final double kSpinRadians = kSpin * math.pi / 180.0;

/// The table's material: 1 real glass, 0 the diagnostic grey.
///
/// ⚠️ THE GREY WAS SCAFFOLDING AND IS NOW BEHIND THE SWITCH, not in front of
/// it. Real glass on a dark ground reflecting a dark object is very nearly
/// invisible, and while the energy was being built we could not tell whether
/// that was the material being subtle or the plane never being hit at all. The
/// opaque grey answered that question and then overstayed by several days.
///
/// `?glass=0` brings it back, which is worth keeping: it is still the fastest
/// way to prove the surface is being hit when something about the table looks
/// wrong.
///
/// Switching it is a bigger change than a material. The contact shadow and the
/// contact darkening both work by MULTIPLYING the surface, so a nearly
/// invisible surface takes the cube's grounding with it — that was the risk
/// when this went on, and it was checked: the cube keeps its footing.
final double kGlass = qDouble('glass', 1);

/// Cube size as a fraction of the viewport's shortest side.
const double kCubeSize = 0.26;

/// What the cube is made of. `?mat=`.
///
///   0  the plain near-black solid this project ran on for days
///   1  ancient mossed Inca masonry, with a carving in it
///   2  glass — the same material as the sheet it stands on
///
/// ⚠️ IT WAS A TWO-WAY SWITCH AND IS NOW A SELECTOR, because "what is this
/// object made of" turned out to have more than two answers and none of them is
/// a tuning dial. Each is a different claim about what the mark IS, and all
/// three stay reachable rather than being replaced in turn.
///
/// ⚠️ THE STONE CUBE IS NOT BEING ABANDONED. It is a day of work and a whole
/// design, and is likely to be lifted into its own project later. Living behind
/// `?mat=1` means it can be walked back into at any moment; living only in git
/// would mean rebuilding to see it, which in practice means never.
/// Still defaulting to the stone while the glass is being built — the default
/// moves with the commit that makes 2 a real material, not before it.
final double kMaterial = qDouble('mat', 1).clamp(0.0, 2.0);

/// Which model lights the ancient cube's carving. `?carving=`.
///
///   0  an EMISSIVE surface — the channel's floor gives off light, tinted by
///      the moss it passes through on the way out
///   1  GLASS filled with the sheet's own fog, seen through a real Fresnel
///
/// Both are complete designs and the second replaced the first. It is kept
/// because a knob compares two things on one screen in one moment, and a commit
/// hash compares two memories.
final double kCarvingModel = qDouble('carving', 1).clamp(0.0, 1.0);

/// The cube's tuning knobs, live on the deployed build.
///
/// ⚠️ THEY EXIST BECAUSE THE ALTERNATIVE IS WHAT WE DID ALL DAY: change a
/// constant, rebuild for fifty seconds, look, change it again. Every one of
/// these is a number that turned out to be wrong at least once.
///
/// ⚠️ AND [kLevel] AND [kFuzz] ARE SEPARATE ON PURPOSE. The cube went too
/// bright and then too dark because both were moved together — the rim was the
/// fault and the overall level was fine, but adjusted as one they could not be
/// told apart.
final double kLevel = qDouble('lvl', 1).clamp(0.2, 3.0);
final double kFuzz = qDouble('fuzz', 1).clamp(0.0, 4.0);
final double kMoss = qDouble('moss', 1).clamp(0.0, 2.0);
final double kLichen = qDouble('lich', 1).clamp(0.0, 2.0);

/// How deep the carving is cut. 0 leaves the cube uncarved. `?carve=`.
///
/// ⚠️ THE CARVING IS CUT, NOT DRAWN, and this is the one number that says how
/// much. Nothing anywhere paints a line: the shader lowers the surface, and the
/// material treats a low place the way it already treats a masonry joint —
/// water gathers, moss grows, lichen stays away, and the pattern appears
/// because something grew in it. Same mechanism that makes the blocks legible
/// without a single joint being drawn.
///
/// So this knob is really "how much water does the pattern hold", and 0 is a
/// genuine A/B rather than a disabled feature.
final double kCarve = qDouble('carve', 1).clamp(0.0, 2.0);

/// How much of a face the carved symbol spans, from its centre out. `?glyph=`.
///
/// 1 puts the symbol's cell exactly on the face's edges — the letters sit well
/// inside that, because a glyph does not fill its own box. Past about
/// 1.5 they start running into the cube's corners, where the masonry's own
/// chamfer is, so the clamp is generous rather than tight and the judgement
/// stays his.
final double kGlyphSize = qDouble('glyph', 1.1).clamp(0.3, 2.0);

/// How much energy escapes through the carving. `?emit=`.
///
/// ⚠️ THIS IS WHAT THE CARVING IS FOR. The letters are not a groove that
/// happens to catch the light — they are the CHANNEL the cube's energy leaves
/// through, which is also the answer to why this object glows at all. A solid
/// glowing generally is a lamp; a solid glowing along a carved pattern is an
/// artifact doing something.
///
/// It takes the same colour as the flow across the glass, from the same
/// constant, because it is the same substance: the cube is the source and the
/// surface carries it outward. Tuned apart they would drift into two effects
/// that merely sit next to each other.
final double kEmit = qDouble('emit', 1).clamp(0.0, 4.0);

/// How full of glass the carved channel is. `?inlay=`.
///
/// ⚠️ A KNOB BECAUSE I ASKED HIM A QUESTION HE COULD NOT ANSWER. I described
/// two options in a paragraph — glass poured level with the stone, or sitting
/// below it with the stone lipping over — and asked him to choose. His answer
/// was that a paragraph about two things nobody can see is not something anyone
/// can have an opinion about, which is right, and is written down elsewhere in
/// this project as a rule I keep having to relearn.
///
/// 1 pours it level: a deliberate inlay, finished, precious. Lower sinks it
/// below the rim, so stone lips over the edge and catches shadow along one side
/// — older, rougher, more weathered. Both are defensible; they are different
/// objects, and he can now look at them instead of reading about them.
final double kInlay = qDouble('inlay', 1).clamp(0.15, 1.0);

/// Stones across one face.
///
/// ⚠️ THE ONLY ONE WITH A REAL FLOOR AND CEILING RATHER THAN A RANGE. A face is
/// about 55 pixels on a phone: under four stones stops reading as a wall, and
/// over eight turns the joints to mush. The clamp is the constraint, not taste.
final double kBlocks = qDouble('blocks', 3.4).clamp(3.0, 9.0);

/// What fraction of full resolution the scene shader renders at.
///
/// Fill rate is the cost model, so this is the one lever that reduces work
/// without changing what the shader computes. Only the shader softens; the text
/// is a separate layer and is always at full resolution.
///
/// ⚠️ 1.0 IS NATIVE, AND IT IS WHAT THE CACHING WORK WAS FOR. It ran at 0.7 for
/// three days because the frame could not afford more, and that softness landed
/// on the cube's edges — the one surface in this scene that must never be soft.
/// Caching the static parts bought it back: 45-50 fps at 0.7 before, against a
/// stable 75 at 1.0 after, measured against the pre-caching commit on the same
/// machine on the same afternoon.
///
/// ⚠️ AND IT IS THE MEASURING INSTRUMENT. Frame rate near the display's cap
/// tells you almost nothing: everything piles up against the same ceiling and
/// differences vanish. Raising this pushes the whole scene well below the cap,
/// where a change of a few percent is a change of a few frames instead of
/// nothing at all. Profile at 1.3, decide at 1.0. `?scale=`.
final double kSceneScale = qDouble('scale', 1).clamp(0.3, 2.0);

/// Feature switches — `?off=`, a SUM of the ones to drop.
///
/// ⚠️ IT STARTED AS A PROFILING TOOL AND IS NOW HOW THIS SCENE IS JUDGED. Every
/// part of it is layered on every other part, so "is this better" is usually
/// unanswerable until the thing under discussion is the only thing changing. He
/// asked for exactly that: the same build, with pieces turned off.
///
///     1 cast shadow          2 contact darkening    4 energy on the sheet
///     8 glass transmission  16 reflection + ghost  32 the star field
///    64 the cube's antialiasing
///   128 the fog inside the carving
///   256 the burning cut edges of the carving
///   512 the carving's glass MATERIAL — leaves it an unlit hole in the stone
///  1024 the pool the carving casts on the sheet
final double kOff = qDouble('off', 0);

/// Pins the scene's clock to a fixed second. Negative means run normally.
///
/// ⚠️ A MEASURING INSTRUMENT, and it exists because two separate conclusions
/// today were wrong without it. Everything in this scene moves, so two captures
/// are never of the same picture — the flow across the glass changes a third of
/// its pixels in a few seconds. That makes any before-and-after comparison a
/// comparison of two different moments, and a real change of a few percent
/// vanishes underneath it. Worse, it produced a confident WRONG reading: adding
/// light to the glass appeared to make it darker.
///
/// Page load timing varies too, so "capture both after 25 seconds" does not pin
/// the clock either. This does. With `?t=` set, two builds render the identical
/// frame and a pixel difference means exactly what it looks like.
///
/// The project's own rule was "never pixel-diff whole frames, the shader
/// animates". This is how that rule stops applying. `?t=`.
final double kFrozenTime = qDouble('t', -1);

class WorldScene extends StatefulWidget {
  const WorldScene({required this.camera, super.key});

  final WorldCamera camera;

  @override
  State<WorldScene> createState() => _WorldSceneState();
}

class _WorldSceneState extends State<WorldScene>
    with SingleTickerProviderStateMixin {
  ui.FragmentShader? _shader;
  /// ⚠️ A SECOND, SEPARATE SHADER INSTANCE FOR THE LAYER PASS.
  ///
  /// A FragmentShader carries its uniforms in a buffer that is read when the
  /// picture is RASTERISED, not when it is recorded — and `toImageSync` does
  /// not promise to rasterise before it returns. So recording the layer pass,
  /// then setting the uniforms for the scene pass on the same object, let the
  /// layer be drawn with the scene's values: it sampled the empty placeholder
  /// and stored black. The cube came out perfectly shaped and perfectly black.
  ///
  /// One shader per pass, and the two can never tread on each other.
  ui.FragmentShader? _layerShader;
  /// A third instance, for the light map — same reasoning as _layerShader.
  ui.FragmentShader? _lightShader;
  /// A fourth, for the band — same reasoning again.
  ui.FragmentShader? _bandShader;
  /// A fifth, for the energy — same reasoning again.
  ui.FragmentShader? _energyShader;
  /// A sixth, for the cube's coverage — same reasoning again.
  ui.FragmentShader? _coverShader;
  /// A seventh, for the carving's emission potential — same reasoning again.
  ui.FragmentShader? _emitShader;
  late final Ticker _ticker;
  double _time = 0;
  final _CubeCache _cubeCache = _CubeCache();
  final _LightCache _lightCache = _LightCache();
  final _BandCache _bandCache = _BandCache();

  @override
  void initState() {
    super.initState();
    // ⚠️ SYNCHRONOUS. The program was loaded before the first frame — see
    // [Shaders] — so the scene is drawn properly from the very first frame
    // instead of showing flat background until an await completed.
    _shader = Shaders.scene?.fragmentShader();
    _layerShader = Shaders.scene?.fragmentShader();
    _lightShader = Shaders.scene?.fragmentShader();
    _bandShader = Shaders.scene?.fragmentShader();
    _energyShader = Shaders.scene?.fragmentShader();
    _coverShader = Shaders.scene?.fragmentShader();
    _emitShader = Shaders.scene?.fragmentShader();
    // ⚠️ Runs CONTINUOUSLY, unlike the camera's ticker. Ambient motion is the
    // point of the field, so there is no idle state — a standing cost, and the
    // reason fill rate has to be measured rather than assumed.
    _ticker = createTicker((elapsed) {
      setState(() {
        _time = kFrozenTime >= 0
            ? kFrozenTime
            : elapsed.inMicroseconds / 1e6;
      });
    });
    unawaited(_ticker.start());
  }

  @override
  void dispose() {
    _ticker.dispose();
    _shader?.dispose();
    _layerShader?.dispose();
    _lightShader?.dispose();
    _bandShader?.dispose();
    _energyShader?.dispose();
    _coverShader?.dispose();
    _emitShader?.dispose();
    _cubeCache.dispose();
    _lightCache.dispose();
    _bandCache.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shader = _shader;
    final layerShader = _layerShader;
    final lightShader = _lightShader;
    final bandShader = _bandShader;
    final energyShader = _energyShader;
    final coverShader = _coverShader;
    final emitShader = _emitShader;
    if (shader == null ||
        emitShader == null ||
        coverShader == null ||
        energyShader == null ||
        layerShader == null ||
        lightShader == null ||
        bandShader == null) {
      return const ColoredBox(color: Palette.bg);
    }
    return CustomPaint(
      painter: _ScenePainter(
        shader: shader,
        layerShader: layerShader,
        lightShader: lightShader,
        bandShader: bandShader,
        energyShader: energyShader,
        coverShader: coverShader,
        emitShader: emitShader,
        lightCache: _lightCache,
        bandCache: _bandCache,
        time: _time,
        camera: widget.camera.position,
        velocity: widget.camera.velocity,
        cache: _cubeCache,
      ),
      size: Size.infinite,
    );
  }
}

/// The cube's shading, drawn once and kept.
///
/// ⚠️ NOTHING ABOUT THE CUBE CHANGES BETWEEN FRAMES. The camera is fixed, the
/// light is fixed, the pose and size are constants, and the material has no
/// notion of time. Its picture is therefore identical every frame, and it was
/// being recomputed sixty times a second — measured at 8.8 ms of a 41.7 ms
/// frame, the largest single item in the scene.
///
/// ⚠️ THE FAILURE MODE IS A STALE CUBE, so the signature below is the whole
/// safety argument: it lists EVERY input the cube's shading depends on, and any
/// change to any of them throws the picture away. Miss one and the cube quietly
/// stops responding to it. That is why the material knobs are in here even
/// though they only ever arrive from the URL — a value that cannot change today
/// is one refactor away from changing tomorrow.
class _CubeCache {
  ui.Image? image;
  /// Coverage and the sub-pixel offset — see uLayer 6. Cached alongside the
  /// shading and invalidated with it, because they answer the same question
  /// about the same fixed object.
  ui.Image? cover;

  /// How much energy the carving COULD emit at each pixel — see uLayer 7.
  ///
  /// ⚠️ THE STATIC HALF OF A MOVING EFFECT, and splitting it out is what lets
  /// the carving breathe without costing the frame rate. Where the letters are,
  /// how deep the cut is, how much moss stands in the way: all fixed, all
  /// expensive, all cached here. How much energy is arriving at this instant is
  /// three octaves of noise, computed live in the scene pass and multiplied
  /// against this. Folding the two together would make the whole cube
  /// time-varying and throw away the caching that took the frame from 45 to 75.
  ui.Image? emit;
  String? signature;

  /// ⚠️ A SAMPLER THAT IS DECLARED MUST BE BOUND, ALWAYS.
  ///
  /// The shader declares the cube layer whichever pass is running, and the very
  /// first pass is the one that DRAWS that layer — so at that moment there is
  /// nothing to bind. Leaving it unbound is undefined: some backends read
  /// garbage, some fail the draw outright, and the whole frame goes with it.
  ///
  /// So there is always something bound, even if it is one black pixel that the
  /// layer pass never reads.
  ui.Image? _placeholder;

  ui.Image get placeholder {
    final existing = _placeholder;
    if (existing != null) return existing;
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 1, 1),
      Paint()..color = const Color(0xFF000000),
    );
    final picture = recorder.endRecording();
    final made = picture.toImageSync(1, 1);
    picture.dispose();
    _placeholder = made;
    return made;
  }

  /// The part of the signature that comes from the knobs, assembled once.
  ///
  /// ⚠️ IT STILL LISTS EVERY INPUT — that is the safety argument and it has not
  /// been weakened. What changed is only WHEN it is built: these are read from
  /// the page URL, which cannot change without a page load, so joining them
  /// into a string sixty times a second was pure waste. The per-frame part
  /// below is the part that can actually vary.
  static final String _knobs = [
    kCubeSize, kCubeHalf, kCubeZ, kSpin, kMaterial, kLevel, kFuzz, kMoss,
    kLichen, kBlocks, kCarve, kGlyphSize, kEmit, kInlay, kCarvingModel,
    kGlass, kOff,
    // ⚠️ WHETHER THE SYMBOLS EXIST IS AN INPUT LIKE ANY OTHER. They are awaited
    // before the first frame so this should always be true — but "should
    // always" is the kind of assumption a cache key exists to not rely on. If
    // the bake ever fails, the cube is cached uncarved and correctly stays that
    // way rather than being half one thing and half the other.
    Carving.map != null,
  ].join(',');

  /// Everything the cube's shading depends on. `time` is deliberately absent:
  /// that is the entire reason this works.
  static String signatureFor(Size low, double camera) =>
      '${low.width},${low.height},$camera,$_knobs';

  void dispose() {
    image?.dispose();
    image = null;
    cover?.dispose();
    cover = null;
    emit?.dispose();
    emit = null;
    _placeholder?.dispose();
    _placeholder = null;
    signature = null;
  }
}

/// The cast shadow and the contact darkening, baked over the table's surface.
///
/// ⚠️ IT DEPENDS ON THE CUBE ALONE — not on the camera, not on the viewport,
/// not on the window size. Fixed light, fixed occluder, fixed floor. So unlike
/// the cube's layer, travelling does not invalidate this at all, and neither
/// does resizing the browser.
///
/// Stored in the surface's own coordinate rather than on screen. The table
/// stretches away from the camera, so a screen-shaped map would be dense where
/// it is near and starved where it is far; in surface space the resolution is
/// even everywhere it matters.
class _LightCache {
  ui.Image? image;
  String? signature;

  /// 512 over eight world units: about 64 texels per unit, and the sharpest
  /// thing in it — the contact darkening right at the cube's foot — is a few
  /// texels across. Costs one megabyte, once.
  static const int size = 512;

  /// ⚠️ kCubeZ BELONGS HERE, and it is the easy one to forget: the map's
  /// CENTRE moved with the cube, not just its contents. Leave it out and
  /// sliding the cube back keeps the old shadow, baked at the old place.
  static final String wanted = [kCubeHalf, kCubeZ, kSpin, kOff].join(',');

  void dispose() {
    image?.dispose();
    image = null;
    signature = null;
  }
}

/// The galaxy's glow, kept until the sky has actually turned far enough to see.
///
/// ⚠️ THIS IS A THIRD KIND OF REUSE, and the distinction is worth keeping
/// straight. The cube's layer is cached because nothing about it CHANGES. The
/// band renders small because it has no DETAIL. This one is neither: it changes
/// continuously and it is already small — it just changes far slower than sixty
/// times a second.
///
/// The sky turns at 0.010 radians per second, so between two frames it moves
/// about a thousandth of a degree. Redrawing a whole pass for that is work
/// nobody can see, and — the reason this is worth doing at all — it was one of
/// five large textures allocated and released every frame. Cutting the rate by
/// fourteen removes most of that pass's share of the churn.
///
/// ⚠️ THE STARS ARE NOT FROZEN WITH IT, deliberately: they twinkle, and they
/// are drawn sharp at full resolution in the scene pass. That does decouple two
/// things designed to be one field — the glow and the star density come from
/// the band, the star POSITIONS are recomputed live — so the tolerance below is
/// what bounds the disagreement, and it is bounded at one pixel.
class _BandCache {
  ui.Image? image;
  Size? at;
  double camera = double.nan;
  double turn = double.nan;

  /// The sky's rotation, in radians. ⚠️ MIRRORS `bandOnly` IN THE SHADER — if
  /// the rates there change, this has to follow or the band stops refreshing at
  /// the right moments.
  static double turnFor(double time, double camera) =>
      time * 0.010 + camera * 0.085;

  /// How far the sky may turn before this is redrawn, in radians.
  ///
  /// Derived, not chosen: an angular change of `d` moves the sky across the
  /// screen by about `d` times the focal length in pixels, so allowing one
  /// pixel of movement in the buffer the scene is composed at means
  /// `1 / (focal in pixels)`. That is a fourteenth of the frames at a typical
  /// desktop size, and it scales correctly when the window does.
  ///
  /// ⚠️ kFocal MIRRORS THE SHADER's constant, same as turnFor above.
  static const double _kFocal = 2.7;
  static double toleranceFor(Size low) =>
      1.0 / (_kFocal * low.shortestSide * kCubeSize);

  bool stale(Size low, double time, double camera) =>
      image == null ||
      at != low ||
      // The camera does not only turn the sky, it re-aims every ray — so any
      // movement at all invalidates this, and during travel it redraws every
      // frame. That is correct, and travel is two seconds of a visit.
      this.camera != camera ||
      (turnFor(time, camera) - turn).abs() > toleranceFor(low);

  void store(ui.Image fresh, Size low, double time, double camera) {
    image?.dispose();
    image = fresh;
    at = low;
    this.camera = camera;
    turn = turnFor(time, camera);
  }

  void dispose() {
    image?.dispose();
    image = null;
    at = null;
  }
}

class _ScenePainter extends CustomPainter {
  const _ScenePainter({
    required this.shader,
    required this.layerShader,
    required this.lightShader,
    required this.bandShader,
    required this.energyShader,
    required this.coverShader,
    required this.emitShader,
    required this.lightCache,
    required this.bandCache,
    required this.time,
    required this.camera,
    required this.velocity,
    required this.cache,
  });


  final ui.FragmentShader shader;
  final ui.FragmentShader layerShader;
  final ui.FragmentShader lightShader;
  final ui.FragmentShader bandShader;
  final ui.FragmentShader energyShader;
  final ui.FragmentShader coverShader;
  final ui.FragmentShader emitShader;
  final double time;
  final double camera;
  final double velocity;
  final _CubeCache cache;
  final _LightCache lightCache;
  final _BandCache bandCache;

  @override
  void paint(Canvas canvas, Size size) {
    // ── Rendered below full resolution, then upscaled ───────────────────────
    //
    // The scene is a full-screen raytraced shader, so its cost is fill rate:
    // instructions × pixels × frames. Measured, the volumetric alone took the
    // frame from 75fps to 30. Pixel count is the only lever that reduces the
    // work without changing what the shader computes.
    //
    // ⚠️ It has to go through an offscreen buffer. Scaling the canvas
    // transform and drawing a smaller rect saves nothing — the same screen
    // area is still rasterised, so the same number of fragments run.
    //
    // The TEXT is unaffected: Flutter draws it as a separate layer at full
    // resolution, so only the shader softens. On a cloudy, noisy scene that is
    // close to invisible, which is why this is preferable to cutting the
    // march or the octaves.
    final low = Size(
      (size.width * kSceneScale).roundToDouble(),
      (size.height * kSceneScale).roundToDouble(),
    );
    if (low.isEmpty) return;

    // The cube belongs to the first location, so travelling moves it off
    // screen with its section — which falls out of the maths in configure()
    // rather than needing to be animated. Everything there is derived from the
    // size of the pass being configured, so the composition is identical at any
    // of them once upscaled.

    // Every uniform except the layer mode, which the caller supplies. Written
    // once and applied to both shaders so the two passes cannot drift apart.
    void configure(ui.FragmentShader s, double layer, [Size? at]) {
      final target = at ?? low;
      // ⚠️ DERIVED FROM THIS PASS'S OWN SIZE. The ray for a pixel is built from
      // where the cube's origin lands and how many pixels a world unit spans,
      // both in the CURRENT target's pixels. A smaller pass that inherited the
      // full-size numbers would aim every ray somewhere else.
      final tCubeX = target.width * (kCubeX - camera);
      final tCubeY = target.height * kCubeY;
      final tUnit = target.shortestSide * kCubeSize;
      // Flat indices in declaration order from the .frag.
      s
        ..setFloat(0, target.width)
        ..setFloat(1, target.height)
        ..setFloat(2, time)
        ..setFloat(3, camera)
        ..setFloat(4, velocity)
        ..setFloat(5, tCubeX)
        ..setFloat(6, tCubeY)
        ..setFloat(7, tUnit)
        // Indices follow scene.frag's declaration order, including uniforms
        // that are currently unused — the layout keeps them, so deleting one
        // silently shifts every index after it.
        ..setFloat(8, 0)   // uCubeGlow
        ..setFloat(9, 1)   // uSurface
        ..setFloat(10, 0)  // uSky — off; the shader is still compiled in
        ..setFloat(11, 1)  // uStars — space beyond the table
        // uClouds — the flying volumetric energy. OFF. Measured at ~60% of the
        // frame (75 FPS without it against 30 with). The surface energy is
        // unaffected: the waterfall over the glass edge lives in the surface
        // shading, not in the volumetric.
        ..setFloat(12, 0)
        // uMaterial — the cube's surface. `?mat=0` for the plain cube.
        ..setFloat(13, kMaterial)
        ..setFloat(14, kLevel)
        ..setFloat(15, kFuzz)
        ..setFloat(16, kMoss)
        ..setFloat(17, kLichen)
        ..setFloat(18, kBlocks)
        ..setFloat(19, kCubeHalf)
        ..setFloat(20, kSpinRadians)
        ..setFloat(21, kGlass)
        // uSpinCS — the pose as (cos, sin), turned once at startup rather than
        // a hundred times per pixel in the shader. See spinInto().
        ..setFloat(22, kSpinCos)
        ..setFloat(23, kSpinSin)
        // uOff — TEMPORARY profiling switches. `?off=`. Remove with the
        // shader's.
        ..setFloat(24, kOff)
        ..setFloat(25, layer)
        // uCubeZ and uCarve — appended after uLayer, and new ones go on the
        // END. Indices follow the .frag's declaration order, so inserting
        // above shifts every value into the wrong slot, silently.
        ..setFloat(26, kCubeZ)
        ..setFloat(27, kCarve)
        ..setFloat(28, kGlyphSize)
        ..setFloat(29, kEmit)
        ..setFloat(30, kInlay)
        ..setFloat(31, kCarvingModel);
    }

    // ⚠️ EVERY DECLARED SAMPLER MUST BE BOUND ON EVERY PASS, whether that pass
    // reads it or not — an unbound one is undefined and can take the whole
    // frame with it. The placeholder stands in wherever a real texture does not
    // exist yet, which on the first frame is all of them.
    void bind(ui.FragmentShader s, {ui.Image? band, ui.Image? energy}) {
      final blank = cache.placeholder;
      s
        ..setImageSampler(0, cache.image ?? blank,
            filterQuality: FilterQuality.low)
        ..setImageSampler(1, lightCache.image ?? blank,
            filterQuality: FilterQuality.low)
        ..setImageSampler(2, band ?? blank, filterQuality: FilterQuality.low)
        ..setImageSampler(3, energy ?? blank, filterQuality: FilterQuality.low)
        // ⚠️ NEAREST, NOT SMOOTH. Coverage and the offset are per-pixel
        // quantities on the same grid as the frame; interpolating them would
        // smear the cube's edge across its neighbours, which is the one thing
        // this whole layer exists to keep exact.
        ..setImageSampler(4, cache.cover ?? blank,
            // Spelled out although it is the default: every other sampler here
            // names its filtering, and a reader comparing them would otherwise
            // have to know the default to see that this one differs on purpose.
            // ignore: avoid_redundant_argument_values
            filterQuality: FilterQuality.none)
        // ⚠️ SMOOTH, AND IT MATTERS MORE HERE THAN ANYWHERE. This one holds
        // DISTANCES, and blending two distances gives a distance — which is the
        // entire reason the letters can be stored as an image at all. Sampled
        // nearest, the field would step, and the letter's edge would inherit
        // every one of those steps as a visible staircase.
        ..setImageSampler(5, Carving.map ?? blank,
            filterQuality: FilterQuality.low)
        ..setImageSampler(6, cache.emit ?? blank,
            filterQuality: FilterQuality.low);
    }

    /// Renders one of the small per-frame passes.
    ui.Image renderSmall(ui.FragmentShader s, double layer, Size at) {
      configure(s, layer, at);
      bind(s);
      final rec = ui.PictureRecorder();
      Canvas(rec).drawRect(Offset.zero & at, Paint()..shader = s);
      final pic = rec.endRecording();
      final made = pic.toImageSync(at.width.toInt(), at.height.toInt());
      pic.dispose();
      return made;
    }

    // ── The light map, baked only when the cube itself changes ──────────────
    //
    // Nothing about the camera reaches this: it is the shadow an object casts
    // on a floor under a fixed light, in the surface's own coordinates. So it
    // survives travelling and window resizes untouched, and in practice is
    // computed exactly once for the life of the page.
    final wantLight = _LightCache.wanted;
    if (lightCache.signature != wantLight || lightCache.image == null) {
      final lightLow = Size(
        _LightCache.size.toDouble(),
        _LightCache.size.toDouble(),
      );
      configure(lightShader, 3, lightLow);
      bind(lightShader);
      final rec = ui.PictureRecorder();
      Canvas(rec)
          .drawRect(Offset.zero & lightLow, Paint()..shader = lightShader);
      final pic = rec.endRecording();
      final fresh = pic.toImageSync(_LightCache.size, _LightCache.size);
      pic.dispose();
      lightCache.image?.dispose();
      lightCache.image = fresh;
      lightCache.signature = wantLight;
    }

    // ── The galaxy band and the energy, at a quarter of each side ────────────
    //
    // Neither needs resolution: both are smooth over the whole frame with no
    // edge of their own anywhere in them, and every edge in that part of the
    // picture belongs to something still drawn at full size. A sixteenth of the
    // pixels, and nothing to give it away.
    //
    // ⚠️ THEY DIFFER IN HOW OFTEN, THOUGH, AND BY A FACTOR OF FOURTEEN. The
    // energy is a flow the eye follows, so it is redrawn every frame. The sky
    // turns a thousandth of a degree in that time — see _BandCache.
    final bandLow = Size(
      (low.width * 0.25).roundToDouble(),
      (low.height * 0.25).roundToDouble(),
    );
    if (bandCache.stale(low, time, camera)) {
      bandCache.store(
        renderSmall(bandShader, 4, bandLow), low, time, camera,
      );
    }
    final bandImage = bandCache.image!;
    final energyImage = renderSmall(energyShader, 5, bandLow);

    // ── The cube's shading, redrawn only when something it depends on moves ──
    //
    // In production that means once, on load, and then never: the camera only
    // moves while travelling between sections, which is a couple of seconds of
    // a visit. During that motion the cube is redrawn every frame — correctly,
    // because panning changes which rays strike it — and it is sliding off the
    // screen anyway.
    final want = _CubeCache.signatureFor(low, camera);
    if (cache.signature != want ||
        cache.image == null ||
        cache.emit == null ||
        cache.cover == null) {
      // Coverage first: the shading pass and the scene pass both read it.
      configure(coverShader, 6, low);
      bind(coverShader, band: bandImage, energy: energyImage);
      final coverRec = ui.PictureRecorder();
      Canvas(coverRec)
          .drawRect(Offset.zero & low, Paint()..shader = coverShader);
      final coverPic = coverRec.endRecording();
      final freshCover =
          coverPic.toImageSync(low.width.toInt(), low.height.toInt());
      coverPic.dispose();
      cache.cover?.dispose();
      cache.cover = freshCover;

      configure(layerShader, 1); // uLayer: the cube's shading alone
      bind(layerShader, band: bandImage, energy: energyImage);
      final layerRecorder = ui.PictureRecorder();
      Canvas(layerRecorder)
          .drawRect(Offset.zero & low, Paint()..shader = layerShader);
      final layerPicture = layerRecorder.endRecording();
      final fresh =
          layerPicture.toImageSync(low.width.toInt(), low.height.toInt());
      layerPicture.dispose();
      // Replace, then dispose the old one — an image held across frames is a
      // real allocation, and dropping the reference does not release it.
      cache.image?.dispose();
      cache.image = fresh;

      // ⚠️ THE EMISSION POTENTIAL, IN ITS OWN PASS AND FOR A DIFFERENT REASON
      // FROM THE OTHERS. The shading and the coverage are cached because they
      // never change. This is cached because its EXPENSIVE half never changes —
      // where the letters are, how deep the cut is, how much growth stands in
      // the light's way. What moves is only how much energy is arriving, and
      // that is three octaves of noise applied live in the scene pass.
      //
      // It costs a second full evaluation of the material at cache time — paid
      // once on load, against a saving for the life of the page.
      configure(emitShader, 7, low);
      bind(emitShader, band: bandImage, energy: energyImage);
      final emitRec = ui.PictureRecorder();
      Canvas(emitRec).drawRect(Offset.zero & low, Paint()..shader = emitShader);
      final emitPic = emitRec.endRecording();
      final freshEmit =
          emitPic.toImageSync(low.width.toInt(), low.height.toInt());
      emitPic.dispose();
      cache.emit?.dispose();
      cache.emit = freshEmit;

      cache.signature = want;
    }

    // ⚠️ ASKED FOR EXPLICITLY. Flutter hands an image to a shader with
    // nearest-neighbour sampling by default, which would put hard pixel steps
    // on the cube — the one surface in this scene that must not have them.
    configure(shader, 2); // uLayer: read everything cached from textures
    bind(shader, band: bandImage, energy: energyImage);

    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(Offset.zero & low, Paint()..shader = shader);
    final picture = recorder.endRecording();
    final image = picture.toImageSync(
      low.width.toInt(),
      low.height.toInt(),
    );

    canvas.drawImageRect(
      image,
      Offset.zero & low,
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.high,
    );

    image.dispose();
    picture.dispose();
    // ⚠️ bandImage IS NOT DISPOSED HERE — the cache owns it now and will free
    // it when it replaces it, or when the widget goes away.
    energyImage.dispose();
  }

  @override
  bool shouldRepaint(_ScenePainter old) =>
      old.time != time || old.camera != camera || old.velocity != velocity;
}
