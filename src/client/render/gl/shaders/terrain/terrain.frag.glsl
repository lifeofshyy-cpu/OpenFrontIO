#version 300 es
precision highp float;
precision highp usampler2D;

// Fantasy-map terrain: the baked terrain colours, aged like parchment, with
// hand-inked map glyphs (mountains, hills, trees, waves) drawn procedurally.
//
// Defines injected by TerrainPass: MAP_W, MAP_H, FANTASY_GLYPHS (0 | 1).

uniform sampler2D uTerrain;
#if FANTASY_GLYPHS
// Raw terrain bytes (R8UI): bit 7 land, bit 6 shoreline, bits 0-4 magnitude.
uniform usampler2D uTerrainBytes;
#endif

in vec2 vUV;
out vec4 fragColor;

const vec3 INK = vec3(0.23, 0.16, 0.09);
const vec3 PAPER = vec3(0.93, 0.86, 0.70);
// Smallest glyph cell, in tiles, and the on-screen size (px) a cell is kept
// near: cells double in size each time the camera zooms out 2x.
const float BASE_CELL = 12.0;
const float TARGET_PX = 64.0;
const float MAX_LOD = 5.0;

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

#if FANTASY_GLYPHS
float seg(vec2 p, vec2 a, vec2 b) {
  vec2 pa = p - a;
  vec2 ba = b - a;
  float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
  return length(pa - ba * h);
}

// 0 = impassable, 1 = plains, 2 = highland, 3 = mountain, 4 = open water,
// 5 = water next to land.
int terrainClass(vec2 tile) {
  ivec2 tc = clamp(ivec2(floor(tile)), ivec2(0), ivec2(MAP_W - 1, MAP_H - 1));
  uint b = texelFetch(uTerrainBytes, tc, 0).r;
  bool land = (b & 0x80u) != 0u;
  bool shore = (b & 0x40u) != 0u;
  uint mag = b & 0x1fu;
  if (land) {
    if (mag == 31u) return 0;
    if (mag < 10u) return 1;
    if (mag < 20u) return 2;
    return 3;
  }
  return shore ? 5 : 4;
}

// 1 on land tiles that touch water (the coastline and river banks).
float coastAt(vec2 tile) {
  ivec2 tc = clamp(ivec2(floor(tile)), ivec2(0), ivec2(MAP_W - 1, MAP_H - 1));
  uint b = texelFetch(uTerrainBytes, tc, 0).r;
  return ((b & 0xc0u) == 0xc0u && (b & 0x1fu) != 31u) ? 1.0 : 0.0;
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

float mountainDist(vec2 q) {
  vec2 apex = vec2(0.0, -0.30);
  float d = seg(q, apex, vec2(-0.12, -0.06));
  d = min(d, seg(q, vec2(-0.12, -0.06), vec2(-0.30, 0.22)));
  d = min(d, seg(q, apex, vec2(0.10, -0.02)));
  d = min(d, seg(q, vec2(0.10, -0.02), vec2(0.30, 0.22)));
  // Shadow hatching on the right-hand slope.
  for (int i = 0; i < 4; i++) {
    float fi = float(i);
    vec2 a = vec2(0.03, -0.18 + 0.10 * fi);
    d = min(d, seg(q, a, a + vec2(0.06 + 0.03 * fi, 0.08)));
  }
  return d;
}

float hillDist(vec2 q) {
  vec2 c = vec2(0.0, 0.15);
  vec2 rad = vec2(0.26, 0.20);
  float arc = abs(length((q - c) / rad) - 1.0) * rad.y;
  float d = q.y < c.y ? arc : 1.0;
  d = min(d, seg(q, vec2(0.10, 0.02), vec2(0.15, 0.10)));
  d = min(d, seg(q, vec2(0.02, -0.01), vec2(0.06, 0.08)));
  return d;
}

float treeDist(vec2 q) {
  float d = abs(length(q - vec2(0.0, -0.06)) - 0.11);
  d = min(d, seg(q, vec2(0.0, 0.05), vec2(0.0, 0.17)));
  d = min(d, seg(q, vec2(-0.07, 0.17), vec2(0.07, 0.17)));
  return d;
}

float tuftDist(vec2 q) {
  vec2 root = vec2(0.0, 0.08);
  float d = seg(q, root, vec2(-0.08, -0.04));
  d = min(d, seg(q, root, vec2(0.0, -0.08)));
  d = min(d, seg(q, root, vec2(0.08, -0.04)));
  return d;
}

float waveDist(vec2 q) {
  float d = abs(q.y - 0.035 * sin(q.x * 22.0));
  return max(d, abs(q.x) - 0.21);
}

// One glyph layer whose cells are `cell` tiles wide. Returns (ink coverage,
// paper fill inside the glyph, shadow on its shaded side), each 0-1.
// `px` is the size of one screen pixel in tiles.
vec3 glyphLayer(vec2 p, float cell, float px) {
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
  int k0 = terrainClass(c);
  if (k0 == 0) return vec3(0.0);

  // Sample the glyph's footprint. Terrain is speckled (mountain tiles mixed
  // into highland), so classify by what the footprint contains, not by the
  // centre tile alone.
  vec2 foot = vec2(0.3, 0.2) * cell;
  int k1 = terrainClass(c + vec2(-foot.x, foot.y));
  int k2 = terrainClass(c + foot);
  int k3 = terrainClass(c + vec2(0.0, -0.25 * cell));
  int k4 = terrainClass(c + vec2(0.12, 0.05) * cell);

  float size = 0.85 + 0.3 * h1;
  q /= size;

  float d;
  float fill = 0.0;
  float shade = 0.0;
  if (k0 >= 4) {
    // Waves only out on open water, clear of every coast.
    if (k0 != 4 || k1 != 4 || k2 != 4 || k3 != 4 || k4 != 4) return vec3(0.0);
    if (h3 > 0.12) return vec3(0.0);
    d = waveDist(q);
  } else {
    // Land glyphs keep both feet and the centre on dry land.
    if (k1 < 1 || k1 > 3 || k2 < 1 || k2 > 3) return vec3(0.0);
    int mtn = int(k0 == 3) + int(k1 == 3) + int(k2 == 3) + int(k3 == 3) +
      int(k4 == 3);
    int high = int(k0 == 2) + int(k1 == 2) + int(k2 == 2) + int(k3 == 2) +
      int(k4 == 2);
    if (mtn >= 2) {
      if (h3 > 0.85) return vec3(0.0);
      d = mountainDist(q);
      vec2 apex = vec2(0.0, -0.30);
      vec2 left = vec2(-0.30, 0.22);
      vec2 right = vec2(0.30, 0.22);
      vec2 base = vec2(0.03, 0.22);
      fill = inTri(q, apex, right, left);
      shade = inTri(q, apex, right, base);
    } else if (mtn + high >= 2) {
      if (h3 > 0.55) return vec3(0.0);
      d = hillDist(q);
      vec2 e = (q - vec2(0.0, 0.15)) / vec2(0.26, 0.20);
      fill = (dot(e, e) < 1.0 && q.y < 0.15) ? 1.0 : 0.0;
    } else {
      if (h3 > 0.2) return vec3(0.0);
      if (h3 < 0.1) {
        d = treeDist(q * 1.2) / 1.2;
        fill = length(q * 1.2 - vec2(0.0, -0.06)) < 0.11 ? 1.0 : 0.0;
      } else {
        d = tuftDist(q * 1.4) / 1.4;
      }
    }
  }
  d *= size;

  // Constant-weight pen: ~1.6 screen pixels wide at every zoom.
  float aa = px / cell;
  float ink = clamp((0.8 * aa - d) / aa + 0.5, 0.0, 1.0);
  return vec3(ink, fill, shade);
}
#endif

void main() {
  vec3 col = texture(uTerrain, vUV).rgb;

  vec2 p = vUV * vec2(float(MAP_W), float(MAP_H));
  // Size of one screen pixel in tiles (bigger = zoomed further out).
  float px = max(max(fwidth(p.x), fwidth(p.y)), 1e-4);
  float zl = log2(px);
  float zi = floor(zl);
  float zf = zl - zi;

  // --- Parchment: large stains plus a fine grain that follows the zoom ---
  float stain = fbm(p / 90.0);
  col *= 0.92 + 0.16 * stain;
  float s = exp2(zi);
  float grain = mix(vnoise(p / (s * 2.5)), vnoise(p / (s * 5.0)), zf);
  col *= 0.965 + 0.07 * grain;

  // --- Aged, darkened map edges ---
  float edge = min(min(vUV.x, 1.0 - vUV.x), min(vUV.y, 1.0 - vUV.y));
  edge += (stain - 0.5) * 0.03;
  col *= mix(0.7, 1.0, smoothstep(0.0, 0.07, edge));

#if FANTASY_GLYPHS
  // --- Inked coastline ---
  // Four taps across the pixel so the one-tile line stays continuous when
  // the camera is zoomed out past one tile per pixel.
  float o = 0.25 * px;
  float coast = 0.25 * (coastAt(p + vec2(-o, -o)) + coastAt(p + vec2(o, -o)) +
    coastAt(p + vec2(-o, o)) + coastAt(p + vec2(o, o)));
  col = mix(col, INK, coast * 0.6);

  // --- Inked glyphs ---
  // Pick the cell size that keeps glyphs near TARGET_PX on screen, and
  // cross-fade to the next size up as the camera zooms out.
  float lod = log2(px * TARGET_PX / BASE_CELL);
  float l0 = clamp(floor(lod), 0.0, MAX_LOD);
  float lf = clamp(lod - l0, 0.0, 1.0);
  vec3 glyph = glyphLayer(p, BASE_CELL * exp2(l0), px);
  if (lf > 0.7 && l0 < MAX_LOD) {
    vec3 next = glyphLayer(p, BASE_CELL * exp2(l0 + 1.0), px);
    glyph = mix(glyph, next, smoothstep(0.7, 1.0, lf));
  }
  // Close up (lod < 0) the glyphs would outgrow the screen: fade them out.
  glyph *= smoothstep(-1.0, 0.0, lod);
  // Clear the busy terrain under a glyph with bare paper, shade one side,
  // then lay the ink on top.
  col = mix(col, PAPER, glyph.y * 0.6);
  col = mix(col, INK, glyph.z * 0.22);
  col = mix(col, INK, glyph.x * 0.85);
#endif

  fragColor = vec4(col, 1.0);
}
