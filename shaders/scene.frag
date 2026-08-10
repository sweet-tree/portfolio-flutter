// THE SCENE. One shader, one pass: a world, a glass surface, and the cube.
//
// This is a real scene, not a trick that works from one angle. Earlier
// versions rotated the ray into the cube's frame and put the "floor" at the
// cube's base in THAT frame, so the surface tilted with the object instead of
// being a surface. Here there is a world: a horizontal plane at y = 0, a cube
// resting on it, a camera looking at both, and an area light.
//
// What is traced rather than faked:
//   · the cube             — exact analytic ray/box intersection
//   · its cast shadow      — rays toward an AREA light, so the penumbra is real
//   · contact occlusion    — hemisphere rays that actually query the box
//   · the glass reflection — a real reflected ray shaded by the same code
//   · transmission         — the background refracted through the surface
//
// Sampling patterns follow flutter_scene: a Poisson disk rotated per pixel by
// interleaved gradient noise, which turns banding into noise the eye ignores.
//
// Cost is fill rate. The expensive work (shadow, occlusion) runs only on
// surface pixels near the cube, where it is visible.

#version 460 core
#include <flutter/runtime_effect.glsl>

precision highp float;

uniform vec2 uSize;
uniform float uTime;

// Field
uniform float uCamera;    // position in locations; 1.0 == one section
uniform float uVelocity;  // locations per second, drives the smear

// Scene placement
uniform vec2 uCubeCenter;  // where the cube's world origin lands, in pixels
uniform float uCubeUnit;   // pixels per world unit at the image plane
uniform float uCubeGlow;   // reserved; kept so the indices below do not move
uniform float uSurface;    // 0 = no surface, 1 = full glass
uniform float uSky;        // 0 = flat ground colour, 1 = the field
uniform float uStars;      // 0 = off, 1 = space beyond the table
uniform float uClouds;     // 0 = off, 1 = the flying volumetric energy

// ⚠️ APPENDED AT THE END ON PURPOSE. Uniform indices follow declaration order,
// so inserting one above would silently shift every index after it and every
// value would land in the wrong slot.
//
// WHAT THE CUBE IS MADE OF — a selector, not a dial:
//
//   0  the plain near-black solid this project ran on for days
//   1  ancient mossed Inca masonry, with a carving in it
//   2  glass — the same material as the sheet it stands on
//
// Each is a different claim about what the mark IS, and that is not a shader's
// choice to make. All three stay reachable rather than replacing one another.
uniform float uMaterial;

// ⚠️ THE TUNING KNOBS, ALL APPENDED AFTER uMaterial — see the note above about
// declaration order. They exist because the alternative is what we did all day:
// change a constant, rebuild, look, change it again. Every one of these is a
// number we argued about at least once.
//
// ⚠️ LEVEL AND FUZZ ARE SEPARATE ON PURPOSE. Moving both at once is exactly how
// the cube ended up too bright and then too dark — the rim was the problem and
// the overall level was fine, but they were adjusted together and the fault
// could not be told apart from the fix.
//
// Deliberately NOT knobs: individual colours, joint width, streak strength. A
// dial per constant is how a control panel becomes unusable.
uniform float uLevel;    // ?lvl=   overall material brightness
uniform float uFuzz;     // ?fuzz=  the soft rim on the growth
uniform float uMoss;     // ?moss=  how much of the surface is growth
uniform float uLichen;   // ?lich=  how much crust
uniform float uBlocks;   // ?blocks= stones across one face
uniform float uCubeHalf; // ?cube=   the cube's own size in the world
uniform float uSpin;     // ?spin=   the cube's resting pose, in radians
uniform float uGlass;    // ?glass=  0 the diagnostic surface, 1 real glass
uniform vec2 uSpinCS;    // (cos, sin) of the pose — see spinInto()

// ⚠️ TEMPORARY MEASURING TOOL — `?off=`, a sum of switches. Remove with its
// Dart setFloat when the profiling is done.
//
// It exists because guessing at where a shader spends its time has been wrong
// three times running. Turning one term off and reading the frame rate is the
// only honest way to find out, and it takes one build instead of one per guess.
//
//   1 cast shadow          2 contact darkening    4 the energy on the sheet
//   8 glass transmission  16 reflection + ghost  32 the star field
//  64 the cube's antialiasing
//
// And the carving, so each half of it can be judged on its own:
// 128 the fog inside the glass    256 the burning cut edges
// 512 the glass MATERIAL — leaves the channel an unlit hole in the stone
//1024 the pool the carving casts on the sheet
//
// Add them: ?off=3 drops both the shadow and the darkening; ?off=384 leaves the
// channel cut and glassy with nothing in it.
uniform float uOff;

// ⚠️ WHICH LAYER THIS PASS IS DRAWING.
//
//   0  the whole scene, cube shaded inline — the original path, kept as the
//      reference the cached path is checked against
//   1  the cube's SHADING ONLY, into a texture to be reused
//   2  the whole scene, reading those textures instead of tracing
//   3  the LIGHT MAP: the cast shadow and contact darkening over the table
//   4  the GALAXY BAND alone, at a fraction of the resolution
//   5  the ENERGY on the surface, likewise
//   6  the cube's COVERAGE and the offset its edge hands the backdrop
//   7  the cube's EMISSION POTENTIAL — how much the carving could put out,
//      before the live flow decides how much of it actually is
//
// ⚠️ THE CACHE HOLDS THE SHADING, NOT THE COVERAGE, and that is deliberate.
// The coverage loop also produces the offset that tells the backdrop where in
// the pixel to sample — the fix for the bright line along the cube's foot — and
// that offset has nowhere to live in four channels. Shading alone has no such
// coupling, and it is 8.8 ms of the 12.
//
// It also means there is no alpha to carry, which sidesteps this project's
// premultiplication trap and frees the channels to be used for precision.
uniform float uLayer;

/// How far back along z the cube sits, in world units. `?depth=`.
///
/// ⚠️ DECLARED LAST OF THE FLOATS, and it has to stay that way. Indices follow
/// declaration order, so putting this anywhere above `uLayer` would shift every
/// index after it and every value would land in the wrong slot — silently.
///
/// The cube was at the world origin, which put its front face 0.25 units from
/// the ledge's front edge and left 2.4 behind it. This slides it back into that
/// room. Positive is away from the camera; 0 is where it always was.
///
/// ⚠️ EVERYTHING GEOMETRIC FOLLOWS IT FOR FREE because it goes through
/// cubeOrigin() — the intersection, the shadow rays, the occlusion, the
/// antialiasing corner tests and the material's own coordinate. The two things
/// that did NOT follow are the energy's origin and the light map's centre, and
/// both are handled explicitly below; look for uCubeZ at those sites.
uniform float uCubeZ;

/// How deep the carving is cut, as a multiplier. 0 is uncarved. `?carve=`.
///
/// ⚠️ ALSO DECLARED AFTER uLayer — see the note on uCubeZ. New float uniforms go
/// at the END of this list, always.
uniform float uCarve;

/// How much of a face the symbol spans, from its centre out. `?glyph=`.
uniform float uGlyph;

/// How much energy escapes through the carving. 0 leaves it an unlit cut.
/// `?emit=`.
uniform float uEmit;

/// How full of glass the carved channel is. 1 pours it level with the stone;
/// below that it sits lower and the stone lips over it. `?inlay=`.
uniform float uInlay;

/// Where the symbols live on the glass cube: 0 nowhere, 1 suspended INSIDE the
/// solid, 2 frosted flat onto its faces. `?letters=`.
uniform float uLetters;

/// How much the glass swallows, as a multiplier. `?absorb=`.
uniform float uAbsorb;

/// How far apart the colour channels bend, as a multiple of real crown glass.
/// `?disp=`.
uniform float uDisp;

/// Which model lights the carving: 1 glass filled with fog, 0 the earlier
/// EMISSIVE surface. `?carving=`.
///
/// ⚠️ THE EMISSIVE ONE IS KEPT ON PURPOSE AND IS NOT DEAD CODE. It was rejected
/// for the ancient cube, but it is a whole design that took a day to reach and
/// this object is likely to be lifted into a project of its own later. Reaching
/// it through git means rebuilding to look at it; reaching it through a knob
/// means comparing two designs on one screen in one moment, which is the only
/// comparison that has ever settled anything here.
uniform float uCarving;

/// How strongly the CUBE bends light. 1 is none at all. `?ior=`.
///
/// ⚠️ SEPARATE FROM THE SHEET'S, WHICH STAYS AT REAL GLASS. The sheet is scenery
/// and should behave like a material; the cube is the mark, and a mark has a
/// different job.
///
/// ⚠️ AND IT IS SET TO 1 HERE, WHICH MEANS THIS CUBE DELIBERATELY DOES NOT
/// REFRACT. His reasoning, and it is the right one: a hiring manager sees this
/// object for ten seconds, notices instantly whether it is clean, and never once
/// wonders whether the optics are correct. Refraction at each face displaces the
/// view behind it by a different amount, so the horizon STEPS at every edge — a
/// real glass block does exactly that, and on a logo it reads as a mistake
/// rather than as physics.
///
/// The knob stays because it is genuinely useful elsewhere: at 1.5 this is real
/// glass and the whole apparatus behind it — chord, absorption, dispersion, the
/// displaced view — is correct and ready. Worth keeping for a project whose
/// subject IS a piece of glass rather than a mark made of one.
uniform float uIor;

/// How wide the symbols' edge ramp is, as a multiple of one pixel. `?edge=`.
///
/// ⚠️ ONE PIXEL IS THE TEXTBOOK ANSWER AND IT IS NOT ALWAYS THE RIGHT ONE. A
/// ramp exactly one pixel wide is the mathematically honest reconstruction of a
/// hard edge; below that it is technically under-filtered and will show a little
/// stair-stepping on a near-horizontal stroke, and above it it is simply blurred.
/// Which side of honest a LOGO should sit on is a judgement about how it reads,
/// not a number anyone can derive — so it is his to make rather than mine.
uniform float uEdge;

/// How strongly the PLATFORM'S energy climbs into the cube. `?wall=`.
///
/// ⚠️ THE SAME FIELD, READ IN A SECOND PLACE — not a third effect that resembles
/// the other two. Until now the sheet's flow, the cube's interior and the pool
/// beneath were three separate fields sharing a colour, and nothing fed anything.
/// Here the cube asks what the energy is doing on the platform DIRECTLY BENEATH
/// it and carries that upward, so the continuity is structural rather than
/// simulated: turn the sheet's flow up and the cube follows, because there is
/// only one of it.
///
/// ⚠️ AND IT IS VERY NEARLY FREE, which is the surprise. The sheet's energy is
/// already rendered once a frame into a texture at a sixteenth of the pixels, so
/// this costs ONE PROJECTION AND ONE LOOKUP against roughly 480 hashed noise
/// evaluations per pixel for the volumetric interior. About a hundredfold, not a
/// twofold.
///
/// The physical story is also the one this scene started from: both are glass,
/// they are in contact where the cube stands, and light trapped inside a sheet
/// climbing into a solid resting on it is exactly how an edge-lit acrylic sign
/// works.
uniform float uWall;

uniform sampler2D uCubeLayer;

/// The cast shadow and the contact darkening, baked over the table's surface.
/// Red is how much of the light reaches a point, green how open it is.
uniform sampler2D uLightMap;

/// The galaxy's diffuse glow, and how densely it packs stars. Smooth
/// everywhere, so it is rendered small and read back scaled up.
uniform sampler2D uBandMap;

/// The energy flowing over the glass. Cloud, with no edge of its own — the
/// edges in that part of the frame all belong to the surface it lies on.
uniform sampler2D uEnergyMap;

/// How much of each pixel the cube covers, and where inside that pixel it does
/// NOT — which is where the backdrop behind it must be sampled from.
uniform sampler2D uCubeCover;

/// The carved symbols, as a DISTANCE FIELD rather than a picture of them — two
/// cells side by side, `Di` then `Se`. Built from the site's own typeface before
/// the first frame; see carving.dart for why it is distance and not coverage.
uniform sampler2D uCarveMap;

/// How much energy each pixel of the cube COULD emit — the static half of the
/// carving's glow, cached with the shading. What is actually getting out right
/// now is this times cubeEnergyFlow, computed live.
uniform sampler2D uCubeEmit;

/// The cube's entry normal, RESOLVED ACROSS THE PIXEL rather than taken from one
/// ray through its centre.
///
/// ⚠️ THE COLOUR WAS ANTIALIASED AND THE GEOMETRY WAS NOT, and that asymmetry is
/// the whole reason the edges came apart. The 64-sample pass resolves the cube's
/// colour and its descriptor properly — but transmission, reflection and the lit
/// rim are computed fresh every frame, and they were reading the geometry from a
/// single ray through the pixel's centre. One ray gives one answer: this face or
/// that face, hit or miss, with nothing in between.
///
/// So at a silhouette pixel whose centre ray MISSES while the cube still covers
/// part of it, every live term vanished — including the rim, which is the bright
/// line itself. And at an internal edge the normal jumped from one face to the
/// other the instant the centre crossed, so the reflection stepped rather than
/// blending. Both are a hard yes/no where the coverage underneath was a smooth
/// fraction.
///
/// ⚠️ AND THE STONE CUBE HID IT COMPLETELY. There the live part was a small glow
/// on top of a fully resolved surface, so a flaw in its geometry was invisible.
/// On glass the live part IS the object, and the same flaw became the first
/// thing anyone sees. A defect that only shows once something else is removed
/// was never fixed — it was covered.
uniform sampler2D uCubeNormal;

out vec4 fragColor;

/// ⚠️ STORED THROUGH A SQUARE ROOT, and read back through a square.
///
/// The layer is an ordinary 8-bit image, and the cube's radiance lives near the
/// bottom of the range — a near-black stone lit dimly. Stored straight, one step
/// of 8-bit is 1/255 of the WHOLE range, which lands as visible banding once
/// the tone curve lifts the darks. A square root spends the codes where the
/// values actually are: at a radiance of 0.01 the step is five times finer.
///
/// Exactly invertible, and cheap in both directions.
/// How far the light map reaches from the cube, in world units.
///
/// ⚠️ IT ONLY HAS TO COVER WHERE THE ANSWER IS NOT 1. The shadow of an object
/// lit from above is contained — at the largest cube this reaches about 2.8
/// units — and the contact darkening cannot reach past its own 2.2 plus the
/// cube's radius. Four covers both with room. Beyond it the map is not read at
/// all and the answer is exactly 1, which is also what the analytic tests
/// already concluded.
const float kLightMapReach = 4.0;

/// The energy's ceiling, for storing it in eight bits. It peaks near 2 where
/// the flow is thickest — well past what a texture holds — so it is scaled down
/// and square-rooted on the way in, and squared back on the way out. The square
/// root matters: the field spends most of its range near zero, which is where
/// linear storage would band.
const float kEnergyMax = 2.5;
vec3 encodeEnergy(vec3 v) { return sqrt(clamp(v / kEnergyMax, 0.0, 1.0)); }
vec3 decodeEnergy(vec3 v) { return v * v * kEnergyMax; }

/// The sub-pixel offset, which is signed and never leaves the sample grid.
const float kOffsetRange = 1.5;

vec3 encodeLayer(vec3 v) { return sqrt(clamp(v, 0.0, 1.0)); }
vec3 decodeLayer(vec3 v) { return v * v; }

// ── World ───────────────────────────────────────────────────────────────────

/// The size the cube's MATERIAL WAS AUTHORED AT. Every threshold, block count
/// and pattern scale in cubeSurface was tuned against a cube this big, and —
/// more to the point — tuned against EACH OTHER.
const float kRefHalf = 0.55;

// ⚠️ THE CUBE'S SIZE IS A UNIFORM — `uCubeHalf`, driven by `?cube=`. GLSL will
// not initialise a global from a uniform, so the two values derived from it are
// functions; they fold to nothing.
//
// The centre sits one half-height up, so the BASE rests on y = 0 at any size.
// Growing the cube lifts its top, never its bottom, which is both what a larger
// stone on a table does and why the LAYOUT needs no changes: the statement is
// held clear of the cube's base, and the base does not move.
vec3 cubeHalf() { return vec3(uCubeHalf); }
vec3 cubeOrigin() { return vec3(0.0, uCubeHalf, uCubeZ); }

/// Where the cube stands on the SHEET, in the surface's own coordinate.
///
/// The sheet is unrolled flat by surfaceCoord — the ledge is (x, z) and the
/// drop keeps walking in the same direction — so on the ledge the cube's place
/// in it is simply its x and z. Both the energy and the light map need this,
/// and they need the SAME answer, so there is one definition.
vec2 cubeOnSurface() { return vec2(0.0, uCubeZ); }

// Three-quarter camera, offset to the side. The straight-on version put the
// ledge edge on a horizontal, which was geometrically what was asked for and
// looked worse — so this is back to the angled view.
const vec3 kEye = vec3(2.15, 1.95, -3.05);
const vec3 kTarget = vec3(0.0, 0.42, 0.0);
const float kFocal = 2.7;

// Area light. The radius is what gives the shadow a penumbra — a point light
// would give a hard-edged shadow, which never looks like a photograph.
const vec3 kLightPos = vec3(-2.6, 3.4, -2.1);
const float kLightRadius = 0.85;

// Where the ledge ends and the panel drops. In front of the cube, between
// it and the camera, so the panel descends into the lower half of the frame
// where the statement sits.
const float kEdgeZ = -0.95;

// The FAR edge of the ledge, behind the cube, and the thickness of the sheet
// there. A cut edge is where light trapped inside the glass escapes, so it is
// the brightest part of any glass table — and the natural place for the
// energy to enter later.
const float kBackZ = 3.1;
const float kEdgeThickness = 0.055;

// The table as SOLID GEOMETRY rather than intersecting half-planes.
// kRound is the radius of every edge; kFillet is the smoothing at the inner
// corner where the ledge meets the drop.
// ⚠️ WIDE ENOUGH FOR ITS OWN FADE, not merely wide enough to leave the frame.
// The surface fades with distance from the cube (see `presence` below) and only
// reaches its cutoff at a radius of about 10. At 7 the sheet ENDED while the
// surface was still ~2% lit — invisible arithmetic, but the ground here is
// nearly black, so it drew a hard straight line down the left side where the
// glass ran out. The camera stands at x = +2.15 and looks back across the
// sheet, which is why only the left end ever came into frame.
const float kTableHalfX = 11.0;
const float kSlab = 0.075;       // sheet thickness
const float kDropDepth = 6.0;    // how far the panel descends
const float kRound = 0.028;
const float kFillet = 0.09;

const float kIor = 1.5;             // glass
const float kGlassThickness = 0.05;

const float kMinRoughness = 0.045;

/// ⚠️ THE ONE COLOUR HERE THAT IS NOT FREE TO CHANGE.
///
/// This is the page's own background. `Palette.bg` and `web/index.html` both
/// say `#0B0B0F`, and they have to agree with the shader or the scene shows a
/// rectangle against the page — most visibly at load, when the HTML background
/// is painted for a moment before Flutter's first frame arrives.
///
/// ⚠️ SO IT IS THE PRE-IMAGE OF #0B0B0F, NOT #0B0B0F ITSELF. Everything this
/// shader computes is now raw brightness that is tone mapped ONCE at the end
/// (see the end of main), so a constant that must arrive at a specific colour
/// has to be the value that lands there AFTER the curve. Solved numerically
/// against ACESToneMap at kExposure; it renders to exactly 11, 11, 15.
///
/// Re-derive it if kExposure changes. Do NOT "fix" it back to 0.043 — that was
/// correct only while the background was the one thing skipping the curve.
const vec3 kBase = vec3(0.04842, 0.04839, 0.06014);
const vec3 kAccent = vec3(1.0, 0.353, 0.212);

/// The single exposure, applied with the tone curve at the very end of main.
///
/// It used to be written as a literal 1.25 at five separate call sites, which
/// is what made it possible for them to drift apart.
const float kExposure = 1.25;

bool isOff(float bit) { return mod(floor(uOff / bit), 2.0) >= 1.0; }

mat3 rotY(float a) {
  float c = cos(a);
  float s = sin(a);
  return mat3(c, 0.0, -s, 0.0, 1.0, 0.0, s, 0.0, c);
}

// ⚠️ THE CUBE'S POSE, PRE-TURNED INTO A MATRIX ON THE CPU.
//
// Every ray/cube test rotates into the cube's frame and its result back out —
// two matrices, so two sines and two cosines. A table pixel casts 28 of those
// tests between its shadow and its occlusion, and a pixel on the cube's edge
// casts 64. That was 56 and 128 pairs of transcendentals per pixel, all of them
// computing the same two numbers, because the pose is a uniform: one value for
// the entire frame.
//
// Sine and cosine run on a separate, slower unit on every GPU. Doing them once
// per frame on the CPU instead of a hundred times per pixel is free.
//
// `uSpinCS` is (cos, sin) of the pose. The sign flips between rotating into the
// cube's frame and back out, which is the only difference between the two.
mat3 spinInto() {
  return mat3(uSpinCS.x, 0.0, -uSpinCS.y,
              0.0, 1.0, 0.0,
              uSpinCS.y, 0.0, uSpinCS.x);
}

mat3 spinOutOf() {
  return mat3(uSpinCS.x, 0.0, uSpinCS.y,
              0.0, 1.0, 0.0,
              -uSpinCS.y, 0.0, uSpinCS.x);
}

// ── Background field ────────────────────────────────────────────────────────

float hash(vec2 p) {
  return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

float noise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  float a = hash(i);
  float b = hash(i + vec2(1.0, 0.0));
  float c = hash(i + vec2(0.0, 1.0));
  float d = hash(i + vec2(1.0, 1.0));
  return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
  float sum = 0.0;
  float amp = 0.5;
  for (int i = 0; i < 5; i++) {
    sum += amp * noise(p);
    p *= 2.03;
    amp *= 0.5;
  }
  return sum;
}

vec3 fieldColor(vec2 uv, float aspect, vec2 fragCoord) {
  vec2 p = vec2((uv.x * aspect + uCamera * 1.35) * 0.55, uv.y * 2.6);
  p.x /= 1.0 + abs(uVelocity) * 2.4;

  float t = uTime * 0.06;
  vec2 q = vec2(fbm(p + vec2(0.0, t)), fbm(p + vec2(5.2, 1.3)));
  vec2 r = vec2(
    fbm(p + 3.4 * q + vec2(1.7, 9.2) + t * 0.7),
    fbm(p + 3.4 * q + vec2(8.3, 2.8) - t * 0.5)
  );
  float f = fbm(p + 3.2 * r);

  vec3 col = mix(kBase, vec3(0.056, 0.055, 0.071), smoothstep(0.20, 0.98, f));
  col += kAccent * smoothstep(0.78, 1.02, f) * 0.16;
  float rim = smoothstep(0.56, 0.615, f) - smoothstep(0.615, 0.70, f);
  col += kAccent * rim * 0.09;
  col += vec3(0.062, 0.062, 0.075) * rim;
  col += (hash(fragCoord + fract(uTime) * 91.7) - 0.5) * 0.022;
  return mix(col, kBase, smoothstep(0.42, 1.0, uv.y) * 0.72);
}

/// How far a copy of the energy travels before it is retired, and how long that
/// takes.
///
/// ⚠️ SHARED BY THE FLOW ON THE GLASS AND THE FLOW INSIDE THE CUBE, and that is
/// the point rather than tidiness. They are one substance: it wells up inside
/// the object, escapes through the carving, and spreads across the sheet. If the
/// two were given their own rates they would beat against each other, and the
/// eye reads two things drifting at different speeds as two things.
const float kCycleDistance = 1.15;
const float kCyclePeriod = 5.0;

/// The energy's colour, wherever it appears.
///
/// ⚠️ ONE CONSTANT, FOUR PLACES: the flow across the glass, the glow inside the
/// carving, the pool that glow casts back onto the sheet, and its reflection.
/// They are one substance seen four ways, and the moment any of them gets its
/// own value they stop being one substance and become four effects that happen
/// to sit near each other.
const vec3 kEnergyTint = vec3(0.30, 0.58, 1.00) * 1.15 + kAccent * 0.12;

/// How much light the carving is putting out RIGHT NOW, as one number for the
/// whole pattern.
///
/// ⚠️ THIS IS DELIBERATELY NOT THE LOCAL FIELD, and the reason is statistical
/// rather than practical. What lands on the glass is the SUM of every lit point
/// on the cube, and a sum of many samples of a random field varies far less than
/// any single one of them does — so a pool of light cast by the whole carving
/// should breathe gently while individual letters churn. Following the local
/// flow here would make the whole table flicker in step with one letter, which
/// is both wrong and the kind of wrong that reads as a video effect.
///
/// Two waves at unrelated rates, so it never falls into an obvious loop, and
/// timed against the same cycle as everything else.
float carvingOutput() {
  float t = uTime / kCyclePeriod;
  return 0.78 + 0.22 * (0.62 * sin(t * 2.0) + 0.38 * sin(t * 3.1 + 1.7));
}

/// One advected sample of the energy field.
///
/// [advect] is how far the sample point has been slid outward along its own
/// radial direction. Sliding is what makes the pattern move away from the
/// cube — and also what shears it, because neighbouring pixels at different
/// angles slide different ways. Bounding how far any one sample is ever slid
/// is what keeps it cloudy; see surfaceEnergy.
float energyLayer(vec2 surf, vec2 dir, float advect) {
  vec2 q = surf * 0.85 - dir * advect;
  vec2 w = vec2(fbm(q + vec2(0.0, advect * 0.25)), fbm(q + vec2(4.7, 2.1)));
  return fbm(q + 2.6 * w);
}

/// The energy the cube emits, travelling the surface and pouring over the edge.
///
/// Sampled in CONTINUOUS surface coordinates, deliberately not polar — an
/// angle from `atan` has a branch cut that showed as a hard seam radiating
/// along the negative-x axis.
///
/// FLOW-MAP ADVECTION. Sliding a sample outward without limit stretches the
/// noise into long radial fibres, because each pixel slides along its own
/// direction. So two copies are advected half a cycle out of phase and
/// cross-faded: each is only ever slid up to half a cycle before a fresh one
/// replaces it, and the weight is zero exactly when a copy resets. The result
/// keeps moving outward but never accumulates stretch — it stays cloud.
/// The step unrolled into one flat sheet, so the ledge and the panel share one
/// coordinate. On the ledge it is simply (x, z); past the front edge, falling
/// by |y| keeps walking in the same direction, so the two agree exactly at the
/// lip and anything laid out in this space pours over it continuously.
///
/// ⚠️ SHARED, NOT COPIED. The energy flows in this space and the baked light
/// map is stored in it. If the two ever disagreed about where a point is, the
/// shadow would slide off the object casting it — so there is exactly one
/// definition and both call it.
///
/// `w` returns how much surface there is at all: zero on the sheet's thin edge,
/// where neither the top nor the front face applies.
vec3 surfaceCoord(vec3 p, vec3 n) {
  vec2 onLedge = p.xz;
  vec2 onDrop = vec2(p.x, kEdgeZ - max(-p.y, 0.0));

  float wTop = clamp(n.y, 0.0, 1.0);
  float wDrop = clamp(-n.z, 0.0, 1.0);
  float total = max(wTop + wDrop, 1e-4);
  return vec3((onLedge * wTop + onDrop * wDrop) / total, total);
}

/// The inverse: a point and a normal on the sheet, from a place on it. Only
/// exact on the two flat faces, which is all the light map needs — the rounded
/// lip between them is a fraction of a texel wide.
void surfacePoint(vec2 surf, out vec3 p, out vec3 n) {
  if (surf.y >= kEdgeZ) {
    p = vec3(surf.x, 0.0, surf.y);
    n = vec3(0.0, 1.0, 0.0);
  } else {
    p = vec3(surf.x, surf.y - kEdgeZ, kEdgeZ - kSlab);
    n = vec3(0.0, 0.0, -1.0);
  }
}

vec3 surfaceEnergy(vec3 p, vec3 n) {
  vec3 sc = surfaceCoord(p, n);
  vec2 surf = sc.xy;
  float total = sc.z;

  // ⚠️ MEASURED FROM THE CUBE, NOT FROM THE WORLD ORIGIN.
  //
  // These were the same point until the cube gained a depth knob, and the
  // distinction is the whole concept rather than a detail: the cube is the
  // SOURCE. Left measuring from the origin, sliding the cube back would leave
  // the glow where it was and the object would visibly stop emitting it.
  //
  // Only the DISTANCE and the DIRECTION move with it. The noise is still
  // sampled in the sheet's own fixed coordinate, so the pattern stays welded to
  // the glass instead of sliding across it when the cube moves.
  vec2 fromCube = surf - cubeOnSurface();
  float travelled = length(fromCube);
  vec2 dir = travelled > 1e-4 ? fromCube / travelled : vec2(1.0, 0.0);

  float phase = uTime / kCyclePeriod;
  float pa = fract(phase);
  float pb = fract(phase + 0.5);

  float a = energyLayer(surf, dir, pa * kCycleDistance);
  float b = energyLayer(surf, dir, pb * kCycleDistance);

  // Triangle weight: 0 when copy A has just reset, 1 when B has.
  float blend = abs(1.0 - 2.0 * pa);
  float f = mix(a, b, blend);

  // Decays with distance travelled, so the cube is unambiguously the source.
  // Slower decay reaches further across the ledge and further down the panel.
  float emit = exp(-travelled * 0.18) * (total > 0.05 ? 1.0 : 0.0);

  // Cooler than the sky field, which is warm from the accent. Same family,
  // clearly a different substance.
  vec3 tint = kEnergyTint;

  // A LOWER threshold turns more of the noise range into visible energy, so
  // the clouds are broader rather than only their brightest peaks showing.
  // Raising brightness alone would just blow out the peaks and leave the rest
  // dark, which reads as harsher, not brighter.
  return tint * smoothstep(0.28, 0.88, f) * emit * 1.7;
}

// ── Stars ───────────────────────────────────────────────────────────────────
//
// Sampled by RAY DIRECTION, not screen position. Stars are effectively at
// infinity, so they belong to where you are looking — which also means there
// is no 2D parameterisation, and therefore no seam of the kind the polar
// coordinates gave the surface energy.
//
// Cells in 3D: each cell may hold one star, jittered inside itself. Only a
// small neighbourhood matters because a star is tiny next to a cell, so this
// is 8 lookups per layer rather than 27.

float hash31(vec3 p) {
  p = fract(p * 0.3183099 + vec3(0.71, 0.113, 0.419));
  p *= 17.0;
  return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

/// 3D value noise, for structure that lives on the sphere of directions.
///
/// The band and its dust have to be sampled in 3D: any 2D parameterisation of
/// a sphere has a seam or a pole, and a dust lane crossing one would tear.
float noise3(vec3 p) {
  vec3 i = floor(p);
  vec3 f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  float n000 = hash31(i + vec3(0.0, 0.0, 0.0));
  float n100 = hash31(i + vec3(1.0, 0.0, 0.0));
  float n010 = hash31(i + vec3(0.0, 1.0, 0.0));
  float n110 = hash31(i + vec3(1.0, 1.0, 0.0));
  float n001 = hash31(i + vec3(0.0, 0.0, 1.0));
  float n101 = hash31(i + vec3(1.0, 0.0, 1.0));
  float n011 = hash31(i + vec3(0.0, 1.0, 1.0));
  float n111 = hash31(i + vec3(1.0, 1.0, 1.0));
  return mix(
    mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
    mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y),
    f.z
  );
}

float fbm3(vec3 p) {
  float sum = 0.0;
  float amp = 0.5;
  for (int i = 0; i < 5; i++) {
    sum += amp * noise3(p);
    p *= 2.07;
    amp *= 0.5;
  }
  return sum;
}

/// The same field, stopped after three octaves.
///
/// ⚠️ FOR ANYTHING SHADED PER SAMPLE RATHER THAN PER PIXEL. The cube's edges
/// are antialiased by shading 64 samples and averaging them, so every
/// instruction inside shadeCube is paid for 64 times on an edge pixel. The two
/// octaves dropped here carry detail finer than one pixel at the size the cube
/// is drawn — invisible, and 16 hash lookups each.
///
/// Its mean is the same as fbm3's; only its ceiling is lower (0.875 against
/// 0.969), so a threshold tuned against one is close but not identical on the
/// other.
float fbm3Coarse(vec3 p) {
  float sum = 0.0;
  float amp = 0.5;
  for (int i = 0; i < 3; i++) {
    sum += amp * noise3(p);
    p *= 2.07;
    amp *= 0.5;
  }
  return sum;
}

// The galactic plane's pole.
//
// ⚠️ CHOSEN AGAINST THE VISIBLE CONE, not by taste. The sky here is a narrow
// strip of directions passing just above the table's back edge — roughly
// (-0.53, 0.05, 0.85). For the band to cross that strip its POLE has to be
// close to perpendicular to it. The first value was ~25 degrees off, so all
// that showed was the band's faintest outer falloff and it read as nothing.
// This one is within a few degrees of perpendicular, and tilted so the band
// runs diagonally rather than level with the table.
const vec3 kGalacticPole = vec3(-0.72, 0.55, -0.42);

/// The Milky Way: a diffuse glow AND a star-density multiplier.
///
/// These are the same thing physically — the band is bright BECAUSE the stars
/// are dense there — so returning both from one function is what keeps them
/// consistent. A separately painted stripe with an evenly scattered star field
/// on top is the version that always looks fake.
///
/// `rgb` is the diffuse light of unresolved stars; `a` multiplies how many
/// cells hold a resolved star.
vec4 galaxyBand(vec3 d) {
  vec3 pole = normalize(kGalacticPole);
  // 0 at the poles, 1 on the plane.
  float onPlane = 1.0 - abs(dot(d, pole));

  // The band is not a clean stripe: its edge is ragged and its width varies.
  float ragged = fbm3(d * 2.6) - 0.5;
  float band = smoothstep(0.62, 0.995, onPlane + ragged * 0.22);

  // Structure WITHIN the band — clumps of brightness at two scales.
  float clumps = fbm3(d * 5.5 + 11.3);
  float fine = fbm3(d * 14.0 + 41.7);

  // DUST LANES. Dark, high-contrast, running along the band — the feature
  // that most says "Milky Way" rather than "glowing smear". They subtract,
  // and they also hide the stars behind them.
  float dust = smoothstep(0.42, 0.72, fbm3(d * vec3(7.0, 22.0, 7.0) + 61.1));
  float lanes = 1.0 - dust * 0.85;

  float density = band * (0.35 + 0.65 * clumps) * lanes;

  // Cooler at the edges, warmer through the core, as it actually appears.
  vec3 cool = vec3(0.42, 0.52, 0.85);
  vec3 warm = vec3(0.95, 0.86, 0.72);
  vec3 tint = mix(cool, warm, clamp(clumps * 0.9 + fine * 0.3, 0.0, 1.0));

  vec3 glow = tint * density * 0.38;

  // Star density: many more resolved stars inside the band, and the dust
  // lanes hide them exactly where they darken the glow.
  float starDensity = 1.0 + band * 2.6 * lanes;
  return vec4(glow, starDensity);
}

vec3 starLayer(vec3 dir, float density, float size, float brightness,
               float starDensity) {
  vec3 p = dir * density;
  vec3 base = floor(p);
  vec3 acc = vec3(0.0);
  for (int i = 0; i < 2; i++) {
    for (int j = 0; j < 2; j++) {
      for (int k = 0; k < 2; k++) {
        vec3 cell = base + vec3(float(i), float(j), float(k));
        float h = hash31(cell);
        // Most cells are empty — a sky where every cell has a star reads as
        // noise, not as stars.
        // The band raises how many cells hold a star; dust lanes lower it.
        if (h < 1.0 - (1.0 - 0.86) * starDensity) continue;

        vec3 jitter = vec3(
          hash31(cell + 1.7), hash31(cell + 3.3), hash31(cell + 5.9)
        );
        float d = length(p - (cell + jitter));
        float core = exp(-(d * d) / (size * size));

        // Colour temperature: real star fields are not white. Blue-white
        // through to warm, which is most of what makes them read as stars.
        float temp = hash31(cell + 9.1);
        vec3 tint = mix(vec3(0.72, 0.82, 1.0), vec3(1.0, 0.90, 0.74), temp);

        // Magnitude varies a lot — a few bright ones carry the impression.
        float mag = pow(fract(h * 37.0), 1.6) * 0.85 + 0.15;

        // TWINKLE. Each star gets its own rate and phase, so the field
        // scintillates instead of pulsing as one. Rates are deliberately
        // uneven — a field that breathes in unison reads as an effect.
        float rate = 0.5 + 2.4 * hash31(cell + 13.7);
        float phase = hash31(cell + 21.3) * 6.2831853;
        mag *= 0.55 + 0.45 * sin(uTime * rate + phase);
        acc += tint * core * mag * brightness;
      }
    }
  }
  return acc;
}

/// The resolved stars, given a band that has already been worked out.
///
/// ⚠️ THE BAND AND THE STARS WANT OPPOSITE TREATMENT, which is why they are
/// separated. The band is a diffuse glow with no edge anywhere in it — four
/// five-octave noise fields, and by far the more expensive half — while the
/// stars are single sharp points that would smear into nothing if softened.
/// Rendering the band at a fraction of the resolution is invisible; rendering
/// the stars there would not be.
///
/// The star density comes from the band because it IS the band: the galaxy is
/// bright where its stars are crowded, and dust lanes darken the glow and hide
/// the stars behind them at the same time. One field, both effects, which is
/// what stops it reading as a painted stripe with a scatter laid over it.
vec3 starsFromBand(vec3 dir, vec3 glow, float starDensity) {
  float turn = uTime * 0.010 + uCamera * 0.085;
  vec3 d = normalize(rotY(turn) * dir);
  vec3 c = starLayer(d, 42.0, 0.105, 3.1, starDensity);
  c += starLayer(d, 95.0, 0.070, 1.7, starDensity);
  c += starLayer(d, 200.0, 0.048, 0.85, starDensity);
  c += glow;
  return c + vec3(0.02138, 0.02595, 0.03425);
}

/// The band alone, for the small pass. `a` carries the star density, remapped
/// into 0..1 so it survives an 8-bit channel.
vec4 bandOnly(vec3 dir) {
  float turn = uTime * 0.010 + uCamera * 0.085;
  vec4 g = galaxyBand(normalize(rotY(turn) * dir));
  return vec4(g.rgb, (g.a - 1.0) / 2.6);
}

vec3 starsColor(vec3 dir) {
  // THE SKY TURNS. Sampling by direction means rotating the direction rotates
  // the whole field rigidly — stars keep their relationships instead of
  // sliding past each other, which is what makes it read as one sky moving
  // rather than a scrolling texture.
  //
  // Two terms: a slow constant drift so it is alive when nothing is
  // happening, and a term tied to the camera's position in the world, so
  // travelling between sections carries the sky with it.
  float turn = uTime * 0.010 + uCamera * 0.085;
  vec3 d = normalize(rotY(turn) * dir);

  // The band first: its density multiplier feeds the star layers, so the
  // resolved stars crowd where the diffuse glow is and thin out in the dust.
  vec4 galaxy = galaxyBand(d);

  // Three densities so the field has depth rather than one flat scatter.
  vec3 c = starLayer(d, 42.0, 0.105, 3.1, galaxy.a);
  c += starLayer(d, 95.0, 0.070, 1.7, galaxy.a);
  c += starLayer(d, 200.0, 0.048, 0.85, galaxy.a);

  c += galaxy.rgb;

  // Space is not black — a faint cool wash keeps it from reading as a hole in
  // the screen.
  //
  // ⚠️ PRE-COMPENSATED, like kBase, and for the same reason: this value has a
  // stated job, which is to land just above black rather than on it. The tone
  // curve has a toe, so the original 0.012/0.014/0.024 — authored back when the
  // sky skipped the curve — arrived at 1, 2, 3 out of 255 and rounded to pure
  // black in places. Solved numerically to render at 3, 4, 6, which is exactly
  // where it sat before the curve moved to the end of main.
  //
  // This is the only value in the shader chosen for looks that was touched by
  // that move; every other one is free to be re-tuned by eye.
  return c + vec3(0.02138, 0.02595, 0.03425);
}

/// How much of the carving's light reaches a point on the sheet.
///
/// ⚠️ WITHOUT THIS THE GLOW IS PAINT, NOT LIGHT. A bright shape on an object
/// that leaves no trace on anything around it is the single clearest tell of a
/// fake — the eye does not check the shape, it checks whether the world agrees
/// that light is there. The letters can be as beautiful as we like; until the
/// glass under them catches something, they are a sticker.
///
/// The carving is spread over four faces, so this treats it as one source at the
/// cube's own centre. That is a real approximation and worth naming: it cannot
/// know that the `Di` face is pointing one way and the `Se` face another, so the
/// pool it casts is symmetrical when the truth is slightly lobed. At the size
/// this appears — a soft wash on dark glass, under an object that is itself
/// sitting in contact shadow — the difference is not resolvable, and the honest
/// alternative costs four times as much for something nobody can see.
///
/// Falls off with the square of the distance because light does, softened by the
/// source's own size so it does not divide by nothing at the cube's foot.
float carvingIrradiance(vec3 p, vec3 n) {
  vec3 d = cubeOrigin() - p;
  float dist2 = max(dot(d, d), 1e-5);
  vec3 dir = d * inversesqrt(dist2);
  // A surface only catches light in proportion to how squarely it faces it.
  float cosN = max(dot(n, dir), 0.0);
  return clamp(cosN / (dist2 + uCubeHalf * uCubeHalf * 2.0), 0.0, 1.0);
}

/// The energy inside the cube, as a raw field — the same one that flows across
/// the glass, sampled in three dimensions instead of two.
///
/// ⚠️ IT IS RETURNED RAW, AND THAT IS THE POINT. The caller applies exactly the
/// same threshold the sheet's flow uses, so the two are not merely similar
/// colours: they are one field, shaped by one curve, differing only in where
/// they are read. He looked at the first version and said it was not the same
/// energy — the fault was never the colour, which was already identical from the
/// same constant. It was that one was a moving cloud and the other a flat fill.
///
/// Same noise, same cycle length, same period, same flow-map advection: two
/// copies half a cycle out of phase, cross-faded on a triangle weight so no
/// sample ever accumulates stretch. The energy wells up inside the cube, travels
/// OUTWARD along its own radius, runs along the glass channels cut into its
/// faces, and pours out onto the sheet below. One story, one field.
///
/// ⚠️ SAMPLED IN THE CUBE'S OWN FRAME, so the turbulence belongs to the object.
/// In world space it would swim across the faces the moment the cube moved.
///
/// ⚠️ AND IT IS ALLOWED TO REACH NOTHING, which the earlier version was not. I
/// held it above a floor because I was afraid a letter would blink out and stop
/// being readable. That fear was wrong, and the crop he sent is what showed it:
/// the channel is real cut geometry, so the letters are perfectly legible with
/// no light in them at all — they simply become dark glass for a moment. Which
/// means the energy in them can be exactly as sparse and dramatic as the fog on
/// the sheet, because losing the light never loses the letterform.
float carveFogField(vec3 p) {
  vec3 lp = spinInto() * (p - cubeOrigin()) / max(uCubeHalf, 1e-4);
  vec3 dir = normalize(lp + vec3(1e-5));

  float phase = uTime / kCyclePeriod;
  float pa = fract(phase);
  float pb = fract(phase + 0.5);

  // ⚠️ TWO MOTIONS, AND THE FIRST VERSION HAD ONLY ONE — measured, not guessed.
  // Two frames seven seconds apart changed 27% of the flow on the glass and
  // 1.5% of the letters: the field was varying in SPACE but standing almost
  // still in TIME.
  //
  // The reason is that radial advection alone cannot travel far here. On the
  // glass the energy slides outward across a sheet twenty units wide; inside the
  // cube everything is squeezed into the range -1 to 1, so the cross-fade only
  // ever rocks the sample point back and forth across about a fifth of one
  // feature. It looks like flow and is very nearly a still image.
  //
  // So a steady DRIFT is added on top. A uniform translation of the sampling
  // domain moves every point by the same vector, which is exactly why it can run
  // without limit and never shears — shearing comes from neighbours sliding
  // differently, and here they do not. The radial term keeps the sense of the
  // energy travelling outward; the drift is what makes it alive.
  const float kScale = 2.1;
  const float kDrift = 0.115;
  vec3 wander = vec3(0.13, 1.0, -0.21) * (uTime * kDrift) + 3.1;
  float a = fbm3Coarse(lp * kScale - dir * (pa * kCycleDistance) + wander);
  float b = fbm3Coarse(lp * kScale - dir * (pb * kCycleDistance) + wander);
  float f = mix(a, b, abs(1.0 - 2.0 * pa));

  // Raw. The caller thresholds it with the sheet's own curve — see kFogLow and
  // kFogHigh — so the two fields are shaped identically rather than similarly.
  return f;
}

/// The window the energy is read through, wherever it is read.
///
/// ⚠️ THE SAME TWO NUMBERS AS THE FLOW ON THE SHEET, and they belong beside the
/// colour constant for the same reason: what makes two things one substance is
/// not the hue, it is the whole chain from field to pixel. A lower threshold
/// turns more of the noise into visible energy, so the cloud is broader rather
/// than only its brightest peaks showing.
///
/// ⚠️ AND fbm3Coarse IS NOT fbm — it runs 0 to 0.875 against the 2D field's
/// 0.97, and sits around 0.44 against 0.48. So the window is shifted by that
/// ratio rather than copied as literals. Copying thresholds between fields with
/// different statistics is the single most expensive mistake made on this
/// object; the moss's first coverage was a tenth of what it should have been for
/// exactly that reason.
const float kFogLow = 0.25;
const float kFogHigh = 0.79;

/// The longest path light can take through the channel, for packing it into
/// eight bits. Refraction bends a ray at most 42 degrees on the way into glass
/// this dense, so it can never travel more than about a third further than the
/// channel is deep.
const float kCarvePathMax = 0.25;

/// Turns a path length through the glass into how much fog is seen along it, and
/// how brightly a cut edge burns.
const float kFogGain = 15.0;
const float kEdgeGain = 1.30;

/// Turns a chord through the glass CUBE into how much fog is seen along it.
///
/// ⚠️ AND IT IS TWO ORDERS OFF THE CARVING'S, WHICH IS NOT A TUNING ACCIDENT.
/// A channel is a millimetre of glass; the body diagonal of the cube is over
/// three units of it, and the fog accumulates along every one of them. Carrying
/// the channel's number over made the cube a solid block of white — the same
/// class of mistake as reusing a threshold between two fields with different
/// statistics, which this project has now paid for three times.
const float kInnerGain = 0.30;

/// How far up the cube the platform's energy reaches, as a multiple of the
/// cube's half-width.
///
/// ⚠️ THE FALLOFF IS THE WHOLE CHARACTER OF IT. Tight, and the energy is a band
/// pooling at the contact — a story about the platform feeding the object.
/// Loose, and the cube is lit through its whole body — a story about the two
/// being one piece of glass. Both are defensible and they say different things,
/// which is why `?wall=` exists rather than a number I picked.
const float kWallRise = 0.85;

/// Turns the sheet's own energy, read beneath the cube, into light in the cube.
const float kWallGain = 0.85;

/// How much the glass swallows per world unit travelled, per channel.
///
/// ⚠️ BEER-LAMBERT, AND WITHOUT IT A THICK SOLID CANNOT READ AS THICK. A sheet
/// can ignore absorption because there is nothing to absorb over; a cube cannot.
/// Light crossing three units of glass arrives weaker than light clipping a
/// corner, so the body goes deep and the edges stay clear — which is exactly how
/// the eye measures how solid something is. Leave it out and the object is a
/// uniformly pale box, because every ray delivers whatever was behind it at full
/// strength no matter how far it came.
///
/// ⚠️ AND IT IS COLOURED, because real glass is. Iron in the melt swallows red
/// first, which is why a thick pane looked at edge-on is green. Here it is tuned
/// toward the energy's own blue instead: the same physics, pointed at the scene
/// this object belongs to rather than at a window.
/// ⚠️ SET FOR A BODY LIGHT CROSSES ONCE, AND IT NOW CROSSES IT THREE OR FOUR
/// TIMES. That is what turned the solid opaque: the same coefficient, applied
/// over folded paths several times longer, left almost nothing of the platform
/// behind it — and the only thing bright enough to survive was the sky reflected
/// off the OUTSIDE of the faces, which is why the cube filled up with stars that
/// are not inside it at all.
///
/// So this is the base, and `?absorb=` scales it, because the right value is a
/// judgement about how the object should read rather than a number anyone can
/// derive.
/// Halved again once he had found the level on the knob — `?absorb=0.5` was
/// where he settled, so that value is the default and the knob reads 1 there.
/// A default nobody uses is a default that is wrong.
vec3 glassAbsorb() { return vec3(0.21, 0.135, 0.08) * uAbsorb; }
#define kGlassAbsorb glassAbsorb()

/// How much further blue bends than red on its way through the solid.
///
/// ⚠️ THIS IS WHERE GLASS STOPS LOOKING LIKE PERSPEX. Denser media refract short
/// wavelengths harder, so anything seen through a thick piece arrives split into
/// a thin fringe of colour along its edges. It is the most recognisable
/// signature real glass has, and it cannot be imitated with a tint because it
/// depends on ANGLE — none at all looking straight in, widening toward the
/// silhouette, which is exactly where the eye goes.
///
/// Real crown glass spans about 0.017 between the red and blue ends. This is
/// several times that, because the cube is one object at a modest size on a
/// screen and the honest number would be invisible — the same reason a film
/// lens flare is drawn larger than physics allows.
/// ⚠️ AND IT IS ONLY HONEST WHILE THE THREE SAMPLES LAND WITHIN A PIXEL OF EACH
/// OTHER. Real dispersion is continuous across the spectrum; this renders three
/// wavelengths. On a smooth gradient nobody can tell. On a POINT SOURCE they can
/// tell instantly — every star seen through the solid splits into three separate
/// coloured dots instead of a short smear, because there is nothing in between
/// them to fill the gap. This scene is mostly black with bright points in it,
/// which is the worst possible case for the trick, and at several times the
/// physical value it turned the cube to confetti.
///
/// `?disp=` scales it. Crown glass is about 0.017 and that is the honest
/// ceiling here — past it the undersampling shows before the effect does.
float dispersion() { return 0.017 * uDisp; }
#define kDispersion dispersion()


/// fbm3 that gives up as soon as the result PROVABLY cannot reach [needed].
///
/// The octave amplitudes are known — 0.5, 0.25, 0.125, 0.0625, 0.03125,
/// summing to 0.96875 — so after each octave the maximum the remaining ones
/// could still add is known exactly. If the partial sum plus that maximum is
/// already below the threshold the caller compares against, no possible value
/// of the remaining octaves changes the outcome, so they are not evaluated.
///
/// This is not an approximation: where it bails, the caller's result is zero
/// either way. It is pure saved work, and inside a 28-step march it is most
/// of the shader's cost.
float fbm3Early(vec3 p, float needed) {
  const float kTotalAmp = 0.96875;
  float sum = 0.0;
  float amp = 0.5;
  float spent = 0.0;
  for (int i = 0; i < 5; i++) {
    sum += amp * noise3(p);
    spent += amp;
    // Best case for every octave still to come.
    if (sum + (kTotalAmp - spent) < needed) return sum;
    p *= 2.07;
    amp *= 0.5;
  }
  return sum;
}

// ── The flying energy: a volumetric medium ──────────────────────────────────
//
// The SECOND structure. The surface energy is bound to the glass — it flows
// across it and pours over the edge. This one is free in the air: a slab of
// participating medium in front of the panel that the camera ray marches
// through, accumulating density and transmittance.
//
// It has to be volumetric rather than another painted layer, for two reasons
// that both matter later: only a medium with real depth parallaxes as the
// world moves, and only a medium can have the TYPE inside it rather than
// merely behind it.

// Declared here because GLSL needs a function before its first use, and the
// sampling section that defines this sits further down the file.
float ign(vec2 pixel);

const float kCloudNear = 2.4;   // how far in front of the panel it reaches
const float kCloudTop = 0.35;   // a little above the ledge
const float kCloudDrop = 5.0;   // how far down it hangs

/// Density of the medium at a point, 0..1.
/// The cloud's analytic envelope — where it can exist at all, before any
/// noise. A few exp and smoothstep calls, against hundreds of hash lookups
/// for the noise, which is why everything tests this first.
float cloudShape(vec3 p) {
  float fromEdge = length(vec2(p.x, p.z - kEdgeZ) * vec2(0.30, 0.85));
  float shape = exp(-fromEdge * 0.55) * exp(-max(-p.y, 0.0) * 0.30);
  shape *= smoothstep(kEdgeZ - kCloudNear, kEdgeZ - kCloudNear + 0.9, p.z);
  shape *= 1.0 - smoothstep(kEdgeZ - 0.15, kEdgeZ + 0.05, p.z);
  shape *= smoothstep(kCloudTop + 0.4, kCloudTop - 0.5, p.y);
  return shape;
}

float cloudDensity(vec3 p, vec3 drift) {
  float shape = cloudShape(p);
  if (shape < 0.012) return 0.0;

  // Drift: a uniform translation of the sample point, so the whole volume
  // moves together without shearing. Slower vertically than horizontally, so
  // it rolls rather than slides.
  // The threshold below is smoothstep(0.46, ...), so density is exactly zero
  // for d <= 0.46. With d = base * 0.75 + detail * 0.25 and detail at most
  // 0.96875, the largest the detail term can contribute is 0.242 — so unless
  // base reaches (0.46 - 0.242) / 0.75 = 0.29, this sample is zero whatever
  // the detail octave turns out to be. Not an approximation: below that,
  // computing it changes nothing.
  const float kBaseNeeded = 0.29;
  float base = fbm3Early(p * 0.85 + drift, kBaseNeeded);
  if (base < kBaseNeeded) return 0.0;

  // A second, finer octave set advected differently gives the billowing that
  // one scale alone never has. Full spectrum: cutting octaves visibly
  // cheapened the look, so the saving comes from skipping work that cannot
  // affect the result rather than from doing it worse.
  float detail = fbm3(p * 2.7 - drift * 1.7 + 17.3);
  float d = base * 0.75 + detail * 0.25;

  return clamp(smoothstep(0.46, 0.88, d) * shape, 0.0, 1.0);
}

/// Marches the medium and returns premultiplied colour and alpha.
vec4 flyingEnergy(vec3 ro, vec3 rd, float tMax) {
  // Slab bounds on z, since the volume hangs in front of the panel.
  float zNear = kEdgeZ - kCloudNear;
  float zFar = kEdgeZ;
  if (abs(rd.z) < 1e-5) return vec4(0.0);
  float ta = (zNear - ro.z) / rd.z;
  float tb = (zFar - ro.z) / rd.z;
  float t0 = max(min(ta, tb), 0.0);
  float t1 = min(max(ta, tb), tMax);
  if (t1 <= t0) return vec4(0.0);

  // WHOLE-RAY REJECTION. Probe the analytic envelope at a few points along
  // the ray first: if the cloud cannot exist anywhere on it, skip the march
  // entirely. Six cheap evaluations against 28 expensive ones, and it cannot
  // change the image because density is exactly zero wherever the envelope is
  // below this threshold anyway.
  // Also NARROW the span to the part of the ray where the cloud can exist.
  // Keeping the step SIZE fixed and marching fewer of them over a shorter
  // span is free: the sampling density is unchanged, so the image is
  // unchanged, but a ray that only clips the edge of the volume stops paying
  // for the empty length on either side.
  const int kMaxSteps = 28;
  float stepSize = (t1 - t0) / float(kMaxSteps);

  float first = t1;
  float last = t0;
  float peak = 0.0;
  for (int i = 0; i < 8; i++) {
    float t = mix(t0, t1, (float(i) + 0.5) / 8.0);
    float sh = cloudShape(ro + rd * t);
    peak = max(peak, sh);
    if (sh >= 0.012) {
      first = min(first, t);
      last = max(last, t);
    }
  }
  if (peak < 0.012) return vec4(0.0);

  // One probe interval of margin either side, so nothing between probes is
  // clipped.
  float margin = (t1 - t0) / 8.0;
  t0 = max(t0, first - margin);
  t1 = min(t1, last + margin);

  int kSteps = int(clamp(ceil((t1 - t0) / stepSize), 1.0, float(kMaxSteps)));

  // Hoisted: it depends only on time, not on the sample point.
  vec3 drift = vec3(uTime * 0.035, uTime * 0.012, uTime * -0.02);

  // Jitter the start per pixel so the fixed step count does not band. Same
  // interleaved gradient noise the shadows use.
  float jitter = ign(FlutterFragCoord().xy);

  vec3 accum = vec3(0.0);
  float transmittance = 1.0;

  vec3 lit = vec3(0.42, 0.66, 1.00) * 1.2 + kAccent * 0.10;

  for (int i = 0; i < kMaxSteps; i++) {
    if (i >= kSteps) break;
    float t = t0 + (float(i) + jitter) * stepSize;
    vec3 p = ro + rd * t;
    float d = cloudDensity(p, drift);
    if (d > 0.001) {
      // Brighter nearer the source, as if lit from the cube rather than
      // uniformly emissive.
      float toSource = length(p - cubeOrigin());
      float energy = exp(-toSource * 0.22);
      float sigma = d * 1.9;
      float absorbed = 1.0 - exp(-sigma * stepSize);
      accum += transmittance * absorbed * lit * energy;
      transmittance *= 1.0 - absorbed;
      if (transmittance < 0.02) break;
    }
  }
  return vec4(accum, 1.0 - transmittance);
}

// ── PBR, following flutter_scene/shaders/pbr.glsl ───────────────────────────

vec3 FresnelSchlick(float cosTheta, vec3 f0) {
  return f0 + (1.0 - f0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

vec3 FresnelSchlickRoughness(float cosTheta, vec3 f0, float roughness) {
  return f0 + (max(vec3(1.0 - roughness), f0) - f0) *
                  pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

float DistributionGGX(vec3 n, vec3 h, float roughness) {
  float nDotH = dot(n, h);
  if (nDotH <= 0.0) return 0.0;
  float alpha = roughness * roughness;
  vec3 nCrossH = cross(n, h);
  float a = nDotH * alpha;
  float k = alpha / (dot(nCrossH, nCrossH) + a * a);
  return k * k * (1.0 / 3.14159265);
}

float VisibilitySmith(float nDotV, float nDotL, float roughness) {
  float alpha = roughness * roughness;
  float ggx = mix(2.0 * nDotL * nDotV, nDotL + nDotV, alpha);
  return 0.5 / max(ggx, 1e-5);
}

// ── Fuzz: the way fabric and moss actually scatter light ────────────────────
//
// ⚠️ MOSS IS NOT A SOLID, AND LIGHTING IT AS ONE IS THE LAST BIG THING WRONG.
//
// GGX describes a surface of microscopic mirrors — right for stone, metal, a
// polished floor. Moss is nothing like that. It is thousands of upright shoots,
// and light entering that thicket scatters sideways off their flanks. The
// consequence is visible and familiar: fuzzy things go BRIGHT AT THEIR RIMS.
// It is why velvet has a glow along its folds, why a peach has a halo in
// sunlight, and why moss looks soft rather than merely dull. GGX cannot produce
// it at any roughness — the effect lives where GGX has nothing.
//
// This is the standard cloth model (Estevez & Kulla's distribution with
// Neubelt's visibility, as Filament uses). It matters more than any texture
// detail at our size, because it changes how the surface answers light from
// EVERY angle rather than adding features a phone cannot resolve.

/// Charlie distribution: an inverted lobe with its energy at grazing angles,
/// which is exactly where a thicket of upright fibres scatters.
float D_Charlie(float roughness, float nDotH) {
  float invAlpha = 1.0 / roughness;
  float cos2h = nDotH * nDotH;
  // Floored so the pow cannot blow up looking straight down the highlight.
  float sin2h = max(1.0 - cos2h, 0.0078125);
  return (2.0 + invAlpha) * pow(sin2h, invAlpha * 0.5) / (2.0 * 3.14159265);
}

/// Neubelt's visibility term, which pairs with Charlie. Deliberately not the
/// Smith term used for GGX: that assumes the mirrors shadow each other
/// geometrically, and a thicket does not work that way.
float V_Neubelt(float nDotV, float nDotL) {
  return 1.0 / (4.0 * (nDotL + nDotV - nDotL * nDotV));
}

vec3 envColor(vec3 d) {
  float up = clamp(d.y * 0.5 + 0.5, 0.0, 1.0);
  vec3 ground = vec3(0.020, 0.020, 0.026);
  vec3 horizon = vec3(0.42, 0.42, 0.50);
  vec3 sky = vec3(1.45, 1.50, 1.75);
  vec3 c = mix(ground, horizon, smoothstep(0.0, 0.55, up));
  c = mix(c, sky, smoothstep(0.5, 1.0, up));
  c *= mix(0.45, 1.55, smoothstep(0.0, 1.0, d.x * 0.5 + 0.5));
  vec3 toLight = normalize(kLightPos);
  c += vec3(1.0, 0.98, 0.95) * pow(clamp(dot(d, toLight), 0.0, 1.0), 40.0) * 9.0;
  return c;
}

vec3 RRTAndODTFit(vec3 v) {
  vec3 a = v * (v + 0.0245786) - 0.000090537;
  vec3 b = v * (0.983729 * v + 0.4329510) + 0.238081;
  return a / b;
}

vec3 ACESToneMap(vec3 color, float exposure) {
  const mat3 inputMat = mat3(
    vec3(0.59719, 0.07600, 0.02840),
    vec3(0.35458, 0.90834, 0.13383),
    vec3(0.04823, 0.01566, 0.83777)
  );
  const mat3 outputMat = mat3(
    vec3(1.60475, -0.10208, -0.00327),
    vec3(-0.53108, 1.10813, -0.07276),
    vec3(-0.07367, -0.00605, 1.07602)
  );
  color *= exposure / 0.6;
  color = inputMat * color;
  color = RRTAndODTFit(color);
  color = outputMat * color;
  return clamp(color, 0.0, 1.0);
}

// ── The table, as a signed distance field ───────────────────────────────────
//
// Half-planes meet at hard 90-degree corners and there is no way to round
// them after the fact — the edge is where two surfaces stop, not a surface in
// itself. An SDF has actual geometry there: rounding is subtracting a radius
// from the distance, and the normal comes from the field's gradient, so it
// turns smoothly through the corner instead of flipping.

float sdRoundBox(vec3 p, vec3 b, float r) {
  vec3 q = abs(p) - b + r;
  return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0) - r;
}

/// Polynomial smooth minimum — the union with a fillet at the join.
float smin(float a, float b, float k) {
  float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
  return mix(b, a, h) - k * h * (1.0 - h);
}

float tableSdf(vec3 p) {
  // The ledge: a slab whose top face is y = 0, running from the front edge
  // back to the cut edge.
  vec3 ledgeCentre = vec3(0.0, -kSlab * 0.5, (kEdgeZ + kBackZ) * 0.5);
  vec3 ledgeHalf = vec3(kTableHalfX, kSlab * 0.5, (kBackZ - kEdgeZ) * 0.5);
  float dLedge = sdRoundBox(p - ledgeCentre, ledgeHalf, kRound);

  // The drop: a panel hanging from the front edge, its face toward the camera.
  vec3 dropCentre = vec3(0.0, -kDropDepth * 0.5, kEdgeZ - kSlab * 0.5);
  vec3 dropHalf = vec3(kTableHalfX, kDropDepth * 0.5, kSlab * 0.5);
  float dDrop = sdRoundBox(p - dropCentre, dropHalf, kRound);

  return smin(dLedge, dDrop, kFillet);
}

vec3 tableNormal(vec3 p) {
  const vec2 e = vec2(6e-4, 0.0);
  return normalize(vec3(
    tableSdf(p + e.xyy) - tableSdf(p - e.xyy),
    tableSdf(p + e.yxy) - tableSdf(p - e.yxy),
    tableSdf(p + e.yyx) - tableSdf(p - e.yyx)
  ));
}

/// Sphere-traces the table. Returns the hit distance, or -1.
float tableTrace(vec3 ro, vec3 rd) {
  // Cheap rejection FIRST. The table lives between y = -kDropDepth and y = 0.
  // A ray starting above it and heading up can never reach it — and that is
  // every sky pixel, each of which was previously marching all 96 steps before
  // giving up.
  if (ro.y > 0.0 && rd.y >= 0.0) return -1.0;
  if (ro.y < -kDropDepth && rd.y <= 0.0) return -1.0;

  // ⚠️ SOLVE THE FLAT PARTS, MARCH ONLY THE EDGES.
  //
  // This is a floor and a panel: two planes, joined by a rounded lip. Marching
  // finds them by stepping toward the surface, and its worst case is a shallow,
  // grazing view of a large flat thing — which is precisely this camera looking
  // across this table. Nearly every pixel in the lower half of the frame was
  // taking that worst case.
  //
  // Away from the edges the surface IS the plane, exactly, so the intersection
  // is a single divide and the answer is not an approximation of the marched
  // one — it is the same answer, found directly.
  //
  // ⚠️ THE MARGINS ARE WHAT MAKE IT SAFE. Within kRound of a boundary the
  // surface curves, and within kFillet of the inner corner the smooth union
  // pulls it away from both planes. Stay that far clear and the plane is the
  // truth; come closer and fall back to marching. Being conservative here costs
  // a few pixels of the old path and nothing else, so the margin is generous.
  //
  // The NORMAL is unaffected either way: it is taken from the field's gradient
  // at the hit point, so a position found by division gets the same rounded
  // normal a marched one would.
  const float kFlatMargin = kRound + kFillet + 0.02;
  float best = -1.0;

  // The ledge's top face, y = 0.
  if (rd.y < -1e-5 && ro.y > 0.0) {
    float t = -ro.y / rd.y;
    vec3 p = ro + rd * t;
    if (abs(p.x) < kTableHalfX - kFlatMargin &&
        p.z > kEdgeZ + kFlatMargin && p.z < kBackZ - kFlatMargin) {
      best = t;
    }
  }

  // The panel's front face, the one the statement stands against.
  float dropZ = kEdgeZ - kSlab;
  if (rd.z > 1e-5 && ro.z < dropZ) {
    float t = (dropZ - ro.z) / rd.z;
    vec3 p = ro + rd * t;
    if (abs(p.x) < kTableHalfX - kFlatMargin &&
        p.y < -kFlatMargin && p.y > -kDropDepth + kFlatMargin &&
        (best < 0.0 || t < best)) {
      best = t;
    }
  }

  if (best > 0.0) return best;

  float t = 0.02;
  for (int i = 0; i < 96; i++) {
    vec3 p = ro + rd * t;
    float d = tableSdf(p);
    // Tolerance scales with distance so far-away pixels do not march forever.
    if (d < 0.0006 * t) return t;
    t += d;
    if (t > 60.0) break;
  }
  return -1.0;
}

// ── Intersection ────────────────────────────────────────────────────────────

/// Exact ray/box by the slab method, in the box's own frame.
vec2 boxIntersectLocal(vec3 ro, vec3 rd, out vec3 normal) {
  vec3 m = 1.0 / rd;
  vec3 k = abs(m) * cubeHalf();
  vec3 t1 = -m * ro - k;
  vec3 t2 = -m * ro + k;
  float tN = max(max(t1.x, t1.y), t1.z);
  float tF = min(min(t2.x, t2.y), t2.z);
  normal = -sign(rd) * step(t1.yzx, t1.xyz) * step(t1.zxy, t1.xyz);
  if (tN > tF || tF < 0.0) return vec2(-1.0);
  return vec2(tN, tF);
}

/// The cube in WORLD space. It spins about its vertical axis, the way an
/// object on a table would — it does not tumble, because it is resting.
vec2 cubeIntersect(vec3 ro, vec3 rd, float spin, out vec3 normal) {
  mat3 toLocal = spinInto();
  vec3 nl;
  vec2 t = boxIntersectLocal(toLocal * (ro - cubeOrigin()), toLocal * rd, nl);
  normal = spinOutOf() * nl;
  return t;
}

bool cubeBlocks(vec3 ro, vec3 rd, float spin, float maxT) {
  vec3 n;
  vec2 t = cubeIntersect(ro, rd, spin, n);
  return t.x > 1e-4 && t.x < maxT;
}

// ── Sampling ────────────────────────────────────────────────────────────────

// flutter_scene's interleaved gradient noise, used to rotate the sample
// pattern per pixel so its structure becomes noise instead of banding.
float ign(vec2 pixel) {
  return fract(52.9829189 *
               fract(dot(floor(pixel), vec2(0.06711056, 0.00583715))));
}

// The 16-tap Poisson disk from flutter_scene's shadow kernel.
vec2 poisson(int i) {
  if (i == 0) return vec2(-0.94201624, -0.39906216);
  if (i == 1) return vec2(0.94558609, -0.76890725);
  if (i == 2) return vec2(-0.09418410, -0.92938870);
  if (i == 3) return vec2(0.34495938, 0.29387760);
  if (i == 4) return vec2(-0.91588581, 0.45771432);
  if (i == 5) return vec2(-0.81544232, -0.87912464);
  if (i == 6) return vec2(-0.38277543, 0.27676845);
  if (i == 7) return vec2(0.97484398, 0.75648379);
  if (i == 8) return vec2(0.44323325, -0.97511554);
  if (i == 9) return vec2(0.53742981, -0.47373420);
  if (i == 10) return vec2(-0.26496911, -0.41893023);
  if (i == 11) return vec2(0.79197514, 0.19090188);
  if (i == 12) return vec2(-0.24188840, 0.99706507);
  if (i == 13) return vec2(-0.81409955, 0.91437590);
  if (i == 14) return vec2(0.19984126, 0.78641367);
  return vec2(0.14383161, -0.14100790);
}

/// Fraction of the AREA light visible from `p`. Real soft shadow: each tap is
/// a ray at a different point on the light's disc, so the penumbra widens
/// with distance from the contact exactly as it does in life.
/// The cube's bounding sphere: centred on its origin, reaching a corner.
/// Derived, because the cube's size is adjustable.
float cubeRadius() { return uCubeHalf * 1.7320508; }

/// ⚠️ CAN THE CUBE POSSIBLY BLOCK THE LIGHT FROM HERE? Answered exactly, before
/// any ray is cast.
///
/// The shadow of an object lit from above is CONTAINED — this light stands at
/// 3.4 and the cube reaches 1.4, so its shadow falls within about two units of
/// it. The table is twenty-two units wide and four deep. Nearly every pixel of
/// it was casting sixteen rays to rediscover that nothing was in the way.
///
/// The test: how close does the line from here to the light pass to the cube's
/// bounding sphere? Widened by the light's own radius, because the sixteen taps
/// aim at a disc rather than a point. Beyond that, no tap can be blocked and
/// the answer is exactly 1 — not approximately.
bool couldShadow(vec3 p) {
  vec3 toLight = kLightPos - p;
  float len = length(toLight);
  vec3 l = toLight / len;
  vec3 toCube = cubeOrigin() - p;
  // Closest approach of the segment to the cube's centre.
  float along = clamp(dot(toCube, l), 0.0, len);
  float miss = length(toCube - l * along);
  return miss < cubeRadius() + kLightRadius;
}

float lightVisibility(vec3 p, vec3 n, float spin, float rotation) {
  if (!couldShadow(p)) return 1.0;

  vec3 toLight = kLightPos - p;
  float dist = length(toLight);
  vec3 l = toLight / dist;

  // Basis on the light's disc.
  vec3 tangent = normalize(cross(abs(l.y) < 0.99 ? vec3(0, 1, 0) : vec3(1, 0, 0), l));
  vec3 bitangent = cross(l, tangent);

  float ca = cos(rotation);
  float sa = sin(rotation);

  // Normal-offset bias, as flutter_scene does for shadow receivers: lift the
  // origin off the surface so the whole kernel clears it and the plane does
  // not shadow itself.
  vec3 origin = p + n * 2e-3;

  float lit = 0.0;
  for (int i = 0; i < 16; i++) {
    vec2 d = poisson(i);
    vec2 rd2 = vec2(d.x * ca - d.y * sa, d.x * sa + d.y * ca) * kLightRadius;
    vec3 target = kLightPos + tangent * rd2.x + bitangent * rd2.y;
    vec3 dir = normalize(target - origin);
    lit += cubeBlocks(origin, dir, spin, length(target - origin)) ? 0.0 : 1.0;
  }
  return lit / 16.0;
}

/// Ambient occlusion by actually querying the scene.
///
/// flutter_scene approximates this from a depth buffer because it has no
/// scene to ask. We can intersect the cube exactly, so we trace it: cosine-
/// weighted rays over the hemisphere, counting how many are blocked. This is
/// the contact darkening, and it is measured rather than tuned.
float occlusion(vec3 p, vec3 n, float spin, float rotation) {
  // ⚠️ THE SAME REASONING AS couldShadow, and this one is even simpler: every
  // ray here is only kReach long, so if the cube's bounding sphere is further
  // away than that, not one of the twelve can reach it. Nothing is occluded and
  // the answer is exactly 1.
  const float kReachTest = 2.2;
  if (length(cubeOrigin() - p) > kReachTest + cubeRadius()) return 1.0;

  vec3 tangent = normalize(cross(abs(n.y) < 0.99 ? vec3(0, 1, 0) : vec3(1, 0, 0), n));
  vec3 bitangent = cross(n, tangent);
  float ca = cos(rotation);
  float sa = sin(rotation);
  vec3 origin = p + n * 2e-3;

  const float kReach = 2.2;  // world units the occluder can matter within
  float open = 0.0;
  for (int i = 0; i < 12; i++) {
    vec2 d = poisson(i);
    vec2 r2 = vec2(d.x * ca - d.y * sa, d.x * sa + d.y * ca);
    // Cosine-weighted hemisphere: project the disc sample up onto it.
    float r = length(r2);
    vec3 dir = normalize(tangent * r2.x + bitangent * r2.y +
                         n * sqrt(max(1.0 - r * r, 0.02)));
    open += cubeBlocks(origin, dir, spin, kReach) ? 0.0 : 1.0;
  }
  return open / 12.0;
}

// ── The cube's material: mossed stone ───────────────────────────────────────
//
// ⚠️ READ THIS BEFORE CHANGING ANY OF IT.
//
// The reference is carved stone under moss in a cloud forest, and the thing
// that makes those photographs work is not the moss — it is that the moss
// REVEALS the stone. It gathers where water sits, which is the hollows, and it
// is scoured off what stands proud. So the growth is not decoration laid over
// the carving; it is the carving made visible. Every rule below serves that.
//
// Two facts bound what is worth computing:
//
//   · The cube is about 180 pixels across on a desktop and 78 on a phone. One
//     face is nearer 55. There is no such thing as photographic detail at that
//     size, so the target is "reads unmistakably as moss", not "you can see the
//     shoots". Anything finer than a pixel is not merely wasted, it ALIASES —
//     it crawls and fizzes as the light moves.
//   · Everything here runs inside the cube's antialiasing. See the resolve in
//     main: the material is now evaluated ONCE PER VISIBLE FACE per pixel
//     rather than once per sub-sample, which is what makes a material this rich
//     affordable at all.

/// fbm whose finest octaves fade out as a pixel grows to cover them.
///
/// ⚠️ THIS IS THE ANTIALIASING FOR EVERYTHING PROCEDURAL HERE, and it is why
/// the material can be sampled once per face instead of 64 times per pixel.
///
/// A detail smaller than a pixel cannot be drawn; it can only be guessed at,
/// differently every frame, which is what makes procedural surfaces crawl. A
/// photograph solves this with mipmaps — smaller copies, pre-blurred. The
/// equivalent for noise is to simply stop adding octaves once their wavelength
/// drops below what a pixel can hold, and fade them out rather than dropping
/// them, or the detail pops as the camera moves.
///
/// [lod] is how much of this noise's own space one pixel covers. The result is
/// renormalised, so it always averages 0.5 whichever octaves survived — without
/// that, a threshold tuned on a desktop would mean something else on a phone.
float fbm3Band(vec3 p, float lod) {
  float sum = 0.0;
  float norm = 0.0;
  float amp = 0.5;
  float freq = 1.0;
  for (int i = 0; i < 5; i++) {
    float w = 1.0 - smoothstep(0.35, 0.90, lod * freq);
    if (w > 0.001) {
      sum += amp * w * noise3(p * freq);
      norm += amp * w;
    }
    freq *= 2.07;
    amp *= 0.5;
  }
  return norm > 1e-4 ? sum / norm : 0.5;
}

/// How thick the growth is at a point, 0..1, averaging 0.5.
///
/// ⚠️ THREE SCALES, BECAUSE MOSS HAS THREE. Where it grows at all (patches
/// across a whole face), the clumps within a patch, and the shoot texture
/// within a clump. One scale alone is the difference between "a pattern" and "a
/// growth" — it reads as camouflage, because nothing in nature has exactly one
/// size of feature. The finest band is below a pixel on a phone and fades
/// itself out there; that is the band limiting above doing its job rather than
/// a compromise.
float mossHeight(vec3 q, float lod) {
  // `patch` is a reserved word in GLSL — it belongs to tessellation shaders.
  float spread = fbm3Band(q * 1.7, lod * 1.7);
  float clump = fbm3Band(q * 6.0 + 13.7, lod * 6.0);
  float shoot = fbm3Band(q * 23.0 + 31.3, lod * 23.0);
  return spread * 0.50 + clump * 0.34 + shoot * 0.16;
}

// ── Inca polygonal masonry ──────────────────────────────────────────────────
//
// The wall at Sacsayhuamán: irregular many-sided blocks, each one bulging
// slightly, fitted so tightly the joints are hairlines. It is one of the few
// real-world patterns a formula produces NATIVELY rather than imitates — space
// divided into cells around scattered points is exactly what that masonry is.
//
// ⚠️ AND IT IS WHY THE MOSS BELONGS WHERE IT IS. A joint is recessed, so it
// holds water, so growth gathers in it. The stonework and the moss are not two
// effects layered on each other; one is the reason for the other, which is
// what makes both read as real instead of applied.

/// Four decorrelated numbers for a cell, in ONE pass.
///
/// ⚠️ THE CELL PATTERNS ARE THE MOST EXPENSIVE THING IN THE FRAME, and this is
/// where they spent it. Each of the 54 cells a block lookup visits wanted three
/// numbers for its jitter and a fourth for its size, and asked FOUR SEPARATE
/// TIMES — four independent hashes, each with its own multiplies and fractions,
/// for what one pass produces. Measured, the cube's material is 10.6 ms of a
/// 43.5 ms frame, more than every other term put together.
///
/// This is the standard mixing trick: perturb by a dot product of the vector
/// with a shuffle of itself, then take fractions of shuffled products. One pass,
/// better distribution than repeating a weaker hash with an offset.
///
/// ⚠️ IT PRODUCES DIFFERENT NUMBERS, so the wall is a different wall — the same
/// kind of masonry with the stones laid out differently. Nothing about its
/// character changes; it was random before and is random now.
vec4 hash43(vec3 p) {
  vec4 q = fract(vec4(p.xyzx) * vec4(0.1031, 0.1030, 0.0973, 0.1099));
  q += dot(q, q.wzxy + 33.33);
  return fract((q.xxyz + q.yzzw) * q.zywx);
}

vec3 hash33(vec3 p) { return hash43(p).xyz; }

/// Distance to the nearest JOINT, and the direction that distance grows in.
///
/// ⚠️ THE TRUE DISTANCE TO THE CELL BOUNDARY, not the usual difference between
/// the nearest and second-nearest points. That shortcut is not a distance: it
/// widens wherever three blocks meet, so every corner blooms into a blob and
/// the joints stop being hairlines — which is precisely the quality this wall
/// is famous for. The exact version (Inigo Quilez's) takes a second pass:
/// having found the closest feature point, measure to the plane that bisects it
/// and each neighbour. The smallest of those IS the cell boundary.
///
/// ⚠️ THE SECOND PASS ALSO HANDS BACK THE GRADIENT FOR FREE. The distance is
/// measured against a plane, so it grows along that plane's normal — no extra
/// samples needed to find the slope. That matters here: sampling this field
/// three more times for a gradient would triple the most expensive thing in the
/// shader. Returned as `yzw`; the field's slope is its negative.
///
/// `w` carries a hash of which stone this is, for per-block variation.
/// ⚠️ THE CELLS ARE WEIGHTED, WHICH IS WHAT GIVES BLOCKS DIFFERENT SIZES.
///
/// Plain cellular noise makes cells of roughly one size, and a wall of
/// same-sized stones reads as tiling however irregular each one is. The wall in
/// the reference does the opposite: a few enormous blocks with small ones packed
/// around them, and that mixture is most of what makes it striking.
///
/// Giving each point a radius and subtracting it from the distance is the
/// standard way — a point with a larger radius claims more space. The exact
/// boundary between two weighted points is a curve rather than a plane, but
/// shifting the plane by half the difference in radii is its tangent at the
/// closest approach, and at these scales the difference is far under a pixel.
float cellWeight(vec3 cell) {
  return hash43(cell).w * 0.30;
}

vec4 masonry(vec3 p, out float stone, out vec3 stoneCell) {
  vec3 ip = floor(p);
  vec3 fp = fract(p);

  // Pass one: which feature point claims this spot.
  float nearest = 8.0;
  vec3 toNearest = vec3(0.0);
  vec3 nearestCell = vec3(0.0);
  float nearestW = 0.0;
  for (int k = -1; k <= 1; k++) {
    for (int j = -1; j <= 1; j++) {
      for (int i = -1; i <= 1; i++) {
        vec3 g = vec3(float(i), float(j), float(k));
        vec3 r = g + hash33(ip + g) - fp;
        float w = cellWeight(ip + g);
        float d = length(r) - w;
        if (d < nearest) {
          nearest = d;
          toNearest = r;
          nearestCell = g;
          nearestW = w;
        }
      }
    }
  }
  // The block's own identity. Anything that must be constant across one stone
  // and change at its joints hashes from this — its tone today, and the dressing
  // of its face below. It is handed back rather than kept private because the
  // carving will want it too: a glyph belongs to a block, not to the wall.
  stoneCell = ip + nearestCell;
  stone = hash31(stoneCell + 3.77);

  // Pass two: the closest bisecting plane between that point and its
  // neighbours. Centred on the NEAREST cell rather than on this one, or the
  // neighbourhood misses blocks whose points lie just outside it.
  float edge = 8.0;
  vec3 dir = vec3(0.0, 1.0, 0.0);
  for (int k = -1; k <= 1; k++) {
    for (int j = -1; j <= 1; j++) {
      for (int i = -1; i <= 1; i++) {
        vec3 g = nearestCell + vec3(float(i), float(j), float(k));
        vec3 r = g + hash33(ip + g) - fp;
        vec3 diff = r - toNearest;
        float sep = dot(diff, diff);
        // Skip the nearest point itself; it has no plane against itself.
        if (sep > 1e-5) {
          vec3 nrm = diff * inversesqrt(sep);
          // The plane sits at the midpoint, shifted toward whichever stone has
          // the smaller claim.
          float d = dot(0.5 * (toNearest + r), nrm) +
                    (nearestW - cellWeight(ip + g)) * 0.5;
          if (d < edge) {
            edge = d;
            dir = nrm;
          }
        }
      }
    }
  }
  return vec4(edge, dir);
}

/// Crustose lichen: flat pale discs growing outward from a point.
///
/// ⚠️ SCATTERED DISCS, NOT A TILING — and that is the whole difference from the
/// masonry above, which uses the same machinery. Cellular noise normally
/// divides ALL of space between its points, so every spot belongs to some cell.
/// Lichen does not work that way: a spore lands, a colony spreads outward as a
/// rough circle, and the rock between colonies is simply bare. So most cells
/// host nothing, and the ones that do are measured by plain distance from their
/// own centre against their own radius — inside is lichen, outside is stone.
///
/// ⚠️ AND IT IS A SECOND ORGANISM, NOT A SECOND DENSITY OF THE FIRST. Two
/// species competing for the same rock is what a real wall looks like, and it
/// reads as alive in a way one thing at two strengths never does: lichen is
/// flat, pale, hard-edged and crusty where moss is deep, dark, soft and fuzzy.
/// It also takes the ground moss leaves alone — the drier, more exposed faces —
/// which is why it is weighted against the moss below rather than added to it.
///
/// Returns coverage; `bloom` comes back as how near this is to a colony's
/// growing edge, which is where a crust is palest and slightly raised.
float lichen(vec3 p, float lod, out float bloom, out float patchId) {
  vec3 ip = floor(p);
  vec3 fp = fract(p);

  float best = 8.0;
  vec3 bestCell = vec3(0.0);
  for (int k = -1; k <= 1; k++) {
    for (int j = -1; j <= 1; j++) {
      for (int i = -1; i <= 1; i++) {
        vec3 cell = ip + vec3(float(i), float(j), float(k));
        // Most of the rock never gets colonised.
        if (hash31(cell + 41.9) < 0.42) continue;
        vec3 r = vec3(float(i), float(j), float(k)) + hash33(cell) - fp;
        // Each colony has spread a different distance from where it started.
        float radius = 0.26 + 0.40 * hash31(cell + 5.31);
        float d = length(r) / radius;
        if (d < best) {
          best = d;
          bestCell = cell;
        }
      }
    }
  }
  patchId = hash31(bestCell + 3.11);

  // ⚠️ COLONIES ARE LOBED, NOT CIRCULAR. A crust spreads faster where the rock
  // suits it and stalls where it does not, so the outline is a rough rosette
  // with fingers and bays — never the clean disc that plain distance gives.
  // Warping the distance itself, rather than the shape, keeps the whole colony
  // consistent: the same lobe reaches out on every frame and at every size.
  best *= 1.0 + (fbm3Band(p * 2.2 + 61.7, lod * 2.2) - 0.5) * 0.55;

  // A crust has a HARD edge, unlike moss — but never harder than a pixel.
  float soft = max(0.10, lod * 4.0);
  bloom = smoothstep(0.55, 1.0, best);
  return 1.0 - smoothstep(1.0 - soft, 1.0, best);
}

/// The split-sum environment BRDF, as maths instead of a lookup texture.
///
/// ⚠️ WITHOUT THIS, A VERY ROUGH SURFACE COMES OUT TOO DARK. A rough material
/// bounces light between its own microscopic facets several times before it
/// escapes; a single-bounce model throws away everything after the first, and
/// the loss grows with roughness. Moss is about as rough as a surface gets, so
/// this is not a subtlety here — it is the difference between moss and grey
/// felt. flutter_scene solves it with a lookup texture; this is Lazarov's
/// analytic fit of the same function, which costs a few instructions and no
/// download.
vec2 envDFG(float nDotV, float roughness) {
  const vec4 c0 = vec4(-1.0, -0.0275, -0.572, 0.022);
  const vec4 c1 = vec4(1.0, 0.0425, 1.04, -0.04);
  vec4 r = roughness * c0 + c1;
  float a004 = min(r.x * r.x, exp2(-9.28 * nDotV)) * r.x + r.y;
  return vec2(-1.04, 1.04) * a004 + r.zw;
}

/// How much of the world one pixel covers at the cube, in world units.
///
/// This is the number that decides how much of the material is worth
/// computing. It falls out of the same constants the camera is built from, so
/// it is automatically right on a phone, on a desktop, and at whatever
/// resolution the scene is being rendered at — `uCubeUnit` already carries the
/// render scale.
float cubeLod() {
  return (length(cubeOrigin() - kEye) / kFocal) / uCubeUnit;
}

/// What the light does inside the carved channel.
///
/// ⚠️ THE CHANNEL IS FULL OF GLASS, and that is the whole design rather than a
/// detail of it. The energy does not come off a glowing surface — it is fog
/// INSIDE a material, seen through it, exactly as it is on the sheet the cube
/// stands on. One rule for the scene: glass is where the energy lives. The
/// letters are glass channels; the table is a glass sheet; the same fog is in
/// both, read through the same curve, tinted by the same constant.
///
/// That is why the previous attempt could never be tuned into this. A glowing
/// surface has one colour, no thickness and no inside. Fog under glass is
/// something you look INTO — it thickens where there is more of it to look
/// through, it goes reflective at a glancing angle, and it lights its own cut
/// edges. None of those can be added to a glowing surface; they come from being
/// a volume.
struct CarveGlass {
  float amount;   // how much of this pixel is the inlay's surface
  float path;     // how far light travels through the glass, in world units
  float trans;    // what fraction gets in rather than reflecting off
  float edge;     // the lit rim where the glass is cut against stone
  float lip;      // stone standing above the glass, when it is not poured full
};

/// Everything the lighting needs to know about the surface at one point.
struct CubeSurface {
  vec3 albedo;
  float roughness;
  vec3 normal;        // tilted by the growth's own slope
  float occlusion;    // light cannot reach the bottom of a clump
  float through;      // how much light passes THROUGH rather than off
  float fuzz;         // how much of this is a thicket rather than a solid
  vec3 f0;            // reflectance head-on
  CarveGlass glass;   // the inlay, if this point is on one
  vec3 emission;      // light this surface MAKES — the `?carving=0` model only
};

/// Squashes a sample position along one direction, so a field sampled with it
/// has features that many times LONGER that way.
///
/// ⚠️ THIS IS THE CHEAP HALF OF ANISOTROPIC FILTERING, AND FOR NOISE IT IS THE
/// WHOLE THING. Taking several taps along the smear is the honest method for a
/// picture, but noise has no picture to be faithful to — only a bandwidth. So
/// instead of sampling a too-fine field many times, make the field coarser in
/// the direction that cannot be resolved, once. The map is linear, so a
/// gradient taken through it stays exact.
///
/// The arithmetic works out to features keeping their SIZE ON SCREEN: a face
/// tilted to `1/aniso` shrinks everything on it by that much, and this grows it
/// back by the same factor along the same axis. Nothing ends up smaller than a
/// pixel, which is the entire goal.
vec3 squashAlong(vec3 v, vec3 dir, float k) {
  return v - dir * dot(v, dir) * k;
}

// ── THE CARVING ─────────────────────────────────────────────────────────────
//
// ⚠️ IT IS CUT, NOT DRAWN. That is the whole decision, and everything here
// follows from it. A painted line is a dark mark that stays put when you move;
// a cut is a place where the surface is LOWER, and lower is a fact the rest of
// the scene already knows what to do with. Shadow falls into it. The view slides
// across it. Water sits in it, so growth fills it — which is the same mechanism
// that already makes the masonry legible without a single joint being drawn.
//
// So this file gains no "carving colour" and no "carving shading". It gains a
// DEPTH, and the material reads that depth the way it already reads a joint.
//
// ⚠️ THE SYMBOLS ALONE, WITH NO BOX AROUND THEM — his call, and it is the
// better one. A ruled frame would have made this a diagram of an element tile;
// two letters cut into stone let the periodic-table reading arrive on its own,
// for anyone who takes it, without the object announcing it. The scientific
// register belongs to the SITE reading the artifact, not to the artifact.
//
// (A rounded-rectangle frame was built here first and removed rather than left
// switched off — a disabled feature is a thing the next reader has to work out
// the status of.)

/// How deep the cut is, as a fraction of the cube's half-width.
///
/// ⚠️ RELATIVE, NOT ABSOLUTE, so a bigger stone carries a proportionally deeper
/// cut — the same object, larger.
///
/// ⚠️ AND DEEP ON PURPOSE, more than twice what it was. Depth is no longer only
/// a shape: the channel is full of glass, so depth is HOW MUCH FOG THERE IS TO
/// LOOK THROUGH. A shallow channel is a thin, weak letter however bright it is
/// made; a deep one has body, and thins naturally toward its own edges where
/// there is less glass in the way. That falloff is the thing that makes it read
/// as a volume rather than a filled outline, and it cannot be faked by a
/// gradient.
const float kCarveDepth = 0.075;

/// The two coordinates of a face, given a position and normal in the cube's own
/// frame. Normalised so the face runs -1 to 1 whatever size the cube is.
vec2 carveFaceUv(vec3 lp, vec3 nl) {
  vec3 a = abs(nl);
  vec2 uv = a.x > 0.5 ? vec2(lp.z, lp.y)
          : a.y > 0.5 ? vec2(lp.x, lp.z)
                      : vec2(lp.x, lp.y);
  return uv / uCubeHalf;
}

/// How the atlas was encoded — mirrors kCarveSpread and the cell size in
/// carving.dart. In CELL PIXELS, which is why it is divided back out below.
const float kGlyphSpread = 40.0;
const float kGlyphCell = 512.0;
const float kGlyphCells = 2.0;

// How much of a face the symbol spans is `uGlyph` — `?glyph=`. It was a
// constant here and became a knob the moment there was anything to judge it
// against, which is the same reason every other number on this object has one.

/// The symbol's signed distance, in the same units as the frame's.
///
/// ⚠️ WHICH SYMBOL DEPENDS ON WHICH FACE, and the sign of the normal has to come
/// into it or half of them read backwards. The two faces at +x and -x look
/// opposite ways, so a coordinate built from the same axis runs the other way on
/// one of them — mirror writing, carved into a rock, which is not a look.
///
/// `Di` faces along x, `Se` along z: two symbols, four faces, and whichever pair
/// the camera sees shows one of each rather than the same one twice.
/// The raw distance to a symbol's edge, in the atlas cell's own units.
///
/// Split out from the face-mapped version below because the cube's interior
/// needs the same letters read a different way: not projected onto a face, but
/// suspended in the body as a shape with a plane of its own.
float glyphAt(vec2 g, float cell) {
  if (abs(g.x) > 1.0 || abs(g.y) > 1.0) return 1e3;
  vec2 t = vec2(
    (cell + (g.x * 0.5 + 0.5)) / kGlyphCells,
    0.5 - g.y * 0.5
  );
  float d = texture(uCarveMap, t).r;
  return (d - 0.5) * 2.0 * kGlyphSpread / (kGlyphCell * 0.5);
}

/// How thick the letters are, as a fraction of the cube's half-width, and how
/// much denser than the surrounding fog they run.
const float kLetterThick = 0.10;
const float kLetterGain = 5.0;

/// How brightly the composited symbols are filled by the field. Higher than the
/// interior's gain because this is the mark itself rather than atmosphere in it.
const float kLetterFill = 2.6;

/// How much of the letters is at this point INSIDE the solid.
///
/// ⚠️ THE LETTERS ARE NOT A FEATURE ON THE OBJECT — THEY ARE THE FOG, GATHERED.
/// Every previous attempt made them a separate thing that then had to be
/// reconciled with the energy: a groove that emitted, a channel that was filled.
/// Here there is nothing to reconcile. They are a region of the same field, at a
/// higher density, suspended in the body — so they cannot be the wrong colour,
/// cannot be the wrong material, and breathe with the flow because they ARE the
/// flow. Laser-etched crystal is exactly this and it is the reference.
///
/// Two plates crossing at the middle of the cube, one carrying each symbol, each
/// perpendicular to the axis it reads along. That they intersect is not a
/// problem to solve: the energy is denser where both cross, which is the centre
/// of the object, which is where it should be densest anyway.
///
/// ⚠️ AND A PLATE SEEN FROM BEHIND READS MIRRORED, deliberately left alone. That
/// is what a real inclusion in a solid does, and correcting it would mean the
/// letters were painted on two faces rather than existing once in the middle.
///
/// ⚠️ THE PLATES ARE INTERSECTED, NOT MARCHED THROUGH, and the first version got
/// this wrong in a way worth keeping written down. Sampling them along the same
/// six steps that carry the fog missed them almost every time: a plate a tenth
/// of a unit thick, sampled every third of a unit, is hit by accident or not at
/// all — the letters came out as broken vertical stripes. Volume marching is for
/// things thicker than the step; a thin sheet has to be solved.
///
/// A straight line crosses a plane exactly once, so each plate costs one
/// division and one lookup, and the answer is exact at any thickness. The path
/// length through it is the thickness over the cosine — light crossing the plate
/// at a slant travels further inside it and comes out brighter, which is real
/// and is free here.
///
/// Returns how much glowing plate the ray passed through, in world units.
float letterChord(vec3 lIn, vec3 lDir, float chord) {
  if (uLetters < 0.5 || uLetters > 1.5) return 0.0;
  // ⚠️ NOT `half` — RESERVED WORD IN GLSL, and the error points at the end of
  // the file rather than the line. Third time on this project, after `patch` and
  // once already in the carving. Name a local after a size, give it a suffix.
  float halfW = max(uCubeHalf, 1e-4);
  float thick = kLetterThick * halfW;
  float span = halfW * max(uGlyph, 1e-3);
  const float kSoft = 0.05;
  float total = 0.0;

  // `Di`, lying in the plane x = 0 and read along x.
  if (abs(lDir.x) > 1e-4) {
    float tt = -lIn.x / lDir.x;
    if (tt > 0.0 && tt < chord) {
      vec3 q = lIn + lDir * tt;
      float d = glyphAt(vec2(q.z, q.y) / span, 0.0);
      total += (1.0 - smoothstep(-kSoft, kSoft, d)) *
               (thick / max(abs(lDir.x), 0.08));
    }
  }

  // `Se`, in the plane z = 0 and read along z.
  if (abs(lDir.z) > 1e-4) {
    float tt = -lIn.z / lDir.z;
    if (tt > 0.0 && tt < chord) {
      vec3 q = lIn + lDir * tt;
      float d = glyphAt(vec2(q.x, q.y) / span, 1.0);
      total += (1.0 - smoothstep(-kSoft, kSoft, d)) *
               (thick / max(abs(lDir.z), 0.08));
    }
  }
  return total;
}

float glyphDist(vec2 uv, vec3 nl) {
  // ⚠️ DERIVED FROM THE CAMERA'S OWN BASIS, NOT GUESSED — and guessing it got
  // one axis backwards, which showed as `Se` carved in mirror writing while `Di`
  // beside it read correctly.
  //
  // Screen right in this shader is `up × forward` (see main), and a viewer
  // facing a face looks along -n. So the right-hand direction on a face is
  // -(y × n), which works out to +z on the +x face and -x on the +z face —
  // opposite signs for the two axes, which is exactly what a single combined
  // test could not express.
  float sx = abs(nl.x) > 0.5 ? sign(nl.x) : -sign(nl.z);
  vec2 g = vec2(uv.x * sx, uv.y) / max(uGlyph, 1e-3);
  // Past its own cell there is no symbol, and reporting a huge distance is both
  // true and what stops the atlas's neighbour bleeding in at the seam.
  if (abs(g.x) > 1.0 || abs(g.y) > 1.0) return 1e3;

  float cell = abs(nl.x) > 0.5 ? 0.0 : 1.0;
  // Into the atlas: y flips because an image runs downward and the face does
  // not.
  vec2 t = vec2(
    (cell + (g.x * 0.5 + 0.5)) / kGlyphCells,
    0.5 - g.y * 0.5
  );
  float d = texture(uCarveMap, t).r;
  // Undo the encoding, then back out of cell pixels into face units.
  float pixels = (d - 0.5) * 2.0 * kGlyphSpread;
  // ⚠️ THE DISTANCE IS SCALED BY THE SAME FACTOR THE SHAPE WAS, and it has to
  // be. A distance field is only a distance in the space it was measured in —
  // stretch the shape and every distance in it stretches too. Skipping this
  // would leave the letters the right size with the wrong-sized walls to their
  // grooves, which is the kind of error that looks like a depth problem.
  return pixels / (kGlyphCell * 0.5) * max(uGlyph, 1e-3);
}

/// Where a NEIGHBOURING pixel lands on this same face, in the face's own
/// coordinates — the raw material for measuring how fast anything on the face is
/// changing across the screen.
///
/// ⚠️ THIS EXISTS BECAUSE `fwidth` IS NOT IN FLUTTER'S SHADER SUBSET. Screen-
/// space derivatives are the standard way to antialias a distance field and the
/// compiler rejects them outright — "no match for fwidth(float)". So the same
/// quantity is measured by hand: fire the neighbouring pixel's ray, land it on
/// the face, and difference. Two ray-box intersections, which on an analytic box
/// is a handful of instructions.
///
/// Returns false when the neighbour misses the cube or lands on a DIFFERENT
/// face. Differencing across a corner would measure the jump between two faces
/// rather than the rate of change on one, and hand back a width some enormous
/// multiple of a pixel — which would smear the letters into fog exactly along
/// the edges where they need to be sharpest.
bool faceUvAt(vec2 fc, vec3 fwd, vec3 right, vec3 up, float spin, vec3 nl0,
              out vec2 uvOut) {
  vec2 uvk = vec2(
    (fc.x - uCubeCenter.x) / uCubeUnit,
    -(fc.y - uCubeCenter.y) / uCubeUnit
  );
  vec3 rdk = normalize(fwd * kFocal + right * uvk.x + up * uvk.y);
  vec3 nk;
  vec2 tk = cubeIntersect(kEye, rdk, spin, nk);
  if (tk.x <= 0.0) return false;
  vec3 nlk = spinInto() * nk;
  if (dot(nlk, nl0) < 0.99) return false;
  uvOut = carveFaceUv(spinInto() * (kEye + rdk * tk.x - cubeOrigin()), nlk);
  return true;
}

/// The carving's signed distance on this face — negative inside the cut.
///
/// ⚠️ THE STROKE IS NEVER ALLOWED BELOW A PIXEL. Fine linework is the worst
/// case in all of rendering: under a pixel wide a line stops being a line and
/// becomes a flicker that crawls as the camera moves. So the cut widens rather
/// than thins, exactly as the masonry's joints already do — and it matters more
/// for a typeface than it did for them, because a letter has thin strokes by
/// design and they are the first thing to go.
///
/// ⚠️ AND THE TOP AND BOTTOM ARE LEFT ALONE. A symbol belongs on the faces you
/// read, and one lying on the floor of the cube would be carved into a surface
/// nobody can see while still costing the march below.
float carveDist(vec3 lp, vec3 nl, float lod) {
  if (abs(nl.y) > 0.5 || uCarve < 1e-4) return 1e3;
  // ⚠️ NOT NAMED `half` — that is a RESERVED WORD in GLSL, and the error it
  // gives ("syntax error, unexpected end of file") points nowhere near the line
  // it is on. The same trap already cost this project time once, over `patch`.
  float halfW = lod / max(uCubeHalf, 1e-4) * 0.5;
  // Widening the letter by half a pixel is invisible while the cube is large,
  // and is what keeps the thin stroke of an `i` from breaking up when it is not.
  return glyphDist(carveFaceUv(lp, nl), nl) - halfW;
}

/// How far below the face the cut reaches here, in WORLD units.
///
/// The profile is a trough with sloped walls rather than a square channel: real
/// carving is made by a tool with an angle on it, and a vertical wall reads as
/// stamped. The walls also give the light something to graze.
float carveDepthAt(vec3 lp, vec3 nl, float lod) {
  float d = carveDist(lp, nl, lod);
  if (d > 0.0) return 0.0;
  // ⚠️ THE WALL'S RUN, AND IT WAS THREE TIMES TOO WIDE — he saw the symptom
  // before I found the cause: only the fattest part of the `S` really lit up.
  //
  // A stroke can only reach full depth if it is wider than this ramp, so at
  // 0.022 the numbers came out: Lora's thick stroke is 0.038 in face units and
  // bottomed out, its thin stroke is 0.015 and stopped at 68% of the depth. The
  // widest point of the `S` bowl was the only place in either letter at full
  // depth. Lora's stroke contrast is 2.6 to 1 — measured when the face was
  // chosen — so this face will always want a cut that bottoms out fast.
  //
  // 0.008 is under the thin stroke's half-width, so every part of every letter
  // now reaches the floor. It is also closer to how inscription is actually
  // cut: a chisel leaves a defined edge, not a long taper.
  const float kWall = 0.008;
  float t = clamp(-d / kWall, 0.0, 1.0);
  return kCarveDepth * uCubeHalf * uCarve * t;
}

/// [stretch] is the direction a pixel smears in, on the surface, and [aniso] is
/// how far. See cubeSurfaceFiltered.
/// Traces the light's path through the glass filling the channel.
///
/// ⚠️ SOLVED, NOT MARCHED. The wall ramp is now a hairline, so the channel is to
/// all intents a flat-bottomed slot with vertical sides — and for that shape the
/// path through the glass has a closed form. The ray either reaches the floor or
/// leaves through a side wall, whichever comes first, and both distances are one
/// division. That is exact where sixteen marching steps were an estimate, and it
/// costs a fraction as much.
///
/// ⚠️ AND THE SIDE-WALL CASE IS WHAT GIVES THE LETTERS THEIR BODY. Near the edge
/// of a stroke there is barely any glass between the surface and the stone, so
/// the fog thins out; through the middle of a stroke there is the full depth of
/// it. That falloff is a real consequence of the shape rather than a gradient
/// anyone chose, and it is most of what separates a volume from a filled
/// outline.
CarveGlass carveGlass(vec3 p, vec3 n, vec3 v, float lod) {
  CarveGlass g;
  g.amount = 0.0;
  g.path = 0.0;
  g.trans = 0.0;
  g.edge = 0.0;
  g.lip = 0.0;

  vec3 nl = spinInto() * n;
  if (abs(nl.y) > 0.5 || uCarve < 1e-4) return g;

  float full = kCarveDepth * uCubeHalf * uCarve;
  // How deep the glass surface sits below the stone's. Poured level, the way an
  // inlay actually is, rather than following the floor.
  float air = full * (1.0 - uInlay);

  float nDotV = max(dot(n, v), 1e-3);

  // Where the view ray meets the glass, which is not where it met the face
  // unless the channel is poured full. That difference IS the parallax of
  // looking into a recess, and it comes out of the geometry rather than being
  // added afterwards.
  vec3 pGlass = p - v * (air / nDotV);
  vec3 lpGlass = spinInto() * (pGlass - cubeOrigin());
  float cd = carveDist(lpGlass, nl, lod);

  // One pixel, in the units the distance is measured in. A distance field
  // antialiases by comparing against exactly this and nothing else.
  float aa = max(lod / max(uCubeHalf, 1e-4), 1e-5);
  g.amount = clamp(-cd / aa, 0.0, 1.0);

  // ⚠️ THE CUT EDGE, AND IT IS THE DETAIL THAT SAYS "INLAID". The brightest part
  // of the table is its far cut edge, because light travelling inside a sheet by
  // total internal reflection escapes wherever the sheet is cut. These letters
  // are cut glass around their entire outline, so they get the same rim — and it
  // reaches slightly OUTWARD onto the stone as well, which is what stops the
  // glow ending in a hard line and reads as light rather than as fill.
  const float kEdge = 0.010;
  g.edge = exp(-abs(cd) / kEdge);

  if (g.amount <= 0.0) return g;

  // Fresnel at the pour's flat surface: what gets in rather than bouncing off.
  // Near head-on almost everything enters and you see the fog; at a glancing
  // angle the glass turns to a mirror and shows the sky instead. That single
  // behaviour is most of what makes it read as a material rather than a shape.
  float f0 = pow((1.0 - kIor) / (1.0 + kIor), 2.0);
  float fres = f0 + (1.0 - f0) * pow(1.0 - nDotV, 5.0);
  g.trans = 1.0 - fres;

  // Bent on the way in, which is why a deep channel does not show its floor
  // where you would expect it.
  vec3 r = refract(-v, n, 1.0 / kIor);
  float down = max(-dot(r, n), 1e-3);
  float sideways = max(length(r - n * dot(r, n)), 1e-4);

  float toFloor = (full - air) / down;
  // How far the light can go before it leaves through a wall — the stroke's own
  // half-width at this point, in world units.
  float toWall = (-cd * uCubeHalf) / sideways;
  g.path = max(min(toFloor, toWall), 0.0);
  g.lip = air > 1e-5 ? 1.0 : 0.0;
  return g;
}

CubeSurface cubeSurface(vec3 p, vec3 n, vec3 v, float spin, float lod,
                        vec3 stretch, float aniso) {
  // ⚠️ THE PLAIN CUBE, for comparison — `?mat=0`. See uMaterial.
  //
  // These are the exact three values the object carried before it had a
  // material: a near-black solid whose faces read only because each one
  // reflects a different part of the environment, with the reflectance pushed
  // well above the physical 0.04 for non-metals precisely to give those faces
  // something to be told apart by.
  //
  // ⚠️ IT IS NOT PIXEL-FOR-PIXEL THE OLD BUILD. The indirect lighting around it
  // is the energy-conserving version now, and the scene it sits in is brighter.
  // This is the old MATERIAL in the current renderer, which is the honest
  // comparison to make — not a time machine.
  if (uMaterial < 0.5) {
    CubeSurface plain;
    plain.albedo = vec3(0.016, 0.016, 0.021);
    plain.roughness = max(0.20, kMinRoughness);
    plain.normal = n;
    plain.occlusion = 1.0;
    plain.through = 0.0;
    plain.fuzz = 0.0;
    plain.f0 = vec3(0.10, 0.10, 0.115);
    plain.glass = carveGlass(p, n, v, lod);
    plain.emission = vec3(0.0);
    return plain;
  }

  // ⚠️ SAMPLED IN THE CUBE'S OWN FRAME, so the growth belongs to the object
  // rather than to the space it sits in. Without the rotation it would swim
  // across the faces the moment the cube turns. Spin is fixed at 0 today, which
  // is exactly why this is easy to get wrong and never notice.
  //
  // ⚠️ AND IT IS 3D NOISE, NOT A PICTURE ON EACH FACE. A pattern that lives in
  // space has no seams: a clump that reaches the edge of one face continues onto
  // the next, the way growth on a real rock does. Texturing face by face has to
  // fight that and always shows a join along the edges.
  // ⚠️ THE MATERIAL LIVES ON A CUBE OF FIXED SIZE, whatever size the cube is.
  //
  // Everything below — the block count, the moss thresholds, the lichen radii,
  // the crack spacing — was tuned against a cube of kRefHalf, and tuned against
  // EACH OTHER: the crust is smaller than a block, the cracks smaller than the
  // crust, the fringe finer than a clump. Normalising the sample space here
  // makes resizing a PURE SCALE — the same stone, larger — so those
  // relationships survive.
  //
  // ⚠️ THE ALTERNATIVE IS ALSO DEFENSIBLE AND IS ONE LINE: drop this scaling
  // and a larger cube gets MORE blocks of the same real-world size, the way a
  // longer wall does, since stones are quarried at human scale. It was not
  // chosen because the point of resizing here is legibility on a phone, and
  // that only improves if each block gets more pixels.
  //
  // The pixel footprint scales with it, or the detail fading would be measuring
  // against the wrong yardstick.
  // ── The carving, before anything is scaled ───────────────────────────────
  //
  // ⚠️ COMPUTED IN WORLD PROPORTIONS, unlike everything below it. The material
  // is normalised to a reference cube so a resize is a pure scale of the SAME
  // stone; the carving is not that kind of thing. It is a mark made on THIS
  // object, so it keeps its place on the face and its share of the surface at
  // any size — which also means its depth and the pixel footprint it is band
  // limited against are still in world units here. Below this line they are
  // not, and using `lod` after the scaling would band limit the cut against the
  // wrong yardstick.
  vec3 lp = spinInto() * (p - cubeOrigin());
  vec3 nl = spinInto() * n;
  float carveD = carveDepthAt(lp, nl, lod);

  // The channel, and what the light does inside it.
  CarveGlass glass = carveGlass(p, n, v, lod);

  // The slope of the stone where it is NOT glass — the lip standing over a
  // channel that was not poured full. Measured by difference along the face's
  // own two axes; stepping by the pixel footprint means it is measured over what
  // is actually visible, so the cut softens as the cube shrinks instead of
  // turning into per-pixel noise. Same reasoning as the moss's slope below.
  //
  // ⚠️ AND IT IS SWITCHED OFF WHERE THE GLASS IS. A pour is LEVEL: its surface
  // is flat and lies in the face's own plane, so tilting the normal there would
  // be describing a groove that the glass has filled in.
  vec3 la = abs(nl);
  vec3 ct1 = la.x > 0.5 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0);
  vec3 ct2 = la.y > 0.5 ? vec3(0.0, 0.0, 1.0) : vec3(0.0, 1.0, 0.0);
  vec3 carveSlope = vec3(0.0);
  if (carveD > 0.0 || carveDist(lp, nl, lod) < 0.05) {
    float ce = max(lod, 0.004);
    float cd1 = carveDepthAt(lp + ct1 * ce, nl, lod);
    float cd2 = carveDepthAt(lp + ct2 * ce, nl, lod);
    // Into world space: the cut goes DOWN into the face, so the surface leans
    // the way the depth increases.
    carveSlope = spinOutOf() * (ct1 * (cd1 - carveD) + ct2 * (cd2 - carveD)) /
                 ce * (1.0 - glass.amount);
  }

  float mScale = kRefHalf / uCubeHalf;
  vec3 q = lp * mScale;
  lod *= mScale;

  // ⚠️ THE MASONRY IS SAMPLED WITH `q`, EVERYTHING FINE WITH `qf`.
  //
  // The blocks are large — several pixels across at any size we draw — so they
  // do not alias and need no help. They must also NOT be squashed: a wall's
  // stones are supposed to foreshorten when you look along the wall, and
  // undoing that would read as the masonry sliding off the surface. What
  // aliases is the fine work — the moss shoots, the crust's cracks, the stone's
  // grain, the fruiting dots. Those have no shape anyone can name, so making
  // them coarser along the unresolvable axis costs nothing anyone can see.
  vec3 sdir = spinInto() * stretch;
  float squash = 1.0 - 1.0 / max(aniso, 1.0);
  vec3 qf = squashAlong(q, sdir, squash);

  // ── The masonry ──────────────────────────────────────────────────────────
  //
  // ⚠️ THE BLOCK COUNT IS SET BY THE PHONE, NOT BY THE REFERENCE. A face is
  // about 55 pixels there. Five blocks across gives 11 pixels each and a joint
  // you can see; twenty would be mush. The wall at Sacsayhuamán happens to be
  // about that coarse, so the constraint and the reference agree — but if they
  // disagreed the phone would win.
  //
  // Stretched in y so blocks are wider than they are tall, which is what
  // courses of masonry look like whatever the culture: gravity settles stones
  // onto their long edge.
  // Cells per world unit, from the count of stones across a face — the cube is
  // two half-sizes wide. Stated as a count because that is the thing anyone
  // actually has an opinion about.
  float kStoneScale = uBlocks / (kRefHalf * 2.0);
  const vec3 kStoneAspect = vec3(1.0, 1.7, 1.0);
  const float kJointWidth = 0.045;
  // How deep a joint is cut, in world units — the cube is 1.1 across, so this
  // is about half a percent of it. A hairline, which is the whole point of this
  // wall. It works out at roughly 40 degrees of chamfer at the joint's edge.
  const float kJointDepth = 0.006;

  float stoneId;
  vec3 stoneCell;
  vec4 mas = masonry(q * kStoneAspect * kStoneScale, stoneId, stoneCell);

  // ⚠️ EVERY BLOCK IS DRESSED SLIGHTLY DIFFERENTLY, and this is the thing that
  // most makes a wall read as built rather than printed.
  //
  // These stones were pecked flat by hand with hammerstones, one at a time, so
  // no two faces end up in quite the same plane — each sits a degree or three
  // off its neighbours. That is why raking light across a real wall picks out
  // individual stones: not because they are different colours, but because they
  // are pointing in slightly different directions and so catch the light
  // differently. Without it a wall is one flat surface with lines drawn on it,
  // which is the tell that no amount of colour variation hides.
  //
  // Constant across a block and changing abruptly at its joints, which is
  // exactly right — and the change is hidden in the chamfer that is already
  // there. The component pointing out of the face is discarded later with the
  // rest of the slope, so a random direction is all this needs to be.
  const float kBlockDressing = 0.13;   // about three degrees, typically
  vec3 blockTilt = (hash33(stoneCell + 19.3) - 0.5) * kBlockDressing;

  // ⚠️ A JOINT NEVER NARROWER THAN A PIXEL. Below that it stops being a line
  // and becomes a flicker — the same reasoning as the band limiting on the
  // noise, applied to a feature that has an exact width rather than a spectrum.
  float jw = max(kJointWidth, lod * kStoneScale * 1.4);

  // Two profiles: a tight chamfer right at the joint, and a much wider, gentler
  // dome across the block. Real Inca faces are not flat — they bulge — and the
  // two together are what reads as a fitted stone rather than a tile.
  float bevel = smoothstep(0.0, jw, mas.x);
  float dome = smoothstep(0.0, jw * 9.0, mas.x);
  float faceH = bevel * 0.55 + dome * 0.45;
  float inJoint = 1.0 - bevel;

  // The slope of that, analytically — see masonry() for why no extra samples
  // are needed. smoothstep's derivative is 6t(1-t)/width, and the field grows
  // along the negative of the plane normal the distance was measured against.
  float b1 = clamp(mas.x / jw, 0.0, 1.0);
  float b2 = clamp(mas.x / (jw * 9.0), 0.0, 1.0);
  float dFace = 0.55 * (6.0 * b1 * (1.0 - b1) / jw) +
                0.45 * (6.0 * b2 * (1.0 - b2) / (jw * 9.0));
  vec3 stoneSlope = (-mas.yzw) * dFace * kStoneAspect * kStoneScale * kJointDepth;

  float h = mossHeight(qf, lod);

  // The growth's SLOPE, from the field itself rather than from the screen.
  // Stepping by the pixel footprint (never smaller) means the slope is measured
  // over exactly what is visible — so the relief softens as the cube gets
  // smaller instead of turning into per-pixel noise.
  // ⚠️ TWO SAMPLES, NOT THREE. The slope was measured along all three world
  // axes and then, further down, had its component along the normal projected
  // straight back out and discarded — a third of this field's cost computing
  // something that was thrown away. Only the part lying ALONG the face can tilt
  // a normal, so measuring along the face's own two directions gives exactly
  // the same answer for two thirds of the work.
  float e = max(lod, 0.004);
  vec3 across = normalize(abs(n.y) < 0.99 ? cross(n, vec3(0.0, 1.0, 0.0))
                                          : vec3(1.0, 0.0, 0.0));
  vec3 down = cross(n, across);
  float hAcross = mossHeight(qf + squashAlong(across * e, sdir, squash), lod);
  float hDown = mossHeight(qf + squashAlong(down * e, sdir, squash), lod);
  vec3 grad = (across * (hAcross - h) + down * (hDown - h));

  // ⚠️ WHERE MOSS GROWS: where water sits. Upward faces are lusher than
  // vertical ones — but only somewhat. The references settle it: a carved
  // VERTICAL wall in a cloud forest is covered edge to edge, because the air
  // itself is wet. "Water runs off the sides" is a dry-climate rule.
  //
  // This same rule is what will make a carving legible later: a groove holds
  // water, so moss fills it and the pattern appears without being drawn.
  // ⚠️ EVERY THRESHOLD BELOW IS A PERCENTILE OF THE FIELD, MEASURED, NOT
  // GUESSED. mossHeight averages 0.483 with a standard deviation of 0.073 —
  // sampled over 120,000 points, and the same to three decimals on a phone as
  // on a desktop, which is the band limiting doing its job.
  //
  // That number is small, and it is the trap here: averaging three bands
  // shrinks the spread, so thresholds carried over from a single-band field sit
  // several deviations out and almost nothing passes. The first version of this
  // used 0.50 with a 0.16 window, which put its midpoint at the 90th percentile
  // and covered a tenth of the surface. RE-MEASURE IF THE BANDS CHANGE.
  //
  // 0.463 puts the midpoint at the 55th percentile, so a vertical face is about
  // 45% covered; 0.405 puts it near the 25th, so an upward one is about 75%.
  // The 0.06 window is roughly 0.8 of a deviation — patches with a defined
  // edge, rather than the soft wash a wider one gives.
  //
  // ⚠️ AND THE JOINTS ARE WHERE THE WATER IS. A joint is a recess, so it holds
  // what runs off the block faces — which is why moss traces the masonry in
  // every photograph of a wall like this. This one term is what makes the
  // stonework legible without any of it being drawn: the pattern appears
  // because something grew in it.
  //
  // The face thresholds are raised at the same time. If the blocks were as
  // covered as the joints there would be no wall to see, only moss.
  // ⚠️ THE EDGE OF A MOSS PATCH IS RAGGED, and a smooth boundary is the most
  // computer-looking thing a procedural surface does. Real moss ends in
  // individual shoots poking out past the mass, so the edge is fringed at a
  // scale far finer than the clumps themselves. Nudging the height with a fine
  // field JUST BEFORE the threshold fringes the outline without disturbing the
  // relief — the slope below still comes from the unfringed field, because this
  // is about where the moss stops, not about its shape.
  float fringe = fbm3Band(qf * 34.0 + 77.3, lod * 34.0);
  float hf = h + (fringe - 0.5) * 0.055;

  // ⚠️ GRAVITY. THE ONE THING NO AMOUNT OF EXTRA NOISE CAN IMITATE.
  //
  // Everything so far has been the same in all directions, and real weathering
  // never is: water gathers in a joint, overflows, and runs DOWN the block
  // below it, leaving a damp tail that grows and stains. Every wall in the
  // world is streaked downward from its joints, and a surface without that
  // reads as decorated rather than weathered however fine its detail.
  //
  // It costs nothing, because the masonry already knows which way its nearest
  // joint lies — that is the direction it hands back for the chamfer. If that
  // joint is ABOVE us, we are in its runoff. The strength falls away with
  // distance from it, which is what makes a tail rather than a band.
  //
  // The direction has to be un-stretched back into world proportions first, or
  // the streaks lean by however much the blocks were squashed.
  vec3 worldUp = vec3(0.0, 1.0, 0.0);
  vec3 faceUpRaw = worldUp - n * dot(n, worldUp);
  float faceUpLen = length(faceUpRaw);
  // On a horizontal face there is no downhill, and no streaking. Correct.
  vec3 faceUp = faceUpLen > 1e-3 ? faceUpRaw / faceUpLen : vec3(0.0);
  vec3 towardJoint = normalize(mas.yzw * kStoneAspect * kStoneScale + 1e-6);
  float fromAbove = clamp(dot(towardJoint, faceUp), 0.0, 1.0);
  float streak = fromAbove * exp(-mas.x * 5.5);

  float upward = clamp(n.y, 0.0, 1.0);
  // The runoff carries the growth down with it.
  float t = mix(0.500, 0.440, upward) - inJoint * 0.10 - streak * 0.055;
  t -= (uMoss - 1.0) * 0.07;   // ?moss=
  float moss = smoothstep(t, t + 0.06, hf);
  // ⚠️ NOTHING GROWS ON GLASS, and this one line replaces a whole tuning problem
  // rather than solving it. The channel used to be made to grow moss on purpose,
  // because growth was what revealed the pattern while nothing lit it — and then
  // the light passing through that growth came out green, which is the one thing
  // the energy must never do. Filling the channel with glass deletes the
  // question: the letters cannot be green because there is nothing green in
  // them. Stone lips above the pour keep their growth, which is where it belongs.
  // ⚠️ TIED TO THERE ACTUALLY BEING GLASS, not applied unconditionally. With
  // `?off=512` there is none in the channel, and under `?carving=0` the channel
  // is not glass at all — in that model the growth IS the effect, because the
  // light comes out through it. Suppressing growth in either case would preserve
  // a photograph of the old design rather than the design.
  bool channelIsGlass = !isOff(512.0) && uCarving > 0.5;
  moss *= channelIsGlass ? (1.0 - glass.amount) : 1.0;
  // How close bare rock is to being overtaken. A clump standing proud throws a
  // little shade onto the stone beside it, and that contact darkening is most
  // of what makes growth sit ON a surface rather than in it.
  float nearMoss = smoothstep(t - 0.09, t, hf) * (1.0 - moss);

  // ── The stone ────────────────────────────────────────────────────────────
  // Not a flat grey. Rock has grain, and it has ridges where it has weathered
  // — that second one is a fold of the noise about its middle, which turns
  // smooth hills into creased ones and is the cheapest thing that reads as
  // erosion rather than as blur.
  // Both stretched across the field's real range rather than used raw: a
  // normalised band sits within about a tenth of 0.5, so feeding it straight
  // into a mix only ever reaches the middle of the two colours.
  float grain = smoothstep(0.40, 0.60, fbm3Band(qf * 9.0 + 71.3, lod * 9.0));
  float creased = 1.0 - abs(2.0 * fbm3Band(qf * 3.3 + 5.9, lod * 3.3) - 1.0);
  float ridge = smoothstep(0.55, 1.0, creased);
  vec3 stone = mix(vec3(0.093, 0.089, 0.082), vec3(0.148, 0.142, 0.130), grain);
  stone *= mix(0.86, 1.08, ridge);
  // ⚠️ EVERY BLOCK ITS OWN STONE. They were quarried separately and have
  // weathered separately for five hundred years, so no two are the same tone.
  // Without this the wall reads as one surface with lines scored into it —
  // which is exactly what a tiled texture looks like, and the tell we are
  // trying to avoid. Hashed from which cell this is, so a block is one colour
  // all the way to its own edges.
  stone *= mix(0.84, 1.16, stoneId);
  // Shaded by the moss standing over it — see nearMoss.
  stone *= mix(1.0, 0.70, nearMoss);
  // ⚠️ WET STONE IS DARKER, and this is where the streaks become visible on
  // bare rock rather than only as extra growth. Water fills the pores so less
  // light scatters straight back out — the same reason a paving slab goes near
  // black in the rain and pales again as it dries.
  stone *= mix(1.0, 0.66, streak);

  // ── The moss ─────────────────────────────────────────────────────────────
  // ⚠️ MOSS IS NOT ONE GREEN, and this is the biggest single gain over a flat
  // tint. In the references it runs from a bright yellow-green on the tips,
  // where the light lands and the growth is newest, through a mid green, down
  // to a cold near-black in the creases. Driving that from the SAME height
  // field that shapes it means the bright parts are exactly the raised parts —
  // they cannot drift out of register, because there is only one field.
  // How far up a clump this is. The window is about 1.6 deviations, so the
  // brightest tips are genuinely reached; t + 0.30 would be four deviations out
  // and the crest colour would never appear at all.
  float tip = smoothstep(t + 0.01, t + 0.13, h);
  // ⚠️ A NARROWER RANGE THAN IT LOOKS LIKE IT SHOULD BE. The first version ran
  // from near-black to a bright yellow-green, about five to one, and read as
  // camouflage — because the light and the occlusion widen this range again on
  // top. Real moss photographs at closer to two to one once you measure it
  // rather than trusting the eye, which exaggerates colour in dark places.
  const vec3 kDeep = vec3(0.042, 0.058, 0.034);
  const vec3 kMid = vec3(0.068, 0.094, 0.044);
  const vec3 kCrest = vec3(0.099, 0.121, 0.051);
  vec3 mossC = mix(kDeep, kMid, smoothstep(0.0, 0.45, tip));
  mossC = mix(mossC, kCrest, smoothstep(0.45, 1.0, tip));

  // Patch-to-patch variation, on a scale much larger than a clump: some of it
  // is drier and browner than the rest. Without this every patch is the same
  // plant, which is the other half of why one-scale noise reads as camouflage.
  float age = fbm3Band(qf * 0.8 + 55.1, lod * 0.8);
  mossC = mix(mossC, mossC * vec3(1.11, 1.00, 0.84), smoothstep(0.50, 0.64, age));

  // ── The lichen ───────────────────────────────────────────────────────────
  // ⚠️ IT TAKES WHAT THE MOSS DOES NOT. They compete for the same rock, and
  // lichen wins on the drier, more exposed ground — the open block faces, not
  // the wet joints. Weighting it against the moss and against the joints is
  // what keeps the two from reading as one speckled mess.
  const float kLichenScale = 11.0;
  float bloom;
  float patchId;
  float crust = lichen(qf * kLichenScale, lod * kLichenScale, bloom, patchId);
  // Crustose lichen wants dry, exposed, open rock — which a cut is the opposite
  // of. Suppressed in the carving for the same reason it is suppressed in the
  // joints, by the same kind of term.
  crust *= (1.0 - moss) * bevel * uLichen *
           (channelIsGlass ? (1.0 - glass.amount) : 1.0);

  // Pale sage, and paler still at the growing edge, which is the newest and
  // thinnest part of the crust. Some colonies run yellow — a different species
  // on the same wall, which is what the references show.
  vec3 crustC = mix(vec3(0.136, 0.143, 0.120), vec3(0.194, 0.200, 0.170), bloom);

  // ⚠️ A REAL WALL CARRIES SEVERAL SPECIES, NOT ONE IN SEVERAL MOODS. Grey-
  // green is the common crust, sulphur yellow and rusty orange are different
  // organisms entirely, and a near-white one is common on exposed stone. Each
  // colony picks one and keeps it, which is what makes them read as separate
  // living things rather than as noise in a single colour.
  vec3 species = crustC;
  species = mix(species, crustC * vec3(1.16, 1.05, 0.60),
                smoothstep(0.44, 0.56, patchId));
  species = mix(species, crustC * vec3(1.26, 0.90, 0.52),
                smoothstep(0.68, 0.78, patchId));
  species = mix(species, crustC * vec3(1.10, 1.11, 1.09),
                smoothstep(0.86, 0.94, patchId));
  crustC = species;

  // ⚠️ THE DARK MARGIN. Most crustose lichens ring themselves with a thin
  // black line — the fungus reaching out ahead of the algae it farms, with no
  // green in it yet. It is a small feature that does an unreasonable amount of
  // work: it separates one colony from the rock and from its neighbours, and
  // it is the detail that says "organism with a boundary" rather than "stain".
  float margin = smoothstep(0.80, 0.97, bloom);
  crustC *= mix(1.0, 0.30, margin);

  // ⚠️ APOTHECIA — the fruiting cups. Small dark discs scattered over the
  // crust, and on many species the most recognisable thing about them. Cheap
  // by construction: they are far smaller than their cell, so the cell a point
  // falls in is the only one that can hold the disc it is inside, and no
  // neighbours need checking at all.
  const float kFruitScale = 74.0;
  vec3 fruitCell = floor(qf * kFruitScale);
  vec3 fruitAt = hash33(fruitCell + 71.1) * 0.6 + 0.2;
  float fruitR = 0.10 + 0.11 * hash31(fruitCell + 13.7);
  float fruitW = max(0.03, lod * kFruitScale);
  float fruit = step(0.70, hash31(fruitCell + 91.3)) *
                (1.0 - smoothstep(fruitR - fruitW, fruitR,
                                  length(fract(qf * kFruitScale) - fruitAt)));
  crustC *= mix(1.0, 0.34, fruit);

  // ⚠️ A CRUST IS CRACKED INTO PLATES. As it dries and swells it splits into
  // small polygons with dark fissures between them — the feature that makes a
  // crustose lichen unmistakable close up, and the reason a smooth pale patch
  // reads as a paint stain instead. It is the same cell pattern as the wall
  // itself, three octaves smaller: the machinery is identical, only the scale
  // and the meaning change. Its slope comes back analytically, so the fissures
  // carry real relief for nothing.
  // ⚠️ ONLY WHERE THERE IS CRUST. This is a second full cell pattern — as
  // expensive as the wall itself — and it was running on every pixel of the
  // cube, including every one buried under moss where its result is multiplied
  // by zero. The default stands for "far from any fissure", which is what a
  // pixel with no crust on it should look like anyway.
  const float kAreoleScale = 32.0;
  float areoleId = 0.5;
  vec3 areoleCell = vec3(0.0);
  vec4 areole = vec4(1.0, 0.0, 1.0, 0.0);
  if (crust > 0.002) {
    areole = masonry(qf * kAreoleScale, areoleId, areoleCell);
  }
  float fissureW = max(0.10, lod * kAreoleScale * 1.6);
  float plate = smoothstep(0.0, fissureW, areole.x);
  crustC *= mix(0.62, 1.06, plate) * mix(0.90, 1.10, areoleId);

  CubeSurface s;
  s.albedo = mix(mix(stone, crustC, crust), mossC, moss);
  // ⚠️ MOSS IN A CLOUD FOREST IS WET, and wet is not matte. A fully rough
  // surface reads as dust or felt; a damp one keeps a soft sheen that appears
  // at grazing angles. The deep parts and the joints hold the most water, so
  // they are the glossiest — which also means the sheen traces the masonry,
  // exactly like the growth does.
  float damp = clamp(inJoint * 0.6 + streak * 0.5 + (1.0 - tip) * 0.4, 0.0, 1.0);
  float mossRough = mix(0.94, 0.70, damp);
  s.roughness = max(mix(mix(0.66, 0.82, crust), mossRough, moss), kMinRoughness);
  // ⚠️ AND WET IS DARKER, not merely shinier. Half of "damp" is the drop in
  // brightness; changing only the gloss gives the odd plastic look of a surface
  // that is somehow polished and dry at once.
  s.albedo *= mix(1.0, mix(1.0, 0.70, damp), moss);
  // Only the growth is a thicket. Stone and crust stay solids.
  s.fuzz = moss * uFuzz;
  // Light does not reach the bottom of a clump. This is what turns shape into
  // depth; without it the relief reads as embossed metal.
  // Spanning the field's real range: smoothstep(0.0, 0.55, h) would sit almost
  // entirely past its own top end and hold nearly still.
  s.occlusion = mix(1.0, mix(0.62, 1.0, smoothstep(0.40, 0.56, h)), moss);
  // A joint sees almost nothing of the sky — it is a slot between two stones.
  s.occlusion *= mix(1.0, 0.60, inJoint);
  // ⚠️ A CHANNEL POURED FULL SEES THE SKY LIKE THE FACE DOES, because its
  // surface IS the face's plane — so no occlusion is owed there. One left below
  // the rim is a slot, and gets it. That is why this depends on how full the
  // pour is rather than on the cut being present.
  s.occlusion *= mix(1.0, mix(0.55, 1.0, uInlay), glass.amount);
  // Only the thin, newest growth at the tips passes light.
  s.through = moss * smoothstep(0.15, 0.85, tip);

  // Only the part of the slope lying ALONG the face may tilt the normal. The
  // component pointing straight out is the growth getting thicker, not the
  // surface leaning, and letting it through would swell the face outward.
  // 0.04 is the physical reflectance of every non-metal. The 0.10 the plain
  // cube uses was invented to give a near-black solid some shape to read by; a
  // surface with real colour in it does not need the help.
  s.f0 = vec3(0.04);
  // ?lvl= — applied only to the material, so ?mat=0 stays a fixed reference.
  s.albedo *= uLevel;

  // ⚠️ ONE SLOPE, TWO CAUSES: the stones' own shape and the growth on them.
  // Adding them before tilting the normal — rather than tilting twice — is what
  // keeps moss sitting IN a joint rather than floating across it.
  //
  // The moss figure is measured, like the thresholds: `grad / e` is the field's
  // slope, which averages 2.17, so the multiplier is roughly the tangent of how
  // far the surface leans — 0.15 is about 18 degrees on average and 27 at its
  // steepest. The first attempt used 26, which works out at 89 degrees, the
  // normal lying flat, and turned every clump into a black hole. Stone keeps a
  // fraction of it, because worn rock is not smooth either.
  // The fissures between the crust's plates, shallow and only where crust is.
  float a1 = clamp(areole.x / fissureW, 0.0, 1.0);
  vec3 areoleSlope = (-areole.yzw) * (6.0 * a1 * (1.0 - a1) / fissureW) *
                     kAreoleScale * 0.0016 * crust;

  vec3 slope = blockTilt + stoneSlope + areoleSlope + carveSlope +
               (grad / e) * mix(0.035, 0.150, moss);
  vec3 alongFace = slope - n * dot(slope, n);
  s.normal = normalize(n - alongFace);

  // ── The glass in the channel ─────────────────────────────────────────────
  //
  // ⚠️ THE SURFACE STOPS BEING STONE HERE, and it has to be a real material
  // swap rather than a tint over the stone. Glass is nearly black in reflected
  // light — you see almost nothing OFF it and almost everything THROUGH it — so
  // its albedo goes to nothing, its roughness to a polish, and its normal back
  // to the face's own plane because a pour is level.
  //
  // Everything after this is then the ordinary lighting model doing the work: a
  // smooth dielectric picks up a sharp specular from the lamp and a mirror of
  // the sky at a glancing angle, both for free, both consistent with the sheet
  // the cube is standing on because it is the same maths.
  //
  // What is NOT here is the fog. That is the one part of this object that moves,
  // so it cannot live in a cached picture — it is applied live in the scene pass
  // from the path length below. See CarveGlass.
  if (!isOff(512.0) && uCarving > 0.5) {
    s.albedo = mix(s.albedo, vec3(0.004), glass.amount);
    s.roughness = mix(s.roughness, max(0.055, kMinRoughness), glass.amount);
    s.f0 = mix(s.f0, vec3(0.04), glass.amount);
    s.fuzz *= 1.0 - glass.amount;
    s.through *= 1.0 - glass.amount;
    s.normal = normalize(mix(s.normal, n, glass.amount));
  }
  s.glass = glass;

  // ── THE EARLIER MODEL — `?carving=0`, kept whole ─────────────────────────
  //
  // The channel as an EMISSIVE SURFACE rather than a volume: its floor gives off
  // light in proportion to how deep the cut is, and that light picks up the
  // colour of the moss it passes through on the way out. Rejected for this
  // object, and correctly — a glowing surface has one colour, no thickness and
  // no inside, so it can never read as the fog under the sheet no matter how the
  // colour is matched. But it is a complete design, and it is one knob away
  // rather than one rebuild away.
  //
  // ⚠️ IT NEEDS THE MOSS BACK IN THE CHANNEL, because the green IS the effect
  // here — light through growth, lit from behind. Restoring the model without
  // restoring what fed it would be preserving a photograph of it.
  s.emission = vec3(0.0);
  if (uCarving < 0.5) {
    float depth = carveDepthAt(lp, nl, lod);
    float carve = clamp(
      depth / max(kCarveDepth * uCubeHalf * uCarve, 1e-6), 0.0, 1.0);
    vec3 through = mix(vec3(1.0), mossC * 9.0, moss * 0.85);
    s.emission = kEnergyTint * carve * uEmit * 1.6 * through;
  }
  return s;
}

/// The surface, filtered for the shape a pixel ACTUALLY covers.
///
/// ⚠️ A PIXEL IS NOT A CIRCLE ON A TILTED FACE, IT IS A LONG THIN SMEAR.
///
/// `lod` describes the footprint on a face viewed square on. Tilt the face away
/// and the same pixel stretches across the surface by 1/cos of the angle, along
/// one direction only. That is not a small correction here: the cube's top face
/// sits at 0.22 from this camera, so a pixel there covers four and a half times
/// more surface one way than the other — and it worsens as the object grows,
/// because raising the cube lifts its top toward the camera's eye level. At a
/// half-size of 0.8 the top is down to 0.09, over ten times.
///
/// Detail finer than that smear survives the fade, cannot be drawn, and
/// aliases. The fizzing is what reads as "pixelated".
///
/// ⚠️ TWO WRONG ANSWERS WERE TRIED FIRST, AND BOTH ARE INSTRUCTIVE.
///
/// Blurring by the whole smear is the safe direction and throws away the SHARP
/// axis along with the soft one — the entire cube went to mush.
///
/// Sampling several times along the smear is what hardware does for a texture,
/// and it works, but it costs a full material evaluation per tap: up to four
/// per face, three faces, where there had been one. Far too expensive for what
/// it buys.
///
/// ⚠️ THE THIRD ANSWER IS THE RIGHT ONE, AND IT IS FREE: a texture has a
/// picture to stay faithful to, and NOISE DOES NOT — it only has a bandwidth.
/// So rather than sampling a too-fine field repeatedly, make the field coarser
/// in the direction that cannot be resolved, once. This function works out how
/// much and which way; cubeSurface applies it to the fine fields and leaves the
/// masonry alone.
/// Walks the view ray down into the cut and returns where it REALLY lands.
///
/// ⚠️ THIS IS THE LINE BETWEEN A CUT AND A DRAWING, and it is worth being exact
/// about what it buys. Tilting the normal alone — which the material already
/// does — makes a groove that catches light correctly and is still, provably,
/// flat: look along the face and the far wall of the channel does not hide its
/// floor, because there is no channel. Here the ray actually travels down into
/// the trough, so a shallow viewing angle slides the floor sideways and the near
/// wall eats it, exactly as a real cut does.
///
/// It is also why moss inside the cut sits BELOW the surface rather than on it:
/// the material is sampled at the point the ray truly reached.
///
/// ⚠️ A RAY THAT MEETS THE FLAT FACE STOPS THERE, and the early return is that
/// fact rather than an optimisation. The carving only ever goes DOWN — nothing
/// is added above the face — so a ray arriving outside the pattern has already
/// hit the solid, and no amount of marching can change its answer. That is what
/// keeps this cheap: it runs on the pattern's own pixels and nowhere else.
///
/// ⚠️ THE SILHOUETTE IS STILL A PLAIN BOX, and for this pattern that is not an
/// approximation — the tile sits well inside its face and never reaches an edge,
/// so there is no outline for it to notch. It becomes a real question only if
/// the kené later runs off the sides, and the honest fix then is to trace the
/// shell for grazing rays too, not to fake it.
vec3 carveRelief(vec3 p, vec3 n, vec3 v, float lod) {
  if (uCarve < 1e-4) return p;
  vec3 nl = spinInto() * n;
  if (abs(nl.y) > 0.5) return p;

  vec3 lp = spinInto() * (p - cubeOrigin());
  // Outside the cut the surface is the face, and the ray is already on it.
  if (carveDepthAt(lp, nl, lod) <= 0.0) return p;

  float nDotV = max(dot(n, v), 1e-3);
  float maxD = kCarveDepth * uCubeHalf * uCarve;
  // Travelling further than this cannot leave the trough, because nothing in it
  // is deeper.
  float sMax = maxD / nDotV;

  // Marched in the CUBE'S OWN FRAME so the pose costs one matrix rather than one
  // per step.
  vec3 dirL = spinInto() * (-v);

  const int kSteps = 16;
  float prevS = 0.0;
  float prevGap = carveDepthAt(lp, nl, lod);   // surface minus ray, at s = 0
  float sHit = 0.0;
  for (int i = 1; i <= kSteps; i++) {
    float s = sMax * float(i) / float(kSteps);
    float gap = carveDepthAt(lp + dirL * s, nl, lod) - s * nDotV;
    if (gap <= 0.0) {
      // Crossed between prevS and s. One linear solve on the two gaps lands
      // within a fraction of a step of the true crossing, which is far below a
      // pixel at this depth — a binary refinement here would be measuring
      // something nothing can display.
      float f = prevGap / max(prevGap - gap, 1e-6);
      sHit = mix(prevS, s, clamp(f, 0.0, 1.0));
      break;
    }
    prevS = s;
    prevGap = gap;
    sHit = s;
  }
  return p - v * sHit;
}

CubeSurface cubeSurfaceFiltered(vec3 p, vec3 n, vec3 v, float spin, float lod) {
  // Down into the cut first — everything below is evaluated where the ray
  // actually landed, not where it met the face's plane.
  p = carveRelief(p, n, v, lod);
  float nDotVg = max(dot(n, v), 1e-4);
  // Capped at eight, the usual ceiling, so a face at the silhouette cannot ask
  // for an unbounded smear.
  float aniso = clamp(1.0 / nDotVg, 1.0, 8.0);

  // The direction the pixel smears in: the view, laid flat onto the face.
  vec3 vt = v - n * dot(n, v);
  float vtl = length(vt);

  // Barely tilted, or looking straight down the normal — nothing to correct,
  // and no direction to correct along.
  if (aniso < 1.15 || vtl < 1e-4) {
    return cubeSurface(p, n, v, spin, lod, vec3(0.0, 1.0, 0.0), 1.0);
  }
  return cubeSurface(p, n, v, spin, lod, vt / vtl, aniso);
}

/// The cube as it appears in a REFLECTION: an average, not a surface.
///
/// ⚠️ THE FULL MATERIAL IS UNRESOLVABLE HERE, so computing it is pure waste.
/// A reflection arrives multiplied by Fresnel — 4 to 10% looking down at a
/// sheet — off a rough, dark surface, and lands on top of the energy, which is
/// the brightest thing in the frame at exactly that spot. Nobody can pick out a
/// lichen colony through that. Two full material evaluations per table pixel
/// were being spent on it, one for the reflection and one for the ghost off the
/// glass's back face.
///
/// What DOES survive is which FACE is being reflected: the faces differ in
/// brightness, and that difference is what makes the reflection read as an
/// object rather than a smudge. So the geometry stays exact and only the
/// surface detail is replaced by its own average.
///
/// ⚠️ AND NO SHADOW RAYS. The caller used to trace sixteen of them to ask
/// whether the cube shadows itself at this point. It cannot: it is convex, and
/// one light cannot put a convex object in its own shadow. The direct path has
/// always known this — shadeCubeRay passes 1.0 with that reasoning written
/// beside it — while the reflection path rediscovered the same constant every
/// frame, for every table pixel that could see the cube.
vec3 shadeCubeCoarse(vec3 p, vec3 n) {
  // The material's mean albedo: stone, growth and crust at their coverages.
  const vec3 kAverage = vec3(0.093, 0.099, 0.076);
  vec3 albedo = kAverage * uLevel;
  vec3 l = normalize(kLightPos - p);
  vec3 direct = albedo * (1.0 / 3.14159265) * max(dot(n, l), 0.0) * 3.4;

  // ⚠️ THE CARVING IS THE ONE THING THAT SURVIVES THIS AVERAGE, and it has to.
  // Everything else here is deliberately reduced to its mean, because nobody can
  // pick a lichen colony out of a reflection arriving at 4% through rough dark
  // glass. But the letters are not surface detail — they are the brightest thing
  // on the object by an order of magnitude, and a bright thing standing over a
  // reflective sheet that shows no sign of it is exactly the mistake this whole
  // pass of work is about. A glowing object with no reflection is a hologram.
  //
  // It costs one distance lookup rather than the full material: where the cut
  // is, how deep, and nothing else.
  // Looked at head-on, which is all a reflection this dim can justify: the
  // Fresnel and the refraction would each cost more than the whole term is
  // worth once it has been multiplied by 4% and landed on top of the energy.
  CarveGlass g = carveGlass(p, n, n, cubeLod());
  float dens = smoothstep(kFogLow, kFogHigh, carveFogField(p));
  vec3 emitted = kEnergyTint * dens * uEmit *
                 (g.path * kFogGain * g.trans * g.amount + g.edge * kEdgeGain);

  return direct + envColor(n) * albedo + emitted;
}

// ── Shading ─────────────────────────────────────────────────────────────────

/// Intersects and shades the cube along one camera ray. Returns its colour
/// and writes 1.0 to [hit].
vec3 shadeCubeRay(vec3 rd, float spin, float lod, out float hit, out vec3 emit);

/// The outward normal at a point ON the box, from where that point sits in the
/// cube's own frame. Needed for the EXIT face, which the intersection routine
/// does not report — it answers about the near hit, and light leaving a solid
/// cares about the far one.
vec3 boxNormalAt(vec3 local) {
  vec3 a = abs(local) / max(uCubeHalf, 1e-5);
  if (a.x >= a.y && a.x >= a.z) return spinOutOf() * vec3(sign(local.x), 0, 0);
  if (a.y >= a.z) return spinOutOf() * vec3(0.0, sign(local.y), 0.0);
  return spinOutOf() * vec3(0.0, 0.0, sign(local.z));
}

/// The longest chord through the cube, for packing it into eight bits: the body
/// diagonal, which no straight line inside a box can beat.
float cubeChordMax() { return uCubeHalf * 3.4641016; }

/// How far a point inside the cube is from the nearest EDGE, in world units.
///
/// Not from a face — from an edge, where two faces meet. That is the quantity a
/// cut edge glows by, and it is the second-smallest of the three distances to
/// the faces: the smallest alone would light up every face as you looked along
/// it, which is a fog, not an edge.
float cubeEdgeDistance(vec3 local) {
  vec3 d3 = cubeHalf() - abs(local);
  float lo = min(d3.x, min(d3.y, d3.z));
  float hi = max(d3.x, max(d3.y, d3.z));
  return d3.x + d3.y + d3.z - lo - hi;
}

/// The STATIC half of the cube as a solid of glass: what it reflects, and where
/// its cut edges burn. What is inside it, and what can be seen through it, both
/// move — those are computed live in the scene pass from the descriptor written
/// into [emit].
///
/// ⚠️ THE SAME MATERIAL AS THE SHEET IT STANDS ON, and that is the entire point
/// of it rather than a resemblance. The scene gets one rule — glass is where the
/// energy lives — and the object stops being a thing that sits in the world and
/// becomes a thing made of the world's own substance.
///
/// ⚠️ AND A SOLID IS NOT A SHEET, which is where the work is. The table is thin
/// enough that what you see through it lands almost where it would have anyway.
/// A cube is thick: light bends going in, crosses a real distance through the
/// medium, and bends again coming out, so the scene behind it arrives displaced
/// and the fog inside has depth to accumulate through. Everything interesting
/// about this material comes from that thickness.
vec3 shadeGlassCube(vec3 p, vec3 n, vec3 v, float lod, out vec3 emit) {
  vec3 rd = -v;
  float nDotV = max(dot(n, v), 1e-4);

  // Schlick: about 4% looking straight into a face, rising to everything at a
  // glancing one. This is what makes the cube read as MADE of something —
  // head-on you see into it, edge-on it turns to a mirror, and the transition
  // happens across every face at once.
  //
  // ⚠️ REFLECTANCE FROM REAL GLASS, BENDING FROM `uIor`, AND THE SPLIT IS
  // DELIBERATE. They are one number in physics and two different jobs here. How
  // a surface REFLECTS is what makes it look like glass; how it BENDS is what
  // displaces the view behind it and steps the horizon at every edge. The mark
  // wants the first and not the second, so at `?ior=1` this cube reflects
  // exactly like glass and refracts not at all — which is not a material that
  // exists, and is the correct answer for a logo.
  float f0 = pow((1.0 - kIor) / (1.0 + kIor), 2.0);
  float fres = f0 + (1.0 - f0) * pow(1.0 - nDotV, 5.0);

  // ── What it reflects ────────────────────────────────────────────────────
  //
  // ⚠️ THE ENVIRONMENT, NOT THE REAL SKY, and deliberately. The star field is
  // available here, but sampling it would tie this cached picture to a sky that
  // turns — and the reflection arrives multiplied by four to ten percent, under
  // a bright interior. The environment carries the one thing that actually
  // matters: that different faces reflect different parts of the world, which is
  // what tells them apart.
  vec3 refl = envColor(reflect(rd, n));

  // A real dielectric also gives a hard specular from the lamp. On a mirror-
  // smooth solid it is a small bright chip on whichever face is angled right,
  // and it is most of what says "polished" rather than "translucent".
  vec3 l = normalize(kLightPos - p);
  vec3 h = normalize(l + v);
  float nDotH = max(dot(n, h), 0.0);
  float nDotL = max(dot(n, l), 0.0);
  const float kPolish = 0.045;
  float spec = DistributionGGX(n, h, kPolish) *
               VisibilitySmith(nDotV, nDotL, kPolish) * nDotL;

  // ── The chord, and the cut edges ────────────────────────────────────────
  vec3 local = spinInto() * (p - cubeOrigin());
  float edgeD = cubeEdgeDistance(local);
  // A hairline, and never finer than a pixel — the same rule the masonry's
  // joints follow, for the same reason: below a pixel a line stops being a line.
  float edgeW = max(0.012 * uCubeHalf, lod * 0.9);
  float edge = exp(-edgeD / edgeW);

  // Bent on the way in, and the distance it then has to cross. Light entering a
  // corner travels almost nothing; light entering the middle of a face crosses
  // the whole body.
  vec3 r1 = refract(rd, n, 1.0 / uIor);
  vec3 nExit;
  vec2 tin = cubeIntersect(p + r1 * 1e-4, r1, 0.0, nExit);
  float chord = max(tin.y, 0.0);

  // ── The other option: the symbols FROSTED onto the faces ────────────────
  //
  // `?letters=2`. Etched glass is glass whose surface has been broken into
  // countless tiny facets, so it stops transmitting cleanly and starts
  // SCATTERING: it goes pale and bright where light reaches it, and you can no
  // longer see through it. Both halves matter — a frost that brightens without
  // also blocking the view reads as paint on a window.
  //
  // Kept as an alternative rather than a fallback. It is a different object from
  // the suspended version: marks made ON the surface of a thing, against
  // something existing inside it.
  float trans = 1.0 - fres;
  vec3 frost = vec3(0.0);
  // ⚠️ 2 ONLY. It was briefly drawn under 3 as well, to be the base the energy
  // added onto — and that quietly undid the entire point of path 3. The frost
  // lives in the CACHED SCENE layer, which is rendered below the display and
  // scaled up; the energy fill is at device resolution. Whichever of the two
  // draws the letter's OUTLINE decides how sharp it looks, and the soft one was
  // drawing it. The crisp pass was only brightening the inside of a soft shape.
  //
  // Under 3 the whole letter — frost and fill together — is drawn by the device
  // resolution pass instead. Same base, same behaviour with the energy off, but
  // the edge belongs to the pass that can actually resolve it.
  if (uLetters > 1.5 && uLetters < 2.5) {
    vec3 nl = spinInto() * n;
    float aa = max(lod / max(uCubeHalf, 1e-4), 1e-5);
    // ⚠️ THE RAMP IS CENTRED ON THE EDGE, and it was not. Ramping from the
    // boundary INWARD over a whole pixel puts the entire transition inside the
    // letter: half a pixel of the stroke is eaten, and what is left is blurred
    // on one side only. A pixel exactly on the edge is half covered, so the
    // ramp has to straddle it — which is the difference between antialiasing a
    // shape and quietly shrinking it.
    float etch =
        clamp(0.5 - glyphDist(carveFaceUv(local, nl), nl) / aa, 0.0, 1.0);
    frost = etch * (envColor(n) * 0.55 + vec3(nDotL) * 0.30);
    trans *= 1.0 - etch * 0.88;
  }

  emit = vec3(
    clamp(chord / cubeChordMax(), 0.0, 1.0),
    trans,
    edge
  );

  return refl * fres + vec3(spec) * 3.4 * fres + frost;
}

/// ⚠️ EMISSION COMES BACK SEPARATELY RATHER THAN ADDED IN, and that separation
/// is the entire reason the carving can breathe without costing the frame rate.
///
/// Everything else about this cube is fixed: the stone, the growth, the light,
/// where the letters are and how deep. That is why its picture can be drawn once
/// and reused, which is what took the frame from 45 to 75. The energy leaving
/// the carving is the one thing that MOVES — and folding it into the returned
/// colour would make the whole picture time-varying, throwing all of that away
/// to animate a few hundred pixels.
///
/// So the expensive, static answer is cached — how much energy this point COULD
/// emit — and the cheap, moving answer is computed per frame and multiplied
/// against it. See uLayer 7 and cubeEnergyFlow.
vec3 shadeCube(vec3 p, vec3 n, vec3 v, float visibility, float spin, float lod,
               out vec3 emit) {
  // A solid of glass is not a surface with a material on it — it has no albedo
  // to light and no growth to occlude, and everything it shows comes from what
  // is inside or behind it. So it takes its own path rather than a branch
  // threaded through the stone's.
  if (uMaterial > 1.5) return shadeGlassCube(p, n, v, lod, emit);

  // ⚠️ THE GEOMETRIC NORMAL, NOT THE BUMPED ONE, wherever the question is about
  // the SHAPE rather than the surface — how edge-on this face is to the camera.
  // Feeding those terms the bumpy normal turns detail finer than a pixel into
  // blotchy brightness, a well-known way to make a textured surface sparkle.
  float nDotVg = max(dot(n, v), 1e-4);

  CubeSurface s = cubeSurfaceFiltered(p, n, v, spin, lod);
  vec3 ns = s.normal;
  vec3 albedo = s.albedo;
  float roughness = s.roughness;

  vec3 f0 = s.f0;

  vec3 l = normalize(kLightPos - p);
  vec3 h = normalize(l + v);
  float nDotL = max(dot(ns, l), 0.0);
  float nDotV = max(dot(ns, v), 1e-4);

  float d = DistributionGGX(ns, h, roughness);
  float vis = VisibilitySmith(nDotV, nDotL, roughness);
  vec3 fresnel = FresnelSchlick(max(dot(h, v), 0.0), f0);
  vec3 direct = (d * vis) * fresnel;

  // ⚠️ WRAPPED DIFFUSE, ON THE MOSS ONLY — the single most "alive" thing here.
  //
  // Moss is not opaque. Light enters a frond, bounces around inside and leaves
  // somewhere else, so the growth stays lit a little way PAST the point where a
  // solid surface would have turned away from the light. That soft, late
  // falloff is what the eye reads as something soft and organic; a hard
  // terminator reads as something carved. Rock keeps the hard one, which is why
  // this is weighted by how much growth is here.
  float wrap = 0.55 * s.through;
  float lambert = clamp((dot(ns, l) + wrap) / ((1.0 + wrap) * (1.0 + wrap)),
                        0.0, 1.0);
  direct += albedo * (1.0 / 3.14159265) * (1.0 - fresnel) *
            (lambert / max(nDotL, 1e-4));

  // ⚠️ THE FUZZ LOBE — see D_Charlie. This is what makes the moss soft rather
  // than merely dull, and it is the difference GGX cannot express at any
  // roughness. Its energy sits at grazing angles, so it appears as a bright rim
  // wherever the growth turns away from the eye, which is exactly what fuzzy
  // things do in life. Tinted toward white, because scattering off the flanks
  // of countless fibres washes the colour out — the pale bloom on velvet.
  //
  // ⚠️ ITS STRENGTH IS THE ONE NUMBER HERE THAT IS PURE JUDGEMENT, so it gets
  // said out loud. The first version used 0.55 and washed the tint 60% toward
  // white; the model was right and the volume was wrong. Measured on the cube,
  // it left the average untouched and lifted the brightest tenth by 26% — which
  // is exactly what a grazing-angle lobe does, and exactly the wrong thing
  // here. Hot rims read as lush and freshly wet. Old stone in dim light is dark
  // and low in contrast, and that is what reads as having been somewhere a long
  // time. The cube also has to sit BEHIND the statement rather than shout over
  // it. So: keep the softness, lose the bloom.
  vec3 fuzzTint = mix(clamp(albedo * 5.5, 0.0, 1.0), vec3(1.0), 0.25);
  if (s.fuzz > 0.0) {
    float nDotH = max(dot(ns, h), 0.0);
    direct += fuzzTint * (D_Charlie(0.35, nDotH) * V_Neubelt(nDotV, nDotL)) *
              s.fuzz * 0.15 * s.occlusion;
  }

  direct *= nDotL * 3.4 * visibility;

  // ⚠️ AND LIGHT THAT COMES THROUGH IT. Thin growth lit from behind glows —
  // the effect that makes a leaf held up to the sun look nothing like a leaf on
  // the ground. Strongest when looking toward the light through the surface,
  // which is why it is driven by the view against the light rather than by the
  // normal against it. Tinted by the moss's own colour, because that is what
  // the light has passed through on the way.
  float behind = pow(clamp(dot(-v, normalize(l + ns * 0.4)), 0.0, 1.0), 3.0);
  direct += albedo * behind * s.through * 1.9 * visibility;

  // ── Indirect ─────────────────────────────────────────────────────────────
  vec3 r = reflect(-v, ns);
  float grazeDamp = mix(0.28, 1.0, smoothstep(0.0, 0.5, nDotVg));

  // Split-sum with multiple-scattering compensation. Without the second term a
  // surface this rough loses a visible amount of its light and reads as felt.
  vec2 dfg = envDFG(nDotVg, roughness);
  vec3 kS = FresnelSchlickRoughness(nDotVg, f0, roughness);
  vec3 fssEss = kS * dfg.x + dfg.y;
  float ems = 1.0 - (dfg.x + dfg.y);
  vec3 fAvg = f0 + (1.0 - f0) / 21.0;
  vec3 fmsEms = ems * fssEss * fAvg / (1.0 - fAvg * ems);

  vec3 ibl = envColor(r) * fssEss * grazeDamp;
  ibl += envColor(ns) * albedo * (fmsEms + (1.0 - fssEss));
  // ⚠️ THE FUZZ HAS TO EXIST IN THE AMBIENT TOO, or the moss is soft only where
  // the lamp reaches it and flat everywhere else — which is worse than not
  // having the lobe at all, because the surface then changes character across
  // the shadow line. Small, and damped by the grazing term like the rest of the
  // indirect light.
  ibl += envColor(ns) * fuzzTint * s.fuzz * 0.045 * grazeDamp;

  // Occlusion darkens only what arrives from everywhere — never the lamp. A
  // crease is hidden from the surroundings, not from a light it can see.
  // ⚠️ EMISSION IS NOT OCCLUDED, and that is the whole difference between light
  // a surface RECEIVES and light it MAKES. Everything above is dimmed by how
  // much of the world this point can see; the energy leaving the channel does
  // not care, because it did not come from the world. Multiplying it by the
  // occlusion would darken the light exactly where the cut is deepest — which is
  // precisely where the most of it should be getting out.
  // ⚠️ THE CHANNEL IS DESCRIBED, NOT LIT, and that separation is what lets
  // something moving sit on a cached object. How far light travels through the
  // glass, how much of it gets in, and where the cut edges are: all fixed for a
  // given pose, all expensive, all cached. What is IN the glass moves, and is
  // applied per frame in the scene pass for the price of one noise field.
  //
  // Packed to survive an 8-bit texture: the path is normalised against the
  // longest one the geometry can produce, and the transmission is weighted by
  // coverage so a pixel half on the letter contributes half.
  //
  // ⚠️ THE SAME TEXTURE CARRIES A DIFFERENT MEANING PER MODEL, which is worth
  // being explicit about rather than clever: under `?carving=0` it is a colour
  // and is encoded like radiance, under `?carving=1` it is three geometric
  // quantities and is stored raw. The mode decides how to read it, and both
  // models get the same caching and the same live modulation as a result.
  emit = uCarving < 0.5
      ? encodeEnergy(s.emission)
      : vec3(clamp(s.glass.path / kCarvePathMax, 0.0, 1.0),
             s.glass.trans * s.glass.amount,
             s.glass.edge);
  return direct + ibl * s.occlusion;
}

vec3 shadeCubeRay(vec3 rd, float spin, float lod, out float hit, out vec3 emit) {
  vec3 n;
  vec2 t = cubeIntersect(kEye, rd, spin, n);
  if (t.x < 0.0) {
    hit = 0.0;
    emit = vec3(0.0);
    return vec3(0.0);
  }
  hit = 1.0;
  // Convex: a single light cannot make it shadow itself.
  return shadeCube(kEye + rd * t.x, n, -rd, 1.0, spin, lod, emit);
}

vec3 traceBackdrop(vec3 ro, vec3 rd, float spin, vec2 fragCoord,
                   vec2 uvScreen, float aspect, float rotation);

/// Follows light through the solid until it finds a way out, bouncing as many
/// times as it must.
///
/// ⚠️ IN A CUBE, LIGHT ENTERING ONE FACE CANNOT LEAVE THROUGH ANY FACE BUT THE
/// OPPOSITE ONE, AND THIS IS A THEOREM RATHER THAN A TENDENCY. Entering glass
/// bends a ray toward the normal by at most the critical angle — about 42
/// degrees at this density. Every other face of a cube is at 90 degrees to the
/// one it entered, so the ray meets those at 48 degrees or more, which is past
/// the escape limit. Every time. So a ray heading for the bottom or a side is
/// ALWAYS turned back.
///
/// ⚠️ WHICH MEANS THE EARLIER VERSION COULD NOT POSSIBLY HAVE WORKED. It
/// followed exactly one crossing and, when the ray could not get out, gave up
/// and substituted a dark environment lookup. But "cannot get out" is the
/// ordinary case in a cube, not the exception — so large parts of every face
/// went flat black, and a flat black region inside a transparent object reads as
/// a solid thing suspended in it. That is exactly what he described, and no
/// amount of tuning would have moved it, because everything worth seeing happens
/// after the bounce that was not being followed.
///
/// The platform below, the far edge cutting across, the space above it: all of
/// it arrives on the second or third pass, folded. That folding is not an
/// artefact to be tolerated — it is what makes a real glass block interesting to
/// look at, and why a paperweight is full of repeated images of the room.
///
/// ⚠️ AND LIGHT ESCAPES AT EVERY BOUNCE, NOT ONLY THE LAST. Where the ray CAN
/// get out, most of it does and a few percent carries on inside; where it
/// cannot, all of it carries on. So the answer accumulates: each escape
/// contributes what it found, weighted by how much of the beam was still
/// travelling by then. Taking only the final escape would throw away the
/// brightest term.
vec3 glassPath(vec3 pIn, vec3 rd, vec3 nIn, float ior, float spin,
               vec2 fragCoord, vec2 uvScreen, float aspect, float rotation) {
  // ⚠️ IT LEAVES ON ITS ORIGINAL HEADING, AND THAT IS THE WHOLE MODEL.
  //
  // Entering a body with parallel faces bends the light one way and leaving
  // bends it back by the same amount, so the two cancel and what survives is a
  // DISPLACEMENT — the scene behind arrives shifted rather than turned. That is
  // what a pane of glass does to the view through it, it is what the sheet in
  // this scene already does, and it is the reason the sheet is the calmest and
  // best-looking thing here.
  //
  // ⚠️ AND IT DELIBERATELY DOES NOT SIMULATE A SOLID. The honest version — bounce
  // the light until it finds the one face it is allowed out of — was built, and
  // it was CORRECT and unusable. In a cube every face but the opposite one turns
  // light back, so each face ends up carved into regions of folded views with
  // hard straight boundaries between them. Real glass paperweights look exactly
  // like that. This is not a paperweight; it is the mark for a website, and the
  // physics was making it worse while costing four scene traces per wavelength.
  //
  // The thickness is not thrown away with the bounces: the ray still crosses the
  // real chord, so it still displaces by the real amount and is still absorbed
  // over the real distance. What is dropped is only the folding.
  vec3 r1 = refract(rd, nIn, 1.0 / ior);
  if (dot(r1, r1) < 1e-6) r1 = rd;

  vec3 nx;
  vec2 t = cubeIntersect(pIn + r1 * 1e-4, r1, 0.0, nx);
  float seg = max(t.y, 0.0);
  vec3 pOut = pIn + r1 * seg;

  return exp(-kGlassAbsorb * seg) *
         traceBackdrop(pOut + rd * 1e-3, rd, spin, fragCoord, uvScreen, aspect,
                       rotation);
}

/// Everything EXCEPT the cube's own primary visibility: the background, and
/// the glass surface with its reflections, shadow and occlusion.
///
/// Split out so the cube can be antialiased separately. Supersampling this
/// would multiply the shadow and occlusion tracing by the sample count, which
/// is unaffordable; the cube's coverage can be sampled cheaply on its own
/// because it needs intersection only, not shading.
vec3 traceBackdrop(vec3 ro, vec3 rd, float spin, vec2 fragCoord,
                   vec2 uvScreen, float aspect, float rotation) {
  // THE FIELD IS THE SKY, and only the sky.
  //
  // It used to fill the whole frame, so the table sat on top of clouds. Now it
  // renders only where a ray passes ABOVE the table's far cut edge — the space
  // beyond where the surface ends. Everything nearer than that is flat ground
  // colour. The shader itself is untouched; only where it is allowed to appear
  // has changed.
  // How much of the sky this ray sees, as a SOFT amount rather than a yes/no.
  //
  // A hard boundary cuts straight through whatever star happens to sit on it,
  // leaving visible half-discs along the table's back edge. Fading over a
  // narrow band means a star near the edge dims out instead of being sliced.
  float skyAmount;
  if (rd.z > 1e-5) {
    // How far above the far edge does this ray pass?
    float tBack = (kBackZ - ro.z) / rd.z;
    skyAmount = smoothstep(-0.01, 0.16, ro.y + rd.y * tBack);
  } else {
    // Not travelling away from the camera: only upward rays escape.
    skyAmount = rd.y > 0.0 ? 1.0 : 0.0;
  }
  bool beyondEdge = skyAmount > 0.0;
  vec3 background = kBase;
  if (beyondEdge) {
    // Both knobs live; neither replaces the other.
    if (uSky > 0.0) {
      background = mix(background, fieldColor(uvScreen, aspect, fragCoord),
                       uSky);
    }
    if (uStars > 0.0 && !isOff(32.0)) {
      vec4 band = texture(uBandMap, uvScreen);
      vec3 sky = starsFromBand(rd, band.rgb, band.a * 2.6 + 1.0);
      background = mix(background, sky, uStars * skyAmount);
    }
  }

  // THE TABLE, sphere-traced as one solid with rounded edges. The old version
  // intersected three half-planes, which meet at hard 90-degree corners that
  // cannot be rounded after the fact.
  float tPlane = tableTrace(ro, rd);
  vec3 n = vec3(0.0, 1.0, 0.0);
  float isCutEdge = 0.0;
  if (tPlane > 0.0) {
    vec3 hitP = ro + rd * tPlane;
    n = tableNormal(hitP);
    // The cut edge is the far end of the sheet: the band of surface whose
    // normal has turned away from straight up, near the back of the ledge.
    isCutEdge = smoothstep(0.55, 0.9, 1.0 - abs(n.y)) *
                smoothstep(kBackZ - 0.22, kBackZ - 0.02, hitP.z);
  }

  bool hitPlane = tPlane > 0.0 && uSurface > 0.0;

  if (hitPlane) {
    vec3 p = ro + rd * tPlane;

    // How much surface exists here. Measured from the step's inner corner
    // rather than the origin, so the ledge and the drop fade together and
    // the composition never gains a horizon line.
    float alongLedge = length(vec2(p.x, p.z - kEdgeZ));
    float downDrop = -min(p.y, 0.0);
    float radial = alongLedge + downDrop * 0.8;
    float presence = exp(-radial * 0.55) * uSurface;
    if (presence < 0.004) return background;

    float cosI = clamp(dot(-rd, n), 0.0, 1.0);
    // Schlick for a dielectric: about 4% head-on, rising to 1 at grazing.
    float f0 = pow((1.0 - kIor) / (1.0 + kIor), 2.0);
    float fres = f0 + (1.0 - f0) * pow(1.0 - cosI, 5.0);

    // Reflection: a real reflected ray, shaded by the same cube code.
    vec3 reflected = vec3(0.0);
    if (!isOff(16.0)) {
    vec3 rr = reflect(rd, n);
    vec3 nr;
    vec2 tr = cubeIntersect(p + n * 1e-3, rr, spin, nr);
    if (tr.x > 0.0) {
      reflected = shadeCubeCoarse(p + n * 1e-3 + rr * tr.x, nr);
    } else {
      reflected = envColor(rr) * 0.25;
    }
    }

    // Transmission: the background REFRACTED through the surface, not just
    // shown through it. The deviation is projected back onto the screen and
    // used to resample the field.
    vec3 rt = refract(rd, n, 1.0 / kIor);
    vec2 deviation = (rt.xz - rd.xz) * 0.16;
    vec3 transmitted = isOff(8.0)
        ? background
        : fieldColor(uvScreen + deviation, aspect, fragCoord);

    // Second surface. A glass sheet has two interfaces, and the dimmer,
    // offset ghost off the back one is the specific tell of glass rather
    // than a mirror.
    vec3 rr2 = reflect(rd, n);
    vec3 nr2;
    vec3 p2 = p + rt * kGlassThickness;
    vec2 tr2 = cubeIntersect(p2 + n * 1e-3, rr2, spin, nr2);
    vec3 second = vec3(0.0);
    if (tr2.x > 0.0 && !isOff(16.0)) {
      second = shadeCubeCoarse(p2 + n * 1e-3 + rr2 * tr2.x, nr2) * 0.35;
    }

    // Traced, not tuned: how much of the light and of the sky this point can
    // actually see with the cube in the way.
    // ⚠️ READ, NOT TRACED. Fixed light, fixed occluder, fixed floor — so this
    // answer never changes, and it was being rediscovered by 28 rays per pixel
    // sixty times a second. Baked once over the surface (see uLayer 3) and
    // sampled here. Outside the map the answer is exactly 1, which is what the
    // analytic bounds concluded anyway.
    // ⚠️ CENTRED ON THE CUBE, NOT ON THE ORIGIN. The map only covers where the
    // answer is not 1, and what it covers is the shadow and the darkening —
    // both of which belong to the cube and travel with it. Left centred on the
    // origin, sliding the cube back would walk its shadow off the edge of the
    // map, where the answer is hard-coded to "fully lit", and the shadow would
    // simply stop in a straight line. Centring costs nothing and keeps every
    // texel where the detail is.
    vec2 lightUv =
        (surfaceCoord(p, n).xy - cubeOnSurface()) / (2.0 * kLightMapReach)
        + 0.5;
    // Red how much of the lamp reaches here, green how open the sky is, blue how
    // much of the CARVING can be seen from here. Outside the map the first two
    // are 1 and the third is 0 — fully lit, and far enough away that the cube's
    // own glow has fallen to nothing.
    vec3 lit = vec3(1.0, 1.0, 0.0);
    if (lightUv.x > 0.0 && lightUv.x < 1.0 &&
        lightUv.y > 0.0 && lightUv.y < 1.0) {
      lit = texture(uLightMap, lightUv).rgb;
    }
    // ⚠️ READ, NOT COMPUTED — see uLayer 5. The flow is cloud: smooth over the
    // whole surface, with no edge of its own anywhere in it. Every edge in this
    // part of the frame belongs to the glass it lies on, and that is still
    // resolved at full resolution here, so the softness has nothing to give it
    // away.
    vec3 energyHere = decodeEnergy(texture(uEnergyMap, uvScreen).rgb);

    float shadow = isOff(1.0) ? 1.0 : lit.r;
    float ao = isOff(2.0) ? 1.0 : lit.g;

    // ⚠️ THE CARVING'S LIGHT, LANDING ON THE GLASS. The shape of the pool is
    // baked; how hard the carving is running at this instant is applied here, so
    // the pool breathes with the letters rather than sitting still under them.
    //
    // Scaled by uEmit so the whole chain moves together on one knob: turn the
    // carving off and its reflection in the world goes with it, which is what
    // makes `?emit=0` an honest A/B rather than a half-disabled state.
    vec3 spill = isOff(1024.0)
        ? vec3(0.0)
        : kEnergyTint * lit.b * carvingOutput() * uEmit * 1.35;

    // ── THE GLASS MATERIAL — the real one, and now the DEFAULT ──────────────
    //
    // ⚠️ RESTORED VERBATIM FROM THE COMMENT IT SAT IN, deliberately unimproved.
    // The point of turning it on was to see WHAT IT WAS, so nothing here was
    // tidied, rebalanced or corrected on the way back in — and then it turned
    // out to need none of that. `?glass=0` selects the diagnostic below.
    //
    // ENERGY CONSERVING: reflect OR transmit, never both added. `fres` is ~4%
    // looking straight down at the sheet and rises to 1 at grazing, so most of
    // what you see through it is the transmitted background. The shadow darkens
    // what passes through; the occlusion darkens the ambient part. The energy
    // moves INSIDE the composite rather than being painted on top, because
    // light inside the sheet is transmitted.
    //
    // ⚠️ EXPECT IT TO BE NEARLY INVISIBLE. That is what clean glass on a dark
    // ground with a dark object does, and it is the whole reason the diagnostic
    // below exists — we could not tell whether the surface was subtle or simply
    // never being hit. What makes it readable is the cut edge, the energy, and
    // eventually some dirt.
    //
    // ⚠️ AND ONE KNOWN INCONSISTENCY, LEFT IN ON PURPOSE. `transmitted` samples
    // the background FIELD, which `uSky` currently switches off — so the glass
    // shows a cloudy sky that is not drawn anywhere above it. Physically it
    // should transmit what is actually behind: flat dark, and stars past the
    // far edge. Fixing that changes what you are judging, so it waits until
    // after the first look.
    if (uGlass > 0.5) {
      vec3 cut = vec3(0.80, 0.86, 1.0) * 2.4 + kAccent * 0.35;
      vec3 surface = mix(transmitted, reflected + second, fres);
      surface *= mix(0.18, 1.0, shadow) * mix(0.25, 1.0, ao);
      // ⚠️ THE SPILL IS OCCLUDED, UNLIKE THE EMISSION ITSELF. Light a surface
      // MAKES ignores what it can see; light it RECEIVES does not, and this is
      // received — so the glass right under the cube, which can barely see the
      // sky, can barely see the carving either.
      if (!isOff(4.0)) surface += spill * ao * (1.0 - fres);
      if (!isOff(4.0)) surface += energyHere * (1.0 - fres);
      surface = mix(surface, cut, isCutEdge);
      return mix(background, surface, presence);
    }

    // ── THE DIAGNOSTIC SURFACE — `?glass=0`, and no longer the default ──────
    //
    // An opaque light floor rather than glass. It exists to answer ONE question
    // unambiguously: is the plane being hit at all? Clean glass on a dark ground
    // reflecting a dark object is so nearly invisible that "subtle" and "never
    // intersected" look identical, and we lost time to that once. If a grey
    // floor with a shadow on it appears here, the geometry is fine.
    //
    // Kept for that reason and no other. It is not a fallback and not a style.
    vec3 diagnostic = vec3(0.52, 0.53, 0.58);
    diagnostic *= mix(0.06, 1.0, shadow);   // the cast shadow
    diagnostic *= mix(0.10, 1.0, ao);       // the contact occlusion
    diagnostic += reflected * fres * 0.6;   // still shows the reflection

    // The energy: across the ledge, over the front edge, down the panel.
    if (!isOff(4.0)) diagnostic += energyHere + spill * ao;

    // The cut edge glows: light travelling inside the sheet by total internal
    // reflection escapes where the glass is cut. Blended by how far the
    // normal has turned off vertical, so it follows the ROUNDED edge rather
    // than switching on at a hard boundary.
    vec3 glow = vec3(0.80, 0.86, 1.0) * 2.4 + kAccent * 0.35;
    diagnostic = mix(diagnostic, glow, isCutEdge);
    return mix(background, diagnostic, presence);

    // ⚠️ THE "PARKED GLASS" RECIPE THAT USED TO SIT HERE IS GONE, and it was
    // deleted rather than left: the glass it described is the live branch a few
    // lines above, so a block of commented-out source claiming to be the way
    // back to it was documentation that had become false. Everything it taught
    // now lives on the real code.
  }

  return background;
}

// ── Entry ───────────────────────────────────────────────────────────────────

void main() {
  vec2 fragCoord = FlutterFragCoord().xy;
  vec2 uvScreen = fragCoord / uSize;
  float aspect = uSize.x / uSize.y;

  // Camera. A real one: eye, target, and an image plane — so the ground plane
  // is genuinely horizontal and the three-quarter view comes from where the
  // camera stands rather than from rotating the world.
  vec3 fwd = normalize(kTarget - kEye);
  vec3 right = normalize(cross(vec3(0.0, 1.0, 0.0), fwd));
  vec3 up = cross(fwd, right);

  // y is negated because FlutterFragCoord runs downward.
  vec2 uv = vec2(
    (fragCoord.x - uCubeCenter.x) / uCubeUnit,
    -(fragCoord.y - uCubeCenter.y) / uCubeUnit
  );
  vec3 rd = normalize(fwd * kFocal + right * uv.x + up * uv.y);

  // FIXED pose. A continuous spin made it impossible to judge the lighting or
  // the edges, the same way the pointer-tracked light did. Motion comes back
  // deliberately, once the still frame is right.
  // Two faces equally visible.
  //
  // The camera sits at azimuth ~55 degrees from the cube's axes, so an
  // UNROTATED cube already presents both of its visible faces at the same
  // incidence. Spinning it 0.66 turned one face nearly head-on and the other
  // almost edge-on — the opposite of the intent.
  // ⚠️ A RESTING POSE, NOT A ROTATION. It was fixed at 0 because a moving cube
  // made the edges impossible to judge; the edges are settled now, so the pose
  // is worth choosing rather than inheriting.
  //
  // It changes the COMPOSITION, not just the object: the camera sits about 55
  // degrees off the cube's axes, so an unturned cube happens to present its two
  // visible faces at the same incidence. Turning it makes one face squarer to
  // the eye and the other more edge-on, which is a real design choice and the
  // reason this is worth a knob rather than a guess.
  //
  // Everything follows it already — the ray intersection, the shadow, the
  // occlusion, the antialiasing tests, and the material, which is sampled in
  // the cube's own frame so the masonry turns WITH the stone instead of sliding
  // across it. Where the moss grows and which way the water ran are measured
  // against the WORLD, which is correct for a pose: the cube has been sitting
  // like this, so up is up. That would need revisiting only if it ever moved.
  float spin = uSpin;
  float rotation = ign(fragCoord) * 6.28318530718;

  // ⚠️ THE BACKDROP IS TRACED AFTER THE CUBE'S COVERAGE, NOT BEFORE.
  //
  // It used to be traced here, along the ray through the pixel's centre, and
  // that is wrong for exactly the pixels the cube's edge passes through. The
  // cube's coverage is resolved with 64 samples; the backdrop behind it is
  // resolved with one. When a pixel straddles the silhouette and its centre
  // falls INSIDE the cube, that one ray sails past the cube and lands on the
  // table several units further back — which is lit, unoccluded and bright,
  // rather than the table at the cube's foot, which is dark and in contact
  // shadow. Blending that in at the edge drew a bright dashed line tracing the
  // cube's lower silhouette.
  //
  // So the coverage is computed first, and the backdrop is then traced along a
  // ray through the part of the pixel the cube does NOT cover. Same cost — one
  // backdrop trace either way — and no supersampling of the shadow and
  // occlusion tracing, which is what makes supersampling the table
  // unaffordable in the first place.

  // ── The cube ─────────────────────────────────────────────────────────────
  //
  // EXACTLY the path that was signed off before the merge. Every sample is
  // SHADED and the shaded results are averaged — not coverage-sampled with a
  // single shade at the pixel centre, which is what the merge changed and
  // what put the staircase back.
  //
  // Band test is the original too: distance from the ray's closest approach
  // for the silhouette, plus the second-smallest face distance for the
  // internal edges where two faces meet.
  vec3 nCube;
  vec2 tCube = cubeIntersect(kEye, rd, spin, nCube);

  vec3 toCentre = cubeOrigin() - kEye;
  float tc = max(dot(toCentre, rd), 0.0);
  vec3 localNear = spinInto() * (kEye + rd * tc - cubeOrigin());
  vec3 qn = abs(localNear) - cubeHalf();
  float nearSurface =
      length(max(qn, 0.0)) + min(max(qn.x, max(qn.y, qn.z)), 0.0);

  // One pixel in world units AT THE CUBE'S DEPTH, not at the image plane.
  float px = (tc / kFocal) / uCubeUnit;

  // ⚠️ THE SYMBOLS AS THEIR OWN LAYER, AT DEVICE RESOLUTION — `?letters=3`.
  //
  // The scene is rendered below the display's real resolution and scaled up,
  // which is right for everything soft in it and wrong for the one thing that
  // has to be pixel perfect. `?scale=2` proved the point and the price: true
  // device resolution for the whole frame costs four times the pixels and ran at
  // 19 fps. So the mark's symbols get what the STATEMENT already gets — their
  // own pass at full resolution, composited on top of a scene that stays cheap.
  //
  // ⚠️ AND IT IS THE STATEMENT'S MECHANISM, NOT A NEW ONE. Rasterise the shape
  // ONCE, let its coverage be the alpha, have a shader supply the colour per
  // pixel from the energy field, composite once. The reason it is built that way
  // is that two rasterisations of one layout share glyph positions but not
  // antialiasing coverage, and nothing reconciles them afterwards — you get a
  // white rim, or a dark rim, or a dark rim everywhere, with no setting in
  // between.
  //
  // So the letters are not tinted to resemble the energy. They are FILLED with
  // it: the same field, the same threshold, read through a glyph mask. Turn the
  // energy up and the letters follow, because there is only one of it.
  //
  // ⚠️ THE TRADE, ACCEPTED KNOWINGLY: composited letters are ON the glass rather
  // than IN it. Nothing reflects over them and the frost does not shade them.
  // That is why this is a third path rather than a replacement — `?letters=2`
  // keeps the etched-into-the-surface version, and both stay switchable.
  //
  // Placed here, before the 64-sample antialiasing, because this pass wants
  // neither the material nor the supersampling — only the geometry above it.
  if (uLayer > 8.5) {
    if (tCube.x <= 0.0) { fragColor = vec4(0.0); return; }
    vec3 nl = spinInto() * nCube;
    // Nothing on the top or bottom: a symbol belongs on the faces you read.
    if (abs(nl.y) > 0.5) { fragColor = vec4(0.0); return; }

    vec3 hit = kEye + rd * tCube.x;
    vec3 lp = spinInto() * (hit - cubeOrigin());
    vec2 uvc = carveFaceUv(lp, nl);
    float d = glyphDist(uvc, nl);

    // ⚠️ THE RAMP'S WIDTH IS MEASURED, NOT PREDICTED, and that is what fixes the
    // `D`. A single footprint is correct on a face you look straight at and
    // wrong on one you look ALONG: the pose deliberately sets the two visible
    // faces at different incidences, so the left one is squeezed horizontally
    // and a pixel there covers far more of the letter across than down. One
    // width for both directions is then too narrow on one axis and too wide on
    // the other — and `D`'s upright stem, the most vertical stroke on the most
    // oblique face, is the worst case in the whole mark.
    //
    // This asks how fast the distance is ACTUALLY changing from this pixel to
    // its neighbours, which answers foreshortening, cube size and viewing angle
    // together because it measures the thing itself instead of predicting it.
    // The material solved this same problem long ago — a pixel on a tilted face
    // is a smear, not a circle — and the glyph edge never got the same
    // treatment.
    float w = max(px / max(uCubeHalf, 1e-4), 1e-5);
    vec2 uvX;
    vec2 uvY;
    if (faceUvAt(fragCoord + vec2(1.0, 0.0), fwd, right, up, spin, nl, uvX) &&
        faceUvAt(fragCoord + vec2(0.0, 1.0), fwd, right, up, spin, nl, uvY)) {
      // ⚠️ LENGTH, NOT THE SUM OF THE TWO. `fwidth` is defined as the sum, and
      // that is deliberately conservative: it over-estimates by up to 40% on a
      // diagonal edge, which is 40% of extra blur bought for nothing. The true
      // rate of change across a pixel is the length of the gradient, and it is
      // the same two numbers.
      float dx = glyphDist(uvX, nl) - d;
      float dy = glyphDist(uvY, nl) - d;
      w = max(length(vec2(dx, dy)) * uEdge, 1e-6);
    }
    float mask = clamp(0.5 - d / w, 0.0, 1.0);
    if (mask <= 0.0) { fragColor = vec4(0.0); return; }

    // ⚠️ THE FROST IS DRAWN HERE TOO, NOT LEFT IN THE SCENE. It is the mark's
    // base — what the letters look like with no energy in them — and whichever
    // pass draws the base draws the OUTLINE. Left in the cached scene layer it
    // was setting the edge at the scene's resolution and the crisp fill was only
    // brightening the inside of a soft shape.
    vec3 l = normalize(kLightPos - hit);
    vec3 base = envColor(nCube) * 0.55 + vec3(max(dot(nCube, l), 0.0)) * 0.30;

    // Filled from the field, sampled a little way INSIDE the solid so the
    // letters read as lit by what is in the cube rather than by a film on it.
    // Switched off with the cube's own energy — the frost stays either way.
    vec3 fill = vec3(0.0);
    if (!isOff(128.0)) {
      float dens = smoothstep(kFogLow, kFogHigh,
                              carveFogField(hit - rd * (uCubeHalf * 0.6)));
      fill = kEnergyTint * dens * uEmit * kLetterFill;
    }
    vec3 lit = base + fill;
    // ⚠️ PREMULTIPLIED, AND ADDED RATHER THAN LAID OVER. Light travelling
    // through a mark can only ever ADD; it must never leave the glass behind it
    // darker than it was. Laid over opaquely — which is what this did — a letter
    // came out HEAVIER than its surroundings wherever the field happened to be
    // thin, because the fill was replacing bright glass with dim energy. The
    // statement gets away with opaque only because it sits on a near-black
    // panel; here the ground underneath is lit.
    //
    // Alpha still carries the coverage rather than being zeroed: a premultiplied
    // colour with no alpha is not a valid colour, and this project has already
    // been bitten by treating that channel as spare.
    fragColor = vec4(ACESToneMap(lit, kExposure) * mask, mask);
    return;
  }

  float edgeDist = 1e9;
  if (tCube.x > 0.0) {
    vec3 hp = abs(spinInto() * (kEye + rd * tCube.x - cubeOrigin()));
    vec3 d3 = cubeHalf() - hp;
    float lo = min(d3.x, min(d3.y, d3.z));
    float hi = max(d3.x, max(d3.y, d3.z));
    edgeDist = d3.x + d3.y + d3.z - lo - hi;
  }

  vec3 sum = vec3(0.0);
  // How much energy this pixel COULD emit — cached, and multiplied per frame by
  // the flow that is actually arriving. See uLayer 7.
  vec3 emitSum = vec3(0.0);
  // The entry normal, resolved over the pixel — see uCubeNormal.
  vec3 nSum = nCube;
  float cov = 0.0;
  // Where in the pixel the cube ISN'T — see the backdrop note above.
  vec2 openOffset = vec2(0.0);
  float openWeight = 0.0;
  // EXACT edge test, alongside the distance band.
  //
  // The band estimates a pixel's distance to the cube by measuring to its
  // CENTRE, which is least accurate at a GRAZING silhouette — a face nearly
  // edge-on to the camera. At 38 degrees of yaw the left face is exactly
  // that, which is why the left edge stepped while the others did not.
  //
  // So: also intersect the pixel's four corners. If any two disagree — one
  // hits and one misses, or they land on different faces — the pixel is on an
  // edge. Four box intersections, no estimation, nothing to be wrong about.
  bool corners = false;
  {
    float first = -2.0;
    vec3 firstN = vec3(0.0);
    for (int c = 0; c < 4; c++) {
      vec2 k = vec2(c == 0 || c == 3 ? -0.5 : 0.5, c < 2 ? -0.5 : 0.5);
      vec2 uvk = vec2(
        (fragCoord.x + k.x - uCubeCenter.x) / uCubeUnit,
        -(fragCoord.y + k.y - uCubeCenter.y) / uCubeUnit
      );
      vec3 rdk = normalize(fwd * kFocal + right * uvk.x + up * uvk.y);
      vec3 nk;
      vec2 tk = cubeIntersect(kEye, rdk, spin, nk);
      float h = tk.x > 0.0 ? 1.0 : 0.0;
      if (c == 0) {
        first = h;
        firstN = nk;
      } else if (h != first || dot(nk, firstN) < 0.99) {
        corners = true;
      }
    }
  }

  // ⚠️ THE WHOLE CUBE, READ RATHER THAN RESOLVED. Its shading, its coverage and
  // the offset its edge hands the backdrop are all fixed for a given pose, size
  // and camera — so the 64 ray tests an edge pixel used to cast are answered
  // once and looked up. This is the branch the scene takes every frame.
  // ⚠️ THE SCENE PASS ONLY. Written as a bare "above 1.5" it also caught the
  // coverage pass, which then read the very texture it existed to fill — and
  // the cube disappeared.
  if (uLayer > 1.5 && uLayer < 2.5) {
    sum = decodeLayer(texture(uCubeLayer, fragCoord / uSize).rgb);
    vec4 cvg = texture(uCubeCover, fragCoord / uSize);
    cov = cvg.r;
    openOffset = (cvg.gb - 0.5) * kOffsetRange;
    emitSum = decodeEnergy(texture(uCubeEmit, fragCoord / uSize).rgb);
    // ⚠️ NOT NORMALISED BACK TO UNIT LENGTH. At an edge this is the average of
    // two face normals and is SHORTER than one — and that shortness is the
    // signal, not an error: it says the pixel straddles a corner. Renormalising
    // would throw the blend away and put the hard switch back.
    nSum = texture(uCubeNormal, fragCoord / uSize).rgb * 2.0 - 1.0;
  } else if (!isOff(64.0) &&
      (corners || abs(nearSurface) < px * 6.0 || edgeDist < px * 6.0)) {
    // 8x8 rotated grid with a Gaussian reconstruction filter.
    //
    // ⚠️ THE SAMPLES RESOLVE COVERAGE. THE MATERIAL IS EVALUATED PER FACE.
    //
    // This used to shade all 64 samples and average the colours, which is the
    // textbook answer and was right while the cube was one flat colour. It
    // stops being right the moment the surface has a material on it, for two
    // separate reasons:
    //
    //   · COST. Every instruction in the material would be paid 64 times on
    //     every edge pixel. A material worth looking at cannot survive that,
    //     and the cube's edges are the one thing that must never be cheapened.
    //   · CORRECTNESS. 64 point samples of a detailed surface do not average to
    //     what that surface looks like — they average to a guess that changes
    //     as the camera moves, which is what makes procedural surfaces crawl.
    //     The material is band limited instead (see fbm3Band), so asking it
    //     once for the right footprint is not an approximation of the 64; it is
    //     better than the 64.
    //
    // A convex box shows at most THREE faces, so the samples are gathered into
    // three buckets by which face they landed on, and each bucket is shaded
    // once at the average position of its own samples. Every sample still tests
    // the geometry, so the silhouette and the internal edges are resolved
    // exactly as finely as before — 64 levels of coverage, unchanged.
    //
    // Three fixed buckets rather than an array: a fragment shader indexed with
    // a computed index is a portability minefield on the GLES backends this
    // compiles down to, and three is not worth the risk.
    const float kRadius = 0.72;
    const float kSigma = 0.42;
    float weightSum = 0.0;
    float hitWeight = 0.0;
    vec3 nA = vec3(0.0), nB = vec3(0.0), nC = vec3(0.0);
    vec3 pA = vec3(0.0), pB = vec3(0.0), pC = vec3(0.0);
    float wA = 0.0, wB = 0.0, wC = 0.0;
    for (int y = 0; y < 8; y++) {
      for (int x = 0; x < 8; x++) {
        // Sheared on BOTH axes. Shearing only x left every sample in a row
        // sharing the same y, so a near-horizontal edge — the top of the cube
        // — crossed all eight of them at once and coverage could only take 8
        // values instead of 64. Vertical edges were fine, horizontal ones
        // stepped. Now every sample has a distinct x and a distinct y.
        vec2 offset = vec2(
          (float(x) + 0.5 + float(y) * (1.0 / 8.0)) / 8.0 - 0.5,
          (float(y) + 0.5 + float(x) * (1.0 / 8.0)) / 8.0 - 0.5
        ) * (kRadius * 2.0);
        float w = exp(-dot(offset, offset) / (2.0 * kSigma * kSigma));
        vec2 uvS = vec2(
          (fragCoord.x + offset.x - uCubeCenter.x) / uCubeUnit,
          -(fragCoord.y + offset.y - uCubeCenter.y) / uCubeUnit
        );
        vec3 rdS = normalize(fwd * kFocal + right * uvS.x + up * uvS.y);
        vec3 nk;
        vec2 tk = cubeIntersect(kEye, rdS, spin, nk);
        weightSum += w;
        if (tk.x > 0.0) {
          hitWeight += w;
          vec3 ph = kEye + rdS * tk.x;
          // Which face. A box's face normals are far apart, so any sane
          // threshold separates them; 0.99 also keeps the rounding at an edge
          // from splitting one face into two buckets.
          if (wA == 0.0 || dot(nk, nA) > 0.99) {
            nA = nk; pA += ph * w; wA += w;
          } else if (wB == 0.0 || dot(nk, nB) > 0.99) {
            nB = nk; pB += ph * w; wB += w;
          } else {
            nC = nk; pC += ph * w; wC += w;
          }
        } else {
          // Where inside the pixel the cube is NOT. Averaging the offsets of
          // the samples that missed gives the centre of the visible sliver,
          // which is the only place the backdrop should be sampled from.
          openOffset += offset * w;
          openWeight += w;
        }
      }
    }

    // One material evaluation per face, at the average position of the samples
    // that landed on it, weighted back by how much of the pixel each face owns.
    //
    // ⚠️ THE EMISSION IS RESOLVED HERE TOO, at the same 64 samples and by the
    // same weights. It is the sharpest thing on this object — a bright letter
    // against dark stone — so resolving it any more coarsely than the shading
    // would put a staircase on the one feature everybody looks at.
    vec3 acc = vec3(0.0);
    vec3 accEmit = vec3(0.0);
    vec3 eA, eB, eC;
    if (wA > 0.0) {
      acc += shadeCube(pA / wA, nA, -rd, 1.0, spin, px, eA) * wA;
      accEmit += eA * wA;
    }
    if (wB > 0.0) {
      acc += shadeCube(pB / wB, nB, -rd, 1.0, spin, px, eB) * wB;
      accEmit += eB * wB;
    }
    if (wC > 0.0) {
      acc += shadeCube(pC / wC, nC, -rd, 1.0, spin, px, eC) * wC;
      accEmit += eC * wC;
    }
    sum = acc / max(hitWeight, 1e-5);
    emitSum = accEmit / max(hitWeight, 1e-5);
    // ⚠️ WEIGHTED BY COVERAGE, NOT BY HITS. Divided by the hit weight this would
    // come back unit-length everywhere and say nothing about how much of the
    // pixel the cube actually owns; divided by the total it shrinks toward zero
    // at the silhouette, which is exactly the fade the live terms need so the
    // rim stops dead at the outline instead of guessing past it.
    nSum = (nA * wA + nB * wB + nC * wC) / max(weightSum, 1e-5);
    cov = hitWeight / max(weightSum, 1e-5);
    // No uncovered sliver at all means the backdrop is completely hidden, so
    // its value cannot matter; leave the ray at the centre.
    if (openWeight > 1e-5) openOffset /= openWeight;
    else openOffset = vec2(0.0);
  } else {
    float hit;
    sum = shadeCubeRay(rd, spin, px, hit, emitSum);
    cov = hit;
  }

  // ⚠️ THE LAYER PASS STOPS HERE. Nothing behind the cube has been traced yet,
  // so this costs only what the cube costs — which is the point.
  if (uLayer > 0.5 && uLayer < 1.5) {
    fragColor = vec4(encodeLayer(sum), 1.0);
    return;
  }
  // ⚠️ A RANGE, NOT A THRESHOLD. This was written as a bare "above 5.5" while
  // there was only one layer up here, and adding a second silently gave the
  // emission pass the coverage pass's output. A selector wants a range the
  // moment there is more than one thing above the line.
  if (uLayer > 5.5 && uLayer < 6.5) {
    fragColor = vec4(cov, openOffset / kOffsetRange + 0.5, 1.0);
    return;
  }
  // The emission pass: how much energy each pixel COULD put out, before the flow
  // decides how much actually is. Square-rooted like the other stored radiance,
  // because it spends most of its range near zero and all of its interest at the
  // bottom.
  if (uLayer > 6.5 && uLayer < 7.5) {
    fragColor = vec4(encodeEnergy(emitSum), 1.0);
    return;
  }
  // The resolved entry normal. Signed, so it is shifted into 0..1 to survive an
  // ordinary image — and read back WITHOUT renormalising, on purpose.
  if (uLayer > 7.5) {
    fragColor = vec4(nSum * 0.5 + 0.5, 1.0);
    return;
  }

  // The backdrop, traced along the ray through the uncovered part of the pixel.
  // For every pixel the cube's edge does not pass through this is exactly the
  // centre ray, so nothing else in the frame changes.
  vec3 backdropRd = rd;
  if (openOffset != vec2(0.0)) {
    vec2 uvB = vec2(
      (fragCoord.x + openOffset.x - uCubeCenter.x) / uCubeUnit,
      -(fragCoord.y + openOffset.y - uCubeCenter.y) / uCubeUnit
    );
    backdropRd = normalize(fwd * kFocal + right * uvB.x + up * uvB.y);
  }
  // The energy pass, on the same fraction of the pixels as the band.
  if (uLayer > 4.5) {
    float t = tableTrace(kEye, rd);
    vec3 e = vec3(0.0);
    if (t > 0.0) {
      vec3 ep = kEye + rd * t;
      e = surfaceEnergy(ep, tableNormal(ep));
    }
    fragColor = vec4(encodeEnergy(e), 1.0);
    return;
  }

  // The band pass. Smooth everywhere, so it runs on a fraction of the pixels.
  if (uLayer > 3.5) {
    fragColor = bandOnly(rd);
    return;
  }

  // ⚠️ THE LIGHT MAP PASS. Every texel is a place on the table's surface rather
  // than a place on the screen, which is the whole point: the table stretches
  // away from the camera, so a screen-shaped cache would be dense where it is
  // near and starved where it is far. In surface space the resolution is even,
  // and the map is independent of the camera and the viewport entirely.
  if (uLayer > 2.5) {
    // The inverse of the lookup above — same centre, or the bake and the read
    // would disagree about where a point is and the shadow would sit beside the
    // object casting it.
    vec2 surf =
        (uvScreen - 0.5) * (2.0 * kLightMapReach) + cubeOnSurface();
    vec3 lp;
    vec3 ln;
    surfacePoint(surf, lp, ln);
    // ⚠️ THE THIRD CHANNEL WAS SITTING EMPTY, and the spill belongs in it for
    // exactly the reasons the other two are here: it depends only on the cube
    // and the floor, never on the camera or the clock. Its SHAPE is baked; how
    // brightly the carving is running at this instant is applied live. Same
    // split as the emission on the cube itself.
    fragColor = vec4(lightVisibility(lp, ln, spin, rotation),
                     occlusion(lp, ln, spin, rotation),
                     carvingIrradiance(lp, ln), 1.0);
    return;
  }

  vec3 col = traceBackdrop(
    kEye, backdropRd, spin, fragCoord, uvScreen, aspect, rotation
  );

  if (cov > 0.0) {
    // ⚠️ THE ONE PART OF THE CUBE THAT IS COMPUTED EVERY FRAME, and it is three
    // octaves of noise on a few thousand pixels rather than the thousand hash
    // lookups the material costs. The surface point comes free: `tCube` was
    // already resolved above for the coverage test, whichever branch ran.
    //
    // Everything static stays cached; only how much energy is arriving right
    // now is live. That is the whole trade — the letters breathe with the same
    // field that moves across the glass, and the frame rate does not notice.
    // ⚠️ THE FOG INSIDE THE LETTERS, AND THE ONLY PART OF THIS CUBE COMPUTED
    // EVERY FRAME. Three octaves of noise on a few thousand pixels, against the
    // thousand hash lookups the material costs — which is why the cube can carry
    // something moving and still be drawn once and kept.
    //
    // ⚠️ AND IT IS THE SHEET'S OWN CHAIN, END TO END: the same field, the same
    // threshold, the same colour constant. Not a colour matched by eye — the
    // same substance, read in a different place. That is the answer to why the
    // first attempt could never be tuned into this one.
    vec3 emitted = vec3(0.0);
    // ⚠️ GATED ON COVERAGE, NOT ON THE CENTRE RAY HITTING. That single change is
    // the edge fix. A pixel the cube half covers has a real, resolved answer
    // waiting in the cache, and asking one ray through its centre whether the
    // cube is "there" throws that away and replaces it with a coin toss — which
    // is why the lit edges broke into dashes exactly where they matter most.
    if (uMaterial > 1.5 && cov > 0.0) {
      // ── The inside of the glass cube, and what is behind it ──────────────
      //
      // ⚠️ EVERYTHING HERE MOVES, WHICH IS WHY IT IS HERE. The cube's picture is
      // drawn once and kept, and that stays true — but a transparent solid
      // cannot cache what is INSIDE it or BEHIND it, because the fog churns and
      // the sheet's own energy churns under it. So the cached pass holds what is
      // fixed (what it reflects, where its edges are, how far light travels
      // through it) and this holds what is not.
      float chord = emitSum.r * cubeChordMax();
      // How much gets IN: one minus Fresnel, and then whatever the frosting
      // takes on top of that.
      float trans = emitSum.g;

      // ⚠️ FRESNEL COMES FROM THE GEOMETRY, NOT FROM `trans`, and deriving it
      // from `trans` was a real bug: the frosted letters reduce transmission, so
      // reading reflectance back out of it made every letter reflect as if it
      // were edge-on. They came out as mirrors. Reflection is a property of the
      // ANGLE; frosting is a property of the SURFACE; one cannot be recovered
      // from the other once they have been multiplied together.
      // ⚠️ THE RESOLVED NORMAL, AND ITS LENGTH IS DOING WORK. At an edge it is
      // the average of two faces and therefore shorter than one — so its
      // direction blends the two, and its length says how much of the pixel the
      // cube owns. Both are needed: direction to stop the reflection stepping,
      // length to stop the rim reaching past the outline.
      float own = clamp(length(nSum), 0.0, 1.0);
      vec3 nAvg = own > 1e-3 ? nSum / own : nCube;

      float nDotV = max(dot(nAvg, -rd), 1e-4);
      // Reflectance from real glass; bending from `uIor`. See shadeGlassCube.
      float f0 = pow((1.0 - kIor) / (1.0 + kIor), 2.0);
      float fres = f0 + (1.0 - f0) * pow(1.0 - nDotV, 5.0);

      // ⚠️ WHERE THE LIGHT ENTERS, SOLVED FROM THE RESOLVED NORMAL RATHER THAN
      // FROM THE CENTRE RAY'S HIT. On a box the face carrying that normal is a
      // known plane, so this is one division and it is CONTINUOUS across the
      // silhouette — where the centre ray's own answer does not exist at all.
      vec3 nl = spinInto() * nAvg;
      vec3 roL = spinInto() * (kEye - cubeOrigin());
      vec3 rdL = spinInto() * rd;
      float denom = dot(rdL, nl);
      float tEnter = abs(denom) > 1e-4
          ? (uCubeHalf - dot(roL, nl)) / denom
          : max(tCube.x, 0.0);
      vec3 pIn = kEye + rd * max(tEnter, 0.0);
      vec3 r1 = refract(rd, nAvg, 1.0 / uIor);

      // ⚠️ THE FOG IS INTEGRATED ALONG THE CHORD, not sampled at the surface,
      // and that is the difference between a solid full of something and a
      // solid with something painted on it. A ray crossing a corner passes
      // through almost no medium; one crossing the middle passes through the
      // whole body, and comes out carrying that much more. Nothing chooses that
      // falloff — it is the shape.
      vec3 inner = vec3(0.0);
      if (!isOff(128.0) && chord > 1e-4) {
        // ⚠️ FRONT TO BACK, WITH ABSORPTION APPLIED AS IT GOES — not a mean of
        // the samples, which is what this was and is why the interior read as
        // flat haze. Averaging a turbulent field is a low-pass filter: it throws
        // away exactly the structure that makes the sheet's energy look like
        // cloud, and hands back its mean, which is fog with nothing in it.
        //
        // Integrating properly keeps it, and gives the one cue a mean cannot:
        // near fog hides far fog. What is at the front of the solid arrives
        // whole, what is deep inside arrives dimmed by everything in front of
        // it — so the interior gains depth ORDER rather than being a uniform
        // slab, and the whole body starts reading as a volume you are looking
        // into rather than a colour you are looking at.
        const int kSteps = 10;
        float dt = chord / float(kSteps);
        vec3 acc = vec3(0.0);
        for (int i = 0; i < kSteps; i++) {
          float s = dt * (float(i) + 0.5);
          vec3 sp = pIn + r1 * s;
          float d = smoothstep(kFogLow, kFogHigh, carveFogField(sp));
          acc += d * exp(-kGlassAbsorb * s) * dt;
        }
        vec3 ambient = acc * kInnerGain;

        // ⚠️ THE LETTERS ARE THE SAME FOG, DENSER — not a second substance added
        // into the first. Their brightness is the field's own value at the plate,
        // so they cannot drift in colour or character from the energy around
        // them however either is tuned later, and they churn because it is the
        // churning field being read.
        vec3 lIn = spinInto() * (pIn - cubeOrigin());
        float plate = letterChord(lIn, spinInto() * r1, chord);
        float lit = plate > 1e-5
            ? smoothstep(kFogLow, kFogHigh,
                         carveFogField(pIn + r1 * (chord * 0.5)))
            : 0.0;

        inner = kEnergyTint * (ambient + plate * lit * kLetterGain) * uEmit;
      }

      // ── The platform's own energy, climbing into the solid ────────────────
      //
      // ⚠️ THE SAME FIELD, READ IN A SECOND PLACE. The cube asks what the energy
      // is doing on the sheet DIRECTLY BENEATH this point and carries it upward.
      // Not a third effect matched to the other two — one field, so the two
      // cannot drift apart however either is tuned later.
      //
      // ⚠️ AND IT COSTS ONE PROJECTION AND ONE LOOKUP. The sheet's energy is
      // already rendered once a frame at a sixteenth of the pixels, and that
      // pass traces the TABLE without the cube in the way — so the texture
      // already holds valid energy for the ground the cube is standing on,
      // which is exactly the part you cannot see and exactly the part this
      // needs. Against roughly 480 hashed noise evaluations per pixel for the
      // volumetric interior, this is free.
      vec3 wall = vec3(0.0);
      if (uWall > 1e-4 && !isOff(2048.0)) {
        // Sampled at the middle of the body, so it reads as light IN the glass
        // rather than a film on the face nearest the camera.
        vec3 mid = pIn + rd * (chord * 0.5);
        // Straight down onto the sheet: the footprint this point stands over.
        vec3 foot = vec3(mid.x, 0.0, mid.z);
        vec3 rel = foot - kEye;
        float z = dot(rel, fwd);
        if (z > 1e-3) {
          vec2 sp = vec2(dot(rel, right), dot(rel, up)) * kFocal / z;
          vec2 su = (uCubeCenter + vec2(sp.x, -sp.y) * uCubeUnit) / uSize;
          if (su.x > 0.0 && su.x < 1.0 && su.y > 0.0 && su.y < 1.0) {
            float climb = exp(-max(mid.y, 0.0) / (uCubeHalf * kWallRise));
            wall = decodeEnergy(texture(uEnergyMap, su).rgb) * climb *
                   uWall * kWallGain;
          }
        }
      }

      // ⚠️ WHAT IS SEEN THROUGH IT IS DISPLACED, NOT FOLDED. The scene behind
      // arrives shifted by how far the light was carried sideways crossing the
      // body — real thickness, honestly measured — but leaving on its original
      // heading, so it stays one continuous view rather than being broken into
      // regions. That is the sheet's model, and it is the reason the sheet is
      // the calmest thing in this scene.
      //
      // ⚠️ AND DISPERSION IS ONLY A DIFFERENT DISPLACEMENT PER CHANNEL now, which
      // is both cheaper and better behaved: three slightly different shifts of
      // the same continuous view, rather than three chances to fall on opposite
      // sides of a hard boundary. Traced three times only where the channels have
      // actually separated — a test about whether the answers DIFFER, which is
      // the only honest reason to skip work.
      vec3 through = vec3(0.0);
      if (!isOff(8.0)) {
        float iR = uIor - kDispersion;
        float iB = uIor + kDispersion;
        vec3 rR = refract(rd, nAvg, 1.0 / iR);
        vec3 rB = refract(rd, nAvg, 1.0 / iB);
        if (1.0 - min(dot(rR, rB), 1.0) > 3e-5) {
          through = vec3(
            glassPath(pIn, rd, nAvg, iR, spin, fragCoord, uvScreen, aspect,
                      rotation).r,
            glassPath(pIn, rd, nAvg, uIor, spin, fragCoord, uvScreen, aspect,
                      rotation).g,
            glassPath(pIn, rd, nAvg, iB, spin, fragCoord, uvScreen, aspect,
                      rotation).b
          );
        } else {
          through = glassPath(pIn, rd, nAvg, uIor, spin, fragCoord, uvScreen,
                              aspect, rotation);
        }
      }

      // ⚠️ WHAT IT REFLECTS IS NOW A REAL RAY INTO THE SCENE, and this is the
      // largest single difference from the sheet's glass, which has always
      // traced its reflections properly. The cube was reflecting an ENVIRONMENT
      // APPROXIMATION — a smooth function of direction that knows the sky is
      // brighter above than below and nothing else. It cannot show the sheet, so
      // an object standing on a glowing surface had no sign of it in its own
      // faces, which is the sort of absence the eye reads as wrong without being
      // able to name.
      //
      // ⚠️ AND IT IS TRACED EVERYWHERE, because gating it was a shortcut and it
      // SHOWED. I skipped the trace where Fresnel was under six percent, on the
      // grounds that the approximation is indistinguishable when it is that dim.
      // It is not: dim and DIFFERENT is still different, and the switch drew a
      // hard vertical band across every face at the angle where it flipped —
      // which is the artefact he pointed at.
      //
      // The lesson generalises past this line. A cheap path may only replace an
      // expensive one where the two AGREE, never merely where the result is
      // faint. The dispersion test above is gated correctly by that standard: it
      // asks whether the three channels have separated at all, which is a
      // question about whether the answers differ.
      vec3 rr = reflect(rd, nAvg);
      vec3 reflected = isOff(16.0)
          ? envColor(rr)
          : traceBackdrop(pIn + rr * 1e-3, rr, spin, fragCoord, uvScreen,
                          aspect, rotation);

      // ⚠️ NO ABSORPTION APPLIED HERE, AND THAT IS A FIX RATHER THAN AN OMISSION.
      // It used to be multiplied in twice: once inside each integration, and
      // again on the result — left over from when both were simple averages over
      // the chord. The interior fog came out at roughly a third of its intended
      // strength, which is why switching it off changed nothing visible and why
      // the body read as empty. Absorption now happens once, where the distance
      // is actually known: per leg inside glassPath, and per step inside the fog
      // integration.
      //
      // ⚠️ EACH TERM WITH ITS OWN WEIGHT, NOT MIXED BY FRESNEL. A mix() puts the
      // frosting's attenuation on the wrong side of the balance: what the frost
      // takes out of the transmitted half does not reappear in the reflected
      // half — it scatters. `trans` already carries one-minus-Fresnel AND the
      // frosting, so it weights transmission by itself; reflection takes
      // Fresnel. Their sum cannot exceed one, which is what keeps this energy
      // conserving.
      float rim = isOff(256.0) ? 0.0 : emitSum.b * kEdgeGain;
      emitted = through * trans +
                reflected * fres +
                inner +
                wall +
                kEnergyTint * rim * uEmit;
    } else if (tCube.x > 0.0 && uCarving < 0.5) {
      // The earlier model: a cached emissive colour, breathing with the field.
      vec3 e = decodeEnergy(emitSum);
      float f = carveFogField(kEye + rd * tCube.x);
      emitted = e * mix(0.34, 1.0, smoothstep(0.30, 0.66, f));
    } else if (tCube.x > 0.0 && emitSum.r + emitSum.b > 1e-4) {
      float path = emitSum.r * kCarvePathMax;
      vec3 hit = kEye + rd * tCube.x;
      // Sampled at the middle of the glass rather than at its surface: what is
      // seen is the whole column, and its midpoint is the honest single sample
      // of it. Free, and it makes a deep channel read as deeper.
      float dens = smoothstep(kFogLow, kFogHigh,
                              carveFogField(hit - rd * (path * 0.5)));
      // Fog seen through the glass, plus the rim where the glass is cut against
      // stone — the same reason the sheet's far edge is the brightest thing on
      // it. The rim reaches slightly onto the stone, which is what stops the
      // light ending in a hard line.
      float fog = isOff(128.0) ? 0.0 : path * kFogGain * emitSum.g;
      float rim = isOff(256.0) ? 0.0 : emitSum.b * kEdgeGain;
      emitted = kEnergyTint * dens * uEmit * (fog + rim);
    }
    col = mix(col, sum + emitted, cov);
  }

  // The flying energy sits in FRONT of everything solid here — the slab hangs
  // between the camera and the panel — so it composites last, over the cube
  // as well as the surface.
  if (uClouds > 0.0) {
    vec4 clouds = flyingEnergy(kEye, rd, 1e4);
    col = col * (1.0 - clouds.a * uClouds) + clouds.rgb * uClouds;
  }

  // ⚠️ THE TONE CURVE RUNS ONCE, HERE, AND NOWHERE ELSE.
  //
  // Everything above is RAW BRIGHTNESS and may exceed 1: the cut edge is 2.4,
  // the energy peaks near 2, a star is 3. Squashing that into a displayable
  // range is one operation on the finished picture.
  //
  // It used to happen at five separate points — the cube, its reflection, the
  // second-surface ghost, the cut edge — while the background, the stars and
  // the energy skipped it entirely. That is not a stylistic difference, it is
  // arithmetic: squashing two things and then blending them does not give the
  // same answer as blending and then squashing, because the curve is not a
  // straight line. The error is invisible while everything is dark and roughly
  // matched, and it grows exactly as the scene gains bright and dark parts in
  // the same frame — which is what putting a material on the cube will do.
  //
  // Consequences worth knowing, all of them intended:
  //   · coverage is now averaged in raw brightness before the curve, which is
  //     the correct order for antialiasing an edge
  //   · the energy was deliberately over-bright and its peaks now roll off
  //     instead of clipping flat
  //   · the curve has a TOE, so the very darkest values get slightly darker
  //     while mid-tones get brighter — see kBase, which is pre-compensated
  //
  // ⚠️ It does NOT change the cube. A pixel fully covered by the cube is
  // ACESToneMap(sum) either way; only pixels that mix the cube with something
  // else differ, and there the old order was the wrong one.
  fragColor = vec4(ACESToneMap(col, kExposure), 1.0);
}
