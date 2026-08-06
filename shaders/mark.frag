// The mark — a lit cube.
//
// DiSE → dice → cube. Also a voxel: a pixel with volume, which is where the
// statement ends. No pips: a plain solid reads as an object, and pips would
// make the gambling reading louder than the private joke.
//
// EDGES ARE THE WHOLE PROBLEM with a shape like this. The first version
// raymarched an SDF and took a binary hit/miss per pixel, which staircases
// every silhouette. This one intersects the box ANALYTICALLY — exact, and
// cheaper than 80 march steps — and supersamples, so the edges resolve
// smoothly.
//
// No mesh, no 3D engine, no asset: the whole thing is arithmetic.

#version 460 core
#include <flutter/runtime_effect.glsl>

precision highp float;

uniform vec2 uSize;
uniform float uTime;
uniform vec2 uPointer;  // 0..1 across the widget, y up
uniform float uHover;   // eased 0..1, so the light does not snap on entry

// Where the cube sits, in pixels, and how many pixels one world unit is.
// These let the shader paint across the WHOLE hero while the cube occupies
// only part of it — a tight box clipped the halo into a hard rectangle.
uniform vec2 uCenter;
uniform float uUnit;

out vec4 fragColor;

const vec3 kHalf = vec3(0.55);
const vec3 kRayOrigin = vec3(0.0, 0.0, -5.0);
const float kFocal = 2.6;

mat3 rotY(float a) {
  float c = cos(a);
  float s = sin(a);
  return mat3(c, 0.0, -s, 0.0, 1.0, 0.0, s, 0.0, c);
}

mat3 rotX(float a) {
  float c = cos(a);
  float s = sin(a);
  return mat3(1.0, 0.0, 0.0, 0.0, c, -s, 0.0, s, c);
}

float sdBox(vec3 p) {
  vec3 q = abs(p) - kHalf;
  return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}

// ── Shading, following flutter_scene's PBR pipeline ─────────────────────────
//
// The patterns below are lifted from `flutter_scene/shaders/pbr.glsl` and
// `tone_mapping.glsl` rather than invented. The first version of this shader
// used Blinn-Phong with no Fresnel and no tone mapping, which is why it read
// as a flat grey box: highlights clipped, and grazing angles stayed dead.

const float kMinRoughness = 0.045;

vec3 FresnelSchlick(float cosTheta, vec3 f0) {
  return f0 + (1.0 - f0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

vec3 FresnelSchlickRoughness(float cosTheta, vec3 f0, float roughness) {
  return f0 + (max(vec3(1.0 - roughness), f0) - f0) *
                  pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

// GGX / Trowbridge-Reitz, in the fp16-safe formulation Filament uses.
float DistributionGGX(vec3 n, vec3 h, float roughness) {
  float nDotH = dot(n, h);
  if (nDotH <= 0.0) return 0.0;
  float alpha = roughness * roughness;
  vec3 nCrossH = cross(n, h);
  float a = nDotH * alpha;
  float k = alpha / (dot(nCrossH, nCrossH) + a * a);
  return k * k * (1.0 / 3.14159265);
}

// Height-correlated Smith-GGX visibility, sqrt-free approximation.
float VisibilitySmith(float nDotV, float nDotL, float roughness) {
  float alpha = roughness * roughness;
  float ggx = mix(2.0 * nDotL * nDotV, nDotL + nDotV, alpha);
  return 0.5 / max(ggx, 1e-5);
}

/// The environment the cube sits in, sampled by direction.
///
/// There is no cube map here — it is an analytic gradient: cooler above,
/// near-black below, with a bright key lobe where the light is. Reflecting
/// THIS is what makes a black object look like a manufactured surface rather
/// than a silhouette, and it costs nothing.
vec3 envColor(vec3 d, vec3 lightDir) {
  float up = clamp(d.y * 0.5 + 0.5, 0.0, 1.0);
  // Wide range top to bottom. A near-black object shows its faces ONLY
  // because each one reflects a different part of the environment — with a
  // flat environment every face resolves to the same black and the cube
  // disappears into the background, ring or no ring.
  // Wide range top to bottom. A near-black object shows its faces ONLY
  // because each one reflects a different part of the environment — with a
  // flat environment every face resolves to the same black and the cube
  // disappears into the background, ring or no ring.
  vec3 ground = vec3(0.020, 0.020, 0.026);
  vec3 horizon = vec3(0.42, 0.42, 0.50);
  vec3 sky = vec3(1.45, 1.50, 1.75);
  vec3 c = mix(ground, horizon, smoothstep(0.0, 0.55, up));
  c = mix(c, sky, smoothstep(0.5, 1.0, up));

  // A horizontal gradient as well as a vertical one. Without it the two
  // visible side faces sample nearly the same horizon value and read as one
  // flat shape with a line down the middle.
  float side = d.x * 0.5 + 0.5;
  c *= mix(0.45, 1.55, smoothstep(0.0, 1.0, side));
  // The key light as a soft area source, so reflections carry a highlight
  // with an edge rather than a mathematical point.
  float lobe = pow(clamp(dot(d, lightDir), 0.0, 1.0), 40.0);
  c += vec3(1.0, 0.98, 0.95) * lobe * 9.0;
  return c;
}

// ACES filmic (Stephen Hill fit), as used in flutter_scene's resolve pass.
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

/// Exact ray/box intersection by the slab method, returning entry and exit
/// distances plus the surface normal at entry. Sharp, correct, and constant
/// cost — no iteration, no epsilon, nothing to tune.
vec2 boxIntersect(vec3 ro, vec3 rd, out vec3 normal) {
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

/// Rounds the normal near the cube's edges without changing its silhouette.
///
/// A mathematically exact cube has an instant normal discontinuity where two
/// faces meet, which no amount of supersampling softens — it is a shading
/// edge, not a geometric one. Every manufactured object has a small bevel
/// there that catches a highlight; this reproduces that, cheaply, by blending
/// the face normals within [radius] of an edge.
vec3 bevelNormal(vec3 p, vec3 flat_n, float radius) {
  vec3 d = max(kHalf - abs(p), 0.0);  // distance to each face plane
  // Cubed falloff, not squared: the blend has to collapse fast. A wide,
  // gentle blend turns every edge into a lit wireframe and every corner into
  // a blown-out spot, because the diagonal normal reflects the bright part of
  // the environment straight back at the viewer.
  vec3 w = clamp(1.0 - d / radius, 0.0, 1.0);
  w = w * w * w;
  vec3 n = sign(p) * w;
  float len = length(n);
  return len > 1e-4 ? n / len : flat_n;
}

/// Shades one ray. Returns rgb, and writes 1.0 to [hit] when the ray landed.
vec3 shadeRay(vec2 uv, mat3 rot, vec3 lightO, out float hit) {
  vec3 rd = normalize(vec3(uv, kFocal));
  vec3 roO = rot * kRayOrigin;
  vec3 rdO = rot * rd;

  vec3 n;
  vec2 t = boxIntersect(roO, rdO, n);
  if (t.x < 0.0) {
    hit = 0.0;
    return vec3(0.0);
  }
  hit = 1.0;

  vec3 p = roO + rdO * t.x;
  // NO BEVEL. Rounding the normal near an edge points it diagonally outward,
  // straight at the bright part of the environment, so every edge lit up as a
  // line. The geometric edge is already antialiased by the supersampling —
  // it did not need help.
  // (bevelNormal is kept above; reintroduce with a radius if the edges ever
  // read as too mathematical.)
  vec3 l = normalize(lightO - p);
  vec3 v = normalize(-rdO);
  vec3 h = normalize(l + v);

  // A very dark dielectric with a polished surface: almost no albedo, so
  // everything you see is reflection. That is what a black object actually
  // is, and why the first version — which had diffuse doing the work —
  // looked like grey paint.
  const vec3 albedo = vec3(0.016, 0.016, 0.021);
  const float roughness = max(0.20, kMinRoughness);
  // Higher than a pure dielectric's 0.04 — the mark is a lacquered/anodised
  // surface rather than plastic, and the extra reflectance is what keeps the
  // faces distinguishable at this darkness.
  const vec3 f0 = vec3(0.10, 0.10, 0.115);

  float nDotL = max(dot(n, l), 0.0);
  float nDotV = max(dot(n, v), 1e-4);

  // Direct: GGX specular + Lambert diffuse.
  float d = DistributionGGX(n, h, roughness);
  float vis = VisibilitySmith(nDotV, nDotL, roughness);
  vec3 fresnel = FresnelSchlick(max(dot(h, v), 0.0), f0);
  vec3 direct = (d * vis) * fresnel;
  direct += albedo * (1.0 / 3.14159265) * (1.0 - fresnel);
  direct *= nDotL * 3.4;  // key light intensity, linear HDR

  // Image-based: the environment reflected off the surface, and its
  // irradiance on the diffuse. The reflection term is what gives a black
  // object its edges without a fake rim light.
  vec3 r = reflect(-v, n);
  vec3 fEnv = FresnelSchlickRoughness(nDotV, f0, roughness);
  // ONLY change from the version whose texture worked: the grazing reflection
  // is rolled back. Fresnel physically reaches 1.0 at the silhouette, which
  // on a lone object against a dark ground draws a bright outline around
  // everything. Correct for a render, wrong for a mark.
  float grazeDamp = mix(0.28, 1.0, smoothstep(0.0, 0.5, nDotV));
  vec3 ibl = envColor(r, l) * fEnv * grazeDamp;
  ibl += envColor(n, l) * albedo;

  return direct + ibl;
}

void main() {
  vec2 frag = FlutterFragCoord().xy;

  float wob = uTime * 0.10;
  // Positive pitch: the top face is the visible horizontal one. Negative put
  // the camera underneath and showed the cube's base, which floats.
  mat3 rot = rotY(0.66 + sin(wob) * 0.06) * rotX(0.36 + cos(wob * 0.8) * 0.03);

  // FIXED key light, up and to the left. Pointer tracking is removed for now
  // — it was changing the lighting while we were trying to judge the
  // lighting. The uniforms stay wired so it can come back as one line.
  vec2 pointer = vec2(0.30, 0.78);
  vec3 lightO = rot * vec3(
    (pointer.x - 0.5) * 5.0,
    (pointer.y - 0.5) * 4.0,
    -3.0
  );

  // ── Adaptive supersampling ────────────────────────────────────────────────
  // Distance from the ray's closest approach to the box, used to decide
  // whether this pixel is anywhere near an edge. Interiors and empty space
  // take one sample; only the silhouette pays for nine.
  vec2 uvC = (frag - uCenter) / uUnit;
  vec3 rdC = normalize(vec3(uvC, kFocal));
  vec3 roO = rot * kRayOrigin;
  vec3 rdO = rot * rdC;
  float tc = max(dot(-roO, rdO), 0.0);
  float nearSurface = sdBox(roO + rdO * tc);

  // ONE PIXEL IN WORLD UNITS AT THE CUBE'S DEPTH — not at the image plane.
  // Rays diverge, so a pixel is `distance / focal` times wider out where the
  // box actually is. Using the image-plane size made the antialiased band far
  // too narrow, so most silhouette pixels took the single-sample path and
  // stepped. This was the staircase.
  float px = (tc / kFocal) / uUnit;

  // TWO kinds of edge need antialiasing, and the first version only handled
  // one of them:
  //
  //  · the SILHOUETTE, where the shape meets the background — caught by the
  //    band test on the distance to the surface;
  //  · the INTERNAL edges, where two faces meet. Those pixels are deep inside
  //    the shape, so they fail the band test entirely and took a single
  //    sample. The normal flips discontinuously across them, so they aliased
  //    into hard staircased lines down the middle of the cube.
  //
  // Internal-edge proximity: inside the box, `kHalf - |p|` per axis gives the
  // distance to each face. On a face the smallest is ~0; the SECOND smallest
  // is the distance to the nearest edge.
  vec3 nrm;
  vec2 tHit = boxIntersect(roO, rdO, nrm);
  float edgeDist = 1e9;
  if (tHit.x >= 0.0) {
    vec3 hp = abs(roO + rdO * tHit.x);
    vec3 d3 = kHalf - hp;
    float lo = min(d3.x, min(d3.y, d3.z));
    float hi = max(d3.x, max(d3.y, d3.z));
    edgeDist = d3.x + d3.y + d3.z - lo - hi;  // the middle value
  }

  bool nearSilhouette = abs(nearSurface) < px * 2.5;
  bool nearInternalEdge = edgeDist < px * 2.5;

  vec3 sum = vec3(0.0);
  float cov = 0.0;
  if (nearSilhouette || nearInternalEdge) {
    // 6×6 rotated grid (36 samples) with a GAUSSIAN reconstruction filter.
    //
    // 144 and 64 samples were visually identical to 36 here: 36 gives 37
    // coverage levels and the brightness step across this edge is only ~20
    // levels on an 8-bit display, so the extra samples resolved detail the
    // screen cannot show. Kept low because this is fill rate on a phone.
    //
    // A box filter — every sample inside the pixel square weighted equally,
    // which is what this was — is the crudest reconstruction there is, and it
    // leaves edges looking mechanical no matter how many samples you throw at
    // it. Weighting by distance from the pixel centre, and reaching slightly
    // beyond the pixel, is what real renderers do and what actually makes an
    // edge look smooth.
    const float kRadius = 0.72;   // footprint in pixels; >0.5 overlaps neighbours
    const float kSigma = 0.42;
    float weightSum = 0.0;
    float hitWeight = 0.0;
    for (int y = 0; y < 8; y++) {
      for (int x = 0; x < 8; x++) {
        // Rotated grid: offsetting rows sideways decorrelates the samples
        // from the pixel lattice, worth roughly double the sample count on
        // near-horizontal and near-vertical edges.
        vec2 offset = vec2(
          (float(x) + 0.5 + float(y) * (1.0 / 8.0)) / 8.0 - 0.5,
          (float(y) + 0.5) / 8.0 - 0.5
        ) * (kRadius * 2.0);

        float r2 = dot(offset, offset);
        float w = exp(-r2 / (2.0 * kSigma * kSigma));

        float hit;
        vec3 c = shadeRay((frag + offset - uCenter) / uUnit, rot, lightO, hit);
        sum += c * hit * w;
        hitWeight += hit * w;
        weightSum += w;
      }
    }
    sum /= max(hitWeight, 1e-5);
    cov = hitWeight / max(weightSum, 1e-5);
  } else {
    float hit;
    sum = shadeRay(uvC, rot, lightO, hit);
    cov = hit;
  }

  // NO HALO. The drawn glow was a symmetrical ring traced around the
  // silhouette — it read as a sticker outline rather than as light, because
  // nothing in the scene was actually emitting it. Light around the object
  // belongs to the object lighting its surroundings, not to a ring drawn
  // where the object isn't.

  // Tone map the linear HDR result. Without this the specular clips flat and
  // the object loses its shoulder.
  // Exposure. One lever for overall visibility — it lifts the whole object
  // together rather than changing the material, so the relationship between
  // the faces stays exactly as it is.
  vec3 lit = ACESToneMap(sum, 1.25);

  // Premultiplied — composited over the background field.
  fragColor = vec4(lit * cov, cov);
}
