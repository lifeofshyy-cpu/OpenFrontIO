/**
 * Smoothed land elevation, for the fantasy-map terrain style.
 *
 * Raw terrain magnitude is speckled (mountain tiles mixed into highland), so
 * zones drawn straight from it look like noise. This averages the magnitude
 * of land tiles over blocks of ELEVATION_SCALE × ELEVATION_SCALE tiles and
 * blurs the result, giving a small texture the terrain shader samples with
 * bilinear filtering to get clean, blobby terrain zones.
 *
 * Self-contained on purpose (no imports).
 */

/** Tiles per elevation texel, along each axis. */
export const ELEVATION_SCALE = 4;

/** Stored value = average magnitude (0-30) × this. */
export const ELEVATION_UNIT = 8;

export interface ElevationField {
  /** One byte per texel, row-major: average magnitude × ELEVATION_UNIT. */
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

  // Per block: summed magnitude and count of playable land tiles.
  let sum = new Float32Array(size);
  let count = new Float32Array(size);
  for (let y = 0; y < mapH; y++) {
    const row = Math.floor(y / scale) * width;
    const base = y * mapW;
    for (let x = 0; x < mapW; x++) {
      const b = terrainBytes[base + x];
      const magnitude = b & 0x1f;
      // Land, and not the impassable marker (magnitude 31).
      if ((b & 0x80) !== 0 && magnitude !== 31) {
        const i = row + Math.floor(x / scale);
        sum[i] += magnitude;
        count[i] += 1;
      }
    }
  }

  // Two 3×3 box blurs of both arrays. Dividing blurred sum by blurred count
  // averages over land only, so coasts aren't dragged down by the sea.
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
  for (let pass = 0; pass < 2; pass++) {
    box3(sum, scratch);
    [sum, scratch] = [scratch, sum];
    box3(count, scratch);
    [count, scratch] = [scratch, count];
  }

  const data = new Uint8Array(size);
  for (let i = 0; i < size; i++) {
    if (count[i] > 0) {
      data[i] = Math.min(255, Math.round((sum[i] / count[i]) * unit));
    }
  }
  return { data, width, height };
}
