import * as twgl from "twgl.js";

/**
 * A single triangle that covers the whole viewport in clip space. Vertices
 * (-1,-1) (3,-1) (-1,3) overshoot the screen so the visible region is fully
 * covered with no seam.
 */
export function createFullscreenTri(gl: WebGL2RenderingContext): twgl.BufferInfo {
  return twgl.createBufferInfoFromArrays(gl, {
    position: { numComponents: 2, data: [-1, -1, 3, -1, -1, 3] },
  });
}

/** Draw the full-screen triangle with the given program + uniforms. */
export function drawFullscreen(
  gl: WebGL2RenderingContext,
  programInfo: twgl.ProgramInfo,
  bufferInfo: twgl.BufferInfo,
  uniforms: Record<string, unknown>,
): void {
  gl.useProgram(programInfo.program);
  twgl.setBuffersAndAttributes(gl, programInfo, bufferInfo);
  twgl.setUniforms(programInfo, uniforms);
  twgl.drawBufferInfo(gl, bufferInfo, gl.TRIANGLES, 3);
}
