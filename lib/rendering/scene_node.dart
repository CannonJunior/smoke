import 'package:vector_math/vector_math.dart';
import 'mesh.dart';

/// SceneNode — one node in the aircraft scene graph.
///
/// Each moving aircraft part (aileron, elevator, rudder, gear leg, propeller,
/// bay door) gets its own SceneNode.  The node's LOCAL ORIGIN is placed at
/// the part's hinge line so that rotating the node rotates the mesh around
/// that hinge — no extra pivot-offset math required.
///
/// World matrix cascades top-down:
///   worldMatrix = parentWorldMatrix × localMatrix
///   localMatrix = T × RotY × RotX × RotZ  (no scale — aircraft parts never scale)
///
/// Usage:
/// ```dart
/// final root = SceneNode(id: 'aircraft');
/// final aileron = SceneNode(id: 'aileron_l', mesh: aileronMesh,
///     position: Vector3(-1.1, 0, 0.6));
/// root.addChild(aileron);
///
/// // each frame:
/// aileron.rotation.x = bankRad * 0.4;   // deflect around hinge (X = span axis)
/// root.updateWorldMatrix();
///
/// // render all parts:
/// for (final node in root.renderables) {
///   renderer.renderWithMatrix(node.mesh!, node.worldMatrix, camera);
/// }
/// ```
class SceneNode {
  final String id;

  /// Optional mesh rendered at this node.  Nodes without a mesh act as
  /// invisible pivots (e.g. the aircraft root that carries the world transform).
  Mesh? mesh;

  /// Position in parent-local space (or world space for the root).
  final Vector3 position;

  /// Euler rotation in RADIANS in parent-local space.
  /// Applied order: RotY → RotX → RotZ (matches Transform3d convention).
  final Vector3 rotation;

  /// Computed world-space transform.  Call [updateWorldMatrix] to refresh.
  Matrix4 worldMatrix = Matrix4.identity();

  /// Pre-allocated local matrix — reused each frame to avoid allocation.
  final Matrix4 _localMatrix = Matrix4.identity();

  /// When false the node (and its children) are excluded from [renderables].
  bool visible = true;

  final List<SceneNode> _children = [];

  SceneNode({
    required this.id,
    this.mesh,
    Vector3? position,
    Vector3? rotation,
  })  : position = position ?? Vector3.zero(),
        rotation = rotation ?? Vector3.zero();

  // ── Tree management ────────────────────────────────────────────────────────

  void addChild(SceneNode child) => _children.add(child);

  /// All descendants (and self) that carry a mesh AND are [visible].
  Iterable<SceneNode> get renderables sync* {
    if (!visible) return;
    if (mesh != null) yield this;
    for (final c in _children) yield* c.renderables;
  }

  /// Collect renderable nodes into [out] — avoids sync* iterator allocation.
  void collectRenderables(List<SceneNode> out) {
    if (!visible) return;
    if (mesh != null) out.add(this);
    for (final c in _children) c.collectRenderables(out);
  }

  /// Named lookup — finds the first descendant with the given [id].
  SceneNode? find(String targetId) {
    if (id == targetId) return this;
    for (final c in _children) {
      final found = c.find(targetId);
      if (found != null) return found;
    }
    return null;
  }

  // ── World matrix update ────────────────────────────────────────────────────

  /// Recompute [worldMatrix] for this node and all descendants.
  ///
  /// Call once per frame AFTER updating [position] and [rotation].
  /// Pass [parentMatrix] = null for the root node.
  void updateWorldMatrix([Matrix4? parentMatrix]) {
    _localMatrix.setIdentity();
    _localMatrix.translate(position.x, position.y, position.z);
    _localMatrix.rotateY(rotation.y);
    _localMatrix.rotateX(rotation.x);
    _localMatrix.rotateZ(rotation.z);

    if (parentMatrix != null) {
      worldMatrix.setFrom(parentMatrix);
      worldMatrix.multiply(_localMatrix);
    } else {
      worldMatrix.setFrom(_localMatrix);
    }

    for (final child in _children) {
      child.updateWorldMatrix(worldMatrix);
    }
  }
}
