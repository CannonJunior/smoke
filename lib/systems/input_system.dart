import 'dart:html' as html;
import '../models/game_action.dart';

/// InputSystem - Keyboard input tracking for Fire & Ice.
///
/// Maintains a set of currently-pressed logical key strings.
/// Maps raw key events to [GameAction] values for use by
/// PhysicsSystem and AbilitySystem.
///
/// Call [handleKeyDown] / [handleKeyUp] from the canvas keyboard listeners.
/// Query with [isActionActive] each frame.
///
/// Usage:
/// ```dart
/// html.document.onKeyDown.listen(InputSystem.handleKeyDown);
/// html.document.onKeyUp.listen(InputSystem.handleKeyUp);
///
/// // In game loop:
/// if (InputSystem.isActionActive(GameAction.moveForward)) { ... }
/// ```
class InputSystem {
  InputSystem._(); // Static-only class

  /// Set of currently pressed logical key strings (browser KeyboardEvent.key).
  static final Set<String> _pressedKeys = {};

  // ── Key event handlers ───────────────────────────────────────────────────

  /// Register a key-down event from the browser.
  static void handleKeyDown(html.KeyboardEvent event) {
    _pressedKeys.add(event.key ?? '');
    // Prevent browser default for game keys (arrow scrolling, etc.)
    _maybePreventDefault(event);
  }

  /// Register a key-up event from the browser.
  static void handleKeyUp(html.KeyboardEvent event) {
    _pressedKeys.remove(event.key ?? '');
  }

  /// Check whether a raw logical key is currently held.
  static bool isKeyPressed(String logicalKey) =>
      _pressedKeys.contains(logicalKey);

  // ── Action queries ────────────────────────────────────────────────────────

  /// Returns true if the key(s) bound to [action] are currently pressed.
  static bool isActionActive(GameAction action) {
    switch (action) {
      case GameAction.moveForward:
        return _pressedKeys.contains('w') || _pressedKeys.contains('W');

      case GameAction.moveBackward:
        return _pressedKeys.contains('s') || _pressedKeys.contains('S');

      case GameAction.strafeLeft:
        // Q - bank left
        return _pressedKeys.contains('q') || _pressedKeys.contains('Q');

      case GameAction.strafeRight:
        // E - bank right
        return _pressedKeys.contains('e') || _pressedKeys.contains('E');

      case GameAction.rotateLeft:
        // A - yaw left
        return _pressedKeys.contains('a') || _pressedKeys.contains('A');

      case GameAction.rotateRight:
        // D - yaw right
        return _pressedKeys.contains('d') || _pressedKeys.contains('D');

      case GameAction.sprint:
        // Alt key (both left and right)
        return _pressedKeys.contains('Alt');

      case GameAction.brake:
        // Space bar
        return _pressedKeys.contains(' ');

      // ── Action bar: keys 1–9 map to slots 1–9, 0 maps to slot 10 ────────
      case GameAction.actionBar1:
        return _pressedKeys.contains('1');
      case GameAction.actionBar2:
        return _pressedKeys.contains('2');
      case GameAction.actionBar3:
        return _pressedKeys.contains('3');
      case GameAction.actionBar4:
        return _pressedKeys.contains('4');
      case GameAction.actionBar5:
        return _pressedKeys.contains('5');
      case GameAction.actionBar6:
        return _pressedKeys.contains('6');
      case GameAction.actionBar7:
        return _pressedKeys.contains('7');
      case GameAction.actionBar8:
        return _pressedKeys.contains('8');
      case GameAction.actionBar9:
        return _pressedKeys.contains('9');
      case GameAction.actionBar10:
        return _pressedKeys.contains('0');

      case GameAction.toggleView:
        return _pressedKeys.contains('`');

      case GameAction.cycleTarget:
        return _pressedKeys.contains('Tab') && !_pressedKeys.contains('Shift');

      case GameAction.cycleFriendlyTarget:
        return _pressedKeys.contains('Tab') && _pressedKeys.contains('Shift');

      case GameAction.throttleUp:
        return _pressedKeys.contains(']');
      case GameAction.throttleDown:
        return _pressedKeys.contains('[');
      case GameAction.toggleGear:
        return _pressedKeys.contains('g');

      case GameAction.toggleFlaps:
        return _pressedKeys.contains('f') || _pressedKeys.contains('F');

      case GameAction.toggleProbe:
        return _pressedKeys.contains('p') || _pressedKeys.contains('P');

      case GameAction.toggleDrogue:
        return _pressedKeys.contains('o') || _pressedKeys.contains('O');
    }
  }

  /// Returns true if [action] was just pressed this event (not held).
  ///
  /// Useful for one-shot triggers like ability activation. Must be called
  /// from within the key-down handler, not the game loop, to be accurate.
  static bool wasJustPressed(String key) => _pressedKeys.contains(key);

  /// Clear all pressed keys (e.g. on window blur/focus loss).
  static void clearAll() => _pressedKeys.clear();

  // ── Internal helpers ─────────────────────────────────────────────────────

  /// Prevent browser defaults for keys that would otherwise scroll the page
  /// or trigger other browser shortcuts during gameplay.
  static void _maybePreventDefault(html.KeyboardEvent event) {
    const gameKeys = {
      'w', 'W', 'a', 'A', 's', 'S', 'd', 'D',
      'q', 'Q', 'e', 'E',
      ' ',      // Space
      '1', '2', '3', '4', '5',
      '6', '7', '8', '9', '0',
      'Alt', 'Tab', '`', 'f', 'F', 'g', 'G', 'o', 'O', 'p', 'P', '[', ']',
      'ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight',
    };

    if (gameKeys.contains(event.key)) {
      event.preventDefault();
    }
  }
}
