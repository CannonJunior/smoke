import 'package:vector_math/vector_math.dart';
import '../rendering/mesh.dart';
import '../rendering/transform3d.dart';

/// One tile of the infinite terrain grid.
///
/// [chunkX] / [chunkZ] are chunk-grid coordinates (can be negative).
/// [mesh] vertices are in local space, starting at (0, 0, 0); the caller
/// positions the chunk in the world via [transform].
class TerrainChunk {
  final int       chunkX, chunkZ;
  final Mesh      mesh;
  final Transform3d transform;

  /// Grid resolution this chunk was generated at (32 = full, 16 = LOD).
  final int gridSize;

  const TerrainChunk({
    required this.chunkX,
    required this.chunkZ,
    required this.mesh,
    required this.transform,
    required this.gridSize,
  });

  /// World position of this chunk's (0, 0) corner.
  Vector3 get worldOrigin => transform.position;
}
