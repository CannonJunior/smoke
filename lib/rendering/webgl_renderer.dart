import 'dart:html' as html;
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:vector_math/vector_math.dart';
import 'atmospheric_smoke_plume.dart';
import 'atmospheric_smoke_renderer.dart';
import 'camera3d.dart';
import 'heat_distortion.dart';
import 'mesh.dart';
import 'particle_renderer.dart';
import 'particle_system.dart';
import 'scene_node.dart';
import 'shader_program.dart';
import 'transform3d.dart';

/// WebGLRenderer - Core WebGL rendering engine for Smoke & Terrain.
class WebGLRenderer {
  final html.CanvasElement canvas;
  final dynamic gl;

  late ShaderProgram shader;

  Vector3 lightPosition = Vector3(50, 80, 50);
  Vector3 lightColor    = Vector3(1.0, 0.95, 0.85);
  Vector3 ambientColor  = Vector3(0.25, 0.25, 0.35);

  late HeatDistortionPass heatDistortion;

  ParticleRenderer? _pRenderer;
  bool _useParticleRenderer = false;

  AtmosphericSmokeRenderer? _atmRenderer;

  double _time = 0.0;
  set time(double v) => _time = v;

  bool get toonMode => _pRenderer?.toonMode ?? false;
  set toonMode(bool v) { _pRenderer?.toonMode = v; }

  // ── Particle render state ────────────────────────────────────────────────

  ShaderProgram? _particleShader;
  dynamic _particleVbo;
  Float32List _particleDataBuf = Float32List(0);
  Float32List? _particleDataView;
  int _particleDataViewLen = 0;
  final Vector4 _cpuColorScratch = Vector4.zero();
  int _pFbPosLoc   = -1;
  int _pFbColorLoc = -1;
  int _pFbSizeLoc  = -1;

  final List<SceneNode> _renderablesScratch = [];

  static const String _particleVertSrc = '''
attribute vec3 aPos;
attribute vec4 aColor;
attribute float aSize;
uniform mat4 uViewProj;
varying vec4 vColor;
void main() {
  vColor = aColor;
  gl_Position = uViewProj * vec4(aPos, 1.0);
  gl_PointSize = aSize;
}
''';
  static const String _particleFragSrc = '''
precision mediump float;
varying vec4 vColor;
void main() {
  vec2 c = gl_PointCoord - 0.5;
  if (dot(c, c) > 0.25) discard;
  gl_FragColor = vColor;
}
''';

  final Map<Mesh, _MeshBuffers> _meshBuffers = {};

  dynamic _vaoExt;
  bool _supportsVAO = false;
  dynamic _activeProgram;
  dynamic _activeVAO;

  final Matrix3 _normalMatrixScratch = Matrix3.zero();

  late int _posLoc, _normLoc, _colLoc;

  final Matrix4 _scratchViewProj = Matrix4.identity();
  bool _viewProjDirty = true;

  WebGLRenderer._(this.canvas, this.gl) {
    _initialize();
  }

  factory WebGLRenderer(html.CanvasElement canvas) {
    final attrs = {'alpha': false, 'depth': true, 'antialias': true};
    var gl = canvas.getContext('webgl2', attrs);
    gl ??= canvas.getContext('webgl', attrs);
    if (gl == null) throw Exception('WebGL not supported in this browser');
    return WebGLRenderer._(canvas, gl);
  }

  void _initialize() {
    gl.enable(0x0B71);    // DEPTH_TEST
    gl.depthFunc(0x0201); // LESS
    gl.enable(0x0B44);    // CULL_FACE
    gl.cullFace(0x0405);  // BACK

    gl.clearColor(0.25, 0.50, 0.80, 1.0);

    shader = ShaderProgram.fromSource(gl, defaultVertexShader, defaultFragmentShader);

    _posLoc  = shader.getAttribLocation('aPosition');
    _normLoc = shader.getAttribLocation('aNormal');
    _colLoc  = shader.getAttribLocation('aColor');

    try {
      final testVao = gl.createVertexArray();
      if (testVao != null) {
        gl.deleteVertexArray(testVao);
        _supportsVAO = true;
      }
    } catch (_) {
      _vaoExt = gl.getExtension('OES_vertex_array_object');
      if (_vaoExt != null) _supportsVAO = true;
    }

    heatDistortion = HeatDistortionPass(gl);

    _pRenderer = ParticleRenderer(gl);
    _useParticleRenderer = _pRenderer!.isReady;

    _atmRenderer = AtmosphericSmokeRenderer(gl);

    debugPrint('[WebGLRenderer] initialized (VAO: $_supportsVAO, billboardParticles: $_useParticleRenderer)');
  }

  dynamic _createVAO() => _vaoExt != null
      ? _vaoExt.createVertexArrayOES()
      : gl.createVertexArray();

  void _bindVAO(dynamic vao) => _vaoExt != null
      ? _vaoExt.bindVertexArrayOES(vao)
      : gl.bindVertexArray(vao);

  void _unbindVAO() => _vaoExt != null
      ? _vaoExt.bindVertexArrayOES(null)
      : gl.bindVertexArray(null);

  void _deleteVAO(dynamic vao) => _vaoExt != null
      ? _vaoExt.deleteVertexArrayOES(vao)
      : gl.deleteVertexArray(vao);

  void clear() {
    gl.clear(0x00004000 | 0x00000100); // COLOR | DEPTH
    _viewProjDirty = true;
    _activeProgram = null;
    _unbindActiveVAO();
  }

  void _unbindActiveVAO() {
    if (_activeVAO != null) {
      _unbindVAO();
      _activeVAO = null;
    }
  }

  void render(Mesh mesh, Transform3d transform, Camera3D camera) =>
      renderWithMatrix(mesh, transform.toMatrix(), camera);

  void renderWithMatrix(Mesh mesh, Matrix4 modelMatrix, Camera3D camera) {
    final bufs = _getOrCreateBuffers(mesh);

    if (_activeProgram != shader.program) {
      shader.use();
      _activeProgram = shader.program;
    }

    if (_viewProjDirty) {
      _scratchViewProj.setFrom(camera.getProjectionMatrix());
      _scratchViewProj.multiply(camera.getViewMatrix());
      shader.setUniformVector3('uLightPos',     lightPosition);
      shader.setUniformVector3('uLightColor',   lightColor);
      shader.setUniformVector3('uAmbientColor', ambientColor);
      _viewProjDirty = false;
    }

    shader.setUniformMatrix4('uViewProj',     _scratchViewProj);
    shader.setUniformMatrix4('uModel',        modelMatrix);
    modelMatrix.copyRotation(_normalMatrixScratch);
    shader.setUniformMatrix3('uNormalMatrix', _normalMatrixScratch);

    if (bufs.vao != null) {
      if (bufs.vao != _activeVAO) {
        _bindVAO(bufs.vao);
        _activeVAO = bufs.vao;
      }
      if (bufs.colorBuffer == null) gl.vertexAttrib4f(_colLoc, 1.0, 1.0, 1.0, 1.0);
      gl.drawElements(0x0004, mesh.indices.length, 0x1403, 0);
    } else {
      _unbindActiveVAO();
      if (_posLoc >= 0) {
        gl.bindBuffer(0x8892, bufs.vertexBuffer);
        gl.enableVertexAttribArray(_posLoc);
        gl.vertexAttribPointer(_posLoc, 3, 0x1406, false, 0, 0);
      }
      if (_normLoc >= 0 && bufs.normalBuffer != null) {
        gl.bindBuffer(0x8892, bufs.normalBuffer);
        gl.enableVertexAttribArray(_normLoc);
        gl.vertexAttribPointer(_normLoc, 3, 0x1406, false, 0, 0);
      }
      if (_colLoc >= 0) {
        if (bufs.colorBuffer != null) {
          gl.bindBuffer(0x8892, bufs.colorBuffer);
          gl.enableVertexAttribArray(_colLoc);
          gl.vertexAttribPointer(_colLoc, 4, 0x1406, false, 0, 0);
        } else {
          gl.disableVertexAttribArray(_colLoc);
          gl.vertexAttrib4f(_colLoc, 1.0, 1.0, 1.0, 1.0);
        }
      }
      gl.bindBuffer(0x8893, bufs.indexBuffer);
      gl.drawElements(0x0004, mesh.indices.length, 0x1403, 0);
      if (_posLoc  >= 0) gl.disableVertexAttribArray(_posLoc);
      if (_normLoc >= 0) gl.disableVertexAttribArray(_normLoc);
      if (_colLoc  >= 0) gl.disableVertexAttribArray(_colLoc);
    }
  }

  void renderSceneGraph(SceneNode root, Camera3D camera) {
    _renderablesScratch.clear();
    root.collectRenderables(_renderablesScratch);
    for (final node in _renderablesScratch) {
      renderWithMatrix(node.mesh!, node.worldMatrix, camera);
    }
  }

  _MeshBuffers _getOrCreateBuffers(Mesh mesh) {
    if (_meshBuffers.containsKey(mesh)) return _meshBuffers[mesh]!;

    _unbindActiveVAO();
    final vertexBuffer = _upload(0x8892, mesh.vertices);
    final indexBuffer  = _upload(0x8893, mesh.indices);
    final normalBuffer = mesh.normals != null ? _upload(0x8892, mesh.normals!) : null;
    final colorBuffer  = mesh.colors  != null ? _upload(0x8892, mesh.colors!)  : null;

    dynamic vao;
    if (_supportsVAO) {
      vao = _createVAO();
      _bindVAO(vao);

      if (_posLoc >= 0) {
        gl.bindBuffer(0x8892, vertexBuffer);
        gl.enableVertexAttribArray(_posLoc);
        gl.vertexAttribPointer(_posLoc, 3, 0x1406, false, 0, 0);
      }
      if (_normLoc >= 0 && normalBuffer != null) {
        gl.bindBuffer(0x8892, normalBuffer);
        gl.enableVertexAttribArray(_normLoc);
        gl.vertexAttribPointer(_normLoc, 3, 0x1406, false, 0, 0);
      }
      if (_colLoc >= 0 && colorBuffer != null) {
        gl.bindBuffer(0x8892, colorBuffer);
        gl.enableVertexAttribArray(_colLoc);
        gl.vertexAttribPointer(_colLoc, 4, 0x1406, false, 0, 0);
      }
      gl.bindBuffer(0x8893, indexBuffer);

      _unbindVAO();
      _activeVAO = null;
    }

    final bufs = _MeshBuffers(
      vertexBuffer: vertexBuffer,
      indexBuffer:  indexBuffer,
      normalBuffer: normalBuffer,
      colorBuffer:  colorBuffer,
      vao:          vao,
    );
    _meshBuffers[mesh] = bufs;
    return bufs;
  }

  dynamic _upload(int target, dynamic data) {
    final buf = gl.createBuffer();
    if (buf == null) throw Exception('Failed to create GL buffer');
    gl.bindBuffer(target, buf);
    gl.bufferData(target, data, 0x88E4); // STATIC_DRAW
    gl.bindBuffer(target, null);
    return buf;
  }

  void deleteMeshBuffers(Mesh mesh) {
    final bufs = _meshBuffers.remove(mesh);
    if (bufs == null) return;
    if (bufs.vao != null) _deleteVAO(bufs.vao);
    gl.deleteBuffer(bufs.vertexBuffer);
    gl.deleteBuffer(bufs.indexBuffer);
    if (bufs.normalBuffer != null) gl.deleteBuffer(bufs.normalBuffer);
    if (bufs.colorBuffer  != null) gl.deleteBuffer(bufs.colorBuffer);
  }

  void updateSmoke(double smoke) {
    final r = (0.25 + smoke * 0.22).clamp(0.0, 1.0);
    final g = (0.50 - smoke * 0.30).clamp(0.0, 1.0);
    final b = (0.80 - smoke * 0.64).clamp(0.0, 1.0);
    gl.clearColor(r, g, b, 1.0);
  }

  void beginHeatPass() => heatDistortion.bindFbo();
  void endHeatPass(double intensity) => heatDistortion.apply(intensity, _time);

  void renderParticles(List<Particle> particles, Camera3D camera) {
    if (particles.isEmpty) return;
    _unbindActiveVAO();
    if (_useParticleRenderer && _pRenderer != null) {
      _pRenderer!.render(particles, camera, _time);
      return;
    }
    if (_particleShader == null) {
      _particleShader = ShaderProgram.fromSource(gl, _particleVertSrc, _particleFragSrc);
      _pFbPosLoc   = _particleShader!.getAttribLocation('aPos');
      _pFbColorLoc = _particleShader!.getAttribLocation('aColor');
      _pFbSizeLoc  = _particleShader!.getAttribLocation('aSize');
    }
    _particleVbo ??= gl.createBuffer();

    const stride = 8;
    final needed = particles.length * stride;
    if (_particleDataBuf.length < needed) {
      _particleDataBuf = Float32List(needed + stride * 100);
      _particleDataView = null;
    }
    for (int i = 0; i < particles.length; i++) {
      final p = particles[i];
      p.writeColor(_cpuColorScratch);
      final b = i * stride;
      _particleDataBuf[b]     = p.position.x;
      _particleDataBuf[b + 1] = p.position.y;
      _particleDataBuf[b + 2] = p.position.z;
      _particleDataBuf[b + 3] = _cpuColorScratch.r;
      _particleDataBuf[b + 4] = _cpuColorScratch.g;
      _particleDataBuf[b + 5] = _cpuColorScratch.b;
      _particleDataBuf[b + 6] = _cpuColorScratch.a;
      _particleDataBuf[b + 7] = p.size;
    }

    gl.bindBuffer(0x8892, _particleVbo);
    if (_particleDataView == null || _particleDataViewLen != needed) {
      _particleDataView    = Float32List.view(_particleDataBuf.buffer, 0, needed);
      _particleDataViewLen = needed;
    }
    gl.bufferData(0x8892, _particleDataView!, 0x88E8); // DYNAMIC_DRAW

    _particleShader!.use();
    _activeProgram = _particleShader!.program;

    if (_viewProjDirty) {
      _scratchViewProj.setFrom(camera.getProjectionMatrix());
      _scratchViewProj.multiply(camera.getViewMatrix());
      _viewProjDirty = false;
    }
    _particleShader!.setUniformMatrix4('uViewProj', _scratchViewProj);

    const byteStride = stride * 4;
    if (_pFbPosLoc   >= 0) { gl.enableVertexAttribArray(_pFbPosLoc);   gl.vertexAttribPointer(_pFbPosLoc,   3, 0x1406, false, byteStride, 0);  }
    if (_pFbColorLoc >= 0) { gl.enableVertexAttribArray(_pFbColorLoc); gl.vertexAttribPointer(_pFbColorLoc, 4, 0x1406, false, byteStride, 12); }
    if (_pFbSizeLoc  >= 0) { gl.enableVertexAttribArray(_pFbSizeLoc);  gl.vertexAttribPointer(_pFbSizeLoc,  1, 0x1406, false, byteStride, 28); }

    gl.enable(0x0BE2);       // BLEND
    gl.blendFunc(0x0302, 0x0303); // SRC_ALPHA, ONE_MINUS_SRC_ALPHA
    gl.drawArrays(0x0000, 0, particles.length); // POINTS
    gl.disable(0x0BE2);

    if (_pFbPosLoc   >= 0) gl.disableVertexAttribArray(_pFbPosLoc);
    if (_pFbColorLoc >= 0) gl.disableVertexAttribArray(_pFbColorLoc);
    if (_pFbSizeLoc  >= 0) gl.disableVertexAttribArray(_pFbSizeLoc);
    gl.bindBuffer(0x8892, null);
    _activeProgram = null;
  }

  void renderAtmosphericSmoke(
      List<SmokeColumnBillboard> billboards, Camera3D camera) {
    _unbindActiveVAO();
    _atmRenderer?.render(billboards, camera, _time);
  }

  void resize(int width, int height) {
    canvas.width  = width;
    canvas.height = height;
    gl.viewport(0, 0, width, height);
  }

  void dispose() {
    for (final b in _meshBuffers.values) {
      if (b.vao != null) _deleteVAO(b.vao);
      gl.deleteBuffer(b.vertexBuffer);
      gl.deleteBuffer(b.indexBuffer);
      if (b.normalBuffer != null) gl.deleteBuffer(b.normalBuffer);
      if (b.colorBuffer  != null) gl.deleteBuffer(b.colorBuffer);
    }
    _meshBuffers.clear();
    shader.dispose();
    _particleShader?.dispose();
    if (_particleVbo != null) gl.deleteBuffer(_particleVbo);
    _pRenderer?.dispose();
    _pRenderer = null;
    _atmRenderer?.dispose();
    _atmRenderer = null;
    heatDistortion.dispose();
    debugPrint('[WebGLRenderer] disposed');
  }
}

class _MeshBuffers {
  final dynamic vertexBuffer;
  final dynamic indexBuffer;
  final dynamic normalBuffer;
  final dynamic colorBuffer;
  final dynamic vao;

  const _MeshBuffers({
    required this.vertexBuffer,
    required this.indexBuffer,
    this.normalBuffer,
    this.colorBuffer,
    this.vao,
  });
}
