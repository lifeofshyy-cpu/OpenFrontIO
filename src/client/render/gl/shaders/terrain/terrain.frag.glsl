#version 300 es
precision highp float;
precision highp usampler2D;

// Fantasy-map terrain, painted-parchment style: mottled watercolour land,
// water that pales towards the coast, ink coastlines, and hand-inked glyphs
// (peaks, hills, clumps of little trees) placed from a smoothed elevation
// field. The whole sheet is stained, grained and darkened at the edges.
//
// Defines injected by TerrainPass: MAP_W, MAP_H, FANTASY_GLYPHS (0 | 1) and,
// with FANTASY_GLYPHS, ELEV_W / ELEV_H (the elevation texture's extent in
// tiles). Without FANTASY_GLYPHS the baked terrain colours are drawn as-is.

uniform sampler2D uTerrain;
#if FANTASY_GLYPHS
// Raw terrain bytes (R8UI): bit 7 land, bit 6 shoreline, bits 0-4 magnitude
// (elevation on land, distance from land on water).
uniform usampler2D uTerrainBytes;
// Smoothed land elevation (R8, bilinear): magnitude × 8 / 255.
uniform sampler2D uElevation;
// Land paints from render settings (0-1 RGB): the two washes the lowlands
// are mottled with (plains, highland) and the pale wash under mountains.
uniform vec3 uPlains;
uniform vec3 uHighland;
uniform vec3 uMountain;
#endif

in vec2 vUV;
out vec4 fragColor;

#if FANTASY_GLYPHS
const vec3 INK = vec3(0.16, 0.11, 0.06);
const vec3 TREE_GREEN = vec3(0.42, 0.52, 0.20);
const vec3 SHALLOWS = vec3(0.74, 0.92, 0.84);
// Smallest glyph cell, in tiles, and the on-screen size (px) a cell is kept
// near: cells double in size each time the camera zooms out 2x.
const float BASE_CELL = 12.0;
const float TARGET_PX = 72.0;
const float MAX_LOD = 5.0;
// Tree cells per glyph cell, along each axis.
const float TREES_PER_CELL = 3.0;
// Smoothed magnitude at which hill country and mountains begin.
const float HILLS_AT = 9.0;
const float MOUNTAIN_AT = 16.0;

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

// Smoothed magnitude (0-30) around a tile.
float elevation(vec2 tile) {
  vec2 uv = tile / vec2(float(ELEV_W), float(ELEV_H));
  return texture(uElevation, uv).r * (255.0 / 8.0);
}

// Woods grow in patches of the hill country, not across all of it.
float woodsAt(vec2 tile) {
  return vnoise(tile / 42.0 + 31.7);
}

// Ink coverage for a stroke at distance `d`, `aa` = one pixel in the same
// units. A constant-weight pen about 1.5 screen pixels wide.
float pen(float d, float aa) {
  return clamp((0.75 * aa - d) / aa + 0.5, 0.0, 1.0);
}

// Peaks, hills and grass. Cells are `cell` tiles wide; `px` is one screen
// pixel in tiles. Returns (ink, paper fill inside the glyph, shadow).
vec3 reliefLayer(vec2 p, float cell, float px) {
  vec2 g = p / cell;
  // Offset alternate rows by half a cell so the grid doesn't read as a grid.
  float shift = 0.5 * mod(floor(g.y), 2.0);
  g.x += shift;
  vec2 id = floor(g);
  vec2 q = fract(g) - 0.5;

  vec2 seed = id + cell * 0.371;
  float h1 = hash21(seed);
  float h2 = hash21(seed * 1.7 + 11.3);
  float h3 = hash21(seed * 2.3 + 5.1);
  vec2 jitter = (vec2(h1, h2) - 0.5) * 0.3;
  q -= jitter;

  // Glyph centre in tile coordinates; it decides what gets drawn.
  vec2 c = id + 0.5 + jitter;
  c.x -= shift;
  c *= cell;
  // Centre and both feet on dry land, clear of coasts and rivers.
  vec2 foot = vec2(0.3, 0.2) * cell;
  if (!isInland(c)) return vec3(0.0);
  if (!isInland(c + vec2(-foot.x, foot.y)) || !isInland(c + foot)) {
    return vec3(0.0);
  }

  float e = elevation(c);
  float size = 0.85 + 0.3 * h1;
  q /= size;

  float d;
  float fill = 0.0;
  float shade = 0.0;
  if (e >= MOUNTAIN_AT) {
    vec2 apex = vec2(0.0, -0.32);
    vec2 left = vec2(-0.32, 0.22);
    vec2 right = vec2(0.32, 0.22);
    d = seg(q, apex, vec2(-0.13, -0.06));
    d = min(d, seg(q, vec2(-0.13, -0.06), left));
    d = min(d, seg(q, apex, vec2(0.11, -0.03)));
    d = min(d, seg(q, vec2(0.11, -0.03), right));
    // Ridge line running down from the summit.
    d = min(d, seg(q, apex, vec2(0.02, -0.08)));
    d = min(d, seg(q, vec2(0.02, -0.08), vec2(-0.04, 0.12)));
    // Shadow hatching on the right-hand slope.
    for (int i = 0; i < 4; i++) {
      float fi = float(i);
      vec2 a = vec2(0.05, -0.16 + 0.10 * fi);
      d = min(d, seg(q, a, a + vec2(0.06 + 0.03 * fi, 0.08)));
    }
    fill = inTri(q, apex, right, left);
    shade = inTri(q, apex, right, vec2(0.0, 0.22));
  } else if (e >= HILLS_AT) {
    // Hills only where the woods are not.
    if (woodsAt(c) > 0.45 || h3 > 0.5) return vec3(0.0);
    vec2 hc = vec2(0.0, 0.15);
    vec2 rad = vec2(0.26, 0.20);
    float arc = abs(length((q - hc) / rad) - 1.0) * rad.y;
    d = q.y < hc.y ? arc : 1.0;
    d = min(d, seg(q, vec2(0.10, 0.02), vec2(0.15, 0.10)));
    d = min(d, seg(q, vec2(0.02, -0.01), vec2(0.06, 0.08)));
    vec2 el = (q - hc) / rad;
    fill = (dot(el, el) < 1.0 && q.y < hc.y) ? 1.0 : 0.0;
  } else {
    if (h3 > 0.1) return vec3(0.0);
    vec2 root = vec2(0.0, 0.06);
    d = seg(q, root, vec2(-0.06, -0.03));
    d = min(d, seg(q, root, vec2(0.0, -0.06)));
    d = min(d, seg(q, root, vec2(0.06, -0.03)));
  }
  d *= size;

  return vec3(pen(d, px / cell), fill, shade);
}

// Little round trees, several to a glyph cell, wherever the woods are.
// Returns (ink, canopy fill).
vec2 treeLayer(vec2 p, float cell, float px) {
  vec2 g = p / cell;
  float shift = 0.5 * mod(floor(g.y), 2.0);
  g.x += shift;
  vec2 id = floor(g);
  vec2 q = fract(g) - 0.5;

  vec2 seed = id + cell * 0.731;
  float h1 = hash21(seed);
  float h2 = hash21(seed * 1.9 + 3.7);
  vec2 jitter = (vec2(h1, h2) - 0.5) * 0.36;
  q -= jitter;

  vec2 c = id + 0.5 + jitter;
  c.x -= shift;
  c *= cell;
  if (!isInland(c)) return vec2(0.0);
  float e = elevation(c);
  if (e < HILLS_AT || e >= MOUNTAIN_AT) return vec2(0.0);
  // Thin the edges of each wood so it doesn't end in a hard line.
  float woods = woodsAt(c);
  if (woods < 0.45 + 0.08 * h2) return vec2(0.0);

  float size = 0.85 + 0.3 * h1;
  q /= size;
  vec2 crown = vec2(0.0, -0.06);
  float r = 0.27;
  float dist = length(q - crown);
  float d = abs(dist - r);
  d = min(d, seg(q, vec2(0.0, 0.21), vec2(0.0, 0.36)));
  // A stroke inside the crown, on the shaded side.
  d = min(d, seg(q, vec2(0.08, -0.12), vec2(0.13, 0.02)));
  d *= size;
  return vec2(pen(d, px / cell), dist < r ? 1.0 : 0.0);
}
#endif

void main() {
  vec3 col = texture(uTerrain, vUV).rgb;

#if FANTASY_GLYPHS
  vec2 p = vUV * vec2(float(MAP_W), float(MAP_H));
  // Size of one screen pixel in tiles (bigger = zoomed further out).
  float px = max(max(fwidth(p.x), fwidth(p.y)), 1e-4);
  float stain = fbm(p / 90.0);

  uint centre = terrainByte(p);
  bool onLand = isPlayableLand(centre);
  if (onLand) {
    // --- Land: two watercolour washes mottled together by noise, with a
    // pale wash under the mountains ---
    float wash = fbm(p / 55.0 + 9.0);
    col = mix(uHighland, uPlains, smoothstep(0.38, 0.62, wash));
    col = mix(col, uHighland * 1.08, 0.35 * vnoise(p / 17.0 + 3.0));
    float e = elevation(p);
    col = mix(col, uMountain, 0.8 * smoothstep(MOUNTAIN_AT - 3.0, MOUNTAIN_AT, e));
    // Darker ground under the woods.
    float woods = smoothstep(0.43, 0.5, woodsAt(p)) *
      smoothstep(HILLS_AT - 1.0, HILLS_AT, e) *
      (1.0 - smoothstep(MOUNTAIN_AT - 1.0, MOUNTAIN_AT, e));
    col = mix(col, TREE_GREEN, woods * 0.35);
  } else if ((centre & 0x80u) == 0u) {
    // --- Water: pale shallows along the coast, deepening offshore ---
    float depth = waterDepth(p) + (stain - 0.5) * 3.0;
    float shallow = 1.0 - smoothstep(0.5, 9.0, depth);
    col = mix(col, SHALLOWS, shallow * 0.7);
    col *= 1.0 - 0.22 * smoothstep(8.0, 30.0, depth);
  }

  // --- Inked coastline ---
  // Four taps across the pixel so the one-tile line stays continuous when
  // the camera is zoomed out past one tile per pixel.
  float o = 0.25 * px;
  float coast = 0.25 * (coastAt(p + vec2(-o, -o)) + coastAt(p + vec2(o, -o)) +
    coastAt(p + vec2(-o, o)) + coastAt(p + vec2(o, o)));
  col = mix(col, INK, coast * 0.8);

  // --- Inked glyphs ---
  // Pick the cell size that keeps glyphs near TARGET_PX on screen, and
  // cross-fade to the next size up as the camera zooms out.
  if (onLand) {
    float lod = log2(px * TARGET_PX / BASE_CELL);
    float l0 = clamp(floor(lod), 0.0, MAX_LOD);
    float lf = clamp(lod - l0, 0.0, 1.0);
    float cell = BASE_CELL * exp2(l0);
    vec3 relief = reliefLayer(p, cell, px);
    vec2 trees = treeLayer(p, cell / TREES_PER_CELL, px);
    if (lf > 0.7 && l0 < MAX_LOD) {
      float t = smoothstep(0.7, 1.0, lf);
      relief = mix(relief, reliefLayer(p, cell * 2.0, px), t);
      trees = mix(trees, treeLayer(p, cell * 2.0 / TREES_PER_CELL, px), t);
    }
    // Close up (lod < 0) the glyphs would outgrow the screen: fade them out.
    float near = smoothstep(-1.0, 0.0, lod);
    relief *= near;
    trees *= near;
    col = mix(col, TREE_GREEN, trees.y * 0.85);
    col = mix(col, INK, trees.x * 0.85);
    // Bare paper inside peaks and hills, a shaded side, then the ink.
    col = mix(col, uMountain * 1.04, relief.y * 0.75);
    col = mix(col, INK, relief.z * 0.2);
    col = mix(col, INK, relief.x * 0.85);
  }

  // --- The sheet itself: stains, grain and darkened edges ---
  col *= 0.9 + 0.2 * stain;
  float zl = log2(px);
  float s = exp2(floor(zl));
  float grain = mix(vnoise(p / (s * 2.5)), vnoise(p / (s * 5.0)), fract(zl));
  col *= 0.96 + 0.08 * grain;
  float edge = min(min(vUV.x, 1.0 - vUV.x), min(vUV.y, 1.0 - vUV.y));
  edge += (stain - 0.5) * 0.04;
  col *= mix(0.45, 1.0, smoothstep(0.0, 0.09, edge));
#endif

  fragColor = vec4(col, 1.0);
}
