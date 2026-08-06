// The world field.
//
// Domain-warped fractal noise: noise sampled through coordinates that are
// themselves displaced by noise. That is what gives slow folding strata rather
// than static — plain fbm looks like clouds, warped fbm looks like a material.
//
// THE CAMERA IS A UNIFORM, and that is the whole concept. It offsets the
// sample coordinate, so travelling does not cross-fade between images — it
// moves a window through a field that already extends infinitely in both
// directions. Section two is a different PLACE in the same space.
//
// Cost is fill rate and nothing else: instruction count × pixels covered ×
// frames. Full screen on a phone at 3x is ~3M pixels a frame — the number the
// stats overlay exists to watch.

#version 460 core
#include <flutter/runtime_effect.glsl>

precision highp float;

uniform vec2 uSize;
uniform float uTime;
uniform float uCamera;    // position in locations; 1.0 == one section travelled
uniform float uVelocity;  // locations per second, drives the smear

out vec4 fragColor;

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

void main() {
  vec2 fragCoord = FlutterFragCoord().xy;
  vec2 uv = fragCoord / uSize;
  float aspect = uSize.x / uSize.y;

  // World coordinates. The camera slides this window sideways; the field
  // itself never moves, which is what makes travel feel like displacement
  // rather than animation.
  //
  // ANISOTROPIC ON PURPOSE: x is sampled at a much lower frequency than y, so
  // features stretch into horizontal strata instead of isotropic blobs. Blobs
  // read as stock marble; strata read as layers you are travelling THROUGH,
  // which is the whole concept — and they also make lateral motion legible,
  // because you cross bands rather than swim in soup.
  vec2 p = vec2((uv.x * aspect + uCamera * 1.35) * 0.55, uv.y * 2.6);

  // Travelling compresses the sampling along x, which reads as motion blur
  // without needing a second pass to blur with.
  p.x /= 1.0 + abs(uVelocity) * 2.4;

  float t = uTime * 0.06;

  // Two rounds of warping. One is not enough to lose the fbm signature.
  vec2 q = vec2(fbm(p + vec2(0.0, t)), fbm(p + vec2(5.2, 1.3)));
  vec2 r = vec2(
    fbm(p + 3.4 * q + vec2(1.7, 9.2) + t * 0.7),
    fbm(p + 3.4 * q + vec2(8.3, 2.8) - t * 0.5)
  );
  float f = fbm(p + 3.2 * r);

  vec3 base = vec3(0.043, 0.043, 0.059);
  vec3 accent = vec3(1.0, 0.353, 0.212);

  // Low contrast on purpose. The field is the GROUND, not the subject — it
  // has to survive display type sitting on top of it at every size, and the
  // earlier high-contrast version won the fight against the type.
  vec3 col = mix(base, vec3(0.056, 0.055, 0.071), smoothstep(0.20, 0.98, f));

  // Colour only at the ridges, so the accent reads as an event rather than a
  // wash — and only at the very top of the range, so most of the frame has
  // none of it at all.
  col += accent * smoothstep(0.78, 1.02, f) * 0.16;

  // A faint rim along the fold gradient. This is the one piece of visible
  // STRUCTURE in the field: without it the strata have no edges and the whole
  // thing goes back to looking like a gradient.
  float rim = smoothstep(0.56, 0.615, f) - smoothstep(0.615, 0.70, f);
  col += accent * rim * 0.09;
  col += vec3(0.062, 0.062, 0.075) * rim;

  // Grain. The single cheapest thing that stops flat dark looking cheap.
  float grain = hash(fragCoord + fract(uTime) * 91.7);
  col += (grain - 0.5) * 0.022;

  // Settle the field down into the site's own black at the bottom of the
  // frame, where the statement and the rail live. The type should sit on
  // something close to flat ground; the field is for the space above it.
  float floorFade = smoothstep(0.42, 1.0, uv.y);
  col = mix(col, base, floorFade * 0.72);

  fragColor = vec4(col, 1.0);
}
