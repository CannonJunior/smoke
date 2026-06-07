import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:vector_math/vector_math.dart';
import '../rendering/atmospheric_smoke_plume.dart';
import '../rendering/particle_system.dart';

// ── FireEmitter ───────────────────────────────────────────────────────────────

class FireEmitter {
  final double worldX, worldZ;
  double radius;
  double intensity;

  /// 0 = dry vegetation (light gray→cream smoke), 1 = synthetic (black smoke).
  double fuelDarkness;

  double _emitAccum   = 0.0;
  double _emberAccum  = 0.0;
  double _wispAccum   = 0.0;
  double _nextBurstAt = 0.5;
  double _nextWispAt  = 1.0;
  final math.Random _rng;

  double emitRate     = 60.0;
  double wispRate     = 5.0;  // wisps per second
  double fireLifeMin  = 1.2;
  double fireLifeMax  = 2.8;
  double fireSizeMin  = 0.4;
  double fireSizeMax  = 1.8;
  double smokeSizeMin = 1.2;
  double smokeSizeMax = 4.5;
  double leanFactor   = 0.12;

  FireEmitter({
    required this.worldX,
    required this.worldZ,
    this.radius      = 10.0,
    this.intensity   = 1.0,
    this.fuelDarkness = 0.0,
    math.Random? rng,
  }) : _rng = rng ?? math.Random();

  void tick(ParticleSystem system, double dt, double terrainY, Vector3 wind) {
    if (intensity <= 0.0) return;

    _emitAccum += emitRate * intensity * dt;
    final count = _emitAccum.floor();
    _emitAccum -= count;
    for (int i = 0; i < count; i++) {
      _emitFire(system, terrainY, wind);
    }

    _emberAccum += dt;
    if (_emberAccum >= _nextBurstAt) {
      _emberAccum  = 0;
      _nextBurstAt = 0.3 + _rng.nextDouble() * 0.7;
      final n = 2 + _rng.nextInt(4);
      for (int i = 0; i < n; i++) {
        _emitEmber(system, terrainY);
      }
    }

    _wispAccum += dt;
    if (_wispAccum >= _nextWispAt) {
      _wispAccum  = 0.0;
      _nextWispAt = 1.0 / (wispRate * intensity);
      _emitWisp(system, terrainY, wind);
    }
  }

  void _emitFire(ParticleSystem system, double terrainY, Vector3 wind) {
    final angle = _rng.nextDouble() * math.pi * 2;
    final r     = _rng.nextDouble() * radius;
    final px    = worldX + math.cos(angle) * r;
    final pz    = worldZ + math.sin(angle) * r;
    final py    = terrainY + _rng.nextDouble() * 1.5;

    final life = fireLifeMin + _rng.nextDouble() * (fireLifeMax - fireLifeMin);
    final size = fireSizeMin + _rng.nextDouble() * (fireSizeMax - fireSizeMin);

    final vx = (_rng.nextDouble() - 0.5) * 0.4 + wind.x * leanFactor;
    final vz = (_rng.nextDouble() - 0.5) * 0.4 + wind.z * leanFactor;
    final vy = 1.5 + _rng.nextDouble() * 2.0;

    system.emit(Particle(
      position:     Vector3(px, py, pz),
      velocity:     Vector3(vx, vy, vz),
      lifetime:     life,
      size:         size,
      isFire:       true,
      sourceX:      worldX,
      sourceZ:      worldZ,
      temperature:  0.7 + _rng.nextDouble() * 0.3,
      fuelFraction: 1.0,
      fuelDarkness: fuelDarkness,
    ));
  }

  void _emitWisp(ParticleSystem system, double terrainY, Vector3 wind) {
    // Wisps spawn around and slightly beyond the fire perimeter — they are
    // detached tendrils pulled off the main column by wind shear.
    final angle = _rng.nextDouble() * math.pi * 2;
    final r     = radius * (0.6 + _rng.nextDouble() * 1.4);
    final px    = worldX + math.cos(angle) * r;
    final pz    = worldZ + math.sin(angle) * r;
    final py    = terrainY + 1.5 + _rng.nextDouble() * 6.0;

    // Wisps drift primarily with wind, barely rising.
    final vx = wind.x * 0.25 + (_rng.nextDouble() - 0.5) * 1.0;
    final vz = wind.z * 0.25 + (_rng.nextDouble() - 0.5) * 1.0;
    final vy = 0.05 + _rng.nextDouble() * 0.25;

    system.emit(Particle(
      position:     Vector3(px, py, pz),
      velocity:     Vector3(vx, vy, vz),
      lifetime:     20.0 + _rng.nextDouble() * 30.0,
      size:         0.4 + _rng.nextDouble() * 1.4,
      isFire:       false,
      isEmber:      false,
      isWisp:       true,
      sourceX:      worldX,
      sourceZ:      worldZ,
      temperature:  0.0,
      fuelFraction: 0.0,   // sentinel — smoke shader uses wisp shape when < 0.05
      fuelDarkness: fuelDarkness * 0.55, // wisps are lighter than the main plume
      rotation:     _rng.nextDouble() * math.pi * 2,
    ));
  }

  void _emitEmber(ParticleSystem system, double terrainY) {
    final angle = _rng.nextDouble() * math.pi * 2;
    final r     = _rng.nextDouble() * radius * 0.5;
    final px    = worldX + math.cos(angle) * r;
    final pz    = worldZ + math.sin(angle) * r;
    final py    = terrainY + 0.5 + _rng.nextDouble() * 2.0;

    final vx = (_rng.nextDouble() - 0.5) * 1.2;
    final vz = (_rng.nextDouble() - 0.5) * 1.2;
    final vy = 3.0 + _rng.nextDouble() * 4.0;

    system.emit(Particle(
      position:     Vector3(px, py, pz),
      velocity:     Vector3(vx, vy, vz),
      lifetime:     6.0 + _rng.nextDouble() * 12.0,
      size:         0.1 + _rng.nextDouble() * 0.2,
      isFire:       false,
      isEmber:      true,
      sourceX:      worldX,
      sourceZ:      worldZ,
      temperature:  0.4 + _rng.nextDouble() * 0.3,
      fuelFraction: 1.0,
    ));
  }
}

// ── FireEmitterSystem ─────────────────────────────────────────────────────────

class FireEmitterSystem {
  final ParticleSystem particles;
  final List<FireEmitter> _emitters = [];

  // Per-tree emitters: keyed by tree id, created/destroyed as trees ignite/char.
  final Map<int, FireEmitter> _dynamicEmitters = {};

  AtmosphericSmokeSystem? _atmosphericSmoke;

  bool _configLoaded = false;
  bool get configLoaded => _configLoaded;

  FireEmitterSystem({required this.particles});

  Future<void> loadConfig() async {
    try {
      final raw  = await rootBundle.loadString('assets/data/fire_config.json');
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final f    = data['fire'] as Map<String, dynamic>;

      particles.buoyancy        = (f['buoyancy']             as num).toDouble();
      particles.turbulenceStr   = (f['turbulenceStrength']   as num).toDouble();
      particles.windInfluence   = (f['windInfluence']        as num).toDouble();
      particles.windRadius      = (f['windRadius']           as num).toDouble();
      particles.smokeTransition = (f['smokeTransitionAge']   as num).toDouble();
      particles.smokeFadeAlt    = (f['smokeFadeAltitude']    as num).toDouble();
      particles.updraftStrength = (f['updraftStrength']      as num).toDouble();
      particles.updraftSigma    = (f['updraftSigma']         as num).toDouble();

      double? nf(String k) => (f[k] as num?)?.toDouble();
      particles.smokeBuoyancy      = nf('smokeBuoyancy')      ?? particles.smokeBuoyancy;
      particles.smokeDrag          = nf('smokeDrag')          ?? particles.smokeDrag;
      particles.altWindBase        = nf('altWindBase')        ?? particles.altWindBase;
      particles.altWindStrength    = nf('altWindStrength')    ?? particles.altWindStrength;
      particles.altWindRange       = nf('altWindRange')       ?? particles.altWindRange;
      particles.altDissipation     = nf('altDissipation')     ?? particles.altDissipation;
      particles.smokeLifeMin       = nf('smokeLifetimeMin')   ?? particles.smokeLifeMin;
      particles.smokeLifeMax       = nf('smokeLifetimeMax')   ?? particles.smokeLifeMax;
      particles.smokeSizeGrowth    = nf('smokeSizeGrowth')    ?? particles.smokeSizeGrowth;
      particles.smokeInitSizeMult  = nf('smokeInitSizeMult')  ?? particles.smokeInitSizeMult;
      particles.smokeWindInfluence = nf('smokeWindInfluence') ?? particles.smokeWindInfluence;

      final emitRate    = (f['emitRatePerSecond'] as num).toDouble();
      final fireLifeMin = (f['fireLifetimeMin']   as num).toDouble();
      final fireLifeMax = (f['fireLifetimeMax']   as num).toDouble();
      final fireSzMin   = (f['fireSizeMin']       as num).toDouble();
      final fireSzMax   = (f['fireSizeMax']       as num).toDouble();
      final smokeSzMin  = (f['smokeSizeMin']      as num).toDouble();
      final smokeSzMax  = (f['smokeSizeMax']      as num).toDouble();
      final leanFactor  = (f['leanFactor']        as num).toDouble();

      for (final e in _emitters) {
        e.emitRate     = emitRate;
        e.fireLifeMin  = fireLifeMin;  e.fireLifeMax  = fireLifeMax;
        e.fireSizeMin  = fireSzMin;    e.fireSizeMax  = fireSzMax;
        e.smokeSizeMin = smokeSzMin;   e.smokeSizeMax = smokeSzMax;
        e.leanFactor   = leanFactor;
      }

      final atm = data['atmosphericSmoke'] as Map<String, dynamic>?;
      if (atm != null && _atmosphericSmoke != null) {
        double na(String k, double fb) => (atm[k] as num?)?.toDouble() ?? fb;
        int    ia(String k, int fb)    => (atm[k] as num?)?.toInt()    ?? fb;
        _atmosphericSmoke!.segmentsPerPlume   = ia('segmentsPerPlume',    _atmosphericSmoke!.segmentsPerPlume);
        _atmosphericSmoke!.baseWidth          = na('baseWidth',           _atmosphericSmoke!.baseWidth);
        _atmosphericSmoke!.topWidth           = na('topWidth',            _atmosphericSmoke!.topWidth);
        _atmosphericSmoke!.maxHeight          = na('maxHeight',           _atmosphericSmoke!.maxHeight);
        _atmosphericSmoke!.billowingFrequency = na('billowingFrequency',  _atmosphericSmoke!.billowingFrequency);
        _atmosphericSmoke!.windDriftScale     = na('windDriftScale',      _atmosphericSmoke!.windDriftScale);
      }

      _configLoaded = true;
      debugPrint('[FireEmitterSystem] config loaded');
    } catch (e) {
      debugPrint('[FireEmitterSystem] config load failed: $e — using defaults');
      _configLoaded = true;
    }
  }

  /// Register fire zones.  Each zone is (worldX, worldZ, fuelDarkness) where
  /// fuelDarkness 0 = vegetation and 1 = synthetic/petroleum.
  /// [initialIntensity] is applied to every static zone emitter; set to 0.05
  /// when trees are the primary fuel source.
  void initZones(List<(double, double, double)> zones, double radius,
      {double initialIntensity = 1.0}) {
    _emitters.clear();
    _atmosphericSmoke = AtmosphericSmokeSystem();
    for (int i = 0; i < zones.length; i++) {
      final (fx, fz, fd) = zones[i];
      _emitters.add(FireEmitter(
        worldX:       fx,
        worldZ:       fz,
        radius:       radius * 0.7,
        intensity:    initialIntensity,
        fuelDarkness: fd,
      ));
      _atmosphericSmoke!.addPlume(i, fx, fz);
    }
  }

  /// Add a dynamic emitter (e.g. a burning tree).
  void addEmitter(int id, FireEmitter e) => _dynamicEmitters[id] = e;

  /// Remove a dynamic emitter (e.g. a tree that has finished burning).
  void removeEmitter(int id) => _dynamicEmitters.remove(id);

  List<SmokeColumnBillboard> atmosphericSmokeBillboards(Vector3 cameraPos) =>
      _atmosphericSmoke?.getAllBillboards(cameraPos) ?? const [];

  void tick(
    double dt,
    Vector3 wind,
    Vector3 playerPos,
    double Function(double, double) terrainHeightAt,
  ) {
    for (final e in _emitters) {
      final y = terrainHeightAt(e.worldX, e.worldZ);
      e.tick(particles, dt, y, wind);
    }

    for (final e in _dynamicEmitters.values) {
      final y = terrainHeightAt(e.worldX, e.worldZ);
      e.tick(particles, dt, y, wind);
    }

    particles.tick(dt, wind, playerPos);

    for (int i = 0; i < _emitters.length; i++) {
      _atmosphericSmoke?.tickPlume(i, 1.0, wind, dt);
    }
  }

  List<(double, double, double, double)> get fireLightPositions {
    return [
      for (final e in _emitters)
        (e.worldX, 2.0, e.worldZ, e.intensity),
    ];
  }
}
