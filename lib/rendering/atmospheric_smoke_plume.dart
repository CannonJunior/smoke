import 'dart:math' as math;
import 'package:vector_math/vector_math.dart';

// Colour stratification: ground soot → cream top (5 layers, index 0..4).
const List<List<double>> _kColorLayers = [
  [0.15, 0.12, 0.10], // 0: near-black soot
  [0.40, 0.38, 0.35], // 1: dark warm grey
  [0.65, 0.63, 0.60], // 2: mid grey
  [0.85, 0.83, 0.80], // 3: light grey
  [0.95, 0.95, 0.95], // 4: cream
];
const List<double> _kOpacity = [1.0, 0.80, 0.60, 0.30, 0.10];

/// One stacked-billboard segment of an atmospheric plume.
/// Uses flat doubles instead of a Vector3 to avoid per-frame heap allocation.
class SmokeColumnBillboard {
  final double posX, posY, posZ; // world-space centre of this quad
  final double width;
  final double height;
  final Vector4 color;     // rgb + alpha
  final double  layerIndex; // 0..4 for altitude fade in fragment shader

  const SmokeColumnBillboard({
    required this.posX,
    required this.posY,
    required this.posZ,
    required this.width,
    required this.height,
    required this.color,
    required this.layerIndex,
  });
}

/// A single fire zone's long-range smoke column.
///
/// Grows toward [maxHeight] while burning, shrinks when extinguished.
/// Segments are spaced evenly from ground to [currentHeight]; width expands
/// linearly from [baseWidth] to [topWidth].
class AtmosphericSmokePlume {
  final int    zoneIndex;
  final double sourceX, sourceZ;

  double intensity     = 0.0;
  double currentHeight = 0.0;

  final double maxHeight, baseWidth, topWidth;
  final double billowFrequency, windDriftScale;
  final int    segmentCount;

  double _noisePhase;
  final Vector2 _drift = Vector2.zero(); // accumulated XZ wind drift

  AtmosphericSmokePlume({
    required this.zoneIndex,
    required this.sourceX,
    required this.sourceZ,
    required this.maxHeight,
    required this.baseWidth,
    required this.topWidth,
    required this.billowFrequency,
    required this.windDriftScale,
    required this.segmentCount,
  }) : _noisePhase = math.Random().nextDouble() * math.pi * 2;

  void tick(double intensity, Vector3 wind, double dt) {
    this.intensity = intensity;
    if (intensity <= 0.0) {
      currentHeight = (currentHeight - dt * 4.0).clamp(0.0, maxHeight);
      return;
    }
    currentHeight = (currentHeight + dt * 2.0).clamp(0.0, maxHeight);
    _drift.x     += wind.x * windDriftScale * dt;
    _drift.y     += wind.z * windDriftScale * dt; // world-Z stored in .y
    _noisePhase  += billowFrequency * dt;
  }

  /// Appends billboard segments for this plume directly into [out],
  /// avoiding a transient list allocation.
  void buildBillboards(List<SmokeColumnBillboard> out, {int? count}) {
    if (currentHeight < 0.5) return;
    final n    = count ?? segmentCount;
    final segH = currentHeight / n;

    for (int i = 0; i < n; i++) {
      final t      = n > 1 ? i / (n - 1) : 0.0; // 0 = base, 1 = top
      final layerF = (t * 4.0).clamp(0.0, 4.0);
      final layerI = layerF.floor().clamp(0, 3);  // always safe: layerI+1 ∈ [1,4]
      final blend  = layerF - layerI;

      final c0  = _kColorLayers[layerI];
      final c1  = _kColorLayers[layerI + 1];
      final op0 = _kOpacity[layerI];
      final op1 = _kOpacity[layerI + 1];

      final r  = c0[0] + (c1[0] - c0[0]) * blend;
      final g  = c0[1] + (c1[1] - c0[1]) * blend;
      final b  = c0[2] + (c1[2] - c0[2]) * blend;
      final op = (op0 + (op1 - op0) * blend) * intensity;

      final width = baseWidth + (topWidth - baseWidth) * t;
      // Gentle large-scale lean so the column shapes organically rather than
      // looking like stacked individual pucks.
      final swirl = math.sin(_noisePhase + i * 0.28) * width * 0.03;

      out.add(SmokeColumnBillboard(
        posX:       sourceX + _drift.x + swirl,
        posY:       i * segH + segH * 0.5,
        posZ:       sourceZ + _drift.y,
        width:      width,
        height:     segH * 1.85, // heavy overlap so segments merge into one volume
        color:      Vector4(r, g, b, op),
        layerIndex: layerF,
      ));
    }
  }
}

/// Manages one [AtmosphericSmokePlume] per fire zone and applies LOD.
class AtmosphericSmokeSystem {
  final List<AtmosphericSmokePlume> _plumes = [];

  // Tunable defaults (overridden by fire_config.json atmosphericSmoke section).
  int    segmentsPerPlume   = 12;
  double baseWidth          = 14.0;
  double topWidth           = 28.0;
  double maxHeight          = 100.0;
  double billowingFrequency = 0.05;
  double windDriftScale     = 0.50;

  List<AtmosphericSmokePlume> get plumes => _plumes;

  void addPlume(int zoneIdx, double x, double z) {
    _plumes.add(AtmosphericSmokePlume(
      zoneIndex:        zoneIdx,
      sourceX:          x,
      sourceZ:          z,
      maxHeight:        maxHeight,
      baseWidth:        baseWidth,
      topWidth:         topWidth,
      billowFrequency:  billowingFrequency,
      windDriftScale:   windDriftScale,
      segmentCount:     segmentsPerPlume,
    ));
  }

  void tickPlume(int idx, double intensity, Vector3 wind, double dt) {
    if (idx < _plumes.length) _plumes[idx].tick(intensity, wind, dt);
  }

  /// Minimum horizontal distance (world units) before atmospheric plumes are
  /// rendered. Below this the close-range CPU particle system covers the zone.
  static const double nearCutoff = 150.0;

  // Pre-allocated billboard buffer — rebuilt each call but avoids list growth.
  final List<SmokeColumnBillboard> _billboardBuf = [];

  // Sort caching: only re-sort when camera moves >3 units or every 10 frames.
  final Vector3 _lastSortPos    = Vector3.zero();
  int           _framesSinceSort = 10; // start high so first frame always sorts

  /// Returns all billboard segments sorted back-to-front for correct blending.
  List<SmokeColumnBillboard> getAllBillboards(Vector3 cameraPos) {
    _billboardBuf.clear();
    for (final p in _plumes) {
      final dx   = cameraPos.x - p.sourceX;
      final dz   = cameraPos.z - p.sourceZ;
      final dist = math.sqrt(dx * dx + dz * dz);
      if (dist < nearCutoff) continue;
      // LOD: 15 segments within 300 units, 7 beyond.
      final lod = dist < 300 ? 15 : 7;
      p.buildBillboards(_billboardBuf, count: lod);
    }

    // Re-sort only when camera has moved >3 units or after 10 frames without sorting.
    final sx = cameraPos.x - _lastSortPos.x;
    final sy = cameraPos.y - _lastSortPos.y;
    final sz = cameraPos.z - _lastSortPos.z;
    _framesSinceSort++;
    if (sx * sx + sy * sy + sz * sz > 9.0 || _framesSinceSort >= 10) {
      _billboardBuf.sort((a, b) {
        final dax = a.posX - cameraPos.x;
        final day = a.posY - cameraPos.y;
        final daz = a.posZ - cameraPos.z;
        final dbx = b.posX - cameraPos.x;
        final dby = b.posY - cameraPos.y;
        final dbz = b.posZ - cameraPos.z;
        return (dbx * dbx + dby * dby + dbz * dbz)
            .compareTo(dax * dax + day * day + daz * daz);
      });
      _lastSortPos.setFrom(cameraPos);
      _framesSinceSort = 0;
    }
    return _billboardBuf;
  }
}
