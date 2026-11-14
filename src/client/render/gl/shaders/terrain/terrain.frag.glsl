#version 300 es
precision highp float;
precision highp usampler2D;

// Fantasy-map terrain, painted-parchment style: land painted gold along the
// coasts and green inland, deep teal water with a pale band of shallows, ink
// coastlines, mountain ranges of overlapping shaded peaks, and woods drawn as
// a packed canopy of little round trees. The whole sheet is stained, creased,
// grained and burnt dark at the edges.
//
// Defines injected by TerrainPass: MAP_W, MAP_H, FANTASY_GLYPHS (0 | 1) and,
// with FANTASY_GLYPHS, ELEV_W / ELEV_H (the field texture's extent in
// tiles). Without FANTASY_GLYPHS the baked terrain colours are drawn as-is.

uniform sampler2D uTerrain;
#if FANTASY_GLYPHS
// Raw terrain bytes (R8UI): bit 7 land, bit 6 shoreline, bits 0-4 magnitude
// (elevation on land, distance from land on water).
uniform usampler2D uTerrainBytes;
// Smoothed fields (RG8, bilinear): R = land elevation (magnitude × 8 / 255),
// G = share of nearby tiles that are land.
uniform sampler2D uElevation;
// Land paints from render settings (0-1 RGB): inland green (plains), coastal
// gold (highland) and the pale stone of the mountains.
uniform vec3 uPlains;
uniform vec3 uHighland;
uniform vec3 uMountain;
#endif

in vec2 vUV;
out vec4 fragColor;

#if FANTASY_GLYPHS
const vec3 INK = vec3(0.13, 0.09, 0.05);
const vec3 TREE_DARK = vec3(0.20, 0.30, 0.10);
const vec3 TREE_LIGHT = vec3(0.45, 0.55, 0.20);
const vec3 SHALLOWS = vec3(0.62, 0.90, 0.80);
const vec3 EARTH = vec3(0.55, 0.33, 0.12);
// Smallest glyph cell, in tiles, and the on-screen size (px) a cell is kept
// near: cells double in size each time the camera zooms out 2x.
const float BASE_CELL = 12.0;
const float TARGET_PX = 72.0;
const float MAX_LOD = 5.0;
// Trees per glyph cell, along each axis.
const float TREES_PER_CELL = 5.0;
// A peak's size relative to its cell. Above 1 so neighbours overlap.
const float PEAK_SPAN = 1.55;
// Smoothed magnitude at which hill country and mountains begin.
const float HILLS_AT = 8.5;
const float MOUNTAIN_AT = 15.5;

float hash21(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}

vec2 hash22(vec2 p) {
  return vec2(hash21(p), hash21(p * 1.37 + 19.19));
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

float fbm(vec2 p) {
  return 0.5 * vnoise(p) + 0.3 * vnoise(p * 2.03) + 0.2 * vnoise(p * 4.01);
}

float seg(vec2 p, vec2 a, vec2 b) {
  vec2 pa = p - a;
  vec2 ba = b - a;
  float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
  return length(pa - ba * h);
}

float cross2(vec2 a, vec2 b) {
  return a.x * b.y - a.y * b.x;
}

// 1 inside triangle abc (given in clockwise screen order), else 0.
float inTri(vec2 p, vec2 a, vec2 b, vec2 c) {
  float e0 = cross2(b - a, p - a);
  float e1 = cross2(c - b, p - b);
  float e2 = cross2(a - c, p - c);
  return (e0 >= 0.0 && e1 >= 0.0 && e2 >= 0.0) ? 1.0 : 0.0;
}

uint terrainByte(vec2 tile) {
  ivec2 tc = clamp(ivec2(floor(tile)), ivec2(0), ivec2(MAP_W - 1, MAP_H - 1));
  return texelFetch(uTerrainBytes, tc, 0).r;
}

bool isPlayableLand(uint b) {
  return (b & 0x80u) != 0u && (b & 0x1fu) != 31u;
}

// Land that does not touch water.
bool isInland(vec2 tile) {
  uint b = terrainByte(tile);
  return isPlayableLand(b) && (b & 0x40u) == 0u;
}

// 1 on land tiles that touch water (the coastline and river banks).
float coastAt(vec2 tile) {
  uint b = terrainByte(tile);
  return ((b & 0xc0u) == 0xc0u && (b & 0x1fu) != 31u) ? 1.0 : 0.0;
}

// Distance from land for a water tile (0 on land), in magnitude steps.
float waterDepthAt(vec2 tile) {
  uint b = terrainByte(tile);
  return (b & 0x80u) != 0u ? 0.0 : float(b & 0x1fu) + 1.0;
}

// Bilinear water depth, so the shallows fade without tile-sized steps.
float waterDepth(vec2 p) {
  vec2 q = p - 0.5;
  vec2 i = floor(q) + 0.5;
  vec2 f = q - floor(q);
  float a = waterDepthAt(i);
  float b = waterDepthAt(i + vec2(1.0, 0.0));
  float c = waterDepthAt(i + vec2(0.0, 1.0));
  float d = waterDepthAt(i + vec2(1.0, 1.0));
  return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// (smoothed magnitude 0-30, share of nearby tiles that are land 0-1).
vec2 fieldAt(vec2 tile) {
  vec2 uv = tile / vec2(float(ELEV_W), float(ELEV_H));
  vec2 f = texture(uElevation, uv).rg;
  return vec2(f.r * (255.0 / 8.0), f.g);
}

// Woods grow in patches of the hill country, not across all of it.
float woodsNoise(vec2 tile) {
  return vnoise(tile / 38.0 + 31.7);
}

bool isWoods(vec2 tile) {
  float e = fieldAt(tile).x;
  return e >= HILLS_AT && e < MOUNTAIN_AT && woodsNoise(tile) > 0.4;
}

// Ink coverage for a stroke at distance `d`, `aa` = one pixel in the same
// units. A constant-weight pen about 1.5 screen pixels wide.
float pen(float d, float aa) {
  return clamp((0.75 * aa - d) / aa + 0.5, 0.0, 1.0);
}

// One peak, belonging to glyph cell `id`. Returns (ink, fill, shadow, 1), or
// all zeros where the peak does not cover this fragment.
vec4 peak(vec2 p, vec2 id, float cell, float px) {
  vec2 seed = id + cell * 0.371;
  float h1 = hash21(seed);
  float h2 = hash21(seed * 1.7 + 11.3);
  float h3 = hash21(seed * 2.3 + 5.1);
  vec2 c = (id + 0.5 + (vec2(h1, h2) - 0.5) * 0.4) * cell;
  float span = cell * PEAK_SPAN * (0.8 + 0.4 * h3);
  vec2 q = (p - c) / span;
  if (abs(q.x) > 0.5 || abs(q.y) > 0.5) return vec4(0.0);
  if (h3 > 0.9 || !isInland(c) || fieldAt(c).x < MOUNTAIN_AT) return vec4(0.0);

  vec2 apex = vec2(-0.04 + 0.1 * (h1 - 0.5), -0.40);
  vec2 left = vec2(-0.44, 0.30);
  vec2 right = vec2(0.44, 0.30);
  vec2 lKink = mix(apex, left, 0.45) + vec2(-0.03, -0.02);
  vec2 rKink = mix(apex, right, 0.4) + vec2(0.05, -0.03);
  // The ridge wanders down from the summit and splits light from shadow.
  vec2 r1 = apex + vec2(0.05, 0.20);
  vec2 r2 = apex + vec2(-0.02, 0.42);
  vec2 r3 = vec2(apex.x + 0.06, 0.30);

  float fill = max(inTri(q, apex, rKink, lKink),
    max(inTri(q, lKink, rKink, left), inTri(q, rKink, right, left)));
  // Right of the ridge is in shadow.
  float ridgeX = q.y < r1.y
    ? mix(apex.x, r1.x, (q.y - apex.y) / (r1.y - apex.y))
    : q.y < r2.y
      ? mix(r1.x, r2.x, (q.y - r1.y) / (r2.y - r1.y))
      : mix(r2.x, r3.x, (q.y - r2.y) / (r3.y - r2.y));
  float shade = fill * step(ridgeX, q.x);

  float d = seg(q, apex, lKink);
  d = min(d, seg(q, lKink, left));
  d = min(d, seg(q, apex, rKink));
  d = min(d, seg(q, rKink, right));
  d = min(d, seg(q, apex, r1));
  d = min(d, seg(q, r1, r2));
  // Hatching down the shadow side.
  for (int i = 0; i < 5; i++) {
    float fi = float(i);
    vec2 a = vec2(ridgeX + 0.03, apex.y + 0.16 + 0.11 * fi);
    float hd = seg(q, a, a + vec2(0.05 + 0.035 * fi, 0.07));
    d = min(d, mix(1.0, hd, shade));
  }
  // The foot of the peak melts into the ground instead of ending in a line.
  float foot = 1.0 - smoothstep(0.12, 0.30, q.y);
  float ink = pen(d * span, px) * mix(0.35, 1.0, foot);
  if (fill == 0.0 && ink == 0.0) return vec4(0.0);
  return vec4(ink, fill * foot, shade * foot, 1.0);
}

// Peaks overlap their neighbours into ranges: the cell below is in front,
// then this row, then the cell above.
vec3 rangeLayer(vec2 p, float cell, float px) {
  vec2 id = floor(p / cell);
  vec4 s = peak(p, id + vec2(0.0, 1.0), cell, px);
  if (s.w == 0.0) s = peak(p, id, cell, px);
  if (s.w == 0.0) s = peak(p, id + vec2(-1.0, 0.0), cell, px);
  if (s.w == 0.0) s = peak(p, id + vec2(1.0, 0.0), cell, px);
  if (s.w == 0.0) s = peak(p, id + vec2(0.0, -1.0), cell, px);
  return s.xyz;
}

// Rounded hills in the hill country, between the woods. Returns (ink, fill).
vec2 hillLayer(vec2 p, float cell, float px) {
  vec2 g = p / cell;
  float shift = 0.5 * mod(floor(g.y), 2.0);
  g.x += shift;
  vec2 id = floor(g);
  vec2 q = fract(g) - 0.5;
  vec2 seed = id + cell * 0.531;
  float h1 = hash21(seed);
  float h2 = hash21(seed * 1.7 + 11.3);
  float h3 = hash21(seed * 2.3 + 5.1);
  vec2 jitter = (vec2(h1, h2) - 0.5) * 0.3;
  q -= jitter;
  if (h3 > 0.55) return vec2(0.0);
  vec2 c = id + 0.5 + jitter;
  c.x -= shift;
  c *= cell;
  if (!isInland(c)) return vec2(0.0);
  float e = fieldAt(c).x;
  if (e < HILLS_AT - 1.5 || e >= MOUNTAIN_AT || woodsNoise(c) > 0.37) {
    return vec2(0.0);
  }

  vec2 hc = vec2(0.0, 0.15);
  vec2 rad = vec2(0.30, 0.22);
  vec2 el = (q - hc) / rad;
  float arc = abs(length(el) - 1.0) * rad.y;
  float d = q.y < hc.y ? arc : 1.0;
  d = min(d, seg(q, vec2(0.12, 0.00), vec2(0.18, 0.10)));
  d = min(d, seg(q, vec2(0.03, -0.03), vec2(0.08, 0.08)));
  float fill = (dot(el, el) < 1.0 && q.y < hc.y) ? 1.0 : 0.0;
  return vec2(pen(d * cell, px), fill);
}

// The woods: a packed canopy of round trees, each fragment belonging to its
// nearest tree. Returns (ink, canopy fill, lit side of the crown).
vec3 canopyLayer(vec2 p, float cell, float px) {
  vec2 g = p / cell;
  vec2 id = floor(g);
  vec2 f = fract(g);
  float d1 = 9.0;
  float d2 = 9.0;
  vec2 nearest = vec2(0.0);
  for (int j = -1; j <= 1; j++) {
    for (int i = -1; i <= 1; i++) {
      vec2 o = vec2(float(i), float(j));
      vec2 pt = o + 0.5 + (hash22(id + o + cell * 0.173) - 0.5) * 0.7;
      float d = length(pt - f);
      if (d < d1) {
        d2 = d1;
        d1 = d;
        nearest = pt;
      } else if (d < d2) {
        d2 = d;
      }
    }
  }
  float r = 0.62;
  if (d1 > r) return vec3(0.0);
  vec2 c = (id + nearest) * cell;
  if (!isInland(c) || !isWoods(c)) return vec3(0.0);

  // Outline: the crown's own rim, or where it meets the next tree.
  float rim = min(r - d1, 0.5 * (d2 - d1));
  float ink = pen(rim * cell, px);
  vec2 dir = (f - nearest) / max(d1, 1e-3);
  float lit = smoothstep(0.1, 0.5, d1) * max(0.0, dot(dir, vec2(-0.6, -0.8)));
  return vec3(ink, 1.0, lit);
}
#endif

void main() {
  vec3 col = texture(uTerrain, vUV).rgb;

#if FANTASY_GLYPHS
  vec2 p = vUV * vec2(float(MAP_W), float(MAP_H));
  // Size of one screen pixel in tiles (bigger = zoomed further out).
  float px = max(max(fwidth(p.x), fwidth(p.y)), 1e-4);
  float stain = fbm(p / 90.0);
  float blotch = fbm(p / 31.0 + 9.0);

  uint centre = terrainByte(p);
  bool onLand = isPlayableLand(centre);
  if (onLand) {
    // --- Land: gold along the coasts, green inland, pale stone under the
    // mountains, all broken up by blotchy washes ---
    vec2 field = fieldAt(p);
    float inland = smoothstep(0.5, 0.97, field.y + (blotch - 0.5) * 0.35);
    col = mix(uHighland, uPlains, inland * 0.9);
    col = mix(col, uPlains * 0.72, 0.5 * smoothstep(0.55, 0.8, blotch) * inland);
    col = mix(col, uHighland * 1.12, 0.3 * smoothstep(0.5, 0.2, blotch));
    // Earthy rim where the land meets the sea.
    col = mix(col, EARTH, 0.4 * (1.0 - smoothstep(0.3, 0.62, field.y)));
    float stone = smoothstep(MOUNTAIN_AT - 3.5, MOUNTAIN_AT, field.x);
    col = mix(col, uMountain, 0.85 * stone);
  } else if ((centre & 0x80u) == 0u) {
    // --- Water: a pale band of shallows, then deep and mottled ---
    float depth = waterDepth(p) + (stain - 0.5) * 2.5;
    col = mix(col, SHALLOWS, 0.75 * (1.0 - smoothstep(0.5, 6.0, depth)));
    col *= 1.0 - 0.3 * smoothstep(6.0, 28.0, depth);
    col *= 0.82 + 0.36 * blotch;
  }

  // --- Inked coastline ---
  // Four taps across the pixel so the one-tile line stays continuous when
  // the camera is zoomed out past one tile per pixel.
  float o = 0.25 * px;
  float coast = 0.25 * (coastAt(p + vec2(-o, -o)) + coastAt(p + vec2(o, -o)) +
    coastAt(p + vec2(-o, o)) + coastAt(p + vec2(o, o)));
  col = mix(col, INK, coast * 0.85);

  // --- Inked glyphs ---
  // Pick the cell size that keeps glyphs near TARGET_PX on screen, and
  // cross-fade to the next size up as the camera zooms out.
  if (onLand) {
    float lod = log2(px * TARGET_PX / BASE_CELL);
    float l0 = clamp(floor(lod), 0.0, MAX_LOD);
    float lf = clamp(lod - l0, 0.0, 1.0);
    float cell = BASE_CELL * exp2(l0);
    vec3 trees = canopyLayer(p, cell / TREES_PER_CELL, px);
    vec2 hills = hillLayer(p, cell, px);
    vec3 range = rangeLayer(p, cell, px);
    if (lf > 0.7 && l0 < MAX_LOD) {
      float t = smoothstep(0.7, 1.0, lf);
      trees = mix(trees, canopyLayer(p, cell * 2.0 / TREES_PER_CELL, px), t);
      hills = mix(hills, hillLayer(p, cell * 2.0, px), t);
      range = mix(range, rangeLayer(p, cell * 2.0, px), t);
    }
    // Close up (lod < 0) the glyphs would outgrow the screen: fade them out.
    float near = smoothstep(-1.0, 0.0, lod);
    trees *= near;
    hills *= near;
    range *= near;

    col = mix(col, mix(TREE_DARK, TREE_LIGHT, trees.z), trees.y * 0.92);
    col = mix(col, INK, trees.x * 0.8);
    col = mix(col, uMountain * 0.95, hills.y * 0.7);
    col = mix(col, INK, hills.x * 0.85);
    // Peaks: lit stone, a shadowed side, then the ink.
    col = mix(col, uMountain * 1.06, range.y * 0.95);
    col = mix(col, uMountain * 0.62, range.z * 0.8);
    col = mix(col, INK, range.x * 0.9);
  }

  // --- The sheet itself: stains, creases, grain and burnt edges ---
  col *= 0.86 + 0.26 * stain;
  float crease = abs(vnoise(p / 140.0 + 4.0) - 0.5);
  col *= 1.0 - 0.1 * (1.0 - smoothstep(0.0, 0.012, crease));
  float zl = log2(px);
  float s = exp2(floor(zl));
  float grain = mix(vnoise(p / (s * 2.5)), vnoise(p / (s * 5.0)), fract(zl));
  col *= 0.94 + 0.12 * grain;
  float edge = min(min(vUV.x, 1.0 - vUV.x), min(vUV.y, 1.0 - vUV.y));
  edge += (stain - 0.5) * 0.05;
  col *= mix(0.25, 1.0, smoothstep(0.0, 0.1, edge));
#endif

  fragColor = vec4(col, 1.0);
}
