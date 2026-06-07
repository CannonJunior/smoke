import 'dart:math' as math;
import 'package:vector_math/vector_math.dart';

// ── Particle data ─────────────────────────────────────────────────────────────

class Particle {
  Vector3 position;
  Vector3 velocity;
  double lifetime;
  double age;
  double size;
  bool isFire;

  /// Embers shoot up out of the fire but never convert to smoke.
  bool isEmber;

  /// World-space XZ position of the emitter that spawned this particle.
  /// Used for source-based wind attenuation and updraft column.
  double sourceX;
  double sourceZ;

  /// Normalised temperature [0..1] — drives GPU blackbody coloring.
  double temperature;

  /// Billboard rotation angle (radians) — smoke rotates slowly after spawn.
  double rotation;

  /// Fuel remaining [0..1] — dims fire colour as the particle ages.
  double fuelFraction;

  /// Ice-breath particle — crystal sparks (isEmber=true) or frost mist (!isEmber).
  /// writeColor() outputs blue-white; crystals go additive, mist goes alpha-blend.
  bool isIce;

  /// Thin tendril particle.  Rendered with an elongated mask in the smoke
  /// shader, identified by fuelFraction = 0.0 (sentinel, never used for real
  /// fire) so no extra VBO attribute is needed.
  bool isWisp;

  /// Darkness of the fuel source: 0 = light dry vegetation (gray-white smoke),
  /// 1 = synthetic/petroleum (near-black smoke).  Carried through fire→smoke
  /// conversion and written into vColor.rgb in writeColor().
  double fuelDarkness;

  Particle({
    required this.position,
    required this.velocity,
    required this.lifetime,
    required this.size,
    required this.isFire,
    this.isEmber      = false,
    this.isIce        = false,
    this.isWisp       = false,
    this.sourceX      = 0.0,
    this.sourceZ      = 0.0,
    this.temperature  = 0.8,
    this.rotation     = 0.0,
    this.fuelFraction = 1.0,
    this.fuelDarkness = 0.0,
  }) : age = 0.0;

  bool get isDead => age >= lifetime;
  double get t => (age / lifetime).clamp(0.0, 1.0);

  Vector4 get color {
    final out = Vector4.zero();
    writeColor(out);
    return out;
  }

  /// Fire/ember: GPU owns RGB via blackbody; we pass (temperature, 0, 0, fade).
  /// Ice crystal (isEmber+isIce): bright blue-white → additive sparks.
  /// Ice mist (!isEmber, isIce): pale electric blue → alpha-blend fog.
  /// Smoke: color driven by fuelDarkness — vegetation fires produce light
  ///   gray→cream; synthetic/petroleum fires produce near-black that stays dark.
  /// Wisps: thin translucent tendrils; same hue range but very low alpha.
  void writeColor(Vector4 out) {
    final t_ = t;
    if (isIce) {
      if (isEmber) {
        final fade = (1.0 - t_ * 0.55).clamp(0.0, 1.0);
        out.setValues(0.68, 0.91, 1.0, fade * 0.95);
      } else {
        final fade = t_ < 0.14
            ? t_ / 0.14
            : (1.0 - (t_ - 0.14) / 0.86).clamp(0.0, 1.0);
        out.setValues(0.28, 0.70, 1.0, fade * 0.52);
      }
      return;
    }
    if (isFire || isEmber) {
      out.setValues(temperature, 0.0, 0.0, 1.0 - t_ * 0.4);
      return;
    }

    // Smoke & wisps —————————————————————————————————————————————————————
    // Two endpoint color curves interpolated by fuelDarkness:
    //   veg  (0): light gray at birth → cream at old age
    //   syn  (1): near-black at birth → dark gray at old age (barely lightens)
    final double vr, vg, vb; // vegetation curve
    if (t_ < 0.4) {
      vr = 0.40 + t_ * 0.80;  // 0.40 → 0.72
      vg = 0.37 + t_ * 0.70;  // 0.37 → 0.65
      vb = 0.33 + t_ * 0.60;  // 0.33 → 0.57
    } else {
      vr = 0.72 + (t_ - 0.4) * 0.38; // 0.72 → 0.95
      vg = 0.65 + (t_ - 0.4) * 0.38; // 0.65 → 0.88
      vb = 0.57 + (t_ - 0.4) * 0.36; // 0.57 → 0.79
    }
    final double mr, mg, mb; // manmade / synthetic curve
    if (t_ < 0.4) {
      mr = 0.04 + t_ * 0.25; // 0.04 → 0.14
      mg = 0.03 + t_ * 0.22; // 0.03 → 0.12
      mb = 0.02 + t_ * 0.18; // 0.02 → 0.09
    } else {
      mr = 0.14 + (t_ - 0.4) * 0.10; // 0.14 → 0.20
      mg = 0.12 + (t_ - 0.4) * 0.09; // 0.12 → 0.17
      mb = 0.09 + (t_ - 0.4) * 0.07; // 0.09 → 0.13
    }
    final fd = fuelDarkness.clamp(0.0, 1.0);
    final r = (vr * (1.0 - fd) + mr * fd).clamp(0.0, 1.0);
    final g = (vg * (1.0 - fd) + mg * fd).clamp(0.0, 1.0);
    final b = (vb * (1.0 - fd) + mb * fd).clamp(0.0, 1.0);

    if (isWisp) {
      // Wisps: very transparent, fade-in over first 8% and out over last 30%.
      final fadeIn  = (t_ / 0.08).clamp(0.0, 1.0);
      final fadeOut = t_ > 0.70 ? (1.0 - (t_ - 0.70) / 0.30).clamp(0.0, 1.0) : 1.0;
      out.setValues(r, g, b, fadeIn * fadeOut * 0.28);
    } else {
      // Main smoke: hold near-full opacity until t=0.70, then fade out.
      final alpha = t_ < 0.70 ? 0.92 : 0.92 * (1.0 - (t_ - 0.70) / 0.30);
      out.setValues(r, g, b, alpha.clamp(0.0, 1.0));
    }
  }
}

// ── CPU particle system ───────────────────────────────────────────────────────

class ParticleSystem {
  final int maxParticles;
  final List<Particle> _particles = [];
  final math.Random _rng = math.Random();

  double buoyancy          = 5.2;
  double turbulenceStr     = 0.8;
  double windInfluence     = 0.55;
  double smokeWindInfluence = 0.40; // applied as acceleration; drag sets terminal vel
  double windRadius        = 60.0;
  double smokeTransition   = 0.6;
  double smokeFadeAlt      = 200.0;
  double updraftStrength   = 3.0;
  double updraftSigma      = 3.0;
  // smokeBuoyancy=13.0 → net up = 3.2 m/s² at birth, age decay to ~0 at old age.
  // smokeDrag=0.8   → terminal rise ≈ 4.0 m/s young, ~1.5 m/s mid, ~0 old.
  double smokeBuoyancy     = 13.0;
  double smokeDrag         =  0.8;
  double smokeLifeMin      = 22.0;
  double smokeLifeMax      = 40.0;
  double smokeSizeGrowth   =  0.9;
  double smokeInitSizeMult =  5.0;

  // High-altitude wind: above altWindBase (world Y), extra lateral push
  // sweeps smoke swiftly and accelerated aging causes it to dissipate.
  // altWindBase should sit just above the tallest terrain feature.
  double altWindBase      = 30.0;
  double altWindStrength  =  3.5; // multiplier on base wind at full altitude
  double altWindRange     = 50.0; // altitude range over which effect maxes out
  double altDissipation   =  1.2; // extra age/s per unit of altFrac (0–1)

  // Pre-allocated scratch vectors — eliminates ~36k Vector3 allocs/frame at 6k particles.
  final Vector3 _windScratch  = Vector3.zero();
  final Vector3 _turbScratch  = Vector3.zero();
  final Vector3 _accelScratch = Vector3.zero();
  final Vector3 _dtmpScratch  = Vector3.zero();

  ParticleSystem({this.maxParticles = 5000});

  List<Particle> get particles => _particles;

  void tick(double dt, Vector3 wind, Vector3 playerPos) {
    for (final p in _particles) {
      if (p.isDead) continue;

      // Wind attenuation.
      // Fire/ember: attenuate by distance from their emitter source — hot
      //   gas near the flame base is somewhat sheltered.
      // Smoke/wisp: always fully wind-driven (wFactor = 1.0).  The previous
      //   player-distance heuristic was a bug — it zeroed wind for all smoke
      //   from fire zones > 60 units away, making smoke rise perfectly straight.
      final double wFactor;
      final double wInfluence;
      if (p.isFire || p.isEmber) {
        final dx = p.position.x - p.sourceX;
        final dz = p.position.z - p.sourceZ;
        final dist = math.sqrt(dx * dx + dz * dz);
        wFactor   = (1.0 - dist / windRadius).clamp(0.0, 1.0);
        wInfluence = windInfluence;
      } else {
        wFactor   = 1.0;
        wInfluence = smokeWindInfluence;
      }
      _windScratch.setFrom(wind);
      _windScratch.scale(wInfluence * wFactor);

      // Turbulence — reuse scratch, no alloc.
      final hx = _hash(p.position.x * 3.7 + p.age * 0.8);
      final hz = _hash(p.position.z * 5.1 + p.age * 0.6);
      _turbScratch.setValues(hx * 2 - 1, 0, hz * 2 - 1);
      _turbScratch.scale(turbulenceStr);

      const gravity = -9.8;
      final double netUp;
      if (p.isEmber)     { netUp = buoyancy * 0.5 + gravity; }
      else if (p.isFire) { netUp = buoyancy + gravity; }
      else {
        // Buoyancy decays from 100 % (young) to 75 % (old) as smoke cools.
        // At 75 %, netUp ≈ 13.0 × 0.75 − 9.8 ≈ 0 → old smoke drifts laterally
        // without rising or sinking.  The altitude wind then sweeps it away.
        final ageFrac = 1.0 - p.t.clamp(0.0, 1.0);
        netUp = smokeBuoyancy * (0.75 + 0.25 * ageFrac) + gravity;
      }

      // Updraft column (Gaussian plume; skip if > 3σ).
      double updraftY = 0.0;
      if (p.isFire || p.isEmber) {
        final dx = p.position.x - p.sourceX;
        final dz = p.position.z - p.sourceZ;
        final r  = math.sqrt(dx * dx + dz * dz);
        if (r <= updraftSigma * 3.0) {
          updraftY = updraftStrength *
              math.exp(-r * r / (2.0 * updraftSigma * updraftSigma));
        }
      }

      // Compose acceleration in-place — no intermediate Vector3 allocs.
      _accelScratch.setValues(0, netUp + updraftY, 0);
      _accelScratch.add(_windScratch);
      _accelScratch.add(_turbScratch);

      // High-altitude wind: extra lateral push above altWindBase.
      // Applied inside accelScratch so drag still limits terminal velocity.
      double altFrac = 0.0;
      if (!p.isFire && !p.isEmber && p.position.y > altWindBase) {
        altFrac = ((p.position.y - altWindBase) / altWindRange).clamp(0.0, 1.0);
        _accelScratch.x += wind.x * smokeWindInfluence * altWindStrength * altFrac;
        _accelScratch.z += wind.z * smokeWindInfluence * altWindStrength * altFrac;
      }

      _dtmpScratch.setFrom(_accelScratch);
      _dtmpScratch.scale(dt);
      p.velocity.add(_dtmpScratch);

      // Atmospheric drag caps terminal velocity.
      // Young smoke terminal rise ≈ 3.2/0.8 = 4.0 m/s; old smoke ≈ 0 m/s.
      if (!p.isFire && !p.isEmber) {
        p.velocity.scale((1.0 - smokeDrag * dt).clamp(0.0, 1.0));
      }

      _dtmpScratch.setFrom(p.velocity);
      _dtmpScratch.scale(dt);
      p.position.add(_dtmpScratch);
      p.age += dt;

      // Altitude dissipation: smoke above altWindBase ages faster so it fades
      // and dies while being swept sideways — gives the "blown away" look.
      if (altFrac > 0.0 && !p.isFire && !p.isEmber) {
        p.age += altDissipation * altFrac * dt;
      }

      if (p.isFire) p.fuelFraction = (1.0 - p.t).clamp(0.0, 1.0);

      if (!p.isFire && !p.isEmber) {
        p.rotation += dt * 0.28;
        p.size     += smokeSizeGrowth * dt;
      }

      if (p.isFire && p.t >= smokeTransition && !p.isDead) {
        _maybeTurnToSmoke(p);
      }
    }

    // Swap-remove dead particles — O(n) single pass, no list reallocation.
    int i = 0;
    while (i < _particles.length) {
      if (_particles[i].isDead) {
        _particles[i] = _particles.last;
        _particles.removeLast();
      } else {
        i++;
      }
    }
  }

  void _maybeTurnToSmoke(Particle p) {
    if (p.isEmber) return;
    if (p.isFire && p.t >= smokeTransition) {
      p.isFire      = false;
      p.lifetime    = p.age + smokeLifeMin +
                      _rng.nextDouble() * (smokeLifeMax - smokeLifeMin);
      p.size       *= smokeInitSizeMult;
      p.velocity.y *= 0.55; // retain upward momentum
      p.rotation    = _rng.nextDouble() * math.pi * 2;
    }
  }

  bool emit(Particle p) {
    if (_particles.length >= maxParticles) return false;
    _particles.add(p);
    return true;
  }

  void emitMany(List<Particle> ps) {
    for (final p in ps) {
      if (!emit(p)) break;
    }
  }

  void clear() => _particles.clear();

  static double _hash(double v) =>
      (math.sin(v * 127.1) * 43758.5453).abs() % 1.0;
}
