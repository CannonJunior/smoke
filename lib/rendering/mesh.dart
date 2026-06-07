import 'dart:typed_data';
import 'package:vector_math/vector_math.dart';

/// Mesh - 3D geometry data for WebGL rendering.
///
/// Stores vertex positions, triangle indices, normals, and per-vertex RGBA
/// colors as typed arrays ready for direct upload to GPU buffers.
///
/// Usage:
/// ```dart
/// final mesh = Mesh.cube(size: 1.0, color: Vector3(1.0, 0.5, 0.0));
/// renderer.render(mesh, transform, camera);
/// ```
class Mesh {
  /// Packed vertex positions: [x1, y1, z1, x2, y2, z2, ...]
  final Float32List vertices;

  /// Triangle indices (3 per triangle)
  final Uint16List indices;

  /// Per-vertex normals (same count as vertices)
  final Float32List? normals;

  /// Per-vertex RGBA colors: [r, g, b, a, r, g, b, a, ...]
  final Float32List? colors;

  Mesh({
    required this.vertices,
    required this.indices,
    this.normals,
    this.colors,
  });

  /// Number of vertices in this mesh.
  int get vertexCount => vertices.length ~/ 3;

  /// Number of triangles in this mesh.
  int get triangleCount => indices.length ~/ 3;

  // ── Factory constructors ─────────────────────────────────────────────────

  /// Create a unit cube with uniform color.
  ///
  /// Generates 6 faces × 4 vertices = 24 vertices with correct normals
  /// for lighting. [size] is the side length; [color] is RGB 0-1.
  factory Mesh.cube({double size = 1.0, Vector3? color}) {
    final h = size / 2.0;
    final c = color ?? Vector3(0.8, 0.8, 0.8);

    // 6 faces, 4 vertices each = 24 vertices
    final verts = <double>[];
    final norms = <double>[];
    final cols  = <double>[];
    final idxs  = <int>[];

    // Helper: add a quad face with a given normal and 4 corner positions.
    // Reason: generating per-face avoids shared-vertex normal averaging,
    // giving hard-edged shading appropriate for an aircraft mesh.
    void addFace(List<List<double>> corners, List<double> normal) {
      final base = verts.length ~/ 3;
      for (final v in corners) {
        verts.addAll(v);
        norms.addAll(normal);
        cols.addAll([c.x, c.y, c.z, 1.0]);
      }
      // Two triangles per quad (CCW winding)
      idxs.addAll([base, base + 1, base + 2, base, base + 2, base + 3]);
    }

    // +Y top
    addFace([[-h,h,-h],[h,h,-h],[h,h,h],[-h,h,h]], [0,1,0]);
    // -Y bottom
    addFace([[-h,-h,h],[h,-h,h],[h,-h,-h],[-h,-h,-h]], [0,-1,0]);
    // +X right
    addFace([[h,-h,-h],[h,-h,h],[h,h,h],[h,h,-h]], [1,0,0]);
    // -X left
    addFace([[-h,-h,h],[-h,-h,-h],[-h,h,-h],[-h,h,h]], [-1,0,0]);
    // -Z front
    addFace([[-h,-h,-h],[h,-h,-h],[h,h,-h],[-h,h,-h]], [0,0,-1]);
    // +Z back
    addFace([[h,-h,h],[-h,-h,h],[-h,h,h],[h,h,h]], [0,0,1]);

    return Mesh(
      vertices: Float32List.fromList(verts),
      indices:  Uint16List.fromList(idxs),
      normals:  Float32List.fromList(norms),
      colors:   Float32List.fromList(cols),
    );
  }

  /// Create a detailed fighter-jet aircraft mesh ported from the Racer project.
  ///
  /// Coordinate convention (matches transform3d forward = -Z):
  ///   nose at  z = -halfLength  (forward / -Z direction)
  ///   tail at  z = +halfLength  (aft    / +Z direction)
  ///
  /// [length] sets the fuselage length (default 4.0 world units).
  /// [primaryColor]   → fuselage and nose (default ice-blue).
  /// [secondaryColor] → wings and tail surfaces (default dark gray).
  factory Mesh.aircraft({
    double length = 4.0,
    Vector3? primaryColor,
    Vector3? secondaryColor,
  }) {
    final primary   = primaryColor   ?? Vector3(0.2, 0.5, 0.9); // Ice blue
    final secondary = secondaryColor ?? Vector3(0.15, 0.3, 0.6); // Darker blue

    final hl = length / 2;       // half-length
    final bw = length * 0.15;    // body width
    final bh = length * 0.12;    // body height
    final ws = length * 0.8;     // full wing span
    final tH = length * 0.2;     // tail fin height

    final List<double> verts = [];
    final List<int>    inds  = [];
    final List<double> norms = [];
    final List<double> cols  = [];
    int vo = 0; // running vertex offset for index correction

    void add(List<double> v, List<int> i, List<double> n, Vector3 col) {
      final nv = v.length ~/ 3;
      verts.addAll(v);
      norms.addAll(n);
      for (int k = 0; k < nv; k++) cols.addAll([col.x, col.y, col.z, 1.0]);
      for (final idx in i) inds.add(idx + vo);
      vo += nv;
    }

    // ── Nose cone (tip at -hl, flares toward body) ────────────────────────────
    add([
       0,      0,      -hl,
      -bw*0.3,-bh*0.3,-hl*0.7,
       bw*0.3,-bh*0.3,-hl*0.7,
       bw*0.5, 0,     -hl*0.7,
       bw*0.3, bh*0.3,-hl*0.7,
      -bw*0.3, bh*0.3,-hl*0.7,
      -bw*0.5, 0,     -hl*0.7,
    ], [
      0,2,1, 0,3,2, 0,4,3, 0,5,4, 0,6,5, 0,1,6,
    ], [
       0,    0,   -1,
      -0.5,-0.5,-0.7,  0.5,-0.5,-0.7,  0.7, 0,-0.7,
       0.5, 0.5,-0.7, -0.5, 0.5,-0.7, -0.7, 0,-0.7,
    ], primary);

    // ── Main fuselage body ────────────────────────────────────────────────────
    add([
      // front ring at -hl*0.5
      -bw*0.5,-bh*0.5,-hl*0.5,  bw*0.5,-bh*0.5,-hl*0.5,
       bw*0.7, 0,     -hl*0.5,  bw*0.5, bh*0.5,-hl*0.5,
      -bw*0.5, bh*0.5,-hl*0.5, -bw*0.7, 0,     -hl*0.5,
      // rear ring at +hl*0.6
      -bw*0.5,-bh*0.5, hl*0.6,  bw*0.5,-bh*0.5, hl*0.6,
       bw*0.7, 0,      hl*0.6,  bw*0.5, bh*0.5, hl*0.6,
      -bw*0.5, bh*0.5, hl*0.6, -bw*0.7, 0,      hl*0.6,
    ], [
      0,1,7, 0,7,6,  1,2,8, 1,8,7,  2,3,9,  2,9,8,
      3,4,10,3,10,9, 4,5,11,4,11,10, 5,0,6, 5,6,11,
    ], [
      -0.5,-0.5,0, 0.5,-0.5,0,  1,0,0,  0.5,0.5,0, -0.5,0.5,0, -1,0,0,
      -0.5,-0.5,0, 0.5,-0.5,0,  1,0,0,  0.5,0.5,0, -0.5,0.5,0, -1,0,0,
    ], primary);

    // ── Left delta wing ───────────────────────────────────────────────────────
    add([
      -bw*0.7,  0,     -hl*0.2,
      -bw*0.7,  0,      hl*0.5,
      -ws/2,    0,      hl*0.3,
      -bw*0.7, -0.02,  -hl*0.2,
      -bw*0.7, -0.02,   hl*0.5,
      -ws/2,   -0.02,   hl*0.3,
    ], [0,1,2, 3,5,4], [
      0,1,0, 0,1,0, 0,1,0, 0,-1,0, 0,-1,0, 0,-1,0,
    ], secondary);

    // ── Right delta wing ──────────────────────────────────────────────────────
    add([
       bw*0.7,  0,     -hl*0.2,
       bw*0.7,  0,      hl*0.5,
       ws/2,    0,      hl*0.3,
       bw*0.7, -0.02,  -hl*0.2,
       bw*0.7, -0.02,   hl*0.5,
       ws/2,   -0.02,   hl*0.3,
    ], [0,2,1, 3,4,5], [
      0,1,0, 0,1,0, 0,1,0, 0,-1,0, 0,-1,0, 0,-1,0,
    ], secondary);

    // ── Vertical tail fin ─────────────────────────────────────────────────────
    add([
      0, bh*0.5,      hl*0.4,
      0, bh*0.5,      hl*0.8,
      0, bh*0.5 + tH, hl*0.7,
    ], [0,1,2], [1,0,0, 1,0,0, 1,0,0], secondary);

    // ── Rear engine cone ──────────────────────────────────────────────────────
    add([
      -bw*0.4,-bh*0.3, hl*0.8,
       bw*0.4,-bh*0.3, hl*0.8,
       bw*0.4, bh*0.3, hl*0.8,
      -bw*0.4, bh*0.3, hl*0.8,
       0,      0,      hl,
    ], [0,1,4, 1,2,4, 2,3,4, 3,0,4], [
      -0.5,-0.5,0.7, 0.5,-0.5,0.7, 0.5,0.5,0.7, -0.5,0.5,0.7, 0,0,1,
    ], Vector3(0.1, 0.1, 0.2)); // Dark engine

    // ── Cockpit canopy ────────────────────────────────────────────────────────
    add([
      -bw*0.3,  bh*0.4, -hl*0.4,
       bw*0.3,  bh*0.4, -hl*0.4,
       bw*0.25, bh*0.4, -hl*0.1,
      -bw*0.25, bh*0.4, -hl*0.1,
       0,       bh*0.7, -hl*0.25,
    ], [0,1,4, 1,2,4, 2,3,4, 3,0,4, 0,3,2, 0,2,1], [
      -0.5,0.7,-0.5, 0.5,0.7,-0.5, 0.5,0.7,0.5, -0.5,0.7,0.5, 0,1,0,
    ], Vector3(0.5, 0.8, 1.0)); // Ice-tinted cockpit glass

    return Mesh(
      vertices: Float32List.fromList(verts),
      indices:  Uint16List.fromList(inds),
      normals:  Float32List.fromList(norms),
      colors:   Float32List.fromList(cols),
    );
  }

  /// Thin flat panel for control surfaces (aileron, elevator, flap, bay door).
  ///
  /// Local coordinate convention:
  ///  - X spans ±[halfSpan] (spanwise axis — the rotation axis for ailerons/elevator)
  ///  - Z runs from 0 (hinge / leading edge) to +[chord] (trailing edge)
  ///  - Y runs ±[thickness]/2 (surface thickness)
  ///
  /// Placing the hinge at Z=0 means rotating the SceneNode around its local X
  /// axis correctly sweeps the surface about the hinge line.
  ///
  /// For rudders (vertical surface), rotate the owning SceneNode 90° around Z
  /// so that the span axis becomes Y rather than X.
  factory Mesh.flatPanel({
    required double halfSpan,
    required double chord,
    required double thickness,
    required Vector3 color,
  }) {
    final s = halfSpan;
    final c = chord;
    final t = thickness / 2.0;
    final col = color;

    final verts = <double>[];
    final norms  = <double>[];
    final cols   = <double>[];
    final idxs   = <int>[];

    void addFace(List<List<double>> corners, List<double> n) {
      final b = verts.length ~/ 3;
      for (final v in corners) {
        verts.addAll(v);
        norms.addAll(n);
        cols.addAll([col.x, col.y, col.z, 1.0]);
      }
      idxs.addAll([b, b + 1, b + 2, b, b + 2, b + 3]);
    }

    // +Y top face (normal up)
    addFace([[-s, t, 0], [s, t, 0], [s, t, c], [-s, t, c]], [0, 1, 0]);
    // -Y bottom face (normal down)
    addFace([[-s, -t, c], [s, -t, c], [s, -t, 0], [-s, -t, 0]], [0, -1, 0]);
    // Hinge edge at Z=0 (leading — faces -Z)
    addFace([[-s, -t, 0], [s, -t, 0], [s, t, 0], [-s, t, 0]], [0, 0, -1]);
    // Trailing edge at Z=c (faces +Z)
    addFace([[-s, t, c], [s, t, c], [s, -t, c], [-s, -t, c]], [0, 0, 1]);
    // Left tip at X=-s (faces -X)
    addFace([[-s, t, 0], [-s, t, c], [-s, -t, c], [-s, -t, 0]], [-1, 0, 0]);
    // Right tip at X=+s (faces +X)
    addFace([[s, -t, 0], [s, -t, c], [s, t, c], [s, t, 0]], [1, 0, 0]);

    return Mesh(
      vertices: Float32List.fromList(verts),
      indices:  Uint16List.fromList(idxs),
      normals:  Float32List.fromList(norms),
      colors:   Float32List.fromList(cols),
    );
  }

  /// Box strut for landing gear legs — attachment point at Y=0, tip at Y=-[length].
  ///
  /// Placing the attachment at local Y=0 means SceneNode.position points at the
  /// wing attachment and the strut naturally hangs downward. Driven by
  /// [gearProgress] via SceneNode.position.y in the game loop.
  factory Mesh.strut({
    required double length,
    required double radius,
    required Vector3 color,
  }) {
    final r = radius;
    final l = length;
    final c = color;

    final verts = <double>[];
    final norms  = <double>[];
    final cols   = <double>[];
    final idxs   = <int>[];

    void addFace(List<List<double>> corners, List<double> n) {
      final b = verts.length ~/ 3;
      for (final v in corners) { verts.addAll(v); norms.addAll(n); cols.addAll([c.x,c.y,c.z,1.0]); }
      idxs.addAll([b,b+1,b+2, b,b+2,b+3]);
    }

    // Box from Y=0 (top, attachment) to Y=-length (tip), ±radius in X and Z
    addFace([[-r,0,-r],[r,0,-r],[r,0,r],[-r,0,r]], [0,1,0]);       // top cap
    addFace([[-r,-l,r],[r,-l,r],[r,-l,-r],[-r,-l,-r]], [0,-1,0]);  // bottom cap
    addFace([[r,0,-r],[r,0,r],[r,-l,r],[r,-l,-r]], [1,0,0]);        // +X
    addFace([[-r,0,r],[-r,0,-r],[-r,-l,-r],[-r,-l,r]], [-1,0,0]);  // -X
    addFace([[-r,0,-r],[-r,-l,-r],[r,-l,-r],[r,0,-r]], [0,0,-1]);   // -Z
    addFace([[r,0,r],[r,-l,r],[-r,-l,r],[-r,0,r]], [0,0,1]);        // +Z

    return Mesh(vertices: Float32List.fromList(verts), indices: Uint16List.fromList(idxs),
        normals: Float32List.fromList(norms), colors: Float32List.fromList(cols));
  }

  /// Backward-compat alias — delegates to [Mesh.aircraft].
  factory Mesh.createCharacterMesh({double size = 1.0}) =>
      Mesh.aircraft(length: size * 4.0);

  // ignore: unused_element
  static Mesh _buildFromParts(List<_BoxPart> parts) {
    final verts = <double>[];
    final norms = <double>[];
    final cols  = <double>[];
    final idxs  = <int>[];

    for (final part in parts) {
      final hx = part.sx / 2;
      final hy = part.sy / 2;
      final hz = part.sz / 2;
      final cx = part.cx;
      final cy = part.cy;
      final cz = part.cz;
      final c  = part.color;

      // Inline addFace for each part
      void addFace(List<List<double>> corners, List<double> normal) {
        final b = verts.length ~/ 3;
        for (final v in corners) {
          verts.addAll(v);
          norms.addAll(normal);
          cols.addAll([c.x, c.y, c.z, 1.0]);
        }
        idxs.addAll([b, b+1, b+2, b, b+2, b+3]);
      }

      // +Y
      addFace([[cx-hx,cy+hy,cz-hz],[cx+hx,cy+hy,cz-hz],[cx+hx,cy+hy,cz+hz],[cx-hx,cy+hy,cz+hz]],[0,1,0]);
      // -Y
      addFace([[cx-hx,cy-hy,cz+hz],[cx+hx,cy-hy,cz+hz],[cx+hx,cy-hy,cz-hz],[cx-hx,cy-hy,cz-hz]],[0,-1,0]);
      // +X
      addFace([[cx+hx,cy-hy,cz-hz],[cx+hx,cy-hy,cz+hz],[cx+hx,cy+hy,cz+hz],[cx+hx,cy+hy,cz-hz]],[1,0,0]);
      // -X
      addFace([[cx-hx,cy-hy,cz+hz],[cx-hx,cy-hy,cz-hz],[cx-hx,cy+hy,cz-hz],[cx-hx,cy+hy,cz+hz]],[-1,0,0]);
      // -Z
      addFace([[cx-hx,cy-hy,cz-hz],[cx+hx,cy-hy,cz-hz],[cx+hx,cy+hy,cz-hz],[cx-hx,cy+hy,cz-hz]],[0,0,-1]);
      // +Z
      addFace([[cx+hx,cy-hy,cz+hz],[cx-hx,cy-hy,cz+hz],[cx-hx,cy+hy,cz+hz],[cx+hx,cy+hy,cz+hz]],[0,0,1]);
    }

    return Mesh(
      vertices: Float32List.fromList(verts),
      indices:  Uint16List.fromList(idxs),
      normals:  Float32List.fromList(norms),
      colors:   Float32List.fromList(cols),
    );
  }
}

/// Internal helper: describes one box component of a composite mesh.
class _BoxPart {
  final double cx, cy, cz; // Center position
  final double sx, sy, sz; // Full extents (not half)
  final Vector3 color;

  const _BoxPart({
    required this.cx, required this.cy, required this.cz,
    required this.sx, required this.sy, required this.sz,
    required this.color,
  });
}
