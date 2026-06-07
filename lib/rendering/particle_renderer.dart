import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:vector_math/vector_math.dart';
import 'camera3d.dart';
import 'fire_shaders.dart';
import 'particle_system.dart';
import 'shader_program.dart';

/// Bundles a compiled ShaderProgram with its attribute locations for the
/// standard particle billboard vertex layout (12 floats/vertex).
class _ShaderSet {
  final ShaderProgram shader;
  final int posLoc, cornerLoc, colorLoc, sizeLoc, rotLoc, fuelLoc;
  const _ShaderSet(this.shader, this.posLoc, this.cornerLoc,
      this.colorLoc, this.sizeLoc, this.rotLoc, this.fuelLoc);
}

/// Renders CPU particles as billboard quads with a two-pass strategy:
/// fire + ember (additive) first, then smoke (alpha blend) sorted back-to-front.
///
/// VBO layout — 12 floats/vertex, stride = 48 bytes:
///   aWorldPos(3)  aCorner(2)  aColor(4)  aSize(1)  aRotation(1)  aFuelFraction(1)
///   byte off: 0       12          20        36          40              44
///
/// Set [toonMode] = true to switch to the cel-shaded (Approach A) shader pair.
class ParticleRenderer {
  final dynamic gl;

  late _ShaderSet _classicFire;
  late _ShaderSet _classicSmoke;
  _ShaderSet? _toonFire;
  _ShaderSet? _toonSmoke;

  /// Toggle between classic (false) and cel-shaded toon (true) shaders.
  bool toonMode = false;

  // Keep these for compatibility with the legacy six-field _drawBatch signature.
  late int _fPosLoc, _fCornerLoc, _fColorLoc, _fSizeLoc, _fRotLoc, _fFuelLoc;
  late int _sPosLoc, _sCornerLoc, _sColorLoc, _sSizeLoc, _sRotLoc, _sFuelLoc;

  static const int _floatsPerVertex = 12;
  static const int _vertsPerQuad    = 4;
  static const int _indicesPerQuad  = 6;
  static const int _maxQuads        = 8000;

  late dynamic _vbo;
  late dynamic _ibo;
  late Float32List _vboData;

  static const List<double> _corners = [-1, -1, 1, -1, 1, 1, -1, 1];

  final List<Particle> _scratchFire  = [];
  final List<Particle> _scratchSmoke = [];
  final Vector4        _colorScratch = Vector4.zero();
  final Matrix4        _vpScratch    = Matrix4.identity();
  final Vector3        _camRight     = Vector3.zero();
  final Vector3        _camUp        = Vector3.zero();
  final Vector3        _camPos       = Vector3.zero();
  final Vector3        _sortScratch  = Vector3.zero();

  bool _ready = false;
  bool get isReady => _ready;

  ParticleRenderer(this.gl) {
    try {
      _init();
    } catch (e) {
      debugPrint('[ParticleRenderer] init failed: $e');
    }
  }

  void _init() {
    final fSrc = ShaderProgram.fromSource(gl, particleVertShader, fireFragShader);
    _fPosLoc    = fSrc.getAttribLocation('aWorldPos');
    _fCornerLoc = fSrc.getAttribLocation('aCorner');
    _fColorLoc  = fSrc.getAttribLocation('aColor');
    _fSizeLoc   = fSrc.getAttribLocation('aSize');
    _fRotLoc    = fSrc.getAttribLocation('aRotation');
    _fFuelLoc   = fSrc.getAttribLocation('aFuelFraction');
    _classicFire = _ShaderSet(fSrc, _fPosLoc, _fCornerLoc, _fColorLoc,
        _fSizeLoc, _fRotLoc, _fFuelLoc);

    final sSrc = ShaderProgram.fromSource(gl, particleVertShader, smokeFragShader);
    _sPosLoc    = sSrc.getAttribLocation('aWorldPos');
    _sCornerLoc = sSrc.getAttribLocation('aCorner');
    _sColorLoc  = sSrc.getAttribLocation('aColor');
    _sSizeLoc   = sSrc.getAttribLocation('aSize');
    _sRotLoc    = sSrc.getAttribLocation('aRotation');
    _sFuelLoc   = sSrc.getAttribLocation('aFuelFraction');
    _classicSmoke = _ShaderSet(sSrc, _sPosLoc, _sCornerLoc, _sColorLoc,
        _sSizeLoc, _sRotLoc, _sFuelLoc);

    try {
      final tf = ShaderProgram.fromSource(gl, particleVertShader, toonFireFragShader);
      _toonFire = _ShaderSet(
        tf,
        tf.getAttribLocation('aWorldPos'),
        tf.getAttribLocation('aCorner'),
        tf.getAttribLocation('aColor'),
        tf.getAttribLocation('aSize'),
        tf.getAttribLocation('aRotation'),
        tf.getAttribLocation('aFuelFraction'),
      );
      final ts = ShaderProgram.fromSource(gl, particleVertShader, toonSmokeFragShader);
      _toonSmoke = _ShaderSet(
        ts,
        ts.getAttribLocation('aWorldPos'),
        ts.getAttribLocation('aCorner'),
        ts.getAttribLocation('aColor'),
        ts.getAttribLocation('aSize'),
        ts.getAttribLocation('aRotation'),
        ts.getAttribLocation('aFuelFraction'),
      );
      debugPrint('[ParticleRenderer] toon shaders compiled');
    } catch (e) {
      debugPrint('[ParticleRenderer] toon shaders failed: $e — toon mode unavailable');
    }

    _vboData = Float32List(_maxQuads * _vertsPerQuad * _floatsPerVertex);
    _vbo     = gl.createBuffer();
    _ibo     = _buildIndexBuffer();
    _ready   = true;
    debugPrint('[ParticleRenderer] initialized (max $_maxQuads quads)');
  }

  dynamic _buildIndexBuffer() {
    final indices = Uint16List(_maxQuads * _indicesPerQuad);
    for (int i = 0; i < _maxQuads; i++) {
      final vb = i * _vertsPerQuad;
      final ib = i * _indicesPerQuad;
      indices[ib]   = vb;     indices[ib + 1] = vb + 1; indices[ib + 2] = vb + 2;
      indices[ib+3] = vb;     indices[ib + 4] = vb + 2; indices[ib + 5] = vb + 3;
    }
    final buf = gl.createBuffer();
    gl.bindBuffer(0x8893, buf);
    gl.bufferData(0x8893, indices, 0x88E4); // STATIC_DRAW
    gl.bindBuffer(0x8893, null);
    return buf;
  }

  void render(List<Particle> particles, Camera3D camera, double time) {
    if (!_ready || particles.isEmpty) return;

    final viewMat = camera.getViewMatrix();
    _camRight.setValues(viewMat[0], viewMat[4], viewMat[8]);
    _camUp.setValues(viewMat[1], viewMat[5], viewMat[9]);
    _vpScratch.setFrom(camera.getProjectionMatrix());
    _vpScratch.multiply(viewMat);

    _scratchFire.clear();
    _scratchSmoke.clear();
    for (final p in particles) {
      if (p.isFire || p.isEmber) _scratchFire.add(p);
      else _scratchSmoke.add(p);
    }

    // Sort smoke back-to-front for correct alpha compositing.
    _camPos.setValues(viewMat[12], viewMat[13], viewMat[14]);
    _scratchSmoke.sort((a, b) {
      _sortScratch.setFrom(a.position); _sortScratch.sub(_camPos);
      final da = _sortScratch.length2;
      _sortScratch.setFrom(b.position); _sortScratch.sub(_camPos);
      final db = _sortScratch.length2;
      return db.compareTo(da);
    });

    final fireSet  = (toonMode && _toonFire  != null) ? _toonFire!  : _classicFire;
    final smokeSet = (toonMode && _toonSmoke != null) ? _toonSmoke! : _classicSmoke;

    gl.depthMask(false);
    gl.enable(0x0BE2); // BLEND

    // Fire + ember: additive (SRC_ALPHA, ONE)
    gl.blendFunc(0x0302, 0x0001);
    _drawBatch(_scratchFire, fireSet,
        _vpScratch, _camRight, _camUp, time);

    // Smoke: standard alpha blend (SRC_ALPHA, ONE_MINUS_SRC_ALPHA)
    gl.blendFunc(0x0302, 0x0303);
    _drawBatch(_scratchSmoke, smokeSet,
        _vpScratch, _camRight, _camUp, time);

    gl.disable(0x0BE2);
    gl.depthMask(true);
  }

  void _drawBatch(
    List<Particle> batch, _ShaderSet set,
    Matrix4 viewProj, Vector3 camRight, Vector3 camUp, double time,
  ) {
    if (batch.isEmpty) return;
    final limit = math.min(batch.length, _maxQuads);
    int quadCount = 0;

    for (int qi = 0; qi < limit; qi++) {
      final p    = batch[qi];
      p.writeColor(_colorScratch);
      final base = qi * _vertsPerQuad * _floatsPerVertex;

      for (int vi = 0; vi < _vertsPerQuad; vi++) {
        final off = base + vi * _floatsPerVertex;
        _vboData[off]    = p.position.x;
        _vboData[off+1]  = p.position.y;
        _vboData[off+2]  = p.position.z;
        _vboData[off+3]  = _corners[vi * 2];
        _vboData[off+4]  = _corners[vi * 2 + 1];
        _vboData[off+5]  = _colorScratch.r;
        _vboData[off+6]  = _colorScratch.g;
        _vboData[off+7]  = _colorScratch.b;
        _vboData[off+8]  = _colorScratch.a;
        _vboData[off+9]  = p.size;
        _vboData[off+10] = p.rotation;
        _vboData[off+11] = p.fuelFraction;
      }
      quadCount++;
    }

    gl.bindBuffer(0x8892, _vbo);
    final uploadCount = quadCount * _vertsPerQuad * _floatsPerVertex;
    gl.bufferData(0x8892, Float32List.view(_vboData.buffer, 0, uploadCount), 0x88E8);

    set.shader.use();
    set.shader.setUniformMatrix4('uViewProj',    viewProj);
    set.shader.setUniformVector3('uCameraRight', camRight);
    set.shader.setUniformVector3('uCameraUp',    camUp);
    set.shader.setUniformFloat('uTime', time);

    const int stride = _floatsPerVertex * 4; // 48 bytes
    _bindAttrib(set.posLoc,    3, stride, 0);
    _bindAttrib(set.cornerLoc, 2, stride, 12);
    _bindAttrib(set.colorLoc,  4, stride, 20);
    _bindAttrib(set.sizeLoc,   1, stride, 36);
    _bindAttrib(set.rotLoc,    1, stride, 40);
    _bindAttrib(set.fuelLoc,   1, stride, 44);

    gl.bindBuffer(0x8893, _ibo);
    gl.drawElements(0x0004, quadCount * _indicesPerQuad, 0x1403, 0);

    _unbindAttrib(set.posLoc);    _unbindAttrib(set.cornerLoc);
    _unbindAttrib(set.colorLoc);  _unbindAttrib(set.sizeLoc);
    _unbindAttrib(set.rotLoc);    _unbindAttrib(set.fuelLoc);
    gl.bindBuffer(0x8892, null);
    gl.bindBuffer(0x8893, null);
  }

  void _bindAttrib(int loc, int size, int stride, int offset) {
    if (loc < 0) return;
    gl.enableVertexAttribArray(loc);
    gl.vertexAttribPointer(loc, size, 0x1406, false, stride, offset);
  }

  void _unbindAttrib(int loc) {
    if (loc >= 0) gl.disableVertexAttribArray(loc);
  }

  void dispose() {
    if (!_ready) return;
    gl.deleteBuffer(_vbo);
    gl.deleteBuffer(_ibo);
    _classicFire.shader.dispose();
    _classicSmoke.shader.dispose();
    _toonFire?.shader.dispose();
    _toonSmoke?.shader.dispose();
    _ready = false;
  }
}
