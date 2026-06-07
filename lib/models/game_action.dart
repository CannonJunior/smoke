/// GameAction - All bindable player actions in Fire & Ice.
///
/// Used by InputSystem to map physical keys to logical game actions.
/// This decouples input handling from key bindings so controls can
/// be remapped without touching physics or game logic.
///
/// Usage:
/// ```dart
/// if (InputSystem.isActionActive(GameAction.moveForward)) {
///   // pitch up (climb)
/// }
/// ```
enum GameAction {
  /// W - pitch up (climb)
  moveForward,

  /// S - pitch down (dive)
  moveBackward,

  /// Q - bank left only (no yaw)
  strafeLeft,

  /// E - bank right only (no yaw)
  strafeRight,

  /// A - yaw left + bank-enhanced turn rate
  rotateLeft,

  /// D - yaw right + bank-enhanced turn rate
  rotateRight,

  /// Alt - 1.5x speed boost
  sprint,

  /// Space - air brake (slow + upward bump)
  brake,

  // ── Action bar ability slots (keys 1..0) ──────────────────────────

  /// Key 1 - ability slot 1
  actionBar1,

  /// Key 2 - ability slot 2
  actionBar2,

  /// Key 3 - ability slot 3
  actionBar3,

  /// Key 4 - ability slot 4
  actionBar4,

  /// Key 5 - ability slot 5
  actionBar5,

  /// Key 6 - ability slot 6
  actionBar6,

  /// Key 7 - ability slot 7
  actionBar7,

  /// Key 8 - ability slot 8
  actionBar8,

  /// Key 9 - ability slot 9
  actionBar9,

  /// Key 0 - ability slot 10
  actionBar10,

  /// ` (backtick) - toggle between third-person and cockpit views
  toggleView,

  /// Tab - cycle through hostile targets (active fires + living wyverns) by proximity
  cycleTarget,

  /// Shift+Tab - cycle through friendly targets (tanker + airbase) by proximity
  cycleFriendlyTarget,

  /// ] - increase throttle
  throttleUp,

  /// [ - decrease throttle
  throttleDown,

  /// G - toggle landing gear up/down
  toggleGear,

  /// F - cycle flaps through four detents (UP → T/O → APPR → FULL → UP)
  toggleFlaps,

  /// P - deploy / retract IceFighter refueling probe
  toggleProbe,

  /// O - deploy / retract SkyTanker drogue basket
  toggleDrogue,
}
