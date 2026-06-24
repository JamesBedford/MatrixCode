// Persistent cols x rows RGBA8 texture holding the packed simulation state.
// Uploaded each frame via texSubImage2D (no per-frame allocation). NEAREST
// filtering so the glyph shader reads crisp per-cell values.

export class StateTexture {
  readonly texture: WebGLTexture;
  private gl: WebGL2RenderingContext;
  cols: number;
  rows: number;

  constructor(gl: WebGL2RenderingContext, cols: number, rows: number) {
    this.gl = gl;
    this.cols = cols;
    this.rows = rows;
    const tex = gl.createTexture();
    if (!tex) throw new Error("Failed to create state texture");
    this.texture = tex;
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    this.allocate(cols, rows);
  }

  private allocate(cols: number, rows: number): void {
    const gl = this.gl;
    gl.bindTexture(gl.TEXTURE_2D, this.texture);
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, cols, rows, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
  }

  resize(cols: number, rows: number): void {
    if (cols === this.cols && rows === this.rows) return;
    this.cols = cols;
    this.rows = rows;
    this.allocate(cols, rows);
  }

  /** Upload packed state (length must be cols*rows*4). */
  upload(data: Uint8Array): void {
    const gl = this.gl;
    gl.bindTexture(gl.TEXTURE_2D, this.texture);
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
    gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, this.cols, this.rows, gl.RGBA, gl.UNSIGNED_BYTE, data);
  }

  dispose(): void {
    this.gl.deleteTexture(this.texture);
  }
}
