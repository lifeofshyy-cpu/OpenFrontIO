#version 300 es
precision highp float;

// Drifting pixel-art clouds over the map, with a soft shadow on the ground.
// They are see-through, only appear once the camera is zoomed out, and fade
// away as it zooms in, so they never cover close-up play.

uniform float uTime;     // seconds
uniform float uOpacity;  // 0-1 overall strength
uniform float uSpeed;    // drift, in tiles per second
uniform float uCoverage; // 0-1 share of sky with cloud

in vec2 vWorldPos;
out vec4 fragColor;

// Tiles per cloud "pixel".
const float BLOCK = 8.0;
// Where a cloud's shadow falls, in cloud pixels.
const vec2 SHADOW_OFFSET = vec2(3.0, 4.0);

float hash21(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}

float vnoise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  float a = hash21(i);
  float b = hash21(i + vec2(1.0, 0.0));
  float c = hash21(i + vec2(0.0, 1.0));
  float d = hash21(i + vec2(1.0, 1.0));
  return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// Cloud density at a cloud pixel: big shapes with lumpy edges.
float density(vec2 b) {
  return 0.6 * vnoise(b / 20.0) + 0.28 * vnoise(b / 8.0 + 7.3) +
    0.12 * vnoise(b / 3.0 + 1.7);
}

void main() {
  // Size of one screen pixel in tiles (bigger = zoomed further out).
  float px = max(fwidth(vWorldPos.x), fwidth(vWorldPos.y));
  float visible = smoothstep(0.45, 1.4, px) * uOpacity;
  if (visible <= 0.0) discard;

  // The whole pattern slides with the wind.
  vec2 wind = vec2(1.0, 0.22) * uSpeed * uTime;
  vec2 b = floor((vWorldPos - wind) / BLOCK);
  float threshold = mix(0.78, 0.42, clamp(uCoverage, 0.0, 1.0));

  if (density(b) > threshold) {
    // Flat white, with a pale blue underside along the lower edge.
    bool underside = density(b + vec2(0.0, 2.0)) <= threshold;
    vec3 col = underside ? vec3(0.80, 0.87, 0.97) : vec3(1.0);
    fragColor = vec4(col, 0.55 * visible);
  } else if (density(b - SHADOW_OFFSET) > threshold) {
    fragColor = vec4(0.04, 0.07, 0.20, 0.2 * visible);
  } else {
    discard;
  }
}
