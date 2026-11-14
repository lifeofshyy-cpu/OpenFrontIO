/**
 * TerrainPass — renders the terrain map as a textured quad.
 *
 * Initial upload happens once; incremental updates flow through
 * applyTerrainRects() so water-nuke conversions (land → water) are reflected
 * live. Vertex shader transforms the map quad by the camera mat3; fragment
 * shader samples the RGBA8 terrain texture with nearest-neighbour filtering
 * so each terrain cell stays pixel-crisp at every zoom level.
 */

import { assetUrl } from "@openfront/shared/AssetUrls";
import type { TerrainRect } from "../../types";
import terrainFragSrc from "../shaders/terrain/terrain.frag.glsl?raw";
import terrainVertSrc from "../shaders/terrain/terrain.vert.glsl?raw";
import {
  buildTerrainRGBA,
  encodeTerrainTile,
  TerrainColorOverrides,
} from "../utils/ColorUtils";
import { buildElevationField, ELEVATION_SCALE } from "../utils/ElevationField";
import {
  createMapQuad,
  createProgram,
  createTexture2D,
  shaderSrc,
} from "../utils/GlUtils";

// Land colour used when the caller supplies none.
const DEFAULT_PLAINS = [142, 194, 60] as const;

const terrainSpritesUrl = assetUrl("atlases/terrain-sprites.png");

// ---------------------------------------------------------------------------
// TerrainPass
// ---------------------------------------------------------------------------

export class TerrainPass {
  private program: WebGLProgram;
  private tex: WebGLTexture;
  private vao: WebGLVertexArrayObject;
  private uCamera: WebGLUniformLocation;
  private uTerrain: WebGLUniformLocation | null;
  private uTerrainBytes: WebGLUniformLocation | null;
  private uElevation: WebGLUniformLocation | null;
  // Smoothed land elevation (R8); only built for the fantasy-map look.
  private elevationTex: WebGLTexture | null = null;
  private uPlains: WebGLUniformLocation | null;
  private uSprites: WebGLUniformLocation | null;
  // Terrain sprite atlas (mountains, trees, hills, boulders). A transparent
  // placeholder until the image has loaded.
  private spriteTex: WebGLTexture | null = null;
  private disposed = false;
  private mapW: number;
  private mapH: number;
  // Base ocean (deep water) color; reused by applyTerrainRects and rebuilds.
  private terrainColors: TerrainColorOverrides | undefined;
  // Scratch RGBA buffer for rect sub-uploads; grown as needed and reused
  // across applyTerrainRects calls.
  private rgbaScratch = new Uint8Array(0);

  constructor(
    private gl: WebGL2RenderingContext,
    // Regenerates current per-tile terrain bytes (reflecting water-nuke
    // conversions) for the rare full re-bake in setTerrainColors. A provider
    // instead of a retained buffer: terrain bytes are map-sized (8 MB on the
    // giant map).
    private terrainSource: () => Uint8Array,
    terrainBytes: Uint8Array,
    mapW: number,
    mapH: number,
    terrainColors?: TerrainColorOverrides,
    // Raw terrain bytes (R8UI), owned by the caller. When given, the shader
    // paints the fantasy-map look from it (flat bright land, outlined
    // coasts, sprite glyphs); without it the baked colours are drawn as-is.
    private terrainBytesTex: WebGLTexture | null = null,
  ) {
    this.mapW = mapW;
    this.mapH = mapH;
    this.terrainColors = terrainColors;
    const fragDefines: Record<string, number> = {
      MAP_W: mapW,
      MAP_H: mapH,
      FANTASY_GLYPHS: terrainBytesTex ? 1 : 0,
    };
    if (terrainBytesTex) {
      const field = buildElevationField(terrainBytes, mapW, mapH);
      fragDefines.ELEV_W = field.width * ELEVATION_SCALE;
      fragDefines.ELEV_H = field.height * ELEVATION_SCALE;
      gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
      this.elevationTex = createTexture2D(gl, {
        width: field.width,
        height: field.height,
        internalFormat: gl.R8,
        format: gl.RED,
        type: gl.UNSIGNED_BYTE,
        data: field.data,
        filter: gl.LINEAR,
      });
      this.spriteTex = createTexture2D(gl, {
        width: 1,
        height: 1,
        internalFormat: gl.RGBA8,
        format: gl.RGBA,
        type: gl.UNSIGNED_BYTE,
        data: new Uint8Array(4),
        filter: gl.NEAREST,
      });
      void this.loadSprites();
    }
    this.program = createProgram(
      gl,
      shaderSrc(terrainVertSrc, { MAP_W: mapW, MAP_H: mapH }),
      shaderSrc(terrainFragSrc, fragDefines),
      "TerrainPass",
    );
    this.uCamera = gl.getUniformLocation(this.program, "uCamera")!;
    this.uTerrain = gl.getUniformLocation(this.program, "uTerrain");
    this.uTerrainBytes = gl.getUniformLocation(this.program, "uTerrainBytes");
    this.uElevation = gl.getUniformLocation(this.program, "uElevation");
    this.uPlains = gl.getUniformLocation(this.program, "uPlains");
    this.uSprites = gl.getUniformLocation(this.program, "uSprites");

    this.tex = createTexture2D(gl, {
      width: mapW,
      height: mapH,
      internalFormat: gl.RGBA8,
      format: gl.RGBA,
      type: gl.UNSIGNED_BYTE,
      data: buildTerrainRGBA(terrainBytes, mapW, mapH, terrainColors),
      filter: gl.NEAREST, // pixel-crisp at all zoom levels
    });

    this.vao = createMapQuad(gl, mapW, mapH);
  }

  /**
   * Replace the base terrain colors and re-upload the whole terrain texture.
   * Called when the user changes the terrain colors in graphics settings.
   */
  /** Load the terrain sprite atlas and swap it in for the placeholder. */
  private async loadSprites(): Promise<void> {
    const img = new Image();
    img.crossOrigin = "anonymous";
    img.src = terrainSpritesUrl;
    try {
      await img.decode();
    } catch {
      // Without the atlas the map simply has no terrain sprites.
      return;
    }
    if (this.disposed || !this.spriteTex) return;
    const gl = this.gl;
    gl.bindTexture(gl.TEXTURE_2D, this.spriteTex);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, img);
  }

  setTerrainColors(terrainColors?: TerrainColorOverrides): void {
    this.terrainColors = terrainColors;
    const gl = this.gl;
    gl.bindTexture(gl.TEXTURE_2D, this.tex);
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
    gl.texSubImage2D(
      gl.TEXTURE_2D,
      0,
      0,
      0,
      this.mapW,
      this.mapH,
      gl.RGBA,
      gl.UNSIGNED_BYTE,
      buildTerrainRGBA(
        this.terrainSource(),
        this.mapW,
        this.mapH,
        terrainColors,
      ),
    );
  }

  /**
   * Update terrain regions in-place (e.g. land→water from a water nuke).
   * Each rect's terrain bytes are stored row-major, concatenated in `bytes`
   * in rect order. One texSubImage2D per rect — a massive bomb changes tens
   * of thousands of tiles, so per-tile 1×1 uploads are too slow. A later full
   * re-upload (setTerrainColors) regenerates from terrainSource, whose
   * backing game map already reflects these conversions.
   */
  applyTerrainRects(rects: readonly TerrainRect[], bytes: Uint8Array): void {
    if (rects.length === 0) return;
    const gl = this.gl;
    gl.bindTexture(gl.TEXTURE_2D, this.tex);
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
    let offset = 0;
    for (const r of rects) {
      const count = r.w * r.h;
      if (this.rgbaScratch.length < count * 4) {
        this.rgbaScratch = new Uint8Array(count * 4);
      }
      for (let i = 0; i < count; i++) {
        encodeTerrainTile(
          bytes[offset + i],
          this.rgbaScratch,
          i * 4,
          this.terrainColors,
        );
      }
      gl.texSubImage2D(
        gl.TEXTURE_2D,
        0,
        r.x,
        r.y,
        r.w,
        r.h,
        gl.RGBA,
        gl.UNSIGNED_BYTE,
        this.rgbaScratch,
        0,
      );
      offset += count;
    }
  }

  /** Render the terrain. Call with depth test disabled, no blending. */
  draw(cameraMatrix: Float32Array): void {
    const gl = this.gl;
    gl.useProgram(this.program);
    gl.uniformMatrix3fv(this.uCamera, false, cameraMatrix);

    if (this.terrainBytesTex) {
      gl.activeTexture(gl.TEXTURE1);
      gl.bindTexture(gl.TEXTURE_2D, this.terrainBytesTex);
      gl.uniform1i(this.uTerrainBytes, 1);
      gl.activeTexture(gl.TEXTURE2);
      gl.bindTexture(gl.TEXTURE_2D, this.elevationTex);
      gl.uniform1i(this.uElevation, 2);
      const c = this.terrainColors;
      const [pr, pg, pb] = c?.plainsColor ?? DEFAULT_PLAINS;
      gl.uniform3f(this.uPlains, pr / 255, pg / 255, pb / 255);
      gl.activeTexture(gl.TEXTURE3);
      gl.bindTexture(gl.TEXTURE_2D, this.spriteTex);
      gl.uniform1i(this.uSprites, 3);
    }
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, this.tex);
    gl.uniform1i(this.uTerrain, 0);

    gl.bindVertexArray(this.vao);
    gl.drawArrays(gl.TRIANGLES, 0, 6);
  }

  dispose(): void {
    const gl = this.gl;
    gl.deleteProgram(this.program);
    gl.deleteTexture(this.tex);
    if (this.elevationTex) gl.deleteTexture(this.elevationTex);
    if (this.spriteTex) gl.deleteTexture(this.spriteTex);
    this.disposed = true;
    // VAO + buffer leak is acceptable on dispose (context is being destroyed)
  }
}
