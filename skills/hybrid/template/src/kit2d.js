// 2D character layer for the hybrid kit (owner 2026-11-18): hand-drawn characters that live inside the 3D world.
//
// A character is a drawing that is a function of its pose. We draw it on an offscreen canvas every frame and put
// that canvas on a camera-facing plane in the THREE scene, with a soft ground shadow, so 3D props can stand in
// front of and behind it and the sun in the scene and the cel shading in the drawing agree.
//
// Contract (same as the rest of the kit): every pixel of a frame is a function of t. The pose carries all the time
// it needs (phase, blinkT, waveT...); draw() uses only the pose. No clocks, no Math.random.
import { THREE, TAU, clamp, lerp, seg, ease, wobble } from './kit.js';

const norm = (x, y) => { const d = Math.hypot(x, y) || 1; return [x / d, y / d]; };

// tapered capsule between two joints (external tangent between two circles) + optional ink outline
function limbPath(g, ax, ay, bx, by, ra, rb) {
  const dx = bx - ax, dy = by - ay, D = Math.hypot(dx, dy) || 1e-4;
  const a = Math.atan2(dy, dx);
  const b = Math.acos(clamp((ra - rb) / D, -1, 1));
  const p1 = [ax + ra * Math.cos(a + b), ay + ra * Math.sin(a + b)];
  const p2 = [bx + rb * Math.cos(a + b), by + rb * Math.sin(a + b)];
  const p3 = [bx + rb * Math.cos(a - b), by + rb * Math.sin(a - b)];
  const p4 = [ax + ra * Math.cos(a - b), ay + ra * Math.sin(a - b)];
  g.beginPath();
  g.moveTo(p1[0], p1[1]); g.lineTo(p2[0], p2[1]);
  g.arc(bx, by, rb, a + b, a - b, true);          // end cap (round)
  g.lineTo(p3[0], p3[1]); g.lineTo(p4[0], p4[1]);
  g.arc(ax, ay, ra, a - b, a + b, true);          // start cap
  g.closePath();
}

// fill a part in its base colour, ink it, then lay a cel shadow on the side the light leaves (+sun), clipped to it
function part(g, path, base, o) {
  path();
  g.fillStyle = base; g.fill();
  if (o.shade) {
    g.save(); g.clip(); g.fillStyle = o.shade;
    const s = o.sun, big = o.size;
    g.fillRect(s[0] * big, s[1] * big, s[0] * big, s[1] * big); // a big rect pushed toward the shadow side
    g.restore();
  }
  if (o.ink) { path(); g.lineWidth = o.lw; g.strokeStyle = o.ink; g.lineJoin = 'round'; g.stroke(); }
}

const shadeOf = (hex, k = 0.22) => {         // a muted darker tone of a hex colour
  const c = new THREE.Color(hex).lerp(new THREE.Color('#20202a'), k); return '#' + c.getHexString();
};

// One hand-drawn character. Returns { root, mesh, shadow, pose(p) }. Add root to the scene; root sits on the ground.
export function make2DCharacter(o = {}) {
  const H = o.height || 1.55;                                  // world metres from foot to hair
  const [cw, ch] = o.canvas || [256, 384];
  const skin = o.skin || '#f0c19a', shirt = o.shirt || '#e4572e', pants = o.pants || '#35508a';
  const hair = o.hair || '#5a3825', shoe = o.shoe || '#3a2c2c';
  const ink = o.ink || '#2a2230';
  const skinSh = shadeOf(skin), shirtSh = shadeOf(shirt), pantsSh = shadeOf(pants), hairSh = shadeOf(hair);
  const sun = norm(...(o.sun || [-0.55, -0.95]));               // light travel direction in the drawing (down-left)
  const lw = Math.max(1.1, ch * 0.006);                         // ink weight
  const S = (x, y) => [x * cw, y * ch];                         // fraction of canvas -> pixels

  const canvas = document.createElement('canvas'); canvas.width = cw; canvas.height = ch;
  const g = canvas.getContext('2d');
  const texture = new THREE.CanvasTexture(canvas); texture.colorSpace = THREE.SRGBColorSpace;
  const mat = new THREE.MeshBasicMaterial({ map: texture, transparent: true, toneMapped: false });
  const bb = new THREE.Mesh(new THREE.PlaneGeometry(1, 1), mat);
  bb.scale.set(H * (cw / ch), H, 1);                            // keep the drawing's aspect
  bb.position.y = H / 2;                                        // feet at the root
  const root = new THREE.Group(); root.add(bb);

  const sh = new THREE.Mesh(new THREE.CircleGeometry(0.5, 24),
    new THREE.MeshBasicMaterial({ color: '#181420', transparent: true, opacity: 0.3, depthWrite: false }));
  sh.rotation.x = -Math.PI / 2; sh.position.y = 0.004; sh.scale.set(H * 0.52, H * 0.3, 1); root.add(sh);

  const P = { walk: 0, phase: 0, headYaw: 0, headTilt: 0, blinkT: null, wave: 0, waveT: 0, armsUp: 0, bounce: 0, smile: 1, flip: 0, breath: 0 };

  function draw() {
    g.clearRect(0, 0, cw, ch);
    g.save();
    if (P.flip) { g.translate(cw, 0); g.scale(-1, 1); }
    const breathe = Math.sin(P.breath * TAU) * 0.004;
    const hop = -P.bounce * ch;
    const [footY] = S(0, 0.965);
    const hipY = ch * (0.55 + breathe) + hop, shY = ch * (0.32 + breathe) + hop;
    const hipX = cw * 0.5, headR = ch * 0.108, headX = cw * 0.5;
    const swing = Math.sin(P.phase * TAU), swing2 = Math.sin(P.phase * TAU * 2);
    const o2 = { shade: null, ink: null, lw, sun, size: ch };

    // legs (back leg first)
    const legR = (side) => {
      const hx = hipX + side * cw * 0.045, kx = hx + side * swing * cw * 0.05,
        footX = hx + side * swing * cw * 0.09, lift = Math.max(0, side * swing) * ch * 0.05 * (P.walk > 0 ? 1 : 0);
      const kY = lerp(hipY, footY, 0.55), fY = footY - lift;
      part(g, () => limbPath(g, hx, hipY, kx, kY, cw * 0.032, cw * 0.026), pants, { ...o2, shade: pantsSh });
      part(g, () => limbPath(g, kx, kY, footX, fY, cw * 0.026, cw * 0.022), pants, { ...o2, shade: pantsSh });
      // shoe
      part(g, () => { g.beginPath(); g.ellipse(footX + cw * 0.012, fY, cw * 0.05, cw * 0.028, 0, 0, TAU); }, shoe, o2);
    };
    legR(-1);

    // arms (back arm)
    const armR = (side) => {
      const sx = hipX + side * cw * 0.1, elx = sx + side * (cw * 0.03 + swing * cw * 0.04),
        hax = elx + side * cw * 0.01, elY = lerp(shY, hipY, 0.5) - P.armsUp * ch * 0.05;
      const haY = lerp(elY, hipY, 0.5) - P.armsUp * ch * 0.12;
      const waveA = side < 0 ? P.wave : 0;
      const wx = hax + side * cw * 0.02, wy = haY - waveA * ch * 0.22 + (waveA ? Math.sin(P.waveT * 14) * ch * 0.03 * waveA : 0);
      part(g, () => limbPath(g, sx, shY, elx, elY, cw * 0.03, cw * 0.026), shirt, { ...o2, shade: shirtSh });
      part(g, () => limbPath(g, elx, elY, wx, wy, cw * 0.026, cw * 0.024), skin, { ...o2, shade: skinSh });
      part(g, () => { g.beginPath(); g.arc(wx, wy, cw * 0.036, 0, TAU); }, skin, { ...o2, shade: skinSh }); // mitten
    };
    armR(-1);

    // torso
    part(g, () => { const w = cw * 0.135;
      g.beginPath(); g.moveTo(hipX - w, hipY);
      g.quadraticCurveTo(headX, shY - ch * 0.02, hipX + w, hipY);
      g.quadraticCurveTo(headX, hipY + ch * 0.01, hipX - w, hipY); g.closePath(); }, shirt, { ...o2, shade: shirtSh });

    // near leg + arm
    legR(1);
    armR(1);

    // head
    const hcX = headX + Math.sin(P.headYaw) * cw * 0.02, hcY = shY - headR * 1.05 + Math.cos(P.headTilt) * 0;
    g.save(); g.translate(hcX, hcY); g.rotate(P.headTilt);
    part(g, () => { g.beginPath(); g.arc(0, 0, headR, 0, TAU); }, skin, { ...o2, shade: skinSh });
    part(g, () => { g.beginPath(); g.arc(0, -headR * 0.12, headR * 1.02, Math.PI * 1.05, Math.PI * 1.95); g.closePath(); }, hair, { ...o2, shade: hairSh });
    // eyes
    const blink = P.blinkT === null ? 1 : (Math.abs(((P.blinkT % 3.7) + 3.7) % 3.7 - 0.1) < 0.07 ? 0.12 : 1);
    const ex = headR * 0.42, ey = headR * 0.06, so = Math.sin(P.headYaw) * headR * 0.18;
    for (const s of [-1, 1]) {
      g.save(); g.translate(s * ex + so, ey); g.scale(1, blink);
      g.fillStyle = '#fffaf2'; g.beginPath(); g.arc(0, 0, headR * 0.17, 0, TAU); g.fill();
      g.beginPath(); g.arc(0, headR * 0.02, headR * 0.085, 0, TAU); g.fillStyle = ink; g.fill();
      g.restore();
    }
    // smiling mouth
    g.beginPath(); g.arc(so, headR * 0.34, headR * 0.26, Math.PI * 0.15, Math.PI * 0.85);
    g.lineWidth = lw * 1.2; g.strokeStyle = ink; g.lineCap = 'round'; g.stroke();
    g.restore();

    g.restore();
  }

  // face the camera around Y only, so the drawing stays upright on the ground; redraw and re-upload the texture
  bb.onBeforeRender = (renderer, scene, camera) => {
    const dx = camera.position.x - root.position.x, dz = camera.position.z - root.position.z;
    bb.rotation.y = Math.atan2(dx, dz);
    draw(); texture.needsUpdate = true;
  };

  const c = { root, mesh: bb, shadow: sh, texture };
  c.pose = (p = {}) => { Object.assign(P, p); return c; };
  return c;
}
