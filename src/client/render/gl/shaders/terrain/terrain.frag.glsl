#version 300 es
precision highp float;
precision highp usampler2D;

// Fantasy-map terrain, bright pixel-art style: flat vivid land with a dark
// outline and a shaded lower rim, blue water in two flat depths with a pale
// foam line along the coast, and terrain sprites from an atlas — mountains,
// stands of trees, hills and boulders — placed from a smoothed elevation
// field and overlapping into ranges and forests.
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
// Terrain sprite atlas: one row of SPRITE_COUNT square cells, each sprite
// standing at the bottom centre of its cell. Unfiltered.
uniform sampler2D uSprites;
// Land colour from render settings (0-1 RGB).
uniform vec3 uPlains;
#endif

in vec2 vUV;
out vec4 fragColor;

#if FANTASY_GLYPHS
// Smallest glyph cell, in tiles, and the on-screen size (px) a cell is kept
// near: cells double in size each time the camera zooms out 2x.
const float BASE_CELL = 10.0;
const float TARGET_PX = 56.0;
const float MAX_LOD = 5.0;
// Mountain and woodland cells, as a fraction of a glyph cell, and the size
// of a sprite's atlas cell relative to them. Above 1 so neighbours overlap.
const float PEAK_CELL = 0.9;
const float WOOD_CELL = 0.62;
const float SPRITE_SPAN = 1.9;
// Smoothed magnitude at which forest and mountains begin.
const float FOREST_AT = 10.0;
const float MOUNTAIN_AT = 16.0;

// Atlas cells, left to right.
const float SPRITE_COUNT = 8.0;
const int S_SNOW_PEAKS = 0;
const int S_ROCK_PEAKS = 1;
const int S_PINES = 2;
const int S_TREES = 3;
const int S_HILL = 4;
const int S_HILLS = 5;
const int S_GREY_BOULDERS = 6;
const int S_BROWN_BOULDERS = 7;

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

uint terrainByte(vec2 tile) {
  ivec2 tc = clamp(ivec2(floor(tile)), ivec2(0), ivec2(MAP_W - 1, MAP_H - 1));
  return texelFetch(uTerrainBytes, tc, 0).r;
}

bool isLand(uint b) {
  return (b & 0x80u) != 0u;
}

bool isPlayableLand(uint b) {
  return (b & 0x80u) != 0u && (b & 0x1fu) != 31u;
}

// Open water: not land, and not touching land.
bool isOpenWater(uint b) {
  return (b & 0xc0u) == 0u;
}

// 1 on land tiles that touch water (the coastline and river banks).
float coastAt(vec2 tile) {
  uint b = terrainByte(tile);
  return ((b & 0xc0u) == 0xc0u && (b & 0x1fu) != 31u) ? 1.0 : 0.0;
}

// Smoothed magnitude (0-30) around a tile.
float elevation(vec2 tile) {
  vec2 uv = tile / vec2(float(ELEV_W), float(ELEV_H));
  return texture(uElevation, uv).r * (255.0 / 8.0);
}

// Granite country (snowy grey ranges) versus warm bare rock, by region.
bool isGranite(vec2 tile) {
  return vnoise(tile / 170.0 + 2.0) > 0.52;
}

// Position of `p` inside a sprite's atlas cell (0-1), for a sprite centred
// on `c` and `size` tiles across, or (-1, -1) when outside it.
vec2 spriteUV(vec2 p, vec2 c, float size) {
  vec2 uv = (p - c) / size + 0.5;
  if (uv.x < 0.0 || uv.x >= 1.0 || uv.y < 0.0 || uv.y >= 1.0) return vec2(-1.0);
  return uv;
}

vec4 spriteTexel(int sprite, vec2 uv, bool flip) {
  float u = flip ? 1.0 - uv.x : uv.x;
  // Fetch by texel so neighbouring atlas cells can never bleed in.
  ivec2 size = textureSize(uSprites, 0);
  int cell = size.y;
  ivec2 tc = ivec2(sprite * cell + int(u * float(cell)), int(uv.y * float(cell)));
  if (tc.x >= size.x) return vec4(0.0);
  vec4 t = texelFetch(uSprites, tc, 0);
  return t.a < 0.5 ? vec4(0.0) : vec4(t.rgb, 1.0);
}

// The mountain of cell (`col`, `row`) at `p`. Cells are `cell` tiles wide
// and alternate rows are offset by half a cell, so the peaks interlock.
vec4 peakSprite(vec2 p, float col, float row, float cell) {
  vec2 id = vec2(col, row);
  vec2 seed = id + cell * 0.371;
  float h1 = hash21(seed);
  float h2 = hash21(seed * 1.7 + 11.3);
  float h3 = hash21(seed * 2.3 + 5.1);
  float shift = 0.5 * mod(row, 2.0);
  vec2 c = (id + vec2(0.5 + shift, 0.5) + (vec2(h1, h2) - 0.5) * 0.25) * cell;
  vec2 uv = spriteUV(p, c, cell * SPRITE_SPAN);
  if (uv.x < 0.0) return vec4(0.0);
  uint b = terrainByte(c);
  if (!isPlayableLand(b) || (b & 0x40u) != 0u) return vec4(0.0);
  float e = elevation(c);
  if (e < MOUNTAIN_AT) return vec4(0.0);
  // The highest ground is always snowy; elsewhere it goes by region.
  bool snowy = e > MOUNTAIN_AT + 3.5 || isGranite(c);
  // The light comes from the left, so mountains are never mirrored.
  return spriteTexel(snowy ? S_SNOW_PEAKS : S_ROCK_PEAKS, uv, false);
}

// Trees, hills and boulders: the sprite of woodland cell (`col`, `row`).
vec4 woodSprite(vec2 p, float col, float row, float cell) {
  vec2 id = vec2(col, row);
  vec2 seed = id + cell * 0.731;
  float h1 = hash21(seed);
  float h2 = hash21(seed * 1.9 + 3.7);
  float h3 = hash21(seed * 2.7 + 8.3);
  float shift = 0.5 * mod(row, 2.0);
  vec2 c = (id + vec2(0.5 + shift, 0.5) + (vec2(h1, h2) - 0.5) * 0.4) * cell;
  vec2 uv = spriteUV(p, c, cell * SPRITE_SPAN);
  if (uv.x < 0.0) return vec4(0.0);
  uint b = terrainByte(c);
  if (!isPlayableLand(b) || (b & 0x40u) != 0u) return vec4(0.0);
  float e = elevation(c);
  if (e >= MOUNTAIN_AT) return vec4(0.0);
  bool flip = h2 > 0.5;
  if (e < FOREST_AT) {
    // Open country: stray trees near the woods, the odd hill or boulder.
    if (e > FOREST_AT - 2.0 && h3 < 0.1) return spriteTexel(S_TREES, uv, flip);
    if (h3 > 0.985) return spriteTexel(S_HILL, uv, flip);
    if (h3 > 0.975) return spriteTexel(S_GREY_BOULDERS, uv, flip);
    return vec4(0.0);
  }
  // Clearings break up the forest with rolling hills and open grass.
  if (vnoise(c / 46.0 + 31.0) < 0.36) {
    if (h3 < 0.22) return spriteTexel(S_HILL, uv, flip);
    if (h3 < 0.4) return spriteTexel(S_HILLS, uv, flip);
    if (h3 < 0.5) return spriteTexel(S_TREES, uv, flip);
    return vec4(0.0);
  }
  // Just under the mountains the forest thins out among boulders.
  if (e > MOUNTAIN_AT - 1.5 && h3 < 0.3) {
    return spriteTexel(isGranite(c) ? S_GREY_BOULDERS : S_BROWN_BOULDERS, uv, flip);
  }
  // Pines in the high forest, broadleaf lower down, in drifts.
  float kind = vnoise(c / 60.0 + 5.0) + (e - FOREST_AT) * 0.08;
  return spriteTexel(kind > 0.62 ? S_PINES : S_TREES, uv, flip);
}

// Two small wave ticks out on open water.
vec4 waveSprite(vec2 p, vec2 id, float cell) {
  vec2 seed = id + cell * 0.531;
  float h1 = hash21(seed);
  float h2 = hash21(seed * 1.7 + 11.3);
  float h3 = hash21(seed * 2.3 + 5.1);
  if (h3 > 0.16) return vec4(0.0);
  vec2 c = (id + 0.5 + (vec2(h1, h2) - 0.5) * 0.3) * cell;
  vec2 uv = spriteUV(p, c, cell * 0.7);
  if (uv.x < 0.0) return vec4(0.0);
  vec2 foot = vec2(0.4, 0.3) * cell;
  if (!isOpenWater(terrainByte(c)) || !isOpenWater(terrainByte(c - foot)) ||
    !isOpenWater(terrainByte(c + foot))) {
    return vec4(0.0);
  }
  // Drawn on a 16x16 grid: a chevron at (3, 6) and another at (10, 8).
  ivec2 g = ivec2(uv * 16.0);
  int a = abs(g.x - 3);
  int b2 = abs(g.x - 10);
  bool tick = (a <= 2 && g.y == 6 + a) || (b2 <= 2 && g.y == 8 + b2);
  return tick ? vec4(0.86, 0.93, 1.0, 1.0) : vec4(0.0);
}

// All sprites for one level of detail. Sprites overlap their neighbours:
// rows further down the map are in front, and mountains stand in front of
// woodland.
vec4 glyphLayer(vec2 p, float cell, bool onLand) {
  if (!onLand) return waveSprite(p, floor(p / cell), cell);

  float pc = cell * PEAK_CELL;
  float row0 = floor(p.y / pc);
  for (int dr = 1; dr >= -1; dr--) {
    float row = row0 + float(dr);
    float col0 = floor(p.x / pc - 0.5 * mod(row, 2.0));
    vec4 s = peakSprite(p, col0, row, pc);
    if (s.a == 0.0) s = peakSprite(p, col0 - 1.0, row, pc);
    if (s.a == 0.0) s = peakSprite(p, col0 + 1.0, row, pc);
    if (s.a > 0.0) return s;
  }

  float wc = cell * WOOD_CELL;
  row0 = floor(p.y / wc);
  for (int dr = 1; dr >= -1; dr--) {
    float row = row0 + float(dr);
    float col0 = floor(p.x / wc - 0.5 * mod(row, 2.0));
    vec4 s = woodSprite(p, col0, row, wc);
    if (s.a == 0.0) s = woodSprite(p, col0 - 1.0, row, wc);
    if (s.a == 0.0) s = woodSprite(p, col0 + 1.0, row, wc);
    if (s.a > 0.0) return s;
  }
  return vec4(0.0);
}
#endif

void main() {
  vec3 col = texture(uTerrain, vUV).rgb;

#if FANTASY_GLYPHS
  vec2 p = vUV * vec2(float(MAP_W), float(MAP_H));
  // Size of one screen pixel in tiles (bigger = zoomed further out).
  float px = max(max(fwidth(p.x), fwidth(p.y)), 1e-4);
  vec2 tile = floor(p) + 0.5;

  uint centre = terrainByte(p);
  bool onLand = isPlayableLand(centre);
  // Thickness of rims and outlines: a couple of tiles, and never thinner
  // than a pixel and a half so they survive zooming out.
  float rim = max(2.0, 1.5 * px);
  if (onLand) {
    // --- Land: one flat colour, darker along its lower (south) edge so it
    // reads as raised above the water ---
    col = uPlains;
    if (!isLand(terrainByte(tile + vec2(0.0, rim))) ||
      !isLand(terrainByte(tile + vec2(0.0, 2.0 * rim)))) {
      col = uPlains * vec3(0.5, 0.62, 0.62);
    }
  } else if (!isLand(centre)) {
    // --- Water: two flat depths with a blocky edge between them. The pale
    // foam line along the coast is already in the baked colour. ---
    float depth = float(centre & 0x1fu);
    vec2 block = floor(tile / 6.0);
    float wobble = vnoise(block / 5.0) * 10.0;
    if ((centre & 0x40u) == 0u && depth + wobble > 17.0) col *= 0.8;
  }

  // --- Dark outline along the coast ---
  // Four taps across the pixel so the one-tile line stays continuous when
  // the camera is zoomed out past one tile per pixel.
  float o = 0.25 * px;
  float coast = 0.25 * (coastAt(p + vec2(-o, -o)) + coastAt(p + vec2(o, -o)) +
    coastAt(p + vec2(-o, o)) + coastAt(p + vec2(o, o)));
  col = mix(col, uPlains * vec3(0.28, 0.4, 0.42), coast);

  // --- Terrain sprites ---
  // Pick the cell size that keeps sprites near TARGET_PX on screen, and
  // cross-fade to the next size up as the camera zooms out.
  float lod = log2(px * TARGET_PX / BASE_CELL);
  float l0 = clamp(floor(lod), 0.0, MAX_LOD);
  float lf = clamp(lod - l0, 0.0, 1.0);
  // Close up (lod < 0) the sprites would outgrow the screen: fade them out.
  float near = smoothstep(-1.0, 0.0, lod);
  float t = (lf > 0.7 && l0 < MAX_LOD) ? smoothstep(0.7, 1.0, lf) : 0.0;
  vec4 glyph = glyphLayer(p, BASE_CELL * exp2(l0), onLand);
  col = mix(col, glyph.rgb, glyph.a * (1.0 - t) * near);
  if (t > 0.0) {
    vec4 next = glyphLayer(p, BASE_CELL * exp2(l0 + 1.0), onLand);
    col = mix(col, next.rgb, next.a * t * near);
  }
#endif

  fragColor = vec4(col, 1.0);
}
