/**
 * Smoothed terrain fields for the fantasy-map terrain style.
 *
 * Raw terrain magnitude is speckled (mountain tiles mixed into highland), so
 * anything drawn straight from it looks like noise. This works on blocks of
 * ELEVATION_SCALE × ELEVATION_SCALE tiles and produces a small two-channel
 * texture the terrain shader samples with bilinear filtering:
 *
 *   R: average magnitude of nearby land × ELEVATION_UNIT — where the hill
 *      country and mountains are, as clean blobby zones.
 *   G: share of nearby tiles that are land × 255 — low along coasts, high
 *      deep inland — used to paint land differently near the sea.
 *
 * Self-contained on purpose (no imports).
 */

/** Tiles per field texel, along each axis. */
export const ELEVATION_SCALE = 4;

/** Stored elevation = average magnitude (0-30) × this. */
export const ELEVATION_UNIT = 8;

export interface ElevationField {
  /** Two bytes per texel (elevation, land share), row-major. */
  data: Uint8Array;
  width: number;
  height: number;
}

export function buildElevationField(
  terrainBytes: Uint8Array,
  mapW: number,
  mapH: number,
): ElevationField {
  const scale = 4;
  const unit = 8;
  const width = Math.ceil(mapW / scale);
  const height = Math.ceil(mapH / scale);
  const size = width * height;

  // Per block: summed magnitude and count of playable land tiles, and the
  // number of tiles the block holds (blocks on the far edges can be partial).
  let sum = new Float32Array(size);
  let count = new Float32Array(size);
  let area = new Float32Array(size);
  for (let y = 0; y < mapH; y++) {
    const row = Math.floor(y / scale) * width;
    const base = y * mapW;
    for (let x = 0; x < mapW; x++) {
      const i = row + Math.floor(x / scale);
      area[i] += 1;
      const b = terrainBytes[base + x];
      const magnitude = b & 0x1f;
      // Land, and not the impassable marker (magnitude 31).
      if ((b & 0x80) !== 0 && magnitude !== 31) {
        sum[i] += magnitude;
        count[i] += 1;
      }
    }
  }

  const box3 = (src: Float32Array, dst: Float32Array) => {
    for (let y = 0; y < height; y++) {
      const y0 = Math.max(0, y - 1);
      const y1 = Math.min(height - 1, y + 1);
      for (let x = 0; x < width; x++) {
        const x0 = Math.max(0, x - 1);
        const x1 = Math.min(width - 1, x + 1);
        let acc = 0;
        for (let yy = y0; yy <= y1; yy++) {
          const r = yy * width;
          for (let xx = x0; xx <= x1; xx++) acc += src[r + xx];
        }
        dst[y * width + x] = acc;
      }
    }
  };
  let scratch = new Float32Array(size);
  const data = new Uint8Array(size * 2);

  // Elevation: two 3×3 box blurs. Dividing blurred sum by blurred count
  // averages over land only, so coasts aren't dragged down by the sea.
  for (let pass = 0; pass < 2; pass++) {
    box3(sum, scratch);
    [sum, scratch] = [scratch, sum];
    box3(count, scratch);
    [count, scratch] = [scratch, count];
    box3(area, scratch);
    [area, scratch] = [scratch, area];
  }
  for (let i = 0; i < size; i++) {
    if (count[i] > 0) {
      data[i * 2] = Math.min(255, Math.round((sum[i] / count[i]) * unit));
    }
  }

  // Land share: blurred twice more, so it falls off over a wider band.
  for (let pass = 0; pass < 2; pass++) {
    box3(count, scratch);
    [count, scratch] = [scratch, count];
    box3(area, scratch);
    [area, scratch] = [scratch, area];
  }
  for (let i = 0; i < size; i++) {
    if (area[i] > 0) {
      data[i * 2 + 1] = Math.min(255, Math.round((count[i] / area[i]) * 255));
    }
  }
  return { data, width, height };
}
