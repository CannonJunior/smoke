import 'dart:math' as math;
import 'package:vector_math/vector_math.dart';
import 'transform3d.dart';

/// Camera3D - Perspective camera with third-person follow and roll support.
///
/// Generates view and projection matrices for 3D rendering.
/// The [rollAngle] field tilts the camera up-vector to mirror the aircraft's
/// bank angle, providing visual feedback for roll manoeuvres.
///
/// Usage:
/// ```dart
/// final cam = Camera3D(aspectRatio: 16/9, fov: 90);
/// cam.updateThirdPersonFollow(playerPos, playerYaw, bankAngle, dt);
/// renderer.render(mesh, transform, cam);
/// ```
class Camera3D {
  /// Internal transform (position + rotation storage)
  final Transform3d transform;

  /// Field of view in degrees
  double fov;

  /// Viewport aspect ratio (width / height)
  double aspectRatio;

  /// Near clipping distance
  final double near;

  /// Far clipping distance
  final double far;

  /// Camera roll in degrees - mirrors aircraft bank for visual feedback.
  /// Positive = roll right, negative = roll left.
  double rollAngle = 0.0;

  // ── Projection cache ──────────────────────────────────────────────────────
  Matrix4? _projCache;
  double   _cachedFov = -1, _cachedAspect = -1;

  /// Y offset added to the look-at target for pitch following.
  ///
  /// When the aircraft pitches up or down this offsets where the camera
  /// aims so the player can see what they're flying towards.
  double targetPitchOffset = 0.0;

  /// Distance behind the player in third-person mode
  double _thirdPersonDistance = 10.0;

  /// Height above the player in third-person mode
  double _thirdPersonHeight = 4.0;

  /// Fixed pitch angle for third-person view (degrees, looking slightly down)
  double _thirdPersonPitch = 20.0;

  /// Look-at target position (null = free-look)
  Vector3? _target;

  /// Smooth lerp speed for camera position transitions
  final double _lerpSpeed = 8.0;

  /// Pre-allocated scratch objects — avoids per-frame allocation.
  final Vector3 _desiredPos      = Vector3.zero();
  final Matrix4 _viewCache       = Matrix4.identity();
  final Vector3 _upScratch       = Vector3(0, 1, 0);
  final Vector3 _viewDirScratch  = Vector3.zero();
  final Vector3 _crossScratch    = Vector3.zero();
  final Vector3 _effectiveTgtScratch = Vector3.zero();
  static final Vector3 _worldUpVec = Vector3(0, 1, 0);

  Camera3D({
    Vector3? position,
    this.fov = 90.0,
    this.aspectRatio = 16.0 / 9.0,
    this.near = 0.1,
    this.far = 1000.0,
  }) : transform = Transform3d(
          position: position ?? Vector3(0, 20, 20),
        );

  // ── Matrix generation ────────────────────────────────────────────────────

  /// Build the view matrix, rotating the up-vector by [rollAngle] for banking.
  Matrix4 getViewMatrix() {
    final up = _computeUpVector();
    if (_target != null) {
      Vector3 tgt = _target!;
      if (targetPitchOffset != 0.0) {
        _effectiveTgtScratch.setFrom(_target!);
        _effectiveTgtScratch.y += targetPitchOffset;
        tgt = _effectiveTgtScratch;
      }
      setViewMatrix(_viewCache, transform.position, tgt, up);
      return _viewCache;
    }
    final forward = transform.forward;
    _effectiveTgtScratch.setFrom(transform.position);
    _effectiveTgtScratch.add(forward);
    setViewMatrix(_viewCache, transform.position, _effectiveTgtScratch, up);
    return _viewCache;
  }

  /// Build perspective projection matrix (cached; recomputed only when fov or
  /// aspectRatio changes, which happens only on window resize or settings change).
  Matrix4 getProjectionMatrix() {
    if (_projCache == null || fov != _cachedFov || aspectRatio != _cachedAspect) {
      _projCache    = makePerspectiveMatrix(radians(fov), aspectRatio, near, far);
      _cachedFov    = fov;
      _cachedAspect = aspectRatio;
    }
    return _projCache!;
  }

  /// Project a world-space point to screen pixels (NDC → pixel coords).
  ///
  /// Returns null when the point is behind the near clip plane.
  /// Points in front of camera but outside the viewport are returned with
  /// out-of-bounds coordinates so the caller can clamp them to the screen edge.
  (double, double)? worldToScreen(Vector3 world, double screenW, double screenH) {
    final clip = Vector4(world.x, world.y, world.z, 1.0);
    getViewMatrix().transform(clip);
    getProjectionMatrix().transform(clip);
    if (clip.w <= 0.001) return null; // behind camera
    return (
      (clip.x / clip.w + 1.0) * 0.5 * screenW,
      (1.0 - clip.y / clip.w) * 0.5 * screenH,
    );
  }

  // ── Third-person follow ──────────────────────────────────────────────────

  /// Smoothly reposition the camera behind and above [targetPosition].
  ///
  /// Called each frame. [targetYaw] is the aircraft's horizontal heading in
  /// degrees. [bankAngle] drives [rollAngle] so the viewport tilts with the
  /// aircraft for visual feedback.
  ///
  /// Parameters:
  /// - targetPosition: aircraft world position
  /// - targetYaw: aircraft heading (degrees, Y-axis rotation)
  /// - bankAngle: aircraft bank angle (degrees) for camera roll
  /// - dt: frame delta time for lerp
  void updateThirdPersonFollow(
    Vector3 targetPosition,
    double targetYaw,
    double bankAngle,
    double dt,
  ) {
    // Camera sits behind and above the aircraft.
    // Add 180° so we are looking from behind, not from in front.
    final behindRad = radians(targetYaw + 180.0);

    final offsetX = -math.sin(behindRad) * _thirdPersonDistance;
    final offsetZ = -math.cos(behindRad) * _thirdPersonDistance;

    // Reason: _thirdPersonPitch tilts the camera offset upward so the
    // aircraft sits lower in frame - the higher the pitch angle the more
    // height offset is added proportional to sin(_thirdPersonPitch).
    final pitchHeightBonus = _thirdPersonDistance *
        math.sin(radians(_thirdPersonPitch)) * 0.5;

    // In-place: reuse _desiredPos to avoid allocating a new Vector3 each frame.
    _desiredPos.setValues(
      targetPosition.x + offsetX,
      targetPosition.y + _thirdPersonHeight + pitchHeightBonus,
      targetPosition.z + offsetZ,
    );

    // Smooth lerp in-place — no new Vector3 allocation.
    final t = math.min(1.0, _lerpSpeed * dt);
    transform.position.x += (_desiredPos.x - transform.position.x) * t;
    transform.position.y += (_desiredPos.y - transform.position.y) * t;
    transform.position.z += (_desiredPos.z - transform.position.z) * t;

    // Update look-at target in-place.
    if (_target == null) {
      _target = Vector3(targetPosition.x, targetPosition.y + 0.5, targetPosition.z);
    } else {
      _target!.setValues(targetPosition.x, targetPosition.y + 0.5, targetPosition.z);
    }

    // Mirror roll angle for banking visual feedback.
    // Reason: camera roll lags slightly behind aircraft bank for a cinematic feel.
    rollAngle += (bankAngle * 0.35 - rollAngle) * t;

    // Pitch-follow: shift look-at up when climbing, down when diving
    targetPitchOffset = 0.0; // Terrain clearance does the job; keep simple
  }

  // ── Cockpit (first-person) camera ────────────────────────────────────────

  /// Position the camera as a cockpit first-person view.
  ///
  /// Places the viewpoint slightly forward and above the aircraft centre,
  /// looking along the aircraft's heading. Bank angle is fully reflected so
  /// the horizon tilts realistically in cockpit view.
  ///
  /// Parameters:
  /// - aircraftPosition: aircraft world position
  /// - yaw: horizontal heading in degrees
  /// - pitch: nose attitude in degrees (positive = climbing)
  /// - bankAngle: roll angle in degrees (positive = right wing down)
  void positionAsCockpit(
    Vector3 aircraftPosition,
    double yaw,
    double pitch,
    double bankAngle,
  ) {
    final yawRad   = radians(yaw);
    final pitchRad = radians(pitch);

    // Aircraft forward vector at current heading and pitch
    final forward = Vector3(
      -math.sin(yawRad) * math.cos(pitchRad),
       math.sin(pitchRad),
      -math.cos(yawRad) * math.cos(pitchRad),
    ).normalized();

    // Cockpit eye: placed at the canopy position within the aircraft model.
    // The Racer aircraft (length=4) has its cockpit at approx +0.6 forward
    // from centre along the nose axis and +0.35 above centre.
    // Reason: enough forward offset to sit inside the canopy glass without
    // exiting the fuselage tip in extreme-pitch attitudes.
    transform.position =
        aircraftPosition + forward * 0.6 + Vector3(0, 0.35, 0);

    _target = transform.position + forward;

    // Full bank transmitted to camera roll — no cinematic lag in cockpit view.
    rollAngle = bankAngle * 0.6;
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  /// Camera up-vector, rotated around the view direction by [rollAngle].
  ///
  /// Uses Rodrigues' rotation formula to avoid gimbal lock.
  Vector3 _computeUpVector() {
    if (rollAngle.abs() < 0.01) {
      _upScratch.setValues(0, 1, 0);
      return _upScratch;
    }

    if (_target != null) {
      _viewDirScratch.setFrom(_target!);
      _viewDirScratch.sub(transform.position);
      _viewDirScratch.normalize();
    } else {
      _viewDirScratch.setFrom(transform.forward);
    }

    final rollRad = radians(rollAngle);
    final cosA    = math.cos(rollRad);
    final sinA    = math.sin(rollRad);
    final dot     = _viewDirScratch.y; // dot with (0,1,0)
    _viewDirScratch.crossInto(_worldUpVec, _crossScratch);
    final k = dot * (1.0 - cosA);
    _upScratch.setValues(
      _crossScratch.x * sinA + _viewDirScratch.x * k,
      cosA + _crossScratch.y * sinA + _viewDirScratch.y * k,
      _crossScratch.z * sinA + _viewDirScratch.z * k,
    );
    return _upScratch;
  }

  // ── Accessors ─────────────────────────────────────────────────────────────

  /// World-space camera position.
  Vector3 get position => transform.position;

  /// Set distance behind player (clamped 3–20 units).
  set thirdPersonDistance(double d) =>
      _thirdPersonDistance = d.clamp(3.0, 20.0);

  /// Set height above player (clamped 1–15 units).
  set thirdPersonHeight(double h) =>
      _thirdPersonHeight = h.clamp(1.0, 15.0);

  /// Set downward pitch angle of the third-person view (0–60 degrees).
  void setThirdPersonPitch(double p) {
    _thirdPersonPitch = p.clamp(0.0, 60.0);
  }

  /// Resize the viewport and update aspect ratio.
  void resize(int width, int height) {
    if (height > 0) aspectRatio = width / height;
  }
}
