// THE LETTERS AS AMPLIFIERS.
//
// Energy arrives at a word faint, having travelled from the cube, across the
// ledge and down the panel. The letterform does not merely show it — it
// concentrates it. A weak wash landing on a word flares into bright, coloured
// light and spills into the air around it, then dies back as the flow moves on.
//
// WHAT THIS PROGRAM IS AND IS NOT
//
// It does not draw the type. Flutter draws the statement exactly as it always
// has — same widget, same colour, crisp, from the glyph atlas — and this runs
// on a layer ABOVE it that can only ADD light. That matters for two reasons:
// the crisp glyphs underneath still define every edge, and it avoids the one
// Flutter API that would have broken the site on a phone.
//
// ⚠️ WHY NOT A SHADER ON THE TEXT'S OWN PAINT, which is the obvious approach:
// the two web renderers disagree. skwasm (the --wasm build, desktop) passes
// the whole Paint through, so a shader fill works. CanvasKit (the JavaScript
// fallback, which is what EVERY browser on iOS gets) keeps only the paint's
// COLOUR and silently drops the shader — canvaskit/text.dart:563. A Paint
// carrying only a shader has a default colour of opaque black, so the
// statement would have rendered black-on-black on an iPhone while looking
// perfect on a Mac. Samplers and blend modes, which this uses instead, are
// implemented on both.
//
// ⚠️ COORDINATES ARE DEVICE PIXELS. On the web FlutterFragCoord() is
// gl_FragCoord.xy — the pixel position in the current render target, not
// widget-local and not logical pixels. Everything here is therefore derived
// from the buffer's own size, exactly as the scene shader does, so the ray
// this builds is the same ray the scene builds for the same point.
//
// ⚠️ THE ENERGY BELOW IS DUPLICATED FROM scene.frag AND MUST STAY IDENTICAL.
// Flutter compiles one file per program with no way to share source. If one
// copy is edited the other has to be edited with it, or the light on a letter
// will drift out of step with the light on the glass behind it — which is the
// one seam this effect cannot survive.

#version 460 core
#include <flutter/runtime_effect.glsl>

precision highp float;

uniform vec2 uSize;     // this pass's buffer, in pixels
uniform float uTime;
uniform float uCamera;  // position in locations; 1.0 == one section

// How hard a letter amplifies what lands on it, and how sharply. The exponent
// is what makes it a FLARE rather than a fade: below the knee almost nothing
// happens, above it the letter takes off.
uniform float uGain;
uniform float uKnee;

// Glyph coverage in the red channel, baked once per layout in the hero
// panel's own coordinates. See type_glow.dart.
uniform sampler2D uMask;

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

// ── The flare ───────────────────────────────────────────────────────────────

// The colour a letter takes when the energy is on it. Unmistakably red.
const vec3 kHitColour = vec3(1.0, 0.13, 0.10);

void main() {
  vec2 frag = FlutterFragCoord().xy;

  // The mask is baked in the panel's own coordinates and the panel travels
  // with the world, so the lookup shifts by one viewport width per location.
  vec2 maskUV = vec2(frag.x / uSize.x + uCamera, frag.y / uSize.y);
  float glyph = texture(uMask, maskUV).r;
  if (glyph < 0.004) {
    fragColor = vec4(0.0);
    return;
  }

  // THE SAME CAMERA THE SCENE USES, resolved against this buffer. Both
  // cubeCentre and unit scale with the buffer, so the ray through a given
  // point on screen is identical whatever resolution either pass runs at.
  vec2 cubeCentre = vec2(uSize.x * (kCubeX - uCamera), uSize.y * kCubeY);
  float unit = min(uSize.x, uSize.y) * kCubeSize;

  vec3 fwd = normalize(kTarget - kEye);
  vec3 right = normalize(cross(vec3(0.0, 1.0, 0.0), fwd));
  vec3 up = cross(fwd, right);

  vec2 uv = vec2((frag.x - cubeCentre.x) / unit,
                 -(frag.y - cubeCentre.y) / unit);
  vec3 rd = normalize(fwd * kFocal + right * uv.x + up * uv.y);

  // The panel's front face — the glass the statement stands against.
  if (rd.z <= 1e-5) {
    fragColor = vec4(0.0);
    return;
  }
  float t = (kEdgeZ - kSlab - kEye.z) / rd.z;
  if (t <= 0.0) {
    fragColor = vec4(0.0);
    return;
  }

  vec3 energy = surfaceEnergy(kEye + rd * t, vec3(0.0, 0.0, -1.0));
  float landed = dot(energy, vec3(0.2126, 0.7152, 0.0722));

  // How much of the letter the energy has taken over. Straight and linear —
  // no amplification curve, no knee. More energy, more red.
  float a = clamp((landed - uKnee) * uGain, 0.0, 1.0);
  if (a < 0.004) {
    fragColor = vec4(0.0);
    return;
  }

  // ⚠️ THIS REPLACES THE LETTER'S COLOUR, IT DOES NOT ADD TO IT, and that is
  // why the painter composites it with source-over rather than plus.
  //
  // The statement is white. Adding red to white does nothing — white is
  // already at the top of every channel, so an additive layer is invisible on
  // it no matter how strong. The only way a white letter can turn red is for
  // something to be painted OVER it. The crisp glyphs underneath still supply
  // the shape, because this is confined to the glyph coverage.
  float alpha = clamp(a * glyph, 0.0, 1.0);
  fragColor = vec4(kHitColour * alpha, alpha);
}
