import 'dart:typed_data';
import 'package:flutter/foundation.dart' show debugPrint;
import 'fire_shaders.dart';
import 'shader_program.dart';

// ── HeatDistortionPass ────────────────────────────────────────────────────────
// Two-pass post-processing effect:
//   Pass 1 — scene renders into an offscreen framebuffer texture.
//   Pass 2 — a full-screen quad samples that texture with animated UV noise,
//             distortion strength driven by uHeat (0=none, 1=max).
//
// The pass is optional; if WebGL framebuffer creation fails the class degrades
// gracefully (isAvailable == false) and the caller skips both passes.

class HeatDistortionPass {
  final dynamic gl;

  dynamic _fbo;
  dynamic _fboTex;
  dynamic _quadVbo;
  late ShaderProgram _shader;
  late int _posLoc, _uvLoc;

  int _width  = 0;
  int _height = 0;
  bool _available = false;

  HeatDistortionPass(this.gl);

  bool get isAvailable => _available;

  // ── Initialisation (called after canvas size is known) ─────────────────────

  void init(int width, int height) {
    try {
      _shader  = ShaderProgram.fromSource(gl, heatDistortVertShader, heatDistortFragShader);
      _posLoc  = _shader.getAttribLocation('aPosition');
      _uvLoc   = _shader.getAttribLocation('aTexCoord');
      _quadVbo = _buildQuadVbo();
      _resize(width, height);
      _available = true;
      debugPrint('[HeatDistortionPass] initialized ${width}x${height}');
    } catch (e) {
      debugPrint('[HeatDistortionPass] init failed (will skip): $e');
    }
  }

  // ── Resize: recreate FBO texture when canvas dimensions change ─────────────

  void resize(int width, int height) {
    if (!_available) return;
    if (width == _width && height == _height) return;
    _destroyFbo();
    _resize(width, height);
  }

  void _resize(int width, int height) {
    _width  = width;
    _height = height;

    _fboTex = gl.createTexture();
    gl.bindTexture(0x0DE1, _fboTex);           // TEXTURE_2D
    gl.texImage2D(0x0DE1, 0, 0x1908,           // RGBA
        width, height, 0, 0x1908, 0x1401, null); // UNSIGNED_BYTE
    gl.texParameteri(0x0DE1, 0x2801, 0x2601);  // MIN_FILTER = LINEAR
    gl.texParameteri(0x0DE1, 0x2800, 0x2601);  // MAG_FILTER = LINEAR
    gl.texParameteri(0x0DE1, 0x2802, 0x812F);  // WRAP_S = CLAMP_TO_EDGE
    gl.texParameteri(0x0DE1, 0x2803, 0x812F);  // WRAP_T = CLAMP_TO_EDGE
    gl.bindTexture(0x0DE1, null);

    _fbo = gl.createFramebuffer();
    gl.bindFramebuffer(0x8D40, _fbo);          // FRAMEBUFFER
    gl.framebufferTexture2D(
        0x8D40, 0x8CE0, 0x0DE1, _fboTex, 0);  // COLOR_ATTACHMENT0
    final status = gl.checkFramebufferStatus(0x8D40);
    gl.bindFramebuffer(0x8D40, null);

    if (status != 0x8CD5) { // FRAMEBUFFER_COMPLETE
      debugPrint('[HeatDistortionPass] framebuffer incomplete: $status');
      _available = false;
    }
  }

  // ── Bind FBO: redirect subsequent draws into the offscreen texture ─────────

  void bindFbo() {
    if (!_available) return;
    gl.bindFramebuffer(0x8D40, _fbo);
  }

  // ── Apply distortion pass: blit FBO texture to screen with distortion ──────

  void apply(double heatIntensity, double time) {
    if (!_available) return;

    // Restore default framebuffer (screen)
    gl.bindFramebuffer(0x8D40, null);

    // Full clear is not needed — the quad covers the whole screen.
    gl.disable(0x0B71);    // DEPTH_TEST off for screen-space quad
    gl.disable(0x0BE2);    // BLEND off

    _shader.use();

    // Bind the scene texture to unit 0
    gl.activeTexture(0x84C0);      // TEXTURE0
    gl.bindTexture(0x0DE1, _fboTex);
    _shader.setUniformInt('uScene', 0);
    _shader.setUniformFloat('uHeat', heatIntensity.clamp(0.0, 1.0));
    _shader.setUniformFloat('uTime', time);

    gl.bindBuffer(0x8892, _quadVbo);

    // Interleaved: [posX, posY, uvX, uvY]  stride = 16 bytes
    if (_posLoc >= 0) {
      gl.enableVertexAttribArray(_posLoc);
      gl.vertexAttribPointer(_posLoc, 2, 0x1406, false, 16, 0);
    }
    if (_uvLoc >= 0) {
      gl.enableVertexAttribArray(_uvLoc);
      gl.vertexAttribPointer(_uvLoc, 2, 0x1406, false, 16, 8);
    }

    gl.drawArrays(0x0005, 0, 4);   // TRIANGLE_STRIP, 4 vertices

    if (_posLoc >= 0) gl.disableVertexAttribArray(_posLoc);
    if (_uvLoc  >= 0) gl.disableVertexAttribArray(_uvLoc);
    gl.bindBuffer(0x8892, null);
    gl.bindTexture(0x0DE1, null);

    // Restore render state for subsequent passes (geometry, HUD)
    gl.enable(0x0B71);
  }

  // ── Quad VBO ───────────────────────────────────────────────────────────────

  dynamic _buildQuadVbo() {
    // Full-screen triangle strip in NDC [-1,+1], UV [0,1].
    // Interleaved: [posX, posY, uvX, uvY] × 4 vertices.
    final data = Float32List.fromList([
      -1.0, -1.0,  0.0, 0.0,
       1.0, -1.0,  1.0, 0.0,
      -1.0,  1.0,  0.0, 1.0,
       1.0,  1.0,  1.0, 1.0,
    ]);
    final buf = gl.createBuffer();
    gl.bindBuffer(0x8892, buf);
    gl.bufferData(0x8892, data, 0x88E4);  // STATIC_DRAW
    gl.bindBuffer(0x8892, null);
    return buf;
  }

  // ── Cleanup ────────────────────────────────────────────────────────────────

  void _destroyFbo() {
    if (_fbo    != null) { gl.deleteFramebuffer(_fbo);  _fbo    = null; }
    if (_fboTex != null) { gl.deleteTexture(_fboTex);   _fboTex = null; }
  }

  void dispose() {
    if (!_available) return;
    _destroyFbo();
    if (_quadVbo != null) gl.deleteBuffer(_quadVbo);
    _shader.dispose();
    _available = false;
    debugPrint('[HeatDistortionPass] disposed');
  }
}
