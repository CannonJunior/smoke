import 'dart:math' as math;
import 'package:vector_math/vector_math.dart';
import '../rendering/mesh.dart';
import '../rendering/transform3d.dart';
import 'terrain_chunk.dart';
import 'terrain_generator.dart';

/// InfiniteTerrainManager - Streams terrain chunks in and out as the player moves.
///
/// Maintains a square window of [renderDistance] chunks around the player.
/// New chunks are generated at most [_maxPerFrame] per frame to avoid stutter.
/// All chunks for the same seed produce seamless height boundaries because
/// the noise is sampled in global world coordinates.
class InfiniteTerrainManager {
  // ── Configuration ─────────────────────────────────────────────────────────

  /// Tiles per chunk side.
  static const int    chunkGridSize  = 32;

  /// World units per tile — matches the airfield generator.
  static const double chunkTileSize  = 2.0;

  /// Side length of one chunk in world units.
  static const double chunkWorldSize = chunkGridSize * chunkTileSize; // 64.0

  /// How many chunks in each cardinal direction from the player are kept loaded.
  /// 5 → 11×11 = 121 chunks visible, covering ±320 world units.
  static const int renderDistance = 5;

  /// Half-resolution grid size for outermost LOD ring (distance == renderDistance).
  static const int chunkLODGridSize = 16;

  static const double _maxHeight  = TerrainGenerator.kTerrainMaxHeight;
  static const int    _seed       = 1337;

  /// Maximum new chunks generated per game-loop frame to limit CPU spikes.
  static const int _maxPerFrame = 8;

  // ── State ─────────────────────────────────────────────────────────────────

  // Integer key: packs (cx, cz) into one int — avoids string allocation per lookup.
  // Supports chunk coords in ±524287 range (>> sufficient for any playable world).
  static int _key(int cx, int cz) => (cx & 0xFFFFF) << 20 | (cz & 0xFFFFF);

  final Map<int, TerrainChunk> _chunks = {};

  // Meshes removed during _unloadDistant, drained by game_widget for GPU cleanup.
  final List<Mesh> _removedMeshes = [];

  int _lastCX = 0x7fffffff;
  int _lastCZ = 0x7fffffff;

  // ── Coordinate helpers ────────────────────────────────────────────────────

  /// World coordinate → chunk index along one axis.
  static int worldToChunk(double w) => (w / chunkWorldSize).floor();

  // ── Public API ────────────────────────────────────────────────────────────

  /// Generate all chunks in render distance synchronously.
  ///
  /// Call once during scene initialisation.  Subsequent frame-by-frame
  /// expansion is handled by [update].
  void preload(Vector3 playerPos) {
    final cx = worldToChunk(playerPos.x);
    final cz = worldToChunk(playerPos.z);
    for (int dx = -renderDistance; dx <= renderDistance; dx++) {
      for (int dz = -renderDistance; dz <= renderDistance; dz++) {
        _generate(cx + dx, cz + dz, _lodGridSize(dx, dz));
      }
    }
    _lastCX = cx;
    _lastCZ = cz;
  }

  /// Call every frame.  Generates up to [_maxPerFrame] new chunks and
  /// discards any chunk that has drifted outside render distance + 1.
  void update(Vector3 playerPos) {
    final cx = worldToChunk(playerPos.x);
    final cz = worldToChunk(playerPos.z);
    if (cx != _lastCX || cz != _lastCZ) {
      _unloadDistant(cx, cz);
      _lastCX = cx;
      _lastCZ = cz;
    }
    _loadAround(cx, cz);
  }

  /// All currently loaded chunks — pass each to the renderer every frame.
  ///
  /// Returns the map values view directly (no copy) so the render loop iterates
  /// in-place without allocating a new List on every frame.
  Iterable<TerrainChunk> get loadedChunks => _chunks.values;

  /// Diagnostic: number of loaded chunks.
  int get loadedCount => _chunks.length;

  /// Register a circular flat zone (delegates to [TerrainGenerator.addFlatZone]).
  /// Call before [preload] so all generated chunks respect the zone.
  void addFlatZone(double wx, double wz, double radius, {double blend = 40.0}) =>
      TerrainGenerator.addFlatZone(wx, wz, radius, blend: blend);

  /// Returns meshes unloaded since the last call — game_widget frees their GPU buffers.
  List<Mesh> drainRemovedMeshes() {
    if (_removedMeshes.isEmpty) return const [];
    final out = List<Mesh>.from(_removedMeshes);
    _removedMeshes.clear();
    return out;
  }

  // ── Private ───────────────────────────────────────────────────────────────

  void _loadAround(int cx, int cz) {
    final needed = <(int, int, int)>[]; // (dist², dx, dz)
    for (int dx = -renderDistance; dx <= renderDistance; dx++) {
      for (int dz = -renderDistance; dz <= renderDistance; dz++) {
        final key           = _key(cx + dx, cz + dz);
        final targetGrid    = _lodGridSize(dx, dz);
        final existing      = _chunks[key];
        // Evict if LOD level changed (e.g. player moved toward an outer chunk).
        if (existing != null && existing.gridSize != targetGrid) {
          _chunks.remove(key);
        }
        if (!_chunks.containsKey(key)) {
          needed.add((dx * dx + dz * dz, dx, dz));
        }
      }
    }

    // Generate closest chunks first so the area around the player fills in fast
    needed.sort((a, b) => a.$1.compareTo(b.$1));

    final limit = math.min(_maxPerFrame, needed.length);
    for (int i = 0; i < limit; i++) {
      final (_, dx, dz) = needed[i];
      _generate(cx + dx, cz + dz, _lodGridSize(dx, dz));
    }
  }

  /// Returns the grid resolution for a chunk at offset (dx, dz) from the player.
  ///
  /// Only the outermost ring (Chebyshev distance == renderDistance) is
  /// downsampled — this limits the LOD transition zone to the far edge of the
  /// visible area, minimising pop when the player crosses a chunk boundary.
  int _lodGridSize(int dx, int dz) {
    final dist = math.max(dx.abs(), dz.abs());
    return dist < renderDistance ? chunkGridSize : chunkLODGridSize;
  }

  void _unloadDistant(int cx, int cz) {
    const buffer = renderDistance + 1;
    _chunks.removeWhere((_, chunk) {
      final remove = (chunk.chunkX - cx).abs() > buffer ||
                     (chunk.chunkZ - cz).abs() > buffer;
      if (remove) _removedMeshes.add(chunk.mesh);
      return remove;
    });
  }

  void _generate(int cx, int cz, int gridSize) {
    final key = _key(cx, cz);
    if (_chunks.containsKey(key)) return;

    final mesh = TerrainGenerator.generateChunk(
      chunkX:    cx,    chunkZ:    cz,
      gridSize:  gridSize,
      tileSize:  chunkTileSize,
      maxHeight: _maxHeight,
      seed:      _seed,
    );

    _chunks[key] = TerrainChunk(
      chunkX:    cx,
      chunkZ:    cz,
      mesh:      mesh,
      gridSize:  gridSize,
      transform: Transform3d(
          position: Vector3(cx * chunkWorldSize, 0, cz * chunkWorldSize)),
    );
  }
}
