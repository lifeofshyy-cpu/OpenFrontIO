/**
 * CloudPass — drifting pixel-art clouds over the whole map.
 *
 * Purely decorative and fully procedural (no textures). The clouds are
 * translucent, only show once the camera is zoomed out, and fade away as it
 * zooms in. Tuned by `settings.clouds`.
 */

import type { RenderSettings } from "../RenderSettings";
import { createMapQuad, createProgram } from "../utils/GlUtils";

import cloudsFragSrc from "../shaders/clouds/clouds.frag.glsl?raw";
import overlayVertSrc from "../shaders/map-overlay/overlay.vert.glsl?raw";

export class CloudPass {
  private gl: WebGL2RenderingContext;
  private program: WebGLProgram;
  private vao: WebGLVertexArrayObject;

  private uCamera: WebGLUniformLocation;
  private uTime: WebGLUniformLocation;
  private uOpacity: WebGLUniformLocation;
  private uSpeed: WebGLUniformLocation;
  private uCoverage: WebGLUniformLocation;

  private settings: RenderSettings;
  private startTime = performance.now();

  constructor(
    gl: WebGL2RenderingContext,
    mapW: number,
    mapH: number,
    settings: RenderSettings,
  ) {
    this.gl = gl;
    this.settings = settings;

    this.program = createProgram(
      gl,
      overlayVertSrc,
      cloudsFragSrc,
      "CloudPass",
    );
    this.uCamera = gl.getUniformLocation(this.program, "uCamera")!;
    this.uTime = gl.getUniformLocation(this.program, "uTime")!;
    this.uOpacity = gl.getUniformLocation(this.program, "uOpacity")!;
    this.uSpeed = gl.getUniformLocation(this.program, "uSpeed")!;
    this.uCoverage = gl.getUniformLocation(this.program, "uCoverage")!;

    this.vao = createMapQuad(gl, mapW, mapH);
  }

  /** Expects alpha blending (SRC_ALPHA, ONE_MINUS_SRC_ALPHA) to be on. */
  draw(cameraMatrix: Float32Array): void {
    const clouds = this.settings.clouds;
    if (!clouds.enabled || clouds.opacity <= 0) return;
    const gl = this.gl;

    gl.useProgram(this.program);
    gl.uniformMatrix3fv(this.uCamera, false, cameraMatrix);
    gl.uniform1f(this.uTime, (performance.now() - this.startTime) / 1000);
    gl.uniform1f(this.uOpacity, clouds.opacity);
    gl.uniform1f(this.uSpeed, clouds.speed);
    gl.uniform1f(this.uCoverage, clouds.coverage);

    gl.bindVertexArray(this.vao);
    gl.drawArrays(gl.TRIANGLES, 0, 6);
  }

  dispose(): void {
    const gl = this.gl;
    gl.deleteProgram(this.program);
    gl.deleteVertexArray(this.vao);
  }
}
