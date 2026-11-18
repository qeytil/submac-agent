// Example: a hand-drawn kid in a modelled meadow (10 s). Replace all of this for a new video.
// The 3D world runs on global time t (so cuts stay continuous); cameras run on shot-local time.
// The kid is 2D (kit2d): a drawing on a camera-facing plane with a ground shadow, standing among 3D trees and rocks.
import { THREE, toon, mesh, sunlight, skyGradient, scatter, tree, rock, cloud, grass,
  keys, seg, ease, lerp, wobble, title } from './kit.js';
import { make2DCharacter } from './kit2d.js';

export function buildStory(stage, B) {
  const cue = B.cues;

  // ------------------------------------------------ set: the meadow (3D)
  const scene = new THREE.Scene();
  skyGradient(scene, [[0, '#7fb6e8'], [0.55, '#cfe6f2'], [1, '#f6e7c8']]);
  scene.fog = new THREE.Fog('#e9eadb', 18, 55);
  sunlight(scene, { sun: '#fff0d2', sky: '#cfe3ff', ground: '#7d9a52', intensity: 2.8, ambient: 1.3, dir: [-6, 9, 6], area: 12 });
  const ground = mesh(new THREE.CircleGeometry(60, 64), toon('#8cc263', 3), { rot: [-Math.PI / 2, 0, 0] });
  scene.add(ground);
  const path = mesh(new THREE.PlaneGeometry(16, 1.3), toon('#e2c98f', 3), { pos: [0, 0.005, 0], rot: [-Math.PI / 2, 0, 0] });
  scene.add(path);
  scene.add(scatter(3, 22, r => tree(r), [-24, 24], [-24, -6]));
  scene.add(scatter(9, 12, r => rock(r, { size: lerp(0.15, 0.4, r()) }), [-9, 9], [-4, 5], (x, z) => Math.abs(z) < 1.4));
  scene.add(scatter(6, 8, r => tree(r, { h: 1.6 }), [-24, 24], [7, 15], (x) => Math.abs(x) < 7));
  const blades = grass(4, 4500, [-12, 12], [-6, 6]); scene.add(blades);
  const clouds = scatter(8, 6, r => cloud(r, { scale: lerp(1, 1.8, r()) }), [-30, 30], [-40, -30]);
  clouds.position.y = 12; scene.add(clouds);

  // cast: one factory per character or key object, used by the film AND the design sheet.
  const cast = {
    // A 2D character: drawn each frame, on a camera-facing plane; sun matches the scene light (from the left).
    kid: () => make2DCharacter({ shirt: '#e4572e', pants: '#35508a', hair: '#5a3825', skin: '#f0c19a', height: 1.15, sun: [-0.5, -0.95] }),
    ball: () => mesh(new THREE.SphereGeometry(0.09, 20, 16), toon('#ffd23f', 3)),
  };
  const kid = cast.kid(), ball = cast.ball();
  scene.add(kid.root, ball);

  // ------------------------------------------------ the world over global time
  const walkEnd = cue['throw'] - 0.8;
  const kidX = t => keys(t, [[cue['walk-start'], -5], [walkEnd, -0.4, 'out']]);
  const throwT = cue['throw'], landT = cue['ball-lands'];
  const landAt = [4.4, 0, -0.9];
  function world(t) {
    blades.sway(t);
    clouds.position.x = t * 0.25;
    const x = kidX(t);
    kid.root.position.set(x, 0, 0.1);
    kid.pose({
      walk: (t < walkEnd ? 1 : 0) * (1 - seg(t, walkEnd - 0.4, walkEnd)), phase: (x + 5) / 0.9, blinkT: t / 1.4,
      headYaw: lerp(0, 0.4, seg(t, throwT, landT)),
      armsUp: seg(t, throwT - 0.5, throwT) * (1 - seg(t, throwT + 0.25, throwT + 0.8)),
      wave: Math.max(seg(t, throwT - 0.5, throwT) * (1 - seg(t, throwT + 0.25, throwT + 0.8)), seg(t, cue['wave'], cue['wave'] + 0.4)), waveT: t,
      bounce: 0.05 * ease.arc(seg(t, throwT - 0.1, throwT + 0.3)), breath: t * 0.3,
    });
    // the ball is a 3D prop, so it can arc out of the drawn hand and land in the world
    if (t < throwT) ball.position.set(x + 0.18, 0.72, 0.3);
    else if (t < landT) {
      const p = seg(t, throwT, landT);
      ball.position.set(lerp(x + 0.18, landAt[0], p), lerp(0.72, 0.09, p) + Math.sin(Math.PI * p) * 1.8, lerp(0.3, landAt[2], p));
    } else {
      const p = seg(t, landT, cue['roll-end']);
      ball.position.set(landAt[0] + ease.out(p) * 1.1, 0.09 + Math.abs(Math.sin(p * 9)) * 0.4 * Math.pow(1 - p, 2), landAt[2] + p * 0.2);
    }
  }
  const sets = { meadow: { scene, update: t => world(t) } };

  // ------------------------------------------------ shots (camera on local time)
  const handheld = (l, a = 0.03) => [wobble(l * 0.7, 1) * a, wobble(l * 0.6, 2) * a, 0];
  const shots = [
    { set: 'meadow', dur: 4, cam: (l, p) => { const h = handheld(l);
      return { pos: [lerp(-1.5, -0.2, ease.io(p)) + h[0], 1.4 + h[1], lerp(8.5, 6.5, ease.io(p))], look: [lerp(-2.5, 0.6, p), 0.7, 0], fov: 33 }; } },
    { set: 'meadow', dur: 3, in: { type: 'dissolve', dur: 0.5 }, cam: (l, p) => { const h = handheld(l, 0.02);
      return { pos: [-1.8 + h[0], 1.0 + h[1], 4.2], look: [lerp(-0.8, 2.6, ease.io(p)), lerp(0.9, 1.0, p), -0.3], fov: 38 }; } },
    { set: 'meadow', dur: 3, in: { type: 'whip', dur: 0.3, dir: 1 }, cam: (l, p) => { const h = handheld(l, 0.02);
      return { pos: [lerp(6.4, 6.1, p) + h[0], 0.7 + h[1], lerp(1.6, 1.4, p)], look: [5.0, 0.3, -0.8], fov: 34 }; } },
  ];

  function overlay(g, t) {
    title(g, t, 'The Walk', { at: cue['title'], dur: 2.4, y: 0.18, size: 170 });
  }
  const design = [
    { name: 'The kid', note: 'Hand-drawn 2D character in the 3D meadow. Red tee, denim, brown hair.', make: () => { const c = cast.kid(); c.pose({ phase: 0.15, headYaw: 0.15 }); return c.root; }, zoom: 0.9 },
    { name: 'The ball', note: '3D prop the kid throws.', make: () => cast.ball(), float: true, zoom: 0.6 },
  ];
  return { sets, shots, overlay, design, designTitle: B.title + ': cast', finish: { grain: 0.06, vignette: 0.35, fadeIn: 0.5, fadeOut: 0.8 } };
}
