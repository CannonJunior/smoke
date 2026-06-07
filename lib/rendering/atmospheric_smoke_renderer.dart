import 'dart:typed_data';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:vector_math/vector_math.dart';
import 'atmospheric_smoke_plume.dart';
import 'camera3d.dart';
import 'fire_shaders.dart';
import 'shader_program.dart';

/// Renders [SmokeColumnBillboard] segments as camera-facing quads.
///
/// VBO layout — 12 floats/vertex, stride = 48 bytes:
///   aWorldPos(3)  aCorner(2)  aColor(4)  aWidth(1)  aHeight(1)  aLayerIndex(1)
///   byte off: 0       12         20         36          40           44
///
/// Back-to-front sorting is the caller's responsibility ([AtmosphericSmokeSystem.getAllBillboards]).
class AtmosphericSmokeRenderer {
  final dynamic gl;

  ShaderProgram? _shader;
  dynamic _vbo, _ibo;
  Float32List _vboData = Float32List(0);
  bool _ready = false;

  static const int _floatsPerVertex = 12;
  static const int _vertsPerQuad    = 4;
  static const int _indicesPerQuad  = 6;
  static const int _maxQuads        = 1000;

  // Attribute locations
  late int _posLoc, _cornerLoc, _colorLoc, _widthLoc, _heightLoc, _layerLoc;

  // Corner offsets for a unit quad (two triangles)
  static const List<double> _corners = [-1.0, -1.0, 1.0, -1.0, 1.0, 1.0, -1.0, 1.0];

  bool get isReady => _ready;

  AtmosphericSmokeRenderer(this.gl) {
    try { _init(); }
    catch (e) { debugPrint('[AtmosphericSmokeRenderer] init failed: $e'); }
  }

  void _init() {
    _shader = ShaderProgram.fromSource(
        gl, atmosphericSmokeVertSrc, atmosphericSmokeFragSrc);

    _posLoc    = _shader!.getAttribLocation('aWorldPos');
    _cornerLoc = _shader!.getAttribLocation('aCorner');
    _colorLoc  = _shader!.getAttribLocation('aColor');
    _widthLoc  = _shader!.getAttribLocation('aWidth');
    _heightLoc = _shader!.getAttribLocation('aHeight');
    _layerLoc  = _shader!.getAttribLocation('aLayerIndex');

    _vboData = Float32List(_maxQuads * _vertsPerQuad * _floatsPerVertex);
    _vbo     = gl.createBuffer();
    _ibo     = _buildIndexBuffer();
    _ready   = true;
    debugPrint('[AtmosphericSmokeRenderer] ready (max $_maxQuads quads)');
  }

  dynamic _buildIndexBuffer() {
    final idx = Uint16List(_maxQuads * _indicesPerQuad);
    for (int i = 0; i < _maxQuads; i++) {
      final vb = i * 4, ib = i * 6;
      idx[ib] = vb; idx[ib+1] = vb+1; idx[ib+2] = vb+2;
      idx[ib+3] = vb; idx[ib+4] = vb+2; idx[ib+5] = vb+3;
    }
    final buf = gl.createBuffer();
    gl.bindBuffer(0x8893, buf);
    gl.bufferData(0x8893, idx, 0x88E4); // STATIC_DRAW
    gl.bindBuffer(0x8893, null);
    return buf;
  }

  void render(
      List<SmokeColumnBillboard> billboards, Camera3D camera, double time) {
    final s = _shader;
    if (!_ready || s == null || billboards.isEmpty) return;

    final viewMat  = camera.getViewMatrix();
    final viewProj = Matrix4.copy(camera.getProjectionMatrix())..multiply(viewMat);
    final camRight = Vector3(viewMat[0], viewMat[4], viewMat[8]);
    final camUp    = Vector3(viewMat[1], viewMat[5], viewMat[9]);

    final count = billboards.length.clamp(0, _maxQuads);

    for (int i = 0; i < count; i++) {
      final b  = billboards[i];
      final vi = i * _vertsPerQuad * _floatsPerVertex;
      for (int v = 0; v < _vertsPerQuad; v++) {
        final base = vi + v * _floatsPerVertex;
        _vboData[base]     = b.posX;
        _vboData[base + 1] = b.posY;
        _vboData[base + 2] = b.posZ;
        _vboData[base + 3] = _corners[v * 2];
        _vboData[base + 4] = _corners[v * 2 + 1];
        _vboData[base + 5] = b.color.r;
        _vboData[base + 6] = b.color.g;
        _vboData[base + 7] = b.color.b;
        _vboData[base + 8] = b.color.a;
        _vboData[base + 9]  = b.width;
        _vboData[base + 10] = b.height;
        _vboData[base + 11] = b.layerIndex;
      }
    }

    gl.bindBuffer(0x8892, _vbo);
    gl.bufferData(0x8892, _vboData, 0x88E8); // DYNAMIC_DRAW

    gl.depthMask(false);
    gl.enable(0x0BE2);              // BLEND
    gl.blendFunc(0x0302, 0x0303);   // SRC_ALPHA, ONE_MINUS_SRC_ALPHA

    s.use();
    s.setUniformMatrix4('uViewProj',    viewProj);
    s.setUniformVector3('uCameraRight', camRight);
    s.setUniformVector3('uCameraUp',    camUp);
    s.setUniformFloat('uTime', time);

    const byteStride = _floatsPerVertex * 4;
    _enable(_posLoc,    3, byteStride,  0);
    _enable(_cornerLoc, 2, byteStride, 12);
    _enable(_colorLoc,  4, byteStride, 20);
    _enable(_widthLoc,  1, byteStride, 36);
    _enable(_heightLoc, 1, byteStride, 40);
    _enable(_layerLoc,  1, byteStride, 44);

    gl.bindBuffer(0x8893, _ibo);
    gl.drawElements(0x0004, count * _indicesPerQuad, 0x1403, 0);

    for (final loc in [_posLoc, _cornerLoc, _colorLoc,
                        _widthLoc, _heightLoc, _layerLoc]) {
      if (loc >= 0) gl.disableVertexAttribArray(loc);
    }
    gl.bindBuffer(0x8892, null);
    gl.bindBuffer(0x8893, null);
    gl.disable(0x0BE2);
    gl.depthMask(true);
  }

  void _enable(int loc, int size, int stride, int offset) {
    if (loc < 0) return;
    gl.enableVertexAttribArray(loc);
    gl.vertexAttribPointer(loc, size, 0x1406, false, stride, offset);
  }

  void dispose() {
    if (!_ready) return;
    _shader?.dispose();
    gl.deleteBuffer(_vbo);
    gl.deleteBuffer(_ibo);
    _ready = false;
    debugPrint('[AtmosphericSmokeRenderer] disposed');
  }
}
