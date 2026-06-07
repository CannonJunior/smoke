// GLSL shader sources for fire, smoke, and heat-distortion rendering.
// All shaders target GLSL ES 1.00 (WebGL 1.0) for broadest compatibility.
// The GPU particle simulation shader targets GLSL ES 3.00 (WebGL 2.0) and
// is only compiled when transform-feedback support is detected.

// ── Particle billboard vertex shader (shared by fire and smoke) ──────────────
// Applies per-particle billboard rotation before camera-axis expansion.
// aRotation: radians; smoke rotates slowly, fire uses 0.
// aFuelFraction: [0..1] passed through as a varying for the fire shader.
const String particleVertShader = '''
attribute vec3 aWorldPos;
attribute vec2 aCorner;
attribute vec4 aColor;
attribute float aSize;
attribute float aRotation;
attribute float aFuelFraction;

uniform mat4 uViewProj;
uniform vec3 uCameraRight;
uniform vec3 uCameraUp;

varying vec2 vUV;
varying vec4 vColor;
varying float vFuelFraction;

void main() {
  float cosR = cos(aRotation);
  float sinR = sin(aRotation);
  vec2 rotCorner = vec2(
    cosR * aCorner.x - sinR * aCorner.y,
    sinR * aCorner.x + cosR * aCorner.y
  );
  vec3 pos = aWorldPos
    + uCameraRight * rotCorner.x * aSize
    + uCameraUp    * rotCorner.y * aSize;
  vUV          = aCorner * 0.5 + 0.5;
  vColor       = aColor;
  vFuelFraction = aFuelFraction;
  gl_Position  = uViewProj * vec4(pos, 1.0);
}
''';

// ── Shared noise helpers (smoke + heat distortion) ────────────────────────────
const String _noiseGlsl = '''
float _hash(vec2 p) {
  return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}
float _noise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  return mix(
    mix(_hash(i),             _hash(i + vec2(1.0, 0.0)), f.x),
    mix(_hash(i + vec2(0.0,1.0)), _hash(i + vec2(1.0,1.0)), f.x),
    f.y);
}
''';

// ── Fire fragment shader (additive blending) ─────────────────────────────────
// Fire/ember particles (detected by vColor.g < 0.01 && vColor.b < 0.01):
//   vColor.r = temperature [0..1], GPU maps to blackbody RGB.
//   vFuelFraction dims the fire as fuel is consumed.
// Non-fire particles use vColor directly (handled by smokeFragShader; this
// branch is unused in the fire batch but guarded here for safety).
const String fireFragShader = '''
precision mediump float;

varying vec2 vUV;
varying vec4 vColor;
varying float vFuelFraction;
uniform float uTime;

float _fHash(vec2 p) {
  return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}
float _fNoise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  return mix(
    mix(_fHash(i),             _fHash(i + vec2(1.0, 0.0)), f.x),
    mix(_fHash(i + vec2(0.0,1.0)), _fHash(i + vec2(1.0,1.0)), f.x),
    f.y);
}
// iq rotation matrix for domain warp
mat2 _fm = mat2(1.6, 1.2, -1.2, 1.6);
float _fbm(vec2 p) {
  return 0.5 * _fNoise(p) + 0.25 * _fNoise(_fm * p);
}

void main() {
  float d    = length(vUV - 0.5) * 2.0;
  float mask = 1.0 - smoothstep(0.55, 1.0, d);

  // Domain-warped fBm: organic fire turbulence without textures.
  vec2  uv = vUV * 3.5 + vec2(0.0, -uTime * 2.3);
  vec2  q  = vec2(_fbm(uv + 0.1 * uTime));
  float n  = _fbm(uv + 4.0 * q);

  float intensity = mask * n * (1.0 - vUV.y * 0.6);

  if (vColor.g < 0.01 && vColor.b < 0.01) {
    // Fire / ember: blackbody coloring from temperature × fuel fraction.
    float t = vColor.r * vFuelFraction;
    vec3 rgb = vec3(
      clamp(t * 3.0, 0.0, 1.0),
      pow(clamp(t * 3.0 - 0.7, 0.0, 1.0), 2.0) * 0.9,
      pow(clamp(t * 3.0 - 2.0, 0.0, 1.0), 3.0) * 0.7
    );
    float alpha = vColor.a * intensity;
    if (alpha < 0.01) discard;
    gl_FragColor = vec4(rgb, alpha);
  } else {
    vec4 col = vColor;
    col.a   *= intensity;
    if (col.a < 0.01) discard;
    gl_FragColor = col;
  }
}
''';

// ── Smoke fragment shader (standard alpha blending) ──────────────────────────
// Two particle shapes share this shader, selected by vFuelFraction:
//
//  vFuelFraction >= 0.05  →  volumetric billow (main smoke column)
//    Domain-warped distance field breaks the circle into a lobed cauliflower.
//    Two warp passes (large-scale deformation + medium bumps) produce highly
//    non-circular silhouettes.  The opaque core prevents the interior from
//    looking hollow; the lobed edge makes adjacent billboards merge visually.
//
//  vFuelFraction < 0.05   →  wisp (thin tendril, sentinel value = 0.0)
//    Elongated ellipse (3:1 Y:X) with directional streaks.  Billboard rotation
//    from the vertex shader randomises wisp orientation in world space.
//    Very low opacity — wisps are transparent tendrils far from the main column.
const String smokeFragShader = '''
precision mediump float;

varying vec2 vUV;
varying vec4 vColor;
varying float vFuelFraction;
uniform float uTime;

$_noiseGlsl

float _fbm2(vec2 p) {
  return 0.5*_noise(p) + 0.3*_noise(p*2.1+vec2(1.3,0.7)) + 0.2*_noise(p*4.4+vec2(0.2,2.1));
}

void main() {
  // ── Wisp branch (sentinel vFuelFraction < 0.05) ────────────────────────
  if (vFuelFraction < 0.05) {
    // Elongated ellipse: tall and thin.  Billboard rotation (vertex shader)
    // randomises the orientation so each wisp points a different direction.
    vec2 cp = vUV - 0.5;
    cp.x *= 3.0;
    float dw = length(cp) * 2.0;
    float wEdge = 1.0 - smoothstep(0.25, 1.0, dw);

    // Directional streaks along the long axis (Y in UV space).
    vec2 sUV = vec2(abs(cp.x)*4.0, vUV.y*5.0 + uTime*0.08);
    float streak = _fbm2(sUV) * (1.0 - smoothstep(0.0, 0.35, abs(cp.x)*3.5));

    // Thin fade at billboard top and bottom so wisps don't have hard caps.
    float ends = smoothstep(0.0, 0.18, vUV.y) * smoothstep(1.0, 0.82, vUV.y);

    float wMask = max(wEdge * 0.6, streak) * ends;
    float alpha = wMask * vColor.a;
    if (alpha < 0.005) discard;
    gl_FragColor = vec4(vColor.rgb, alpha);
    return;
  }

  // ── Volumetric billow branch ────────────────────────────────────────────
  vec2 p = vUV;

  // Pass 1 — large-scale domain warp (~0.25 UV units).
  float wx1 = _noise(p * 2.2 + vec2(uTime * 0.04, 0.0));
  float wy1 = _noise(p * 2.2 + vec2(7.3, uTime * 0.035));
  p += (vec2(wx1, wy1) - 0.5) * 0.25;

  // Pass 2 — medium bumps (~0.12 UV units, higher frequency).
  float wx2 = _noise(p * 4.8 + vec2(uTime * 0.07, 1.1));
  float wy2 = _noise(p * 4.8 + vec2(3.2, uTime * 0.06));
  p += (vec2(wx2, wy2) - 0.5) * 0.12;

  float d = length(p - 0.5) * 2.0;

  // Cauliflower lobes on the silhouette edge.
  float lobeN = _noise(vUV * 7.5 + vec2(uTime * 0.03, 0.0));
  float bd    = d - lobeN * 0.24 * smoothstep(0.22, 0.68, d);

  float coreMask = 1.0 - smoothstep(0.40, 0.88, bd);
  float edgeMask = 1.0 - smoothstep(0.60, 1.0,  bd);
  float rawMask  = max(coreMask, edgeMask * 0.55);

  // Surface noise modulates only the fringe, not the opaque core.
  vec2  nuv = vUV * 2.8 + vec2(uTime * 0.06, -uTime * 0.28);
  float n   = _fbm2(nuv);
  float edgeFrac = smoothstep(0.30, 0.85, d);
  float mask = mix(rawMask, rawMask * (n * 0.55 + 0.45), edgeFrac);

  float alpha = mask * vColor.a;
  if (alpha < 0.01) discard;
  gl_FragColor = vec4(vColor.rgb, alpha);
}
''';

// ── Heat-distortion pass shaders ─────────────────────────────────────────────
const String heatDistortVertShader = '''
attribute vec2 aPosition;
attribute vec2 aTexCoord;

varying vec2 vTexCoord;

void main() {
  vTexCoord   = aTexCoord;
  gl_Position = vec4(aPosition, 0.0, 1.0);
}
''';

const String heatDistortFragShader = '''
precision mediump float;

varying vec2 vTexCoord;
uniform sampler2D uScene;
uniform float uHeat;
uniform float uTime;

$_noiseGlsl

void main() {
  vec2  uv   = vTexCoord;
  vec2  nuv  = uv * 6.0 + vec2(uTime * 0.3, uTime * 0.17);
  float nx   = _noise(nuv);
  float ny   = _noise(nuv + vec2(1.7, 0.4));
  vec2  off  = (vec2(nx, ny) - 0.5) * uHeat * 0.018;
  gl_FragColor = texture2D(uScene, uv + off);
}
''';

// ── GPU particle simulation shader (WebGL 2.0 / GLSL ES 3.00) ───────────────
const String gpuSimVertShader = '''#version 300 es
in vec3 aPos;
in vec3 aVel;
in float aAge;
in float aLifetime;
in float aSize;
in vec4 aColor;

out vec3 outPos;
out vec3 outVel;
out float outAge;
out float outLifetime;
out float outSize;
out vec4 outColor;

uniform float uDt;
uniform vec3  uWind;
uniform float uWindRadius;
uniform vec3  uPlayerPos;
uniform float uBuoyancy;
uniform float uTurbStrength;
uniform float uTime;

float ghash(vec2 p) {
  return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void main() {
  if (aAge >= aLifetime) {
    outPos = aPos; outVel = aVel; outAge = aAge;
    outLifetime = aLifetime; outSize = aSize; outColor = aColor;
    return;
  }

  float d       = length(aPos - uPlayerPos);
  float wFactor = max(0.0, 1.0 - d / uWindRadius);
  vec3 windForce = uWind * wFactor * 0.55;

  float h   = ghash(aPos.xz + vec2(uTime * 0.3, uTime * 0.17));
  float h2  = ghash(aPos.xz * 1.7 + vec2(uTime * 0.2));
  vec3 turb = vec3(h * 2.0 - 1.0, 0.0, h2 * 2.0 - 1.0) * uTurbStrength;

  float isFire = step(0.5, aColor.r - aColor.b);
  float netUp  = uBuoyancy * isFire + uBuoyancy * 0.3 * (1.0 - isFire) - 9.8;

  vec3 accel = vec3(0.0, netUp, 0.0) + windForce + turb;
  outVel     = aVel + accel * uDt;
  outPos     = aPos + outVel * uDt;
  outAge     = aAge + uDt;
  outLifetime = aLifetime;
  outSize    = aSize;
  outColor   = aColor;
}
''';

const String gpuBillboardVertShader = '''#version 300 es
in vec3 aPos;
in vec4 aColor;
in float aSize;
in float aAge;
in float aLifetime;
in vec2 aCorner;

uniform mat4 uViewProj;
uniform vec3 uCameraRight;
uniform vec3 uCameraUp;

out vec2 vUV;
out vec4 vColor;

void main() {
  float t  = aAge / max(aLifetime, 0.001);
  float alpha = aColor.a * (1.0 - smoothstep(0.7, 1.0, t));
  vec3 pos = aPos
    + uCameraRight * aCorner.x * aSize
    + uCameraUp    * aCorner.y * aSize;
  vUV         = aCorner * 0.5 + 0.5;
  vColor      = vec4(aColor.rgb, alpha);
  gl_Position = uViewProj * vec4(pos, 1.0);
}
''';

const String gpuFireFragShader  = fireFragShader;
const String gpuSmokeFragShader = smokeFragShader;

// ── Toon fire fragment shader (cel-shaded, A/B toggle via ParticleRenderer) ──
// Requires GL_OES_standard_derivatives for fwidth()-based anti-aliasing of
// band boundaries.  The extension is built-in on WebGL2 contexts; on WebGL1 it
// is universally available in modern browsers but explicitly enabled here.
//
// Design:
//  • Temperature envelope = particle.temperature × fuelFraction × radial × height
//    × domain-warped FBM modulation.  Banding is applied to this smooth envelope,
//    NOT to raw noise, so cel bands are large and readable.
//  • 4 discrete color bands (crimson → orange-red → orange → hot yellow) with
//    fwidth()-smoothed transitions to suppress crawling sub-pixel aliasing.
//  • Slow breath pulse: 5 rad/s ≈ 0.8 Hz, well under the 3 Hz perceptual limit.
//  • Rim darkening toward the billboard edge gives an ink-line silhouette feel.
const String toonFireFragShader = '''
#extension GL_OES_standard_derivatives : enable
precision mediump float;

varying vec2 vUV;
varying vec4 vColor;
varying float vFuelFraction;
uniform float uTime;

float hash21(vec2 p) {
  return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}
float vnoise(vec2 p) {
  vec2 i = floor(p); vec2 f = fract(p);
  f = f*f*(3.0-2.0*f);
  return mix(mix(hash21(i),           hash21(i+vec2(1,0)), f.x),
             mix(hash21(i+vec2(0,1)), hash21(i+vec2(1,1)), f.x), f.y);
}
mat2 m2 = mat2(1.6, 1.2, -1.2, 1.6);
float fbm(vec2 p) {
  return 0.5*vnoise(p) + 0.25*vnoise(m2*p) + 0.125*vnoise(m2*m2*p);
}

// 4-band cel palette with fwidth()-smoothed transitions.
// Pass the continuous envelope in; banding happens here so colors and AA share
// the same derivative information.
vec3 firePalette(float t) {
  float fw = max(fwidth(t), 0.003);
  vec3 c0 = vec3(0.55, 0.02, 0.00); // deep crimson  (coolest)
  vec3 c1 = vec3(0.90, 0.25, 0.00); // orange-red
  vec3 c2 = vec3(1.00, 0.55, 0.05); // orange
  vec3 c3 = vec3(1.00, 0.92, 0.10); // hot yellow    (hottest)
  vec3 col = c0;
  col = mix(col, c1, smoothstep(0.25-fw, 0.25+fw, t));
  col = mix(col, c2, smoothstep(0.50-fw, 0.50+fw, t));
  col = mix(col, c3, smoothstep(0.75-fw, 0.75+fw, t));
  return col;
}

void main() {
  float d    = length(vUV - 0.5) * 2.0;
  float mask = 1.0 - smoothstep(0.55, 1.0, d);
  if (mask < 0.01) discard;

  // Safety pass-through for any non-fire encoding that ends up here.
  if (vColor.g > 0.05 || vColor.b > 0.05) {
    gl_FragColor = vec4(vColor.rgb, vColor.a * mask);
    return;
  }

  // Domain-warped FBM for organic flame turbulence.
  vec2 uv = vUV * 3.0 + vec2(0.0, -uTime * 2.0);
  vec2 q  = vec2(fbm(uv + 0.12*uTime), fbm(uv + vec2(5.2, 1.3)));
  float n = fbm(uv + 3.0*q);

  // Temperature envelope — band this, not the raw noise.
  float temp     = vColor.r * vFuelFraction;
  float radial   = 1.0 - d * 0.55;                       // hot centre, cool edge
  float height   = 1.0 - vUV.y * 0.65;                   // hot base, cool tip
  float pulse    = 1.0 + 0.025 * sin(uTime * 5.0);       // 0.8 Hz breath
  float envelope = clamp(temp * radial * height * pulse * (0.75 + 0.25*n), 0.0, 1.0);

  vec3 rgb = firePalette(envelope);

  // Ink-line feel: darken toward billboard rim without post-process outline pass.
  float rim = smoothstep(0.35, 0.72, d);
  rgb *= 1.0 - rim * 0.45;

  float alpha = vColor.a * mask;
  if (alpha < 0.01) discard;
  gl_FragColor = vec4(rgb, alpha);
}
''';

// ── Toon smoke fragment shader (cel-shaded, ink-wash) ────────────────────────
// Shares the vFuelFraction < 0.05 wisp sentinel with the classic smoke shader.
// Additional toon elements:
//  • Domain-warped non-circular silhouette (same two-pass warp as classic).
//  • 3 discrete cel opacity levels with fwidth() AA.
//  • Per-billboard SDF rim darkening → ink-line illusion.
//  • 2-step interior tone (lit vs shadow).
//  • Toon wisps: elongated cel shape with hard ink rim.
const String toonSmokeFragShader = '''
#extension GL_OES_standard_derivatives : enable
precision mediump float;

varying vec2 vUV;
varying vec4 vColor;
varying float vFuelFraction;
uniform float uTime;

float hash21(vec2 p) {
  return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}
float vnoise(vec2 p) {
  vec2 i = floor(p); vec2 f = fract(p);
  f = f*f*(3.0-2.0*f);
  return mix(mix(hash21(i),           hash21(i+vec2(1,0)), f.x),
             mix(hash21(i+vec2(0,1)), hash21(i+vec2(1,1)), f.x), f.y);
}
float fbm3(vec2 p) {
  return 0.5*vnoise(p) + 0.25*vnoise(p*2.0+vec2(1.3,0.7)) + 0.125*vnoise(p*4.0+vec2(0.2,2.1));
}
float celStep(float value, float edge) {
  float fw = max(fwidth(value), 0.004);
  return smoothstep(edge-fw, edge+fw, value);
}

void main() {
  // ── Toon wisp branch ────────────────────────────────────────────────────
  if (vFuelFraction < 0.05) {
    vec2 cp = vUV - 0.5;
    cp.x *= 3.0;
    float dw   = length(cp) * 2.0;
    float wRaw = 1.0 - smoothstep(0.25, 1.0, dw);
    vec2  sUV  = vec2(abs(cp.x)*4.0, vUV.y*5.0 + uTime*0.08);
    float stk  = fbm3(sUV) * (1.0 - smoothstep(0.0, 0.35, abs(cp.x)*3.5));
    float ends = smoothstep(0.0, 0.18, vUV.y) * smoothstep(1.0, 0.82, vUV.y);
    float wMask = max(wRaw * 0.6, stk) * ends;

    // 2-level cel opacity for wisps
    float cel = 0.15 * celStep(wMask, 0.15) + 0.15 * celStep(wMask, 0.45);
    // Hard rim darkening at wisp edges
    float rimW  = smoothstep(0.45, 0.75, dw);
    vec3  rgbW  = vColor.rgb * (1.0 - rimW * 0.60);
    float alpha = cel * vColor.a;
    if (alpha < 0.005) discard;
    gl_FragColor = vec4(rgbW, alpha);
    return;
  }

  // ── Toon billow branch ──────────────────────────────────────────────────
  // Two-pass domain warp for non-circular silhouette.
  vec2 p = vUV;
  float wx1 = vnoise(p * 2.2 + vec2(uTime * 0.04, 0.0));
  float wy1 = vnoise(p * 2.2 + vec2(7.3, uTime * 0.035));
  p += (vec2(wx1, wy1) - 0.5) * 0.25;
  float wx2 = vnoise(p * 4.8 + vec2(uTime * 0.07, 1.1));
  float wy2 = vnoise(p * 4.8 + vec2(3.2, uTime * 0.06));
  p += (vec2(wx2, wy2) - 0.5) * 0.12;

  float d     = length(p - 0.5) * 2.0;
  float dOrig = length(vUV - 0.5) * 2.0; // unwarped d for rim

  float lobeN = vnoise(vUV * 7.5 + vec2(uTime * 0.03, 0.0));
  float bd    = d - lobeN * 0.24 * smoothstep(0.22, 0.68, d);

  float coreMask = 1.0 - smoothstep(0.40, 0.88, bd);
  float edgeMask = 1.0 - smoothstep(0.60, 1.0,  bd);
  float rawMask  = max(coreMask, edgeMask * 0.55);

  vec2  nuv = vUV * 2.8 + vec2(uTime * 0.06, -uTime * 0.28);
  float n   = 0.5*vnoise(nuv) + 0.30*vnoise(nuv*2.2+vec2(0.53,0.79))
                               + 0.20*vnoise(nuv*4.7+vec2(0.11,0.44));
  float edgeFrac = smoothstep(0.30, 0.85, d);
  float mask     = mix(rawMask, rawMask * (n * 0.55 + 0.45), edgeFrac);

  // 3 discrete opacity levels.
  float cel = 0.0;
  cel += 0.45 * celStep(mask, 0.28);
  cel += 0.45 * celStep(mask, 0.62);

  // Per-billboard SDF rim on unwarped radius for a clean ink ring.
  float rim     = smoothstep(0.52, 0.78, dOrig);
  float rimDark = 1.0 - rim * 0.62;

  // 2-step interior tone.
  vec2  tUV  = vUV * 3.2 + vec2(uTime * 0.04, 0.0);
  float tone = 0.80 + 0.20 * celStep(fbm3(tUV), 0.50);

  vec3  rgb   = vColor.rgb * rimDark * tone;
  float alpha = cel * vColor.a;
  if (alpha < 0.01) discard;
  gl_FragColor = vec4(rgb, alpha);
}
''';

// ── Atmospheric smoke plume vertex shader ─────────────────────────────────────
// Each billboard segment has an independent width/height for the stacked column.
// aLayerIndex drives the fragment altitude fade (0 = soot base, 4 = cream top).
const String atmosphericSmokeVertSrc = '''
attribute vec3  aWorldPos;
attribute vec2  aCorner;
attribute vec4  aColor;
attribute float aWidth;
attribute float aHeight;
attribute float aLayerIndex;

uniform mat4 uViewProj;
uniform vec3 uCameraRight;
uniform vec3 uCameraUp;

varying vec2  vUV;
varying vec4  vColor;
varying float vHeightFactor;

void main() {
  vec3 pos = aWorldPos
    + uCameraRight * aCorner.x * aWidth
    + uCameraUp    * aCorner.y * aHeight;
  vUV          = aCorner * 0.5 + 0.5;
  vColor       = aColor;
  vHeightFactor = aLayerIndex / 4.0;
  gl_Position  = uViewProj * vec4(pos, 1.0);
}
''';

// ── Atmospheric smoke plume fragment shader ────────────────────────────────────
// Domain-warped irregular silhouette (not circular), per-quad top/bottom fade
// so heavily-overlapping segments merge into one continuous smoke volume.
const String atmosphericSmokeFragSrc = '''
precision mediump float;

varying vec2  vUV;
varying vec4  vColor;
varying float vHeightFactor;

uniform float uTime;

float ahash(vec2 p) {
  return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}
float anoise(vec2 p) {
  vec2 i = floor(p); vec2 f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  float n0 = mix(ahash(i),             ahash(i + vec2(1.0, 0.0)), f.x);
  float n1 = mix(ahash(i + vec2(0.0,1.0)), ahash(i + vec2(1.0,1.0)), f.x);
  return mix(n0, n1, f.y);
}
float afbm(vec2 p) {
  float r = 0.0; float a = 0.5;
  for (int i = 0; i < 2; i++) { r += a * anoise(p); p *= 2.0; a *= 0.5; }
  return r;
}

void main() {
  // Domain-warp the UV space to produce an irregular, non-circular shape.
  // The warp is driven by slow fBm so the silhouette billows organically.
  vec2 warpUV = vUV * 3.2 + vec2(uTime * 0.012, -uTime * 0.007);
  float wx = afbm(warpUV) - 0.5;
  float wy = afbm(warpUV + vec2(1.73, 2.31)) - 0.5;
  vec2 dUV = vUV + vec2(wx, wy) * 0.22;
  float d = length(dUV - 0.5);

  // Dense opaque core, cauliflower fringe via lobed noise.
  float core = 1.0 - smoothstep(0.24, 0.44, d);
  float edge = 1.0 - smoothstep(0.38, 0.65, d);
  vec2 lobeUV = vUV * 5.5 + vec2(uTime * 0.018, uTime * 0.011);
  float lobe  = anoise(lobeUV) * 0.28;
  float mask  = max(core, clamp(edge + lobe, 0.0, 1.0) * 0.72);

  // Altitude fade: fully opaque low, wispy near the column top.
  float altFade = smoothstep(0.0, 0.20, 1.0 - vHeightFactor)
                * smoothstep(1.05, 0.50, vHeightFactor);

  // Per-quad vertical fade: segments fade in/out at their own top and bottom
  // so that heavily-overlapping quads dissolve into each other seamlessly.
  float segFade = smoothstep(0.0, 0.30, vUV.y) * smoothstep(1.0, 0.70, vUV.y);

  float alpha = vColor.a * mask * altFade * segFade;
  if (alpha < 0.015) discard;
  gl_FragColor = vec4(vColor.rgb, alpha);
}
''';

// ── Cloud billboard vertex shader ─────────────────────────────────────────────
// Shared by cumulus, CB, cirrus, and pyrocumulus billboard quads.
// Supports per-billboard rotation for visual variety.
const String cloudVertSrc = '''
attribute vec3  aWorldPos;
attribute vec2  aCorner;
attribute vec4  aColor;
attribute float aSize;
attribute float aRotation;

uniform mat4 uViewProj;
uniform vec3 uCameraRight;
uniform vec3 uCameraUp;

varying vec2 vUV;
varying vec4 vColor;

void main() {
  float cosR = cos(aRotation);
  float sinR = sin(aRotation);
  vec2  rc   = vec2(cosR * aCorner.x - sinR * aCorner.y,
                    sinR * aCorner.x + cosR * aCorner.y);
  vec3 pos = aWorldPos
    + uCameraRight * rc.x * aSize
    + uCameraUp    * rc.y * aSize;
  vUV         = aCorner * 0.5 + 0.5;
  vColor      = aColor;
  gl_Position = uViewProj * vec4(pos, 1.0);
}
''';

// ── Cloud billboard fragment shader ──────────────────────────────────────────
// Fluffy cumulus shape: opaque rounded core, small-scale bumps on silhouette,
// gentle interior shading. Same non-texture approach as the fire/smoke shaders.
const String cloudFragSrc = '''
precision mediump float;

varying vec2 vUV;
varying vec4 vColor;

uniform float uTime;

float chash(vec2 p) {
  return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}
float cnoise(vec2 p) {
  vec2 i = floor(p); vec2 f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  float n0 = mix(chash(i),             chash(i + vec2(1.0, 0.0)), f.x);
  float n1 = mix(chash(i + vec2(0.0,1.0)), chash(i + vec2(1.0,1.0)), f.x);
  return mix(n0, n1, f.y);
}

void main() {
  float d = length(vUV - 0.5) * 2.0;

  // Rounded core + edge bumps → cauliflower silhouette
  float core = 1.0 - smoothstep(0.42, 0.98, d);
  vec2  edgeUV = vUV * 4.5 + vec2(uTime * 0.018, uTime * 0.012);
  float bump = cnoise(edgeUV) * 0.20;
  float mask = clamp(core + bump * (1.0 - core), 0.0, 1.0);

  // Gentle interior shading (clouds are brighter near the light-facing centre).
  vec2  intUV   = vUV * 3.0 + vec2(uTime * 0.009, -uTime * 0.007);
  float interior = cnoise(intUV) * 0.22 + 0.78;

  float alpha = mask * interior * vColor.a;
  if (alpha < 0.008) discard;
  gl_FragColor = vec4(vColor.rgb, alpha);
}
''';
