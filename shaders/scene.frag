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

out vec4 fragColor;

// ── World ───────────────────────────────────────────────────────────────────

const float kHalfSize = 0.55;
const vec3 kHalf = vec3(kHalfSize);
// The cube's centre is one half-height up, so its BASE rests on y = 0.
const vec3 kCubeOrigin = vec3(0.0, kHalfSize, 0.0);

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
const float kTableHalfX = 7.0;   // wide enough to leave the frame
const float kSlab = 0.075;       // sheet thickness
const float kDropDepth = 6.0;    // how far the panel descends
const float kRound = 0.028;
const float kFillet = 0.09;

const float kIor = 1.5;             // glass
const float kGlassThickness = 0.05;

const float kMinRoughness = 0.045;
const vec3 kBase = vec3(0.043, 0.043, 0.059);
const vec3 kAccent = vec3(1.0, 0.353, 0.212);

mat3 rotY(float a) {
  float c = cos(a);
  float s = sin(a);
  return mat3(c, 0.0, -s, 0.0, 1.0, 0.0, s, 0.0, c);
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
vec3 surfaceEnergy(vec3 p, vec3 n) {
  // Unroll the step into one flat sheet. On the ledge that is just (x, z);
  // past the front edge, falling by |y| keeps walking in the same direction,
  // so the two agree exactly at the lip and the flow pours over.
  vec2 onLedge = p.xz;
  vec2 onDrop = vec2(p.x, kEdgeZ - max(-p.y, 0.0));

  float wTop = clamp(n.y, 0.0, 1.0);
  float wDrop = clamp(-n.z, 0.0, 1.0);
  float total = max(wTop + wDrop, 1e-4);
  vec2 surf = (onLedge * wTop + onDrop * wDrop) / total;

  float travelled = length(surf);
  vec2 dir = travelled > 1e-4 ? surf / travelled : vec2(1.0, 0.0);

  // How far a copy travels before it is retired, and how long that takes.
  const float kCycleDistance = 1.15;
  const float kCyclePeriod = 5.0;

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
  vec3 tint = vec3(0.30, 0.58, 1.00) * 1.15 + kAccent * 0.12;

  // A LOWER threshold turns more of the noise range into visible energy, so
  // the clouds are broader rather than only their brightest peaks showing.
  // Raising brightness alone would just blow out the peaks and leave the rest
  // dark, which reads as harsher, not brighter.
  return tint * smoothstep(0.28, 0.88, f) * emit * 1.7;
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
  vec3 k = abs(m) * kHalf;
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
  mat3 toLocal = rotY(-spin);
  vec3 nl;
  vec2 t = boxIntersectLocal(toLocal * (ro - kCubeOrigin), toLocal * rd, nl);
  normal = rotY(spin) * nl;
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
float lightVisibility(vec3 p, vec3 n, float spin, float rotation) {
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

// ── Shading ─────────────────────────────────────────────────────────────────

/// Intersects and shades the cube along one camera ray. Returns its colour
/// and writes 1.0 to [hit]. This is the unit the supersampler works in: every
/// sample is SHADED, not just tested for coverage.
vec3 shadeCubeRay(vec3 rd, float spin, out float hit);

vec3 shadeCube(vec3 p, vec3 n, vec3 v, float visibility) {
  const vec3 albedo = vec3(0.016, 0.016, 0.021);
  const float roughness = max(0.20, kMinRoughness);
  const vec3 f0 = vec3(0.10, 0.10, 0.115);

  vec3 l = normalize(kLightPos - p);
  vec3 h = normalize(l + v);
  float nDotL = max(dot(n, l), 0.0);
  float nDotV = max(dot(n, v), 1e-4);

  float d = DistributionGGX(n, h, roughness);
  float vis = VisibilitySmith(nDotV, nDotL, roughness);
  vec3 fresnel = FresnelSchlick(max(dot(h, v), 0.0), f0);
  vec3 direct = (d * vis) * fresnel;
  direct += albedo * (1.0 / 3.14159265) * (1.0 - fresnel);
  direct *= nDotL * 3.4 * visibility;

  vec3 r = reflect(-v, n);
  vec3 fEnv = FresnelSchlickRoughness(nDotV, f0, roughness);
  float grazeDamp = mix(0.28, 1.0, smoothstep(0.0, 0.5, nDotV));
  vec3 ibl = envColor(r) * fEnv * grazeDamp;
  ibl += envColor(n) * albedo;

  return direct + ibl;
}

vec3 shadeCubeRay(vec3 rd, float spin, out float hit) {
  vec3 n;
  vec2 t = cubeIntersect(kEye, rd, spin, n);
  if (t.x < 0.0) {
    hit = 0.0;
    return vec3(0.0);
  }
  hit = 1.0;
  // Convex: a single light cannot make it shadow itself.
  return shadeCube(kEye + rd * t.x, n, -rd, 1.0);
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
  bool beyondEdge;
  if (rd.z > 1e-5) {
    // Does this ray clear the far edge on its way out?
    float tBack = (kBackZ - ro.z) / rd.z;
    beyondEdge = (ro.y + rd.y * tBack) > 0.0;
  } else {
    // Not travelling away from the camera: only upward rays escape.
    beyondEdge = rd.y > 0.0;
  }
  vec3 background = (beyondEdge && uSky > 0.0)
      ? mix(kBase, fieldColor(uvScreen, aspect, fragCoord), uSky)
      : kBase;

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
    vec3 rr = reflect(rd, n);
    vec3 nr;
    vec2 tr = cubeIntersect(p + n * 1e-3, rr, spin, nr);
    if (tr.x > 0.0) {
      vec3 pr = p + n * 1e-3 + rr * tr.x;
      float visr = lightVisibility(pr, nr, spin, rotation);
      reflected = ACESToneMap(shadeCube(pr, nr, -rr, visr), 1.25);
    } else {
      reflected = ACESToneMap(envColor(rr) * 0.25, 1.25);
    }

    // Transmission: the background REFRACTED through the surface, not just
    // shown through it. The deviation is projected back onto the screen and
    // used to resample the field.
    vec3 rt = refract(rd, n, 1.0 / kIor);
    vec2 deviation = (rt.xz - rd.xz) * 0.16;
    vec3 transmitted = fieldColor(uvScreen + deviation, aspect, fragCoord);

    // Second surface. A glass sheet has two interfaces, and the dimmer,
    // offset ghost off the back one is the specific tell of glass rather
    // than a mirror.
    vec3 rr2 = reflect(rd, n);
    vec3 nr2;
    vec3 p2 = p + rt * kGlassThickness;
    vec2 tr2 = cubeIntersect(p2 + n * 1e-3, rr2, spin, nr2);
    vec3 second = vec3(0.0);
    if (tr2.x > 0.0) {
      vec3 pr2 = p2 + n * 1e-3 + rr2 * tr2.x;
      second = ACESToneMap(shadeCube(pr2, nr2, -rr2, 1.0), 1.25) * 0.35;
    }

    // Traced, not tuned: how much of the light and of the sky this point can
    // actually see with the cube in the way.
    float shadow = lightVisibility(p, n, spin, rotation);
    float ao = occlusion(p, n, spin, rotation);

    // ⚠️ DIAGNOSTIC MATERIAL — an opaque light floor, not glass.
    //
    // The glass version was invisible and we could not tell whether that was
    // because glass is nearly invisible by nature or because the plane was
    // never being hit. This makes the answer unambiguous: if a grey floor
    // with a shadow on it appears, the scene is correct and the glass was
    // merely too subtle. Revert to the glass branch below once confirmed.
    // The cut edge glows: light that has been travelling inside the sheet by
    // total internal reflection escapes where the glass is cut. On a real
    // glass table this is by far the brightest part of it.

    vec3 diagnostic = vec3(0.52, 0.53, 0.58);
    diagnostic *= mix(0.06, 1.0, shadow);   // the cast shadow
    diagnostic *= mix(0.10, 1.0, ao);       // the contact occlusion
    diagnostic += reflected * fres * 0.6;   // still shows the reflection

    // The energy: across the ledge, over the front edge, down the panel.
    diagnostic += surfaceEnergy(p, n);

    // The cut edge glows: light travelling inside the sheet by total internal
    // reflection escapes where the glass is cut. Blended by how far the
    // normal has turned off vertical, so it follows the ROUNDED edge rather
    // than switching on at a hard boundary.
    vec3 glow = vec3(0.80, 0.86, 1.0) * 2.4 + kAccent * 0.35;
    diagnostic = mix(diagnostic, ACESToneMap(glow, 1.25), isCutEdge);
    return mix(background, diagnostic, presence);

    // ── THE GLASS MATERIAL — parked, not deleted ─────────────────────────────
    //
    // Swap the block above for this to go back to actual glass. Every value it
    // needs is already computed above; this is the line that assembles them,
    // and it is the one that got lost when the diagnostic replaced it.
    //
    // ENERGY CONSERVING: reflect OR transmit, never both added. `fres` is
    // ~4% looking straight down at the sheet and rises to 1 at grazing, so
    // most of what you see through it is the transmitted background.
    //
    //   vec3 surface = mix(transmitted, reflected + second, fres);
    //
    // The shadow darkens what passes through; the occlusion darkens the
    // ambient part.
    //
    //   surface *= mix(0.18, 1.0, shadow) * mix(0.25, 1.0, ao);
    //
    // ⚠️ The energy must move INSIDE this composite rather than being added
    // on top as it is above — light inside the sheet is transmitted, so it
    // belongs with the transmitted term, not painted over the surface:
    //
    //   surface += surfaceEnergy(p, n) * (1.0 - fres);
    //
    // Then the cut edge and the presence fade as above:
    //
    //   surface = mix(surface, ACESToneMap(glow, 1.25), isCutEdge);
    //   return mix(background, surface, presence);
    //
    // Expect it to be nearly INVISIBLE on its own — that is what clean glass
    // on a dark ground does, and it is why the diagnostic exists. What makes
    // it readable is the cut edge, the energy, and eventually some dirt.
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
  float spin = 0.0;
  float rotation = ign(fragCoord) * 6.28318530718;

  vec3 col = traceBackdrop(
    kEye, rd, spin, fragCoord, uvScreen, aspect, rotation
  );

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

  vec3 toCentre = kCubeOrigin - kEye;
  float tc = max(dot(toCentre, rd), 0.0);
  vec3 localNear = rotY(-spin) * (kEye + rd * tc - kCubeOrigin);
  vec3 qn = abs(localNear) - kHalf;
  float nearSurface =
      length(max(qn, 0.0)) + min(max(qn.x, max(qn.y, qn.z)), 0.0);

  // One pixel in world units AT THE CUBE'S DEPTH, not at the image plane.
  float px = (tc / kFocal) / uCubeUnit;

  float edgeDist = 1e9;
  if (tCube.x > 0.0) {
    vec3 hp = abs(rotY(-spin) * (kEye + rd * tCube.x - kCubeOrigin));
    vec3 d3 = kHalf - hp;
    float lo = min(d3.x, min(d3.y, d3.z));
    float hi = max(d3.x, max(d3.y, d3.z));
    edgeDist = d3.x + d3.y + d3.z - lo - hi;
  }

  vec3 sum = vec3(0.0);
  float cov = 0.0;
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

  if (corners || abs(nearSurface) < px * 6.0 || edgeDist < px * 6.0) {
    // 8x8 rotated grid with a Gaussian reconstruction filter.
    const float kRadius = 0.72;
    const float kSigma = 0.42;
    float weightSum = 0.0;
    float hitWeight = 0.0;
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
        float hit;
        vec3 c = shadeCubeRay(rdS, spin, hit);
        sum += c * hit * w;
        hitWeight += hit * w;
        weightSum += w;
      }
    }
    sum /= max(hitWeight, 1e-5);
    cov = hitWeight / max(weightSum, 1e-5);
  } else {
    float hit;
    sum = shadeCubeRay(rd, spin, hit);
    cov = hit;
  }

  if (cov > 0.0) {
    col = mix(col, ACESToneMap(sum, 1.25), cov);
  }

  fragColor = vec4(col, 1.0);
}
