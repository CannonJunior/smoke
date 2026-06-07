import 'package:flutter/foundation.dart' show debugPrint;
import 'package:vector_math/vector_math.dart';

/// ShaderProgram - Compiles and manages a WebGL shader program.
///
/// Wraps vertex and fragment shader compilation, program linking, and
/// provides typed uniform setters with location caching for performance.
///
/// Usage:
/// ```dart
/// final shader = ShaderProgram.fromSource(gl, vertexSrc, fragmentSrc);
/// shader.use();
/// shader.setUniformMatrix4('uProjection', projMatrix);
/// shader.setUniformMatrix4('uView', viewMatrix);
/// shader.setUniformMatrix4('uModel', modelMatrix);
/// ```
class ShaderProgram {
  /// WebGL rendering context (dynamic for dart:html compatibility)
  final dynamic gl;

  /// Compiled and linked WebGL program object
  final dynamic program;

  /// Cached uniform locations to avoid repeated getUniformLocation calls
  final Map<String, dynamic> _uniformLocations = {};

  /// Cached attribute locations
  final Map<String, int> _attribLocations = {};

  ShaderProgram._(this.gl, this.program);

  /// Compile vertex + fragment shaders and link a program.
  ///
  /// Throws [Exception] if compilation or linking fails.
  factory ShaderProgram.fromSource(
    dynamic gl,
    String vertexSource,
    String fragmentSource,
  ) {
    final vs = _compileShader(gl, 0x8B31, vertexSource); // VERTEX_SHADER
    if (vs == null) throw Exception('Failed to compile vertex shader');

    final fs = _compileShader(gl, 0x8B30, fragmentSource); // FRAGMENT_SHADER
    if (fs == null) {
      gl.deleteShader(vs);
      throw Exception('Failed to compile fragment shader');
    }

    final prog = gl.createProgram();
    if (prog == null) {
      gl.deleteShader(vs);
      gl.deleteShader(fs);
      throw Exception('Failed to create shader program');
    }

    gl.attachShader(prog, vs);
    gl.attachShader(prog, fs);
    gl.linkProgram(prog);

    // LINK_STATUS = 0x8B82
    if (gl.getProgramParameter(prog, 0x8B82) == 0) {
      final err = gl.getProgramInfoLog(prog);
      gl.deleteProgram(prog);
      gl.deleteShader(vs);
      gl.deleteShader(fs);
      throw Exception('Shader link error: $err');
    }

    // Shaders are now baked into the program; free the intermediate objects
    gl.deleteShader(vs);
    gl.deleteShader(fs);

    return ShaderProgram._(gl, prog);
  }

  /// Compile a transform-feedback shader (WebGL2 only).
  factory ShaderProgram.fromSourceWithVaryings(
    dynamic gl,
    String vertexSource,
    String fragmentSource,
    List<String> varyings,
  ) {
    final vs = _compileShader(gl, 0x8B31, vertexSource);
    if (vs == null) throw Exception('Failed to compile vertex shader');
    final fs = _compileShader(gl, 0x8B30, fragmentSource);
    if (fs == null) { gl.deleteShader(vs); throw Exception('Failed to compile fragment shader'); }
    final prog = gl.createProgram();
    if (prog == null) {
      gl.deleteShader(vs); gl.deleteShader(fs);
      throw Exception('Failed to create shader program');
    }
    gl.attachShader(prog, vs);
    gl.attachShader(prog, fs);
    gl.transformFeedbackVaryings(prog, varyings, 0x8C8C); // INTERLEAVED_ATTRIBS
    gl.linkProgram(prog);
    if (gl.getProgramParameter(prog, 0x8B82) == 0) {
      final err = gl.getProgramInfoLog(prog);
      gl.deleteProgram(prog); gl.deleteShader(vs); gl.deleteShader(fs);
      throw Exception('Shader link error: $err');
    }
    gl.deleteShader(vs);
    gl.deleteShader(fs);
    return ShaderProgram._(gl, prog);
  }

  /// Compile a single shader stage. Returns null and logs on error.
  static dynamic _compileShader(dynamic gl, int type, String source) {
    final shader = gl.createShader(type);
    if (shader == null) return null;

    gl.shaderSource(shader, source);
    gl.compileShader(shader);

    // COMPILE_STATUS = 0x8B81
    if (gl.getShaderParameter(shader, 0x8B81) == 0) {
      final err = gl.getShaderInfoLog(shader);
      debugPrint('[ShaderProgram] Compile error: $err');
      gl.deleteShader(shader);
      return null;
    }

    return shader;
  }

  /// Activate this program for subsequent draw calls.
  void use() => gl.useProgram(program);

  /// Get (and cache) a uniform location. Returns null for inactive uniforms.
  dynamic _getUniformLocation(String name) {
    if (_uniformLocations.containsKey(name)) return _uniformLocations[name];
    try {
      final loc = gl.getUniformLocation(program, name);
      if (loc != null) _uniformLocations[name] = loc;
      return loc;
    } catch (_) {
      return null; // Uniform was optimised out
    }
  }

  /// Get (and cache) a vertex attribute location.
  int getAttribLocation(String name) {
    return _attribLocations.putIfAbsent(
      name, () => gl.getAttribLocation(program, name) as int,
    );
  }

  // ── Uniform setters ──────────────────────────────────────────────────────

  /// Upload a column-major 4×4 matrix uniform.
  void setUniformMatrix4(String name, Matrix4 m) {
    final loc = _getUniformLocation(name);
    if (loc != null) gl.uniformMatrix4fv(loc, false, m.storage);
  }

  /// Upload a column-major 3×3 matrix uniform.
  void setUniformMatrix3(String name, Matrix3 m) {
    final loc = _getUniformLocation(name);
    if (loc != null) gl.uniformMatrix3fv(loc, false, m.storage);
  }

  /// Upload a vec3 uniform.
  void setUniformVector3(String name, Vector3 v) {
    final loc = _getUniformLocation(name);
    if (loc != null) gl.uniform3f(loc, v.x, v.y, v.z);
  }

  /// Upload a float uniform.
  void setUniformFloat(String name, double v) {
    final loc = _getUniformLocation(name);
    if (loc != null) gl.uniform1f(loc, v);
  }

  /// Upload an int uniform.
  void setUniformInt(String name, int v) {
    final loc = _getUniformLocation(name);
    if (loc != null) gl.uniform1i(loc, v);
  }

  /// Free GPU resources.
  void dispose() {
    gl.deleteProgram(program);
    _uniformLocations.clear();
    _attribLocations.clear();
  }
}

// ── GLSL shader sources ──────────────────────────────────────────────────────

/// Default vertex shader: transforms position + normal through MVP matrices.
///
/// uViewProj = projection * view, pre-multiplied on the CPU once per frame.
/// uNormalMatrix = mat3(uModel), pre-computed on the CPU once per draw call.
/// Both eliminate per-vertex matrix operations from the GPU.
const String defaultVertexShader = '''
attribute vec3 aPosition;
attribute vec3 aNormal;
attribute vec4 aColor;

uniform mat4 uViewProj;
uniform mat4 uModel;
uniform mat3 uNormalMatrix;

varying vec3 vNormal;
varying vec4 vColor;
varying vec3 vFragPos;

void main() {
  vec4 worldPos   = uModel * vec4(aPosition, 1.0);
  vFragPos        = worldPos.xyz;
  vNormal         = uNormalMatrix * aNormal;
  vColor          = aColor;
  gl_Position     = uViewProj * worldPos;
}
''';

/// Default fragment shader: Blinn-Phong diffuse + ambient lighting.
const String defaultFragmentShader = '''
precision mediump float;

varying vec3 vNormal;
varying vec4 vColor;
varying vec3 vFragPos;

uniform vec3 uLightPos;
uniform vec3 uLightColor;
uniform vec3 uAmbientColor;

void main() {
  vec3 norm     = normalize(vNormal);
  vec3 lightDir = normalize(uLightPos - vFragPos);
  float diff    = max(dot(norm, lightDir), 0.0);
  vec3 ambient  = uAmbientColor;
  vec3 diffuse  = diff * uLightColor;
  vec3 result   = (ambient + diffuse) * vColor.rgb;
  gl_FragColor  = vec4(result, vColor.a);
}
''';
