// Generates resources/atlases/icon-atlas.png: the pixel-art building sprites
// StructurePass draws for structures (castle, harbour, workshop, fort, watch
// tower, missile silo), one 64x64 cell per structure in a single row.
//
//   node scripts/gen-structure-sprites.mjs
//
// Each sprite is 16x16 art pixels, drawn 4x. Characters:
//   .  transparent        #  outline          k  window / doorway
//   S  light stone        s  stone            d  dark stone
//   W  wood               w  dark wood        o  white
//   r  red                y  lamplight
//   p  owner colour       q  owner colour, shaded
// The owner-colour pixels are written as pure magenta; the structure shader
// swaps them for the owning player's colour.
// Rows shorter than 16 are padded on the right; missing rows are added on top.
import fs from "node:fs";
import path from "node:path";
import zlib from "node:zlib";
import { fileURLToPath } from "node:url";

// In StructurePass's atlas column order.
const SPRITES = {
  // City → castle: a keep between two towers, flying the owner's flag.
  city: `
.......#pp......
.......#pppp....
.......#pp......
.....#S#S#S#....
.#S#.#SSSSs#.#S#
#SSs##SkSSs##SSd
#Sss#SSSSSss#Ssd
#SkS#SSkSSss#Skd
#Sss#SSSSSss#Ssd
#SSSSSSSSSsssssd
#SSSS#kkk#sssssd
#SsSS#kwk#ssdssd
#SSSS#kwk#sssssd
################`,
  // Port → harbour: a quay house, a wooden pier and a moored boat.
  port: `
.....pppp.......
....pppppq......
...#pppppqq#....
...#SSSSssd#....
...#SkSSksd#.#..
...#SSSSssd#.##.
.WWWWWWWWWWW.#o#
.w.w.w.w.w.w#ooo
.w...w...w.#WWWW
............#ww#`,
  // Factory → workshop: a long roofed hall with a smoking chimney.
  factory: `
...........oo...
..........oo....
...........#d#..
...........#d#..
..pppppppq.#d#..
.pppppppppq#d#..
#ppppppppqq#d#..
#SSSSSSSSss#sd#.
#SkSSkSSSss#sd#.
#SSSSSSSSss#sd#.
#SS#Ww#SSss#sd#.
#SS#Ww#SSss#sd#.
###############.`,
  // Defense Post → fort: a stout round tower with battlements and a banner.
  fort: `
......#pp.......
......#pppp.....
......#pp.......
...#S#S#S#S#....
...#SSSSSSs#....
....#SSSSsd#....
....#SkSSsd#....
....#SSSSsd#....
....#SSkSsd#....
....#SSSSsd#....
...#SSSSSssd#...
...#SS#kk#sd#...
...#SS#kk#sd#...
...##########...`,
  // SAM Launcher → watch tower: a wooden lookout on a stone base, bolt
  // aimed at the sky.
  sam: `
.............#..
............#o..
....pppp...#o...
...pppppq.#w....
..#pppppq#w.....
..#WWWWWw#......
..#WkWWkw#......
..#WWWWWw#......
...#SSSs#.......
...#SSSs#.......
...#SkSs#.......
...#SSSs#.......
..#SSSSsd#......
..########......`,
  // Missile Silo: a rocket standing in a stone ring.
  silo: `
.......##.......
......#rr#......
......#rr#......
.....#oooo#.....
.....#oooo#.....
.....#oppo#.....
.....#oqqo#.....
.....#oooo#.....
....##oooo##....
...#S#oooo#S#...
..#SS#o##o#Ssd#.
..#SSS#..#Sssd#.
..#SSSSSSSsssd#.
..############..`,
};

const PALETTE = {
  ".": [0, 0, 0, 0],
  "#": [38, 32, 44, 255],
  k: [52, 44, 60, 255],
  S: [204, 206, 212, 255],
  s: [160, 163, 172, 255],
  d: [112, 115, 128, 255],
  W: [176, 122, 74, 255],
  w: [122, 80, 50, 255],
  o: [246, 246, 240, 255],
  r: [214, 64, 56, 255],
  y: [250, 220, 120, 255],
  p: [255, 0, 255, 255],
  q: [184, 0, 184, 255],
};

const ART = 16;
const SCALE = 4;
const CELL = ART * SCALE;
const names = Object.keys(SPRITES);
const width = CELL * names.length;
const height = CELL;
const pixels = Buffer.alloc(width * height * 4);

names.forEach((name, column) => {
  const lines = SPRITES[name].split("\n").filter((l) => l.length > 0);
  if (lines.length > ART) throw new Error(`${name}: more than ${ART} rows`);
  while (lines.length < ART) lines.unshift("");
  lines.forEach((line, y) => {
    if (line.length > ART) throw new Error(`${name}: row wider than ${ART}`);
    [...line.padEnd(ART, ".")].forEach((ch, x) => {
      const rgba = PALETTE[ch];
      if (!rgba) throw new Error(`${name}: bad character "${ch}"`);
      for (let dy = 0; dy < SCALE; dy++) {
        for (let dx = 0; dx < SCALE; dx++) {
          const px = column * CELL + x * SCALE + dx;
          const py = y * SCALE + dy;
          pixels.set(rgba, (py * width + px) * 4);
        }
      }
    });
  });
});

// Minimal PNG writer (8-bit RGBA, no filtering).
const crcTable = new Int32Array(256).map((_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c;
});
const crc32 = (buf) => {
  let c = -1;
  for (const byte of buf) c = crcTable[(c ^ byte) & 0xff] ^ (c >>> 8);
  return (c ^ -1) >>> 0;
};
const chunk = (type, data) => {
  const body = Buffer.concat([Buffer.from(type, "ascii"), data]);
  const out = Buffer.alloc(body.length + 8);
  out.writeUInt32BE(data.length, 0);
  body.copy(out, 4);
  out.writeUInt32BE(crc32(body), body.length + 4);
  return out;
};
const header = Buffer.alloc(13);
header.writeUInt32BE(width, 0);
header.writeUInt32BE(height, 4);
header.set([8, 6, 0, 0, 0], 8);
const raw = Buffer.alloc((width * 4 + 1) * height);
for (let y = 0; y < height; y++) {
  pixels.copy(raw, y * (width * 4 + 1) + 1, y * width * 4, (y + 1) * width * 4);
}
const png = Buffer.concat([
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
  chunk("IHDR", header),
  chunk("IDAT", zlib.deflateSync(raw, { level: 9 })),
  chunk("IEND", Buffer.alloc(0)),
]);

const file = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  "../resources/atlases/icon-atlas.png",
);
fs.writeFileSync(file, png);
console.log(`wrote ${names.length} sprites (${width}x${height})`);
