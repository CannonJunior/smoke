import 'dart:html' as html;
import 'dart:async' show StreamSubscription;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';
import 'package:vector_math/vector_math.dart' show Vector3;

import '../rendering/camera3d.dart';
import '../rendering/particle_system.dart';
import '../rendering/tree_renderer.dart';
import '../rendering/webgl_renderer.dart';
import '../systems/input_system.dart';
import '../systems/physics_system.dart';
import '../terrain/infinite_terrain_manager.dart';
import '../terrain/terrain_generator.dart';
import '../terrain/tree_system.dart';
import '../models/game_action.dart';
import 'fire_emitter.dart';
import 'game_state.dart';

class SmokeAndTerrainGame extends StatefulWidget {
  const SmokeAndTerrainGame({super.key});

  @override
  State<SmokeAndTerrainGame> createState() => _SmokeAndTerrainGameState();
}

class _SmokeAndTerrainGameState extends State<SmokeAndTerrainGame> {
  final GameState _state = GameState();

  WebGLRenderer? _renderer;
  Camera3D?      _camera;

  html.CanvasElement? _canvas;

  InfiniteTerrainManager? _terrain;

  late FireEmitterSystem _fireSystem;
  late TreeSystem        _treeSystem;
  late TreeRenderer      _treeRenderer;
  double _heatIntensity = 0.0;

  double _lastTimestamp = 0.0;
  bool   _running       = false;
  double _gameTime      = 0.0;

  int _lastCanvasW = 0;
  int _lastCanvasH = 0;

  StreamSubscription<html.KeyboardEvent>? _keyDownSub;
  StreamSubscription<html.KeyboardEvent>? _keyUpSub;
  StreamSubscription<html.Event>?         _blurSub;

  bool _prevToggleView = false;

  // ── Debug HUD ─────────────────────────────────────────────────────────────
  bool   _toonMode          = false;
  bool   _treeReady         = false;
  double _displayFps        = 0.0;
  int    _displayParticles  = 0;
  int    _frameCount        = 0;
  double _fpsAccum          = 0.0;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const SizedBox.expand(),
        Positioned(
          top: 8, left: 8,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            color: Colors.black54,
            child: Text(
              '${_displayFps.toStringAsFixed(0)} FPS  |  '
              '$_displayParticles particles  |  '
              '${_toonMode ? "TOON [T]" : "classic [T]"}',
              style: const TextStyle(
                color: Colors.white,
                fontFamily: 'monospace',
                fontSize: 12,
                decoration: TextDecoration.none,
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _running = false;
    if (_renderer != null && _treeReady) _treeRenderer.dispose(_renderer!);
    _renderer?.dispose();
    _canvas?.remove();
    _keyDownSub?.cancel();
    _keyUpSub?.cancel();
    _blurSub?.cancel();
    _fireSystem.particles.clear();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    _setupCanvas();
    _registerKeyListeners();
    _buildScene();
    await _initFireSystem();
    await _initTreeSystem();
    _startLoop();
  }

  // ── Canvas ────────────────────────────────────────────────────────────────

  void _setupCanvas() {
    _canvas = html.CanvasElement();
    _canvas!.style
      ..position = 'absolute'
      ..top = '0'
      ..left = '0'
      ..width = '100%'
      ..height = '100%';
    html.document.body!.append(_canvas!);

    _renderer = WebGLRenderer(_canvas!);
    _camera   = Camera3D(fov: 90.0);

    final w = html.window.innerWidth ?? 800;
    final h = html.window.innerHeight ?? 600;
    _resizeCanvas(w, h);

    html.window.onResize.listen((_) {
      _resizeCanvas(html.window.innerWidth ?? 800, html.window.innerHeight ?? 600);
    });
  }

  void _resizeCanvas(int w, int h) {
    if (w == _lastCanvasW && h == _lastCanvasH) return;
    _lastCanvasW = w;
    _lastCanvasH = h;
    _renderer?.resize(w, h);
    _camera?.resize(w, h);
    if (_renderer != null && _renderer!.heatDistortion.isAvailable == false) {
      _renderer!.heatDistortion.init(w, h);
    } else if (_renderer != null) {
      _renderer!.heatDistortion.resize(w, h);
    }
  }

  void _registerKeyListeners() {
    _keyDownSub = html.document.onKeyDown.listen((e) {
      InputSystem.handleKeyDown(e);
      _handleKeyEdge(e, pressed: true);
    });
    _keyUpSub = html.document.onKeyUp.listen(InputSystem.handleKeyUp);
    _blurSub  = html.window.onBlur.listen((_) => InputSystem.clearAll());
  }

  void _handleKeyEdge(html.KeyboardEvent e, {required bool pressed}) {
    if (!pressed) return;
    if (e.key == '`') {
      _state.toggleViewMode();
    } else if (e.key == 't' || e.key == 'T') {
      _toonMode = !_toonMode;
      _renderer?.toonMode = _toonMode;
      if (mounted) setState(() {});
    }
  }

  // ── Scene ─────────────────────────────────────────────────────────────────

  void _buildScene() {
    _terrain = InfiniteTerrainManager();
    _terrain!.preload(_state.playerPosition);
  }

  Future<void> _initFireSystem() async {
    final particles = ParticleSystem(maxParticles: 8000);
    _fireSystem = FireEmitterSystem(particles: particles);
    await _fireSystem.loadConfig();
    // Static zones run at 5% intensity — burning trees are the primary source.
    _fireSystem.initZones(GameState.fireZones, GameState.fireRadius,
        initialIntensity: 0.05);
  }

  Future<void> _initTreeSystem() async {
    _treeSystem = TreeSystem();
    await _treeSystem.loadConfig();
    _treeSystem.generate(seed: 42);

    // Ignite trees near each static fire zone.
    for (final (fx, fz, _) in GameState.fireZones) {
      _treeSystem.igniteInRadius(Vector3(fx, 0, fz), 20.0);
    }

    // Create fire emitters for the initially burning trees.
    for (final id in _treeSystem.newlyBurningIds) {
      final t = _treeSystem.trees[id];
      _fireSystem.addEmitter(id, FireEmitter(
        worldX:       t.wx,
        worldZ:       t.wz,
        radius:       t.canopyRadius * 1.5,
        intensity:    1.0,
        fuelDarkness: t.fuelDarkness,
      ));
    }
    _treeSystem.newlyBurningIds.clear();

    _treeRenderer = TreeRenderer();
    _treeRenderer.prebuild(_treeSystem, _state.playerPosition);
    _treeReady = true;
    final alive   = _treeSystem.trees.where((t) => t.state == TreeState.alive).length;
    final burning = _treeSystem.trees.where((t) => t.state == TreeState.burning).length;
    debugPrint('[Trees] ${_treeSystem.trees.length} total — $alive alive, $burning burning');
  }

  // ── Game loop ─────────────────────────────────────────────────────────────

  void _startLoop() {
    _running = true;
    html.window.requestAnimationFrame(_onFrame);
  }

  void _onFrame(num timestamp) {
    if (!_running) return;
    html.window.requestAnimationFrame(_onFrame);

    final ts = timestamp.toDouble();
    final dt = _lastTimestamp == 0.0
        ? 0.016
        : math.min((ts - _lastTimestamp) / 1000.0, 0.05);
    _lastTimestamp = ts;
    _gameTime += dt;

    _processInput(dt);
    _updateScene(dt);
    _renderFrame(dt);

    // HUD: update FPS and particle count every ~0.5 s.
    _frameCount++;
    _fpsAccum += dt;
    if (_fpsAccum >= 0.5) {
      final fps = _frameCount / _fpsAccum;
      final pc  = _fireSystem.particles.particles.length;
      if (mounted) {
        setState(() {
          _displayFps       = fps;
          _displayParticles = pc;
        });
      }
      _frameCount = 0;
      _fpsAccum   = 0.0;
    }
  }

  void _processInput(double dt) {
    final forward     = InputSystem.isActionActive(GameAction.moveForward);
    final backward    = InputSystem.isActionActive(GameAction.moveBackward);
    final strafeLeft  = InputSystem.isActionActive(GameAction.strafeLeft);
    final strafeRight = InputSystem.isActionActive(GameAction.strafeRight);
    final bankLeft    = InputSystem.isActionActive(GameAction.rotateLeft);
    final bankRight   = InputSystem.isActionActive(GameAction.rotateRight);

    // Throttle via ] / [
    if (InputSystem.isActionActive(GameAction.throttleUp)) {
      _state.throttle = (_state.throttle + dt * 0.5).clamp(0.0, 1.0);
    }
    if (InputSystem.isActionActive(GameAction.throttleDown)) {
      _state.throttle = (_state.throttle - dt * 0.5).clamp(0.0, 1.0);
    }

    PhysicsSystem.updateFlight(
      _state,
      forward, backward,
      strafeLeft, strafeRight,
      bankLeft, bankRight,
      dt,
    );

    // Toggle view (backtick edge detect)
    final toggleNow = InputSystem.isActionActive(GameAction.toggleView);
    if (toggleNow && !_prevToggleView) _state.toggleViewMode();
    _prevToggleView = toggleNow;
  }

  void _updateScene(double dt) {
    _terrain?.update(_state.playerPosition);

    // Free removed terrain meshes from GPU.
    final removed = _terrain?.drainRemovedMeshes() ?? const [];
    for (final m in removed) {
      _renderer?.deleteMeshBuffers(m);
    }

    _tickTrees(dt);

    _fireSystem.tick(
      dt,
      _state.apparentWind,
      _state.playerPosition,
      TerrainGenerator.heightAt,
    );

    // Update camera.
    final cam = _camera;
    if (cam != null) {
      if (_state.viewMode == ViewMode.cockpit) {
        cam.positionAsCockpit(
          _state.playerPosition,
          _state.playerRotation.y,
          _state.playerRotation.x,
          _state.flightBankAngle,
        );
      } else {
        cam.updateThirdPersonFollow(
          _state.playerPosition,
          _state.playerRotation.y,
          _state.flightBankAngle,
          dt,
        );
      }
    }

    // Heat intensity: proximity to nearest fire zone.
    double heat = 0.0;
    for (final (fx, fz) in GameState.firePositions) {
      final dx = _state.playerPosition.x - fx;
      final dz = _state.playerPosition.z - fz;
      final dist = math.sqrt(dx * dx + dz * dz);
      final dy = _state.playerPosition.y -
          TerrainGenerator.heightAt(fx, fz);
      if (dist < 60 && dy < 40) {
        final contrib = (1.0 - dist / 60.0) * (1.0 - (dy / 40.0).clamp(0.0, 1.0));
        heat = math.max(heat, contrib * 0.6);
      }
    }
    _heatIntensity += (heat - _heatIntensity) * 3.0 * dt;
  }

  void _tickTrees(double dt) {
    _treeSystem.update(dt, _state.apparentWind);

    for (final id in _treeSystem.newlyBurningIds) {
      final t = _treeSystem.trees[id];
      _fireSystem.addEmitter(id, FireEmitter(
        worldX:       t.wx,
        worldZ:       t.wz,
        radius:       t.canopyRadius * 1.5,
        intensity:    1.0,
        fuelDarkness: t.fuelDarkness,
      ));
    }
    _treeSystem.newlyBurningIds.clear();

    for (final id in _treeSystem.newlyCharredIds) {
      _fireSystem.removeEmitter(id);
    }
    _treeSystem.newlyCharredIds.clear();
  }

  void _renderFrame(double dt) {
    final renderer = _renderer;
    final camera   = _camera;
    if (renderer == null || camera == null) return;

    renderer.time = _gameTime;

    final useHeat = renderer.heatDistortion.isAvailable && _heatIntensity > 0.01;
    if (useHeat) renderer.beginHeatPass();

    renderer.clear();

    // Terrain
    if (_terrain != null) {
      for (final chunk in _terrain!.loadedChunks) {
        renderer.render(chunk.mesh, chunk.transform, camera);
      }
    }

    // Trees (three batched draw calls: alive / burning / charred)
    if (_treeReady) _treeRenderer.render(renderer, _treeSystem, camera);

    // Atmospheric smoke (far field)
    final atmBillboards = _fireSystem.atmosphericSmokeBillboards(camera.position);
    renderer.renderAtmosphericSmoke(atmBillboards, camera);

    // Close-range fire + smoke particles
    renderer.renderParticles(_fireSystem.particles.particles, camera);

    if (useHeat) renderer.endHeatPass(_heatIntensity);
  }
}
