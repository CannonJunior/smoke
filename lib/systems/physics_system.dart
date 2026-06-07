import 'dart:math' as math;
import '../game/game_state.dart';

/// Simplified flight physics for the QWEASD flying camera.
///
/// Controls:
///  W/S = pitch up/down   Q/E = bank only   A/D = rudder (yaw only)
///  Q+A / E+D = barrel roll
class PhysicsSystem {
  PhysicsSystem._();

  static void updateFlight(
    GameState state,
    bool forward, bool backward,
    bool strafeLeft, bool strafeRight,
    bool bankLeft, bool bankRight,
    double dt,
  ) {
    _updatePitch(state, forward, backward, dt);
    _updateBanking(state, strafeLeft, strafeRight, bankLeft, bankRight, dt);
    _updateYaw(state, strafeLeft, strafeRight, bankLeft, bankRight, dt);
    _updateSpeed(state, dt);
    _updatePosition(state, dt);
  }

  static void _updatePitch(
    GameState state, bool forward, bool backward, double dt,
  ) {
    if (backward) {
      state.flightPitchAngle += GameState.cfgPitchRate * dt;
    } else if (forward) {
      state.flightPitchAngle -= GameState.cfgPitchRate * dt;
    }
    state.flightPitchAngle = ((state.flightPitchAngle + 180) % 360) - 180;
    state.flightPitchAngle = state.flightPitchAngle.clamp(-80.0, 80.0);
    state.playerRotation.x = state.flightPitchAngle;
  }

  static void _updateBanking(
    GameState state,
    bool qHeld, bool eHeld, bool aHeld, bool dHeld, double dt,
  ) {
    final barrelLeft  = qHeld && aHeld;
    final barrelRight = eHeld && dHeld;
    state.isBarrelRolling = barrelLeft || barrelRight;

    if (barrelLeft) {
      state.flightBankAngle -= GameState.cfgBarrelRollRate * dt;
      if (state.flightBankAngle < -360) state.flightBankAngle += 360;
    } else if (barrelRight) {
      state.flightBankAngle += GameState.cfgBarrelRollRate * dt;
      if (state.flightBankAngle > 360) state.flightBankAngle -= 360;
    } else if (qHeld) {
      state.flightBankAngle = (state.flightBankAngle - GameState.cfgBankRate * dt)
          .clamp(-GameState.cfgMaxBankAngle, GameState.cfgMaxBankAngle);
    } else if (eHeld) {
      state.flightBankAngle = (state.flightBankAngle + GameState.cfgBankRate * dt)
          .clamp(-GameState.cfgMaxBankAngle, GameState.cfgMaxBankAngle);
    } else if (state.flightBankAngle.abs() < GameState.cfgAutoLevelThreshold) {
      if (state.flightBankAngle > 0) {
        state.flightBankAngle =
            (state.flightBankAngle - GameState.cfgAutoLevelRate * dt)
                .clamp(0.0, double.infinity);
      } else if (state.flightBankAngle < 0) {
        state.flightBankAngle =
            (state.flightBankAngle + GameState.cfgAutoLevelRate * dt)
                .clamp(double.negativeInfinity, 0.0);
      }
    }
    state.playerRotation.z = -state.flightBankAngle;
  }

  static void _updateYaw(
    GameState state,
    bool qHeld, bool eHeld, bool aHeld, bool dHeld, double dt,
  ) {
    if ((qHeld && aHeld) || (eHeld && dHeld)) return;

    final bankSin = math.sin(state.flightBankAngle * (math.pi / 180.0));
    if (state.flightBankAngle.abs() > 1.0) {
      state.playerRotation.y -= bankSin * GameState.cfgBankToTurnMult * 60.0 * dt;
    }

    if (aHeld) state.playerRotation.y += GameState.cfgRudderYawRate * dt;
    if (dHeld) state.playerRotation.y -= GameState.cfgRudderYawRate * dt;
  }

  static void _updateSpeed(GameState state, double dt) {
    final targetSpeed = GameState.cfgMinSpeed +
        state.throttle * (GameState.cfgMaxSpeed - GameState.cfgMinSpeed);
    state.flightSpeed += (targetSpeed - state.flightSpeed) * 2.0 * dt;

    // Pitch drives vertical speed (arcade model).
    final pitchImplied =
        state.flightSpeed * math.sin(state.flightPitchAngle * math.pi / 180.0);
    state.verticalSpeed += (pitchImplied - state.verticalSpeed) * 3.0 * dt;
    state.verticalSpeed = state.verticalSpeed.clamp(-20.0, 20.0);
  }

  static void _updatePosition(GameState state, double dt) {
    final yawRad = state.playerRotation.y * (math.pi / 180.0);
    final vsSq   = state.verticalSpeed * state.verticalSpeed;
    final fsSq   = state.flightSpeed * state.flightSpeed;
    final hSpeed = math.sqrt(math.max(0.0, fsSq - vsSq));

    state.playerPosition.x -= math.sin(yawRad) * hSpeed * dt;
    state.playerPosition.z -= math.cos(yawRad) * hSpeed * dt;
    state.playerPosition.y += state.verticalSpeed * dt;
    state.flightAltitude    = state.playerPosition.y;
  }
}
