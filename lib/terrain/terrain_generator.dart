import 'dart:math' as math;
import 'dart:typed_data';
import 'package:vector_math/vector_math.dart';
import '../rendering/mesh.dart';
import '../rendering/transform3d.dart';

/// TerrainGenerator - Procedural heightmap terrain generation.
///
/// Uses bilinear value noise (smoothstep-interpolated hash lattice) for FBM.
/// Height-based vertex coloring: blue valleys → sandy lowlands → green
/// mid-terrain → grey highlands → white snow peaks.
/// Flat zones can be registered (e.g. around the airfield) to suppress hills.
class TerrainGenerator {
  TerrainGenerator._(); // Static-only class

  /// Canonical max terrain height in world units.
  /// Must match [InfiniteTerrainManager._maxHeight].
  static const double kTerrainMaxHeight = 80.0;

  // ── Flat zones ────────────────────────────────────────────────────────────
  // Flat zones suppress terrain height to 0 within a given radius (with a
  // smooth blend) so that structures like the airfield sit flush with
  // the ground.  Call addFlatZone() before preloading terrain chunks.

  static final List<(double, double, double, double)> _flatZones = [];

  /// Register a circular flat zone centred at world (wx, wz).
  static void addFlatZone(double wx, double wz, double radius,
      {double blend = 40.0}) =>
      _flatZones.add((wx, wz, radius, blend));

  static void clearFlatZones() => _flatZones.clear();

  /// Smoothly suppress [h] toward 0 if the point (worldX, worldZ) falls
  /// inside any registered flat zone.
  static double _applyFlatZones(double worldX, double worldZ, double h) {
    for (final (fx, fz, r, blend) in _flatZones) {
      final dx = worldX - fx;
      final dz = worldZ - fz;
      final d = math.sqrt(dx * dx + dz * dz);
      if (d < r) return 0.0;
      if (d < r + blend) {
        final t = (d - r) / blend;
        return h * t * t * (3.0 - 2.0 * t); // smoothstep blend
      }
    }
    return h;
  }

  // ── Public API ───────────────────────────────────────────────────────────

  /// Generate a single centred terrain mesh (original single-tile API).
  static ({Mesh mesh, Transform3d transform}) generate({
    int gridSize    = 64,
    double tileSize = 2.0,
    double maxHeight = 12.0,
    int seed        = 42,
  }) {
    final heights = _generateHeightmap(gridSize, maxHeight, seed);
    final mesh    = _buildMesh(gridSize, tileSize, maxHeight, heights, center: true);
    return (mesh: mesh, transform: Transform3d());
  }

  /// Return the terrain height at world position (wx, wz).
  ///
  /// Mirrors the chunk generator formula exactly so physics queries are
  /// consistent with the visual mesh.  Flat zones are applied so physics
  /// agrees with terrain suppressed under the airfield.
  static double heightAt(double wx, double wz) {
    const so = 1337 * 8.37; // seed offset — matches _generateChunkHeightmap
    final nx = wx + so;
    final nz = wz + so;
    double h = 0.5000 * (_noise(nx * 0.01641, nz * 0.01641) * 2 - 1);
    h       += 0.2500 * (_noise(nx * 0.03359, nz * 0.03359) * 2 - 1);
    h       += 0.1250 * (_noise(nx * 0.06797, nz * 0.06797) * 2 - 1);
    h       += 0.0625 * (_noise(nx * 0.13359, nz * 0.13359) * 2 - 1);
    h = (h + 0.9375) / 1.875;
    h = h.clamp(0.0, 1.0) * kTerrainMaxHeight;
    if (h < kTerrainMaxHeight * 0.15) h *= 0.4;
    return _applyFlatZones(wx, wz, h);
  }

  /// Generate one chunk of an infinite terrain grid.
  ///
  /// Uses world-space coordinates for the noise function so heights are
  /// perfectly continuous at every chunk boundary.  Vertex (0, ?, 0) in
  /// local space corresponds to world position
  /// (chunkX × gridSize × tileSize, ?, chunkZ × gridSize × tileSize).
  static Mesh generateChunk({
    required int chunkX,
    required int chunkZ,
    int gridSize     = 32,
    double tileSize  = 2.0,
    double maxHeight = kTerrainMaxHeight,
    int seed         = 1337,
  }) {
    final heights = _generateChunkHeightmap(
        chunkX, chunkZ, gridSize, tileSize, maxHeight, seed);
    return _buildMesh(gridSize, tileSize, maxHeight, heights, center: false);
  }

  // ── Heightmap generation ─────────────────────────────────────────────────

  /// Build a 2D heightmap for the single-tile (legacy) API using FBM value noise.
  static List<List<double>> _generateHeightmap(
    int size,
    double maxHeight,
    int seed,
  ) {
    // Reason: offset by seed so different seeds produce different maps
    final seedOff = seed.toDouble() * 0.123;

    final heights = List.generate(
      size + 1,
      (_) => List<double>.filled(size + 1, 0.0),
    );

    for (int z = 0; z <= size; z++) {
      for (int x = 0; x <= size; x++) {
        final nx = x / size.toDouble() + seedOff;
        final nz = z / size.toDouble() + seedOff;

        double h = 0.5000 * (_noise(nx * 2.1,  nz * 2.1)  * 2 - 1);
        h       += 0.2500 * (_noise(nx * 4.3,  nz * 4.3)  * 2 - 1);
        h       += 0.1250 * (_noise(nx * 8.7,  nz * 8.7)  * 2 - 1);
        h       += 0.0625 * (_noise(nx * 17.1, nz * 17.1) * 2 - 1);

        h = (h + 0.9375) / 1.875;
        h = h.clamp(0.0, 1.0) * maxHeight;
        if (h < maxHeight * 0.15) h *= 0.4;

        heights[z][x] = h;
      }
    }

    return heights;
  }

  /// Heightmap for one chunk using global world coordinates.
  ///
  /// The noise is sampled at the same frequency as the single-mesh variant
  /// but at absolute world positions, guaranteeing seamless edges between
  /// adjacent chunks regardless of render distance or generation order.
  static List<List<double>> _generateChunkHeightmap(
    int chunkX, int chunkZ,
    int size, double tileSize, double maxHeight, int seed,
  ) {
    // Seed-derived world offset so different seeds look different
    final so = seed * 8.37;

    final heights = List.generate(size + 1, (_) => List<double>.filled(size + 1, 0.0));

    for (int iz = 0; iz <= size; iz++) {
      for (int ix = 0; ix <= size; ix++) {
        // World-space coordinates (absolute) — ensures seamless chunk edges.
        final worldX = (chunkX * size + ix) * tileSize;
        final worldZ = (chunkZ * size + iz) * tileSize;
        final wx = worldX + so; // noise input (seed-shifted)
        final wz = worldZ + so;

        double h = 0.5000 * (_noise(wx * 0.01641, wz * 0.01641) * 2 - 1);
        h       += 0.2500 * (_noise(wx * 0.03359, wz * 0.03359) * 2 - 1);
        h       += 0.1250 * (_noise(wx * 0.06797, wz * 0.06797) * 2 - 1);
        h       += 0.0625 * (_noise(wx * 0.13359, wz * 0.13359) * 2 - 1);

        h = (h + 0.9375) / 1.875;
        h = h.clamp(0.0, 1.0) * maxHeight;
        if (h < maxHeight * 0.15) h *= 0.4;
        h = _applyFlatZones(worldX, worldZ, h);

        heights[iz][ix] = h;
      }
    }
    return heights;
  }

  // ── Value noise ──────────────────────────────────────────────────────────
  // Bilinear value noise with smoothstep interpolation.
  // Returns [0, 1].  Callers use (noise * 2 - 1) to get [-1, 1] for FBM.
  // Unlike the old sin/cos product, this has no zero-crossing grid lines and
  // no long-range periodicity at playable render distances.

  static double _fract(double x) => x - x.floorToDouble();

  static double _hash(double x, double z) {
    final v = math.sin(x * 127.1 + z * 311.7) * 43758.5453;
    return _fract(v.abs()); // [0, 1)
  }

  static double _mix(double a, double b, double t) => a + (b - a) * t;

  static double _noise(double x, double z) {
    final ix = x.floorToDouble();
    final iz = z.floorToDouble();
    final fx = x - ix;
    final fz = z - iz;
    final ux = fx * fx * (3.0 - 2.0 * fx); // smoothstep
    final uz = fz * fz * (3.0 - 2.0 * fz);
    return _mix(
      _mix(_hash(ix,       iz),       _hash(ix + 1.0, iz),       ux),
      _mix(_hash(ix,       iz + 1.0), _hash(ix + 1.0, iz + 1.0), ux),
      uz,
    );
  }

  // ── Mesh construction ────────────────────────────────────────────────────

  /// Build the terrain Mesh from a heightmap.
  ///
  /// [center] = true  → vertices span (−half, 0, −half) to (+half, ?, +half),
  ///            suitable for a single mesh centred at world origin.
  /// [center] = false → vertices span (0, 0, 0) to (size×tileSize, ?, size×tileSize),
  ///            suitable for chunks positioned by a world-space Transform3d.
  static Mesh _buildMesh(
    int size,
    double tileSize,
    double maxHeight,
    List<List<double>> heights, {
    bool center = true,
  }) {
    final vertexCount  = (size + 1) * (size + 1);
    final indexCount   = size * size * 6;

    final vertices = Float32List(vertexCount * 3);
    final normals  = Float32List(vertexCount * 3);
    final colors   = Float32List(vertexCount * 4);
    final indices  = Uint16List(indexCount);

    // ── Vertices + colors ────────────────────────────────────────────────
    for (int z = 0; z <= size; z++) {
      for (int x = 0; x <= size; x++) {
        final vi = (z * (size + 1) + x);
        final h  = heights[z][x];

        final ox = center ? x - size / 2.0 : x.toDouble();
        final oz = center ? z - size / 2.0 : z.toDouble();
        vertices[vi * 3 + 0] = ox * tileSize;
        vertices[vi * 3 + 1] = h;
        vertices[vi * 3 + 2] = oz * tileSize;

        // Height-based coloring
        final t = h / maxHeight; // 0 = valley, 1 = peak
        final c = _heightColor(t);

        colors[vi * 4 + 0] = c.x;
        colors[vi * 4 + 1] = c.y;
        colors[vi * 4 + 2] = c.z;
        colors[vi * 4 + 3] = 1.0;
      }
    }

    // ── Indices ──────────────────────────────────────────────────────────
    int idx = 0;
    for (int z = 0; z < size; z++) {
      for (int x = 0; x < size; x++) {
        final tl = z * (size + 1) + x;
        final tr = tl + 1;
        final bl = (z + 1) * (size + 1) + x;
        final br = bl + 1;

        indices[idx++] = tl;
        indices[idx++] = bl;
        indices[idx++] = br;

        indices[idx++] = tl;
        indices[idx++] = br;
        indices[idx++] = tr;
      }
    }

    // ── Normals (accumulate then normalise) ───────────────────────────────
    // Reason: accumulating face normals per-vertex then normalising gives
    // smooth shading similar to vertex-normal averaging in DCC tools.
    for (int z = 0; z < size; z++) {
      for (int x = 0; x < size; x++) {
        final tl = z * (size + 1) + x;
        final tr = tl + 1;
        final bl = (z + 1) * (size + 1) + x;
        final br = bl + 1;

        _accumulateFaceNormal(vertices, normals, tl, bl, br);
        _accumulateFaceNormal(vertices, normals, tl, br, tr);
      }
    }

    // Normalise accumulated normals
    for (int vi = 0; vi < vertexCount; vi++) {
      final nx = normals[vi * 3 + 0];
      final ny = normals[vi * 3 + 1];
      final nz = normals[vi * 3 + 2];
      final len = math.sqrt(nx * nx + ny * ny + nz * nz);
      if (len > 0.0001) {
        normals[vi * 3 + 0] = nx / len;
        normals[vi * 3 + 1] = ny / len;
        normals[vi * 3 + 2] = nz / len;
      } else {
        normals[vi * 3 + 1] = 1.0; // Fallback to world up
      }
    }

    return Mesh(
      vertices: vertices,
      indices:  indices,
      normals:  normals,
      colors:   colors,
    );
  }

  /// Accumulate face normal for vertices a, b, c into the normals buffer.
  static void _accumulateFaceNormal(
    Float32List verts,
    Float32List norms,
    int a,
    int b,
    int c,
  ) {
    final ax = verts[a*3], ay = verts[a*3+1], az = verts[a*3+2];
    final bx = verts[b*3], by = verts[b*3+1], bz = verts[b*3+2];
    final cx = verts[c*3], cy = verts[c*3+1], cz = verts[c*3+2];

    // Edge vectors
    final ux = bx - ax, uy = by - ay, uz = bz - az;
    final vx = cx - ax, vy = cy - ay, vz = cz - az;

    // Cross product
    final nx = uy * vz - uz * vy;
    final ny = uz * vx - ux * vz;
    final nz = ux * vy - uy * vx;

    for (final vi in [a, b, c]) {
      norms[vi*3+0] += nx;
      norms[vi*3+1] += ny;
      norms[vi*3+2] += nz;
    }
  }

  /// Map a normalized height value (0-1) to a landscape color.
  ///
  /// Biome thresholds (approximate):
  ///  - 0.00–0.10: flat lowland (dry earth / scrub)
  ///  - 0.10–0.35: grassy lowlands
  ///  - 0.35–0.60: green mid-terrain
  ///  - 0.60–0.78: grey rocky highlands
  ///  - 0.78–1.00: white snow peaks
  static Vector3 _heightColor(double t) {
    if (t < 0.10) {
      // Dry earth lowlands — tan/brown, clearly visible from altitude
      final f = t / 0.10;
      return Vector3(0.55 + f * 0.05, 0.45 + f * 0.05, 0.28 + f * 0.02);
    } else if (t < 0.35) {
      // Sandy to grassy transition
      final f = (t - 0.10) / 0.25;
      return Vector3(
        0.60 - f * 0.35,
        0.50 + f * 0.10,
        0.30 - f * 0.18,
      );
    } else if (t < 0.60) {
      // Grassy mid-terrain — bright green
      final f = (t - 0.35) / 0.25;
      return Vector3(
        0.25 + f * 0.10,
        0.60 - f * 0.08,
        0.12 - f * 0.02,
      );
    } else if (t < 0.78) {
      // Rocky grey highlands
      final f = (t - 0.60) / 0.18;
      return Vector3(
        0.40 + f * 0.28,
        0.44 + f * 0.22,
        0.38 + f * 0.26,
      );
    } else {
      // Snow-capped peaks
      final f = ((t - 0.78) / 0.22).clamp(0.0, 1.0);
      return Vector3(
        0.72 + f * 0.28,
        0.78 + f * 0.22,
        0.85 + f * 0.15,
      );
    }
  }
}
