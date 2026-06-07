import 'package:vector_math/vector_math.dart';

enum ViewMode { thirdPerson, cockpit }

/// Minimal game state for the smoke and terrain sandbox.
/// Holds only what's needed for QWEASD camera flight and fire/smoke rendering.
class GameState {
  // ── Player / camera spatial state ─────────────────────────────────────────

  Vector3 playerPosition = Vector3(0, 80, 0);
  Vector3 playerRotation = Vector3(0, 0, 0); // pitch, yaw, roll (degrees)

  ViewMode viewMode = ViewMode.thirdPerson;

  void toggleViewMode() {
    viewMode = viewMode == ViewMode.thirdPerson
        ? ViewMode.cockpit
        : ViewMode.thirdPerson;
  }

  // ── Flight physics state ───────────────────────────────────────────────────

  double flightSpeed      = 20.0;
  double flightPitchAngle = 0.0;  // degrees, +up
  double flightBankAngle  = 0.0;  // degrees, +right-wing-down
  double verticalSpeed    = 0.0;  // world units/sec
  double flightAltitude   = 35.0;
  double terrainHeight    = 0.0;
  double throttle         = 0.7;
  bool   isBarrelRolling  = false;

  // ── Flight config (tunable constants) ─────────────────────────────────────

  static const double cfgPitchRate          = 45.0;  // degrees/sec
  static const double cfgBankRate           = 60.0;  // degrees/sec
  static const double cfgMaxBankAngle       = 75.0;  // degrees
  static const double cfgAutoLevelRate      = 30.0;  // degrees/sec
  static const double cfgAutoLevelThreshold = 2.0;   // degrees
  static const double cfgBarrelRollRate     = 180.0; // degrees/sec
  static const double cfgRudderYawRate      = 50.0;  // degrees/sec
  static const double cfgBankToTurnMult     = 0.012; // bank → yaw coupling
  static const double cfgMinSpeed           = 5.0;
  static const double cfgMaxSpeed           = 60.0;

  // ── Wind ──────────────────────────────────────────────────────────────────

  Vector3 windVelocity = Vector3(3.0, 0, 1.5);

  Vector3 get apparentWind => windVelocity;

  // ── Fire zones (static; always burning) ───────────────────────────────────
  // Tuple: (worldX, worldZ, fuelDarkness)
  //   fuelDarkness 0.0 = dry vegetation → light gray / cream smoke
  //   fuelDarkness 1.0 = synthetic fuel → near-black smoke
  static const List<(double, double, double)> fireZones = [
    ( 80.0,  60.0, 0.10), // grass / light brush
    (-70.0,  40.0, 0.30), // mixed vegetation
    ( 10.0, -80.0, 0.95), // man-made structure / fuel
    ( 50.0,  30.0, 0.20), // dense brush
    (-30.0, -50.0, 1.00), // petroleum / tires
  ];

  static const double fireRadius = 15.0;

  // Legacy positional list kept for heat-intensity calculation in game_widget.
  static List<(double, double)> get firePositions =>
      [for (final (x, z, _) in fireZones) (x, z)];
}
