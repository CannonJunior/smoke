import 'dart:math' as math;
import 'package:vector_math/vector_math.dart';

/// Transform3d - Represents position, rotation, and scale in 3D space.
///
/// Foundation for all 3D objects (player, camera, terrain, effects).
/// Rotation is stored as Euler angles (pitch, yaw, roll) in degrees
/// and converted to a 4x4 matrix for GPU upload.
///
/// Coordinate system:
/// - +X is right
/// - +Y is up
/// - -Z is forward (into the screen)
///
/// Usage:
/// ```dart
/// final t = Transform3d(
///   position: Vector3(0, 15, 0),
///   rotation: Vector3(10, 45, -30), // pitch, yaw, roll
/// );
/// shader.setUniformMatrix4('uModel', t.toMatrix());
/// ```
class Transform3d {
  /// World-space position (x, y, z)
  Vector3 position;

  /// Euler rotation in degrees: x=pitch, y=yaw, z=roll
  Vector3 rotation;

  /// Non-uniform scale
  Vector3 scale;

  /// Pre-allocated model matrix — returned by toMatrix() without heap allocation.
  final Matrix4 _modelMatrix = Matrix4.identity();

  // ── Direction cache — valid until rotation changes ────────────────────────
  final Vector3 _fwdCache   = Vector3(0, 0, -1);
  final Vector3 _rightCache = Vector3(1, 0, 0);
  final Vector3 _upCache    = Vector3(0, 1, 0);
  double _cacheYaw   = double.infinity;
  double _cachePitch = double.infinity;

  void _refreshDirections() {
    if (rotation.y == _cacheYaw && rotation.x == _cachePitch) return;
    _cacheYaw   = rotation.y;
    _cachePitch = rotation.x;
    final yawRad   = radians(_cacheYaw);
    final pitchRad = radians(_cachePitch);
    final cosP = math.cos(pitchRad);
    _fwdCache.setValues(-math.sin(yawRad) * cosP, math.sin(pitchRad), -math.cos(yawRad) * cosP);
    _fwdCache.normalize();
    _rightCache.setValues(math.cos(yawRad), 0, -math.sin(yawRad));
    _rightCache.normalize();
    _fwdCache.crossInto(_rightCache, _upCache);
    _upCache.normalize();
  }

  Transform3d({
    Vector3? position,
    Vector3? rotation,
    Vector3? scale,
  })  : position = position ?? Vector3.zero(),
        rotation = rotation ?? Vector3.zero(),
        scale = scale ?? Vector3(1, 1, 1);

  /// Build a 4x4 model matrix: Translate * RotateY * RotateX * RotateZ * Scale.
  ///
  /// Rotation order (Y → X → Z) produces standard aircraft-style Euler angles:
  /// yaw around world-up, pitch around local right, roll around local forward.
  ///
  /// Returns the internal _modelMatrix — callers must not store the reference
  /// across frames as it is overwritten each call to toMatrix().
  Matrix4 toMatrix() {
    _modelMatrix.setIdentity();
    _modelMatrix.translateByVector3(position);
    _modelMatrix.rotateY(radians(rotation.y));
    _modelMatrix.rotateX(radians(rotation.x));
    _modelMatrix.rotateZ(radians(rotation.z));
    _modelMatrix.scaleByVector3(scale);
    return _modelMatrix;
  }

  /// Forward direction vector computed from yaw and pitch.
  /// Cached: trig is recomputed only when rotation.x/y change.
  Vector3 get forward { _refreshDirections(); return _fwdCache; }

  /// Right direction vector computed from yaw only.
  /// Cached: trig is recomputed only when rotation.y changes.
  Vector3 get right { _refreshDirections(); return _rightCache; }

  /// Up direction vector (cross product of forward × right). Cached; no allocation.
  Vector3 get up { _refreshDirections(); return _upCache; }

  /// Move position by a delta vector.
  void translate(Vector3 delta) {
    position += delta;
  }

  /// Add delta rotation angles (degrees). Keeps angles in [-360, 360].
  void rotate(Vector3 deltaRotation) {
    rotation += deltaRotation;
    rotation.x = rotation.x % 360;
    rotation.y = rotation.y % 360;
    rotation.z = rotation.z % 360;
  }

  /// Deep copy of this transform.
  Transform3d clone() {
    return Transform3d(
      position: Vector3.copy(position),
      rotation: Vector3.copy(rotation),
      scale:    Vector3.copy(scale),
    );
  }

  /// Linear interpolation toward another transform.
  ///
  /// t=0 returns this, t=1 returns [other].
  Transform3d lerp(Transform3d other, double t) {
    return Transform3d(
      position: position * (1 - t) + other.position * t,
      rotation: rotation * (1 - t) + other.rotation * t,
      scale:    scale    * (1 - t) + other.scale    * t,
    );
  }

  @override
  String toString() =>
      'Transform3d(pos: $position, rot: $rotation, scale: $scale)';
}
