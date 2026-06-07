import 'dart:math' as math;
import 'dart:typed_data';
import 'package:vector_math/vector_math.dart';
import 'mesh.dart';
import 'transform3d.dart';
import 'webgl_renderer.dart';
import 'camera3d.dart';
import '../terrain/tree_system.dart';

/// Renders all trees in three batched draw-call groups (alive / burning / charred).
///
/// Each group may span multiple [Mesh] segments because the WebGL renderer uses
/// Uint16 indices (max 65 535 vertices per buffer).  Segments are split whenever
/// a single [_MeshBuilder] reaches [_kVertsPerMesh] vertices.
///
/// Meshes are rebuilt only when [TreeSystem.dirty] is true.
class TreeRenderer {
  List<Mesh> _aliveMeshes   = [];
  List<Mesh> _burningMeshes = [];
  List<Mesh> _charredMeshes = [];

  // Identity transform: tree vertices are already in world space.
  final Transform3d _identity = Transform3d();

  static const double _kCullDist     = 130.0; // skip trees beyond this radius
  static const int    _kVertsPerMesh = 60000; // split threshold (< 65 535 hard limit)

  /// Build initial meshes during scene setup (no GPU resources to free yet).
  void prebuild(TreeSystem system, Vector3 cameraPos) {
    _aliveMeshes   = _buildBatch(system.trees, TreeState.alive,   cameraPos);
    _burningMeshes = _buildBatch(system.trees, TreeState.burning, cameraPos);
    _charredMeshes = _buildBatch(system.trees, TreeState.charred, cameraPos);
    system.dirty = false;
  }

  void render(WebGLRenderer renderer, TreeSystem system, Camera3D camera) {
    if (system.dirty) {
      _freeMeshes(renderer, _aliveMeshes);
      _freeMeshes(renderer, _burningMeshes);
      _freeMeshes(renderer, _charredMeshes);
      final cam = camera.position;
      _aliveMeshes   = _buildBatch(system.trees, TreeState.alive,   cam);
      _burningMeshes = _buildBatch(system.trees, TreeState.burning, cam);
      _charredMeshes = _buildBatch(system.trees, TreeState.charred, cam);
      system.dirty = false;
    }
    for (final m in _aliveMeshes)   renderer.render(m, _identity, camera);
    for (final m in _burningMeshes) renderer.render(m, _identity, camera);
    for (final m in _charredMeshes) renderer.render(m, _identity, camera);
  }

  void dispose(WebGLRenderer renderer) {
    _freeMeshes(renderer, _aliveMeshes);
    _freeMeshes(renderer, _burningMeshes);
    _freeMeshes(renderer, _charredMeshes);
  }

  void _freeMeshes(WebGLRenderer renderer, List<Mesh> meshes) {
    for (final m in meshes) renderer.deleteMeshBuffers(m);
    meshes.clear();
  }

  List<Mesh> _buildBatch(
      List<TreeInstance> trees, TreeState targetState, Vector3 cam) {
    final cullR2 = _kCullDist * _kCullDist;
    final result = <Mesh>[];
    var mb = _MeshBuilder();
    for (final t in trees) {
      if (t.state != targetState) continue;
      final dx = t.wx - cam.x;
      final dz = t.wz - cam.z;
      if (dx * dx + dz * dz > cullR2) continue;
      // Flush current segment before it can overflow Uint16.
      if (mb._vbase + 100 >= _kVertsPerMesh) {
        final m = mb.build();
        if (m != null) result.add(m);
        mb = _MeshBuilder();
      }
      switch (targetState) {
        case TreeState.alive:   _addLivingTree(mb, t);
        case TreeState.burning: _addBurningTree(mb, t);
        case TreeState.charred: _addStump(mb, t);
      }
    }
    final m = mb.build();
    if (m != null) result.add(m);
    return result;
  }

  // ── Tree geometry ──────────────────────────────────────────────────────────

  void _addLivingTree(_MeshBuilder mb, TreeInstance t) {
    final trunkH = t.height * 0.28;
    final crownY = t.wy + trunkH * 0.75;
    final cv = (math.sin(t.wx * 0.053 + t.wz * 0.071) + 1.0) * 0.5;

    _addTaperedPrism(mb, t.wx, t.wy, t.wy + trunkH, t.wz,
        t.trunkRadius, t.trunkRadius * 0.65, 0.34, 0.20, 0.09);

    if (t.type == 2) {
      _addTaperedPrism(mb, t.wx, t.wy + trunkH, t.wy + t.height, t.wz,
          t.trunkRadius * 0.65, t.trunkRadius * 0.30, 0.30, 0.22, 0.14);
      _addSnagBranches(mb, t.wx, t.wz, t.wy + t.height * 0.62,
          t.trunkRadius * 0.45, t.height * 0.20, 0.28, 0.20, 0.12);
    } else if (t.type == 0) {
      _addPineTiers(mb, t.wx, crownY, t.wz, t.canopyRadius, t.height - trunkH * 0.75, cv);
    } else {
      final dr = 0.17 + cv * 0.06;
      final dg = 0.46 + cv * 0.08;
      final db = 0.14 - cv * 0.05;
      _addRoundedCrown(mb, t.wx, crownY, t.wz,
          t.canopyRadius, t.height * 0.72 + trunkH * 0.25, dr, dg, db);
    }
  }

  void _addBurningTree(_MeshBuilder mb, TreeInstance t) {
    final trunkH = t.height * 0.28;
    final crownY = t.wy + trunkH * 0.75;
    _addTaperedPrism(mb, t.wx, t.wy, t.wy + trunkH, t.wz,
        t.trunkRadius, t.trunkRadius * 0.65, 0.22, 0.14, 0.06);
    if (t.type != 2) {
      if (t.type == 0) {
        _addPineTiersBurning(mb, t.wx, crownY, t.wz,
            t.canopyRadius * 0.85, t.height - trunkH * 0.75);
      } else {
        _addRoundedCrown(mb, t.wx, crownY, t.wz,
            t.canopyRadius * 0.85, t.height * 0.60 + trunkH * 0.25,
            0.65, 0.18, 0.04);
      }
    }
  }

  void _addStump(_MeshBuilder mb, TreeInstance t) {
    final stumpH = math.max(t.height * 0.14, 0.4);
    _addTaperedPrism(mb, t.wx, t.wy, t.wy + stumpH, t.wz,
        t.trunkRadius * 0.75, t.trunkRadius * 0.55, 0.14, 0.10, 0.08);
  }

  // ── Crown builders ─────────────────────────────────────────────────────────

  void _addPineTiers(_MeshBuilder mb, double cx, double baseY, double cz,
      double baseR, double crownH, [double cv = 0.5]) {
    final t1Apex = baseY + crownH * 0.46;
    final t2Apex = baseY + crownH * 0.72;
    final t3Apex = baseY + crownH;
    final pg = 0.34 + cv * 0.08;
    final pb = 0.12 - cv * 0.06;
    _addCone(mb, cx, baseY, cz, baseR, t1Apex, 0.11, pg, pb);
    _addCone(mb, cx, baseY + crownH * 0.22, cz, baseR * 0.70, t2Apex, 0.13, pg * 1.14, pb * 0.90);
    _addCone(mb, cx, baseY + crownH * 0.48, cz, baseR * 0.42, t3Apex, 0.16, pg * 1.24, pb * 0.80);
  }

  void _addPineTiersBurning(_MeshBuilder mb, double cx, double baseY, double cz,
      double baseR, double crownH) {
    final t1Apex = baseY + crownH * 0.46;
    final t2Apex = baseY + crownH * 0.72;
    final t3Apex = baseY + crownH * 0.88;
    _addCone(mb, cx, baseY, cz, baseR, t1Apex, 0.70, 0.20, 0.03);
    _addCone(mb, cx, baseY + crownH * 0.22, cz, baseR * 0.65, t2Apex, 0.55, 0.14, 0.02);
    _addCone(mb, cx, baseY + crownH * 0.46, cz, baseR * 0.38, t3Apex, 0.40, 0.10, 0.01);
  }

  /// 4-ring rounded crown for deciduous trees (8-sided for mesh budget).
  void _addRoundedCrown(_MeshBuilder mb, double cx, double baseY, double cz,
      double canopyR, double crownH, double r, double g, double b) {
    const sides = 8;
    const step  = math.pi * 2 / sides;

    final ring2Y = baseY + crownH * 0.28;
    final ring3Y = baseY + crownH * 0.58;
    final ring4Y = baseY + crownH * 0.80;
    final topY   = baseY + crownH;

    final r1 = canopyR;
    final r2 = canopyR * 1.14;
    final r3 = canopyR * 0.82;
    final r4 = canopyR * 0.40;

    final v1 = mb._vbase;
    for (int s = 0; s < sides; s++) {
      final a = s * step;
      mb._addVertex(cx + math.cos(a) * r1, baseY, cz + math.sin(a) * r1,
          0, 0.7, 0.3, r, g, b);
    }
    final v2 = mb._vbase;
    for (int s = 0; s < sides; s++) {
      final a = s * step;
      mb._addVertex(cx + math.cos(a) * r2, ring2Y, cz + math.sin(a) * r2,
          0, 0.7, 0.3, r * 1.08, g * 1.08, b * 0.95);
    }
    final v3 = mb._vbase;
    for (int s = 0; s < sides; s++) {
      final a = s * step;
      mb._addVertex(cx + math.cos(a) * r3, ring3Y, cz + math.sin(a) * r3,
          0, 0.8, 0.2, r * 1.04, g * 1.04, b);
    }
    final v4 = mb._vbase;
    for (int s = 0; s < sides; s++) {
      final a = s * step;
      mb._addVertex(cx + math.cos(a) * r4, ring4Y, cz + math.sin(a) * r4,
          0, 0.9, 0.1, r * 0.92, g * 0.95, b * 0.85);
    }
    final apex = mb._vbase;
    mb._addVertex(cx, topY, cz, 0, 1, 0, r * 0.82, g * 0.88, b * 0.72);

    _beltQuads(mb, v1, v2, sides);
    _beltQuads(mb, v2, v3, sides);
    _beltQuads(mb, v3, v4, sides);
    for (int s = 0; s < sides; s++) {
      mb._addTriangle(v4 + s, apex, v4 + (s + 1) % sides);
    }
  }

  void _beltQuads(_MeshBuilder mb, int loBase, int hiBase, int sides) {
    for (int s = 0; s < sides; s++) {
      final a0 = loBase + s;
      final a1 = loBase + (s + 1) % sides;
      final b0 = hiBase + s;
      final b1 = hiBase + (s + 1) % sides;
      mb._addTriangle(a0, b0, a1);
      mb._addTriangle(a1, b0, b1);
    }
  }

  void _addSnagBranches(_MeshBuilder mb, double cx, double cz, double y,
      double halfW, double reach, double r, double g, double b) {
    _addPrism(mb, cx + reach * 0.55, y,            y + halfW,        cz,             halfW * 0.6,  r, g, b);
    _addPrism(mb, cx,                y + halfW * 2, y + halfW * 2.8, cz - reach * 0.40, halfW * 0.55, r, g, b);
  }

  // ── Primitive builders ─────────────────────────────────────────────────────

  void _addTaperedPrism(_MeshBuilder mb, double cx, double y0, double y1,
      double cz, double halfWBot, double halfWTop,
      double r, double g, double b) {
    final xb0 = cx - halfWBot, xb1 = cx + halfWBot;
    final xt0 = cx - halfWTop, xt1 = cx + halfWTop;
    final zb0 = cz - halfWBot, zb1 = cz + halfWBot;
    final zt0 = cz - halfWTop, zt1 = cz + halfWTop;
    _addQuad(mb, xb1,y0,zb1, xb0,y0,zb1, xt0,y1,zt1, xt1,y1,zt1,  0, 0, 1, r,g,b);
    _addQuad(mb, xb0,y0,zb0, xb1,y0,zb0, xt1,y1,zt0, xt0,y1,zt0,  0, 0,-1, r,g,b);
    _addQuad(mb, xb1,y0,zb0, xb1,y0,zb1, xt1,y1,zt1, xt1,y1,zt0,  1, 0, 0, r,g,b);
    _addQuad(mb, xb0,y0,zb1, xb0,y0,zb0, xt0,y1,zt0, xt0,y1,zt1, -1, 0, 0, r,g,b);
  }

  void _addPrism(_MeshBuilder mb, double cx, double y0, double y1,
      double cz, double halfW, double r, double g, double b) =>
      _addTaperedPrism(mb, cx, y0, y1, cz, halfW, halfW, r, g, b);

  void _addCone(_MeshBuilder mb, double cx, double baseY, double cz,
      double baseR, double apexY, double r, double g, double b) {
    const sides = 8;
    const step  = math.pi * 2 / sides;
    final rise  = apexY - baseY;

    for (int s = 0; s < sides; s++) {
      final a0  = s * step;
      final a1  = (s + 1) * step;
      final bx0 = cx + math.cos(a0) * baseR;
      final bz0 = cz + math.sin(a0) * baseR;
      final bx1 = cx + math.cos(a1) * baseR;
      final bz1 = cz + math.sin(a1) * baseR;

      final midA = a0 + step * 0.5;
      final nLen = math.sqrt(rise * rise + baseR * baseR);
      final nx   = math.cos(midA) * rise / nLen;
      final nz   = math.sin(midA) * rise / nLen;
      final ny   = baseR / nLen;

      final base = mb._vbase;
      mb._addVertex(bx0, baseY, bz0, nx, ny, nz, r, g, b);
      mb._addVertex(bx1, baseY, bz1, nx, ny, nz, r * 0.85, g * 0.85, b * 0.7);
      mb._addVertex(cx,  apexY, cz,  nx, ny, nz, r * 0.75, g * 0.75, b * 0.6);
      mb._addTriangle(base, base + 1, base + 2);
    }
  }

  void _addQuad(_MeshBuilder mb,
      double x0, double y0, double z0,
      double x1, double y1, double z1,
      double x2, double y2, double z2,
      double x3, double y3, double z3,
      double nx, double ny, double nz,
      double r,  double g,  double b) {
    final base = mb._vbase;
    mb._addVertex(x0, y0, z0, nx, ny, nz, r, g, b);
    mb._addVertex(x1, y1, z1, nx, ny, nz, r, g, b);
    mb._addVertex(x2, y2, z2, nx, ny, nz, r, g, b);
    mb._addVertex(x3, y3, z3, nx, ny, nz, r, g, b);
    mb._addTriangle(base, base + 1, base + 2);
    mb._addTriangle(base, base + 2, base + 3);
  }
}

// ── Mesh builder ──────────────────────────────────────────────────────────────

class _MeshBuilder {
  final List<double> _verts = [];
  final List<double> _norms = [];
  final List<double> _cols  = [];
  final List<int>    _idxs  = [];

  int get _vbase => _verts.length ~/ 3;

  void _addVertex(double x, double y, double z,
      double nx, double ny, double nz,
      double r, double g, double b) {
    _verts.addAll([x, y, z]);
    _norms.addAll([nx, ny, nz]);
    _cols.addAll([r, g, b, 1.0]);
  }

  void _addTriangle(int a, int b, int c) => _idxs.addAll([a, b, c]);

  Mesh? build() {
    if (_verts.isEmpty) return null;
    return Mesh(
      vertices: Float32List.fromList(_verts),
      indices:  Uint16List.fromList(_idxs),
      normals:  Float32List.fromList(_norms),
      colors:   Float32List.fromList(_cols),
    );
  }
}
