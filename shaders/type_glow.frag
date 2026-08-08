// THE STATEMENT'S COLOUR, as a function of the energy that reaches it.
//
// This program produces COLOUR ONLY. It knows nothing about where the letters
// are — it fills its whole rectangle — and the glyph shape is applied
// afterwards by compositing the result against a single rasterisation of the
// type. That division is the point, and it is what finally made the edges
// exact.
//
// ⚠️ WHY NOT SAMPLE A GLYPH MASK IN HERE, which is what this used to do.
//
// The statement was being rasterised TWICE: once by the engine as white text
// on screen, and once by us into a mask. Two rasterisations of the same layout
// have the same glyph positions but need not have identical antialiasing
// coverage, and every attempt to reconcile them after the fact traded one
// artefact for another. Under-cover and the outermost pixel of each letter
// never gets coloured, leaving a white rim. Over-cover and the colour lands on
// the panel outside the letter — which is not black but dark BLUE, so
// multiplying it by red strips the blue and leaves a dark rim instead.
//
// There is no setting between those. The fix is not a better mask, it is one
// rasterisation: the type is rasterised once, its alpha IS the glyph coverage,
// and this shader supplies what colour that coverage should be filled with.
// No second edge exists to disagree with the first.
//
// ⚠️ COORDINATES. FlutterFragCoord() is gl_FragCoord.xy on the web — device
// pixels of the current render target — so the buffer's own pixel ratio has to
// be divided out to get back to the layout's coordinates. Everything else here
// is in the panel's logical pixels, which is what the scene's camera maths
// expects.
//
// ⚠️ THE ENERGY BELOW IS DUPLICATED FROM scene.frag AND MUST STAY IDENTICAL.
// Flutter compiles one file per program with no way to share source. Edit one
// copy and the other has to be edited with it, or the light on a letter drifts
// out of step with the light on the glass behind it.

#version 460 core
#include <flutter/runtime_effect.glsl>

precision highp float;

uniform vec2 uSize;        // this pass's buffer, in device pixels
uniform vec2 uOrigin;      // the buffer's top-left, in the panel's coordinates
uniform vec2 uViewport;    // the whole viewport, which the camera ray needs
// Buffer pixels per LOGICAL pixel — deliberately not the device pixel ratio.
// This pass computes a smooth gradient with no detail in it, so it runs on a
// buffer far smaller than the block; every edge in the result comes from the
// glyph rasterisation, which is at full device resolution. Rendering this at
// the device ratio instead cost an iPhone 11 everything it had.
uniform float uPixelRatio;

uniform float uTime;
uniform float uCamera;  // position in locations; 1.0 == one section

uniform float uGain;  // how quickly a letter turns as energy lands on it
uniform float uKnee;  // how much has to land before anything happens

// 0 = the letter's colour, opaque; the glyph coverage is applied by the
// painter. 1 = the bloom source, whose alpha is how hard this point is driven,
// so only the energetic parts of a word spill light into the air.
uniform float uMode;

out vec4 fragColor;

// ── Scene constants. MUST MATCH scene.frag ──────────────────────────────────

const vec3 kEye = vec3(2.15, 1.95, -3.05);
const vec3 kTarget = vec3(0.0, 0.42, 0.0);
const float kFocal = 2.7;
const float kEdgeZ = -0.95;
const float kSlab = 0.075;
const vec3 kAccent = vec3(1.0, 0.353, 0.212);

// Where the cube lands in the frame. MUST MATCH world_scene.dart.
const float kCubeX = 0.5;
const float kCubeY = 0.34;
const float kCubeSize = 0.26;

// The statement's ink.
// ⚠️ MUST MATCH Palette.ink, or the letters change colour the moment this
// shader takes over drawing them.
const vec3 kInkColour = vec3(0.929, 0.929, 0.941);

// How much white is kept in a fully-lit letter.
//
// ZERO: the letters take the fog's colour as it is. The control stays because
// the energy's neat hue is a deep cool blue and this is the one sentence on
// the page that has to be readable — if a fully-saturated letter turns out to
// be too dark to read, this is the dial that buys legibility back without
// inventing a colour.
const float kKeepWhite = 0.0;

// ── The energy. DUPLICATED FROM scene.frag — keep identical ─────────────────

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

float energyLayer(vec2 surf, vec2 dir, float advect) {
  vec2 q = surf * 0.85 - dir * advect;
  vec2 w = vec2(fbm(q + vec2(0.0, advect * 0.25)), fbm(q + vec2(4.7, 2.1)));
  return fbm(q + 2.6 * w);
}

vec3 surfaceEnergy(vec3 p, vec3 n) {
  vec2 onLedge = p.xz;
  vec2 onDrop = vec2(p.x, kEdgeZ - max(-p.y, 0.0));

  float wTop = clamp(n.y, 0.0, 1.0);
  float wDrop = clamp(-n.z, 0.0, 1.0);
  float total = max(wTop + wDrop, 1e-4);
  vec2 surf = (onLedge * wTop + onDrop * wDrop) / total;

  float travelled = length(surf);
  vec2 dir = travelled > 1e-4 ? surf / travelled : vec2(1.0, 0.0);

  const float kCycleDistance = 1.15;
  const float kCyclePeriod = 5.0;

  float phase = uTime / kCyclePeriod;
  float pa = fract(phase);
  float pb = fract(phase + 0.5);

  float a = energyLayer(surf, dir, pa * kCycleDistance);
  float b = energyLayer(surf, dir, pb * kCycleDistance);

  float blend = abs(1.0 - 2.0 * pa);
  float f = mix(a, b, blend);

  float emit = exp(-travelled * 0.18) * (total > 0.05 ? 1.0 : 0.0);
  vec3 tint = vec3(0.30, 0.58, 1.00) * 1.15 + kAccent * 0.12;
  return tint * smoothstep(0.28, 0.88, f) * emit * 1.7;
}

// ── The tone curve. DUPLICATED FROM scene.frag — keep identical ─────────────
//
// ⚠️ IT IS HERE FOR ONE REASON: SO THE LETTERS AND THE GLASS ARE THE SAME
// COLOUR.
//
// The letters take the energy's own hue, which is what makes them read as one
// substance with the light behind them rather than as two things that happen to
// match. But the scene draws that energy through a tone curve, and a tone curve
// is not a straight line — it desaturates as it approaches white. The energy's
// brightest parts land near (0.79, 1.21, 2.00) in raw brightness, a deep blue,
// and arrive on screen at roughly (0.79, 0.85, 0.91), which is nearly white.
//
// So a hue taken from the RAW energy is not the hue on the glass. Take it from
// the tone mapped energy and the two agree by construction, at every brightness,
// without either file carrying a colour the other has to be matched to.
//
// The same duplication note applies as to the energy above: Flutter compiles one
// file per program with no way to share source, so this is a copy, and it and
// scene.frag's copy have to be edited together.
const float kExposure = 1.25;

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

// ── Entry ───────────────────────────────────────────────────────────────────

void main() {
  // Device pixels back to the panel's own coordinates.
  vec2 panel = uOrigin + FlutterFragCoord().xy / uPixelRatio;

  // THE SAME CAMERA THE SCENE USES. The panel travels with the world, so a
  // point's position on SCREEN is its panel position shifted by one viewport
  // width per location — and the ray is built from the screen position.
  vec2 screen = vec2(panel.x - uCamera * uViewport.x, panel.y);

  vec2 cubeCentre =
      vec2(uViewport.x * (kCubeX - uCamera), uViewport.y * kCubeY);
  float unit = min(uViewport.x, uViewport.y) * kCubeSize;

  vec3 fwd = normalize(kTarget - kEye);
  vec3 right = normalize(cross(vec3(0.0, 1.0, 0.0), fwd));
  vec3 up = cross(fwd, right);

  vec2 uv = vec2((screen.x - cubeCentre.x) / unit,
                 -(screen.y - cubeCentre.y) / unit);
  vec3 rd = normalize(fwd * kFocal + right * uv.x + up * uv.y);

  // The panel's front face — the glass the statement stands against.
  vec3 energy = vec3(0.0);
  if (rd.z > 1e-5) {
    float t = (kEdgeZ - kSlab - kEye.z) / rd.z;
    if (t > 0.0) {
      energy = surfaceEnergy(kEye + rd * t, vec3(0.0, 0.0, -1.0));
    }
  }
  // ⚠️ MEASURED ON THE RAW ENERGY, DELIBERATELY — unlike the hue below.
  //
  // This is not a colour, it is "how much energy has reached this point", and
  // uKnee and uGain are calibrated against that quantity. The tone curve
  // compresses the top of the range, so measuring after it would quietly change
  // where a letter starts turning. Two different questions, two different
  // spaces: physics drives the transition, display decides the colour.
  float landed = dot(energy, vec3(0.2126, 0.7152, 0.0722));

  // How far the energy has driven this part of the letter. Straight and
  // linear — no amplification curve.
  float a = clamp((landed - uKnee) * uGain, 0.0, 1.0);

  // ⚠️ THE COLOUR IS THE ENERGY'S OWN, TAKEN AT RUNTIME — not a constant
  // chosen to look like it. Dividing out the brightness leaves the hue, so
  // whatever the energy on the glass is doing, the letters are doing the same
  // thing. Retint the fog and the type follows without touching this file,
  // which is the whole reason the effect reads as one substance rather than as
  // two things that happen to match.
  //
  // ⚠️ TAKEN THROUGH THE SAME TONE CURVE THE SCENE DRAWS THE ENERGY WITH, so
  // this is the hue actually on the glass rather than the hue before the curve
  // desaturated it. See the note on ACESToneMap above.
  vec3 shown = ACESToneMap(energy, kExposure);
  float peak = max(shown.r, max(shown.g, shown.b));
  vec3 hue = peak > 1e-4 ? shown / peak : vec3(1.0);

  if (uMode < 0.5) {
    // THE LETTER'S COLOUR. Opaque: the glyph coverage is applied afterwards by
    // compositing against the rasterised type, which is the only edge in the
    // whole effect.
    vec3 lit = mix(hue, vec3(1.0), kKeepWhite);
    fragColor = vec4(mix(kInkColour, lit, a), 1.0);
  } else {
    // THE BLOOM SOURCE. Only the driven parts spill light, so a word at rest
    // throws nothing into the air. Premultiplied.
    fragColor = vec4(hue * a, a);
  }
}
