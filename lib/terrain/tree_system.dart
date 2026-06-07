import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:vector_math/vector_math.dart';
import 'terrain_generator.dart';

enum TreeState { alive, burning, charred }

class TreeInstance {
  final int    id;
  final double wx, wy, wz;
  final double height;
  final double canopyRadius;
  final double trunkRadius;
  final int    type;         // 0=pine, 1=deciduous, 2=snag
  final double fuelDarkness; // 0=light smoke, 1=black smoke
  TreeState state      = TreeState.alive;
  double    stateTimer = 0.0;

  TreeInstance({
    required this.id,
    required this.wx, required this.wy, required this.wz,
    required this.height, required this.canopyRadius,
    required this.trunkRadius, required this.type,
    required this.fuelDarkness,
  });
}

/// Manages all tree instances: placement and fire spread.
///
/// Placement uses two-layer Poisson disk + clustered stands with value-noise
/// density (no sine-wave banding) and gap zones for clearings/meadows.
///
/// Fire spread is wind-aligned probabilistic, operating only on the burning
/// subset so cost is O(burning), not O(total).
class TreeSystem {
  final List<TreeInstance> trees = [];
  final Map<String, List<int>> _grid = {};

  bool dirty = true;
  final List<int> newlyBurningIds = [];
  final List<int> newlyCharredIds = [];
  final List<TreeInstance> _burning = [];

  final math.Random _rng;

  static const double _kGridCell   = 16.0;
  static const double _kSpreadR    = 14.0;
  static const double _kSpreadRate = 0.12; // slightly faster spread through dense stands
  static const double _kBurnTime   = 6.0;  // shorter burn for smaller trees

  // ── Config (loaded from fire_config.json "trees" block) ───────────────────
  double _scatterMinGap               = 3.0;
  double _scatterDensityThreshold     = 0.44;
  double _clusterSeedSpacing          = 12.0;
  double _clusterSeedDensityThreshold = 0.38;
  int    _clusterCountMin             = 5;
  int    _clusterCountMax             = 12;

  TreeSystem({int rngSeed = 777}) : _rng = math.Random(rngSeed);

  Future<void> loadConfig() async {
    try {
      final raw = await rootBundle.loadString('assets/data/fire_config.json');
      final cfg = (jsonDecode(raw) as Map<String, dynamic>)['trees']
          as Map<String, dynamic>?;
      if (cfg == null) return;
      double? nd(String k) => (cfg[k] as num?)?.toDouble();
      int?    ni(String k) => (cfg[k] as num?)?.toInt();
      _scatterMinGap               = nd('scatterMinGap')               ?? _scatterMinGap;
      _scatterDensityThreshold     = nd('scatterDensityThreshold')     ?? _scatterDensityThreshold;
      _clusterSeedSpacing          = nd('clusterSeedSpacing')          ?? _clusterSeedSpacing;
      _clusterSeedDensityThreshold = nd('clusterSeedDensityThreshold') ?? _clusterSeedDensityThreshold;
      _clusterCountMin             = ni('clusterCountMin')             ?? _clusterCountMin;
      _clusterCountMax             = ni('clusterCountMax')             ?? _clusterCountMax;
      debugPrint('[TreeSystem] config loaded — gap: $_scatterMinGap  clusterMax: $_clusterCountMax');
    } catch (e) {
      debugPrint('[TreeSystem] config load failed ($e) — using defaults');
    }
  }

  // ── Placement ──────────────────────────────────────────────────────────────

  /// Deterministically scatter trees across the ±120 world using two passes:
  ///
  ///   Pass 1 — blue-noise background scatter (Poisson disk, gap = [scatterMinGap]).
  ///   Pass 2 — stand-density clusters: coarser PDS seeds, each expanded into a
  ///             tight local group, producing the "forest stands" appearance.
  ///
  /// Density is driven by a two-octave value-noise field (no sine banding) with
  /// a separate clearing / meadow noise that punches gaps in the canopy.
  void generate({int seed = 42}) {
    trees.clear();
    _burning.clear();
    _grid.clear();
    newlyBurningIds.clear();
    newlyCharredIds.clear();
    dirty = true;

    const double worldMin = -120.0, worldMax = 120.0;
    final rng = math.Random(seed);
    int id = 0;

    // Pass 1 — scattered background.
    final scatter = _poissonDisk(
        _scatterMinGap, worldMin, worldMax, worldMin, worldMax, 25, math.Random(seed));
    for (final (wx, wz) in scatter) {
      if (_densityAt(wx, wz, seed) < _scatterDensityThreshold) continue;
      if (_isGap(wx, wz, seed)) continue;
      final wy = TerrainGenerator.heightAt(wx, wz);
      if (wy < 0.5 || wy > 72.0) continue;
      trees.add(_makeTree(id++, wx, wy, wz, seed));
    }

    // Pass 2 — clustered stands.
    final clusterSeeds = _poissonDisk(
        _clusterSeedSpacing, worldMin, worldMax, worldMin, worldMax, 20,
        math.Random(seed + 99));
    for (final (sx, sz) in clusterSeeds) {
      if (_densityAt(sx, sz, seed) < _clusterSeedDensityThreshold) continue;
      if (_isGap(sx, sz, seed)) continue;
      final sy = TerrainGenerator.heightAt(sx, sz);
      if (sy < 0.5 || sy > 72.0) continue;

      final density = _densityAt(sx, sz, seed);
      final countRange = _clusterCountMax - _clusterCountMin;
      final count = _clusterCountMin + (density * countRange).round();

      for (int c = 0; c < count; c++) {
        final angle = rng.nextDouble() * math.pi * 2;
        // Two-uniform sum approximates Gaussian (σ ≈ 3.5 units).
        final r  = (rng.nextDouble() + rng.nextDouble()) * 5.0;
        final wx = (sx + math.cos(angle) * r).clamp(worldMin, worldMax);
        final wz = (sz + math.sin(angle) * r).clamp(worldMin, worldMax);
        if (_isGap(wx, wz, seed)) continue;
        final wy = TerrainGenerator.heightAt(wx, wz);
        if (wy < 0.5 || wy > 72.0) continue;
        trees.add(_makeTree(id++, wx, wy, wz, seed));
      }
    }

    _rebuildGrid();
    debugPrint('[TreeSystem] generated ${trees.length} trees');
  }

  // ── Value-noise density field ──────────────────────────────────────────────
  //
  // Two-octave blended value noise replaces the sine-wave approach.
  // Hash-based bilinear interpolation has no long-range periodicity, so
  // forest stands look organic rather than striped.

  static double _densityAt(double x, double z, int seed) {
    final s = seed.toDouble();
    // Coarse scale (~40-unit stands): where dense forest patches form.
    final coarse = _valueNoise(x * 0.041 + s * 0.31, z * 0.037 - s * 0.17);
    // Fine scale (~12 units): local density variation within a stand.
    final fine   = _valueNoise(x * 0.113 + s * 0.73, z * 0.091 + s * 0.59);
    return coarse * 0.62 + fine * 0.38;
  }

  /// Returns true when the point falls inside a clearing / meadow.
  /// ~20% of the world surface is open gaps (glades, rock outcrops, paths).
  static bool _isGap(double x, double z, int seed) {
    final s = seed.toDouble();
    final g = _valueNoise(x * 0.058 - s * 0.43, z * 0.054 + s * 0.29);
    return g > 0.80;
  }

  static double _valueNoise(double x, double z) {
    final xi = x.floor();
    final zi = z.floor();
    final fx = x - xi;
    final fz = z - zi;
    // Smoothstep (cubic Hermite) removes gradient discontinuities at cell edges.
    final u = fx * fx * (3.0 - 2.0 * fx);
    final v = fz * fz * (3.0 - 2.0 * fz);
    final a = _hashV(xi.toDouble(),     zi.toDouble());
    final b = _hashV(xi.toDouble() + 1, zi.toDouble());
    final c = _hashV(xi.toDouble(),     zi.toDouble() + 1);
    final d = _hashV(xi.toDouble() + 1, zi.toDouble() + 1);
    return a + (b - a) * u + (c - a) * v + (a - b - c + d) * u * v;
  }

  static double _hashV(double xi, double zi) {
    final v = math.sin(xi * 127.1 + zi * 311.7) * 43758.5453;
    return v.abs() % 1.0; // [0, 1)
  }

  // ── Poisson disk sampling ──────────────────────────────────────────────────

  List<(double, double)> _poissonDisk(
      double minDist, double xMin, double xMax, double zMin, double zMax,
      int maxAttempts, math.Random rng) {
    final result = <(double, double)>[];
    final active  = <int>[];
    final cell    = minDist / math.sqrt(2.0);
    final cols    = ((xMax - xMin) / cell).ceil() + 1;
    final rows    = ((zMax - zMin) / cell).ceil() + 1;
    final grid    = List<int>.filled(cols * rows, -1);

    int gIdx(double x, double z) =>
        ((z - zMin) / cell).floor().clamp(0, rows - 1) * cols +
        ((x - xMin) / cell).floor().clamp(0, cols - 1);

    bool valid(double x, double z) {
      final col = ((x - xMin) / cell).floor();
      final row = ((z - zMin) / cell).floor();
      final md2 = minDist * minDist;
      for (int dr = -2; dr <= 2; dr++) {
        for (int dc = -2; dc <= 2; dc++) {
          final r = row + dr, c = col + dc;
          if (r < 0 || r >= rows || c < 0 || c >= cols) continue;
          final idx = grid[r * cols + c];
          if (idx < 0) continue;
          final dx = result[idx].$1 - x;
          final dz = result[idx].$2 - z;
          if (dx * dx + dz * dz < md2) return false;
        }
      }
      return true;
    }

    void add(double x, double z) {
      final i = result.length;
      result.add((x, z));
      active.add(i);
      grid[gIdx(x, z)] = i;
    }

    add(xMin + rng.nextDouble() * (xMax - xMin),
        zMin + rng.nextDouble() * (zMax - zMin));

    while (active.isNotEmpty) {
      final ri  = rng.nextInt(active.length);
      final src = result[active[ri]];
      bool found = false;
      for (int k = 0; k < maxAttempts; k++) {
        final angle = rng.nextDouble() * math.pi * 2;
        final dist  = minDist * (1.0 + rng.nextDouble());
        final nx    = src.$1 + math.cos(angle) * dist;
        final nz    = src.$2 + math.sin(angle) * dist;
        if (nx < xMin || nx > xMax || nz < zMin || nz > zMax) continue;
        if (!valid(nx, nz)) continue;
        add(nx, nz);
        found = true;
        break;
      }
      if (!found) active.removeAt(ri);
    }
    return result;
  }

  // ── Tree instance factory ──────────────────────────────────────────────────

  TreeInstance _makeTree(int id, double wx, double wy, double wz, int seed) {
    // Elevation-biased species: pines dominate ridges, deciduous fill valleys.
    final elevNorm  = ((wy - 0.5) / 71.5).clamp(0.0, 1.0);
    final typeNoise = _hashV(wx * 0.99 + seed * 0.11, wz * 1.31 - seed * 0.07);
    final type = elevNorm > 0.56
        ? 0  // pine on ridges
        : typeNoise < 0.10
            ? 2  // snag (~10%)
            : typeNoise < 0.52
                ? 0  // pine
                : 1; // deciduous

    // Size variation via per-tree hash (no visible sin-wave grid lines).
    final sizeNoise   = _hashV(wx * 2.1 + seed, wz * 1.7 - seed);
    final scaleFactor = 0.68 + sizeNoise * 0.54; // 0.68–1.22

    // Trees are ~2–6 m tall — sapling/young-forest scale.
    // Compact trees look dense; fire spreading through them is visually dramatic.
    final baseH  = type == 2 ? 1.5 + sizeNoise * 2.0 : 2.5 + sizeNoise * 3.5;
    final height = baseH * scaleFactor;

    // ±10% canopy jitter breaks clone-grid appearance.
    final canopyJitter = 0.92 + _hashV(wx * 3.7 + seed, wz * 2.9) * 0.08;
    final canopyR  = height * (type == 0 ? 0.26 : 0.32) * canopyJitter;
    // Thin trunks: dense-stand trees allocate resources to height, not girth.
    final trunkR   = (0.07 + sizeNoise * 0.07) * math.sqrt(scaleFactor);

    // Smoke darkness by species: deciduous=0.10, pine=0.15, snag/resinous=0.35.
    final fd = type == 1 ? 0.10 : type == 0 ? 0.15 : 0.35;

    return TreeInstance(
      id: id, wx: wx, wy: wy, wz: wz,
      height: height, canopyRadius: canopyR, trunkRadius: trunkR,
      type: type, fuelDarkness: fd,
    );
  }

  // ── Simulation ─────────────────────────────────────────────────────────────

  void update(double dt, Vector3 windVec) {
    int i = 0;
    while (i < _burning.length) {
      final t = _burning[i];
      t.stateTimer += dt;
      final burnDuration = _kBurnTime * (0.7 + t.height / 10.0);
      if (t.stateTimer >= burnDuration) {
        t.state = TreeState.charred;
        t.stateTimer = 0.0;
        dirty = true;
        newlyCharredIds.add(t.id);
        _burning[i] = _burning.last;
        _burning.removeLast();
      } else {
        if (t.stateTimer > 0.8) _trySpread(t, dt, windVec);
        i++;
      }
    }
  }

  void igniteInRadius(Vector3 origin, double radius) {
    final r2 = radius * radius;
    for (final t in trees) {
      if (t.state != TreeState.alive) continue;
      final dx = t.wx - origin.x;
      final dz = t.wz - origin.z;
      if (dx * dx + dz * dz <= r2) _ignite(t);
    }
  }

  void igniteTree(TreeInstance t) {
    if (t.state != TreeState.alive) return;
    _ignite(t);
  }

  // ── Internals ──────────────────────────────────────────────────────────────

  void _ignite(TreeInstance t) {
    t.state = TreeState.burning;
    t.stateTimer = 0.0;
    dirty = true;
    newlyBurningIds.add(t.id);
    _burning.add(t);
  }

  void _trySpread(TreeInstance src, double dt, Vector3 windVec) {
    final windLen = windVec.length;
    final cx = (src.wx / _kGridCell).floor();
    final cz = (src.wz / _kGridCell).floor();

    for (int gx = cx - 1; gx <= cx + 1; gx++) {
      for (int gz = cz - 1; gz <= cz + 1; gz++) {
        final list = _grid['${gx}_${gz}'];
        if (list == null) continue;
        for (final idx in list) {
          final n = trees[idx];
          if (n.state != TreeState.alive) continue;
          final dx = n.wx - src.wx;
          final dz = n.wz - src.wz;
          final dist2 = dx * dx + dz * dz;
          if (dist2 > _kSpreadR * _kSpreadR || dist2 < 0.1) continue;

          double windAlign = 0.3;
          if (windLen > 0.01) {
            final dist = math.sqrt(dist2);
            final dot  = (dx / dist) * windVec.x / windLen +
                         (dz / dist) * windVec.z / windLen;
            windAlign  = 0.1 + 0.9 * ((dot + 1.0) * 0.5);
          }
          final windMult = 1.0 + windLen * 2.5;
          if (_rng.nextDouble() < _kSpreadRate * dt * windAlign * windMult) {
            _ignite(n);
          }
        }
      }
    }
  }

  void _rebuildGrid() {
    _grid.clear();
    for (int i = 0; i < trees.length; i++) {
      _grid
          .putIfAbsent(_gridKey(trees[i].wx, trees[i].wz), () => [])
          .add(i);
    }
  }

  static String _gridKey(double x, double z) =>
      '${(x / _kGridCell).floor()}_${(z / _kGridCell).floor()}';
}
