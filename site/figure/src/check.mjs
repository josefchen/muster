import * as M from "./model.mjs";
import { projector, screenBox, orderScene, moverBoxes } from "./order.mjs";
import { DATA, R, P } from "./build.mjs";
import * as A from "./kit/audit.mjs";

const RAYCAST = process.argv.includes("--raycast");
const ray = { samples: 0, pairs: 0, wrong: [], cycles: 0 };
function moverShapes(world, b) {
  const h = b.head;
  const C = L.carriage;
  const B = L.beam;
  const Hd = L.head;
  const slab = (x0, y0, z0, x1, y1, z1, name) => A.slab({ x: x0, y: y0, w: x1 - x0, d: y1 - y0, r: 0.5 }, z0, z1 - z0, { name }, 2);
  const out = {
    carriage: [slab(b.bx - C.half, C.y0, C.z0, b.bx + C.half, C.y1, C.z1, "carriage")],
    beam: [slab(b.bx - B.half, B.y0, B.z0, b.bx + B.half, B.y1, B.z1, "beam")],
    head: [slab(b.bx + Hd.x0, h.y - Hd.half, Hd.z0, b.bx + Hd.x1, h.y + Hd.half, Hd.z1, "head"), A.cylinder(h.x, h.y, 3.2, Hd.gland, Hd.z0 - Hd.gland, { name: "gland" }), A.cylinder(h.x, h.y, 4.4, Hd.z1, 3.4, { name: "cap" })],
    column: [A.cylinder(h.x, h.y, 4.6, h.pad, 2.4, { name: "pad" }), A.cylinder(h.x, h.y, 1.4, h.pad + 2.4, Math.max(0.1, Hd.gland - h.pad - 2.4), { name: "rod" })],
  };
  if (world.held) out.column.push(A.cylinder(h.x, h.y, L.can.r, h.pad - L.can.h, L.can.h, { name: "held" }));
  b.cans.forEach((box, i) => {
    if (box) out[`can.${world.cans[i].id}`] = [A.cylinder((box[0] + box[3]) / 2, (box[1] + box[4]) / 2, L.can.r, box[2], box[5] - box[2], { name: world.cans[i].id })];
  });
  return out;
}
function raycast(world, b, movers, order) {
  const shapes = moverShapes(world, b);
  const n = R.items.length;
  const near = (sb) => movers.some((m) => m.screen[0] < sb[2] && sb[0] < m.screen[2] && m.screen[1] < sb[3] && sb[1] < m.screen[3]);
  const items = [];
  const rank = [];
  R.items.forEach((item, i) => {
    if (statics[i].screen && near(statics[i].screen)) {
      items.push(item);
      rank.push(order.indexOf(i));
    }
  });
  movers.forEach((m, i) => {
    items.push({ name: m.name, shapes: shapes[m.name], key: 0 });
    rank.push(order.indexOf(n + i));
  });
  const { pairs, least } = A.overlapsOf(items, P, { states: [0] });
  ray.samples++;
  for (const pair of pairs) {
    const ia = pair.a;
    const ib = pair.b;
    if (ia < items.length - movers.length && ib < items.length - movers.length) continue;
    const aFront = pair.front[0].area >= least;
    const bFront = pair.front[1].area >= least;
    ray.pairs++;
    if (aFront && bFront) {
      ray.cycles++;
      continue;
    }
    const wrong = aFront ? rank[ia] < rank[ib] : rank[ib] < rank[ia];
    if (wrong && ray.wrong.length < 12) ray.wrong.push(`${items[aFront ? ia : ib].name} should be over ${items[aFront ? ib : ia].name}  (${Math.max(pair.front[0].area, pair.front[1].area).toFixed(1)} px²)`);
    else if (wrong) ray.wrong.push("…");
  }
}

const { L } = M;
const { iso, depth } = projector(DATA.P);
const statics = DATA.boxes.map((box) => ({ box, screen: screenBox(box, iso) }));
const names = DATA.names;
const world = M.createWorld();
const dt = 1 / 60;
const stats = { frames: 0, conflicts: 0, collisions: new Map(), conflictFrames: [] };
const inter = (a, b, tol = 0.05) => a[0] < b[3] - tol && b[0] < a[3] - tol && a[1] < b[4] - tol && b[1] < a[4] - tol && a[2] < b[5] - tol && b[2] < a[5] - tol;
const centre = (m) => depth([(m.box[0] + m.box[3]) / 2, (m.box[1] + m.box[4]) / 2, (m.box[2] + m.box[5]) / 2]);

const script = [];
for (let t = 4; t < 120; t += 7.3) script.push({ t, act: Math.random() < 0.5 ? "tab" : "allow" });
let touring = true;
let selected = null;
let resumeAt = 0;
for (let frame = 0, t = 0; t < 140; frame++, t += dt) {
  const due = script.find((s) => !s.done && s.t <= t);
  if (due) {
    due.done = true;
    touring = false;
    M.interrupt(world);
    resumeAt = t + 3.6;
    if (due.act === "tab") {
      const list = M.slotsInUrgency(world);
      const index = selected ? list.findIndex((c) => c.id === selected) : -1;
      const next = list[(index + 1) % list.length];
      if (next) {
        selected = next.id;
        M.enqueue(world, M.select(world, next));
      }
    } else {
      const waiting = M.waitingOf(world)[0];
      if (waiting && !M.allowPending(world)) M.enqueue(world, [{ k: "then", allow: true, make: (w) => M.allow(w, waiting.id) }]);
    }
  }
  if (!touring && t > resumeAt) touring = true;
  if (touring && !M.busy(world)) M.enqueue(world, M.tourNext(world));
  M.step(world, dt);
  const b = moverBoxes(world, L);
  const movers = [
    { name: "carriage", box: b.carriage },
    { name: "beam", box: b.beam },
    { name: "head", box: b.headBlock },
    { name: "column", box: b.column },
    ...b.cans.map((box, i) => ({ name: `can.${world.cans[i].id}`, box })),
  ].filter((m) => m.box);
  for (const m of movers) m.screen = screenBox(m.box, iso);
  const { conflicts, order } = orderScene(statics, DATA.edges, movers, centre);
  const planted = process.argv.includes("--control") ? [...order.filter((id) => id >= statics.length), ...order.filter((id) => id < statics.length)] : order;
  if (RAYCAST && frame % (process.argv.includes("--control") ? 400 : 45) === 0) raycast(world, b, movers, planted);
  stats.frames++;
  if (conflicts) {
    stats.conflicts++;
    if (stats.conflictFrames.length < 6) stats.conflictFrames.push(t.toFixed(2));
  }
  for (const m of movers)
    statics.forEach((s, i) => {
      if (s.box && inter(m.box, s.box)) {
        const key = `${m.name} × ${names[i]}`;
        stats.collisions.set(key, (stats.collisions.get(key) ?? 0) + 1);
      }
    });
  for (let i = 0; i < movers.length; i++)
    for (let j = i + 1; j < movers.length; j++)
      if (inter(movers[i].box, movers[j].box)) {
        const key = `${movers[i].name} × ${movers[j].name}`;
        stats.collisions.set(key, (stats.collisions.get(key) ?? 0) + 1);
      }
}
console.log(`motion check · ${stats.frames} frames (${(stats.frames * dt).toFixed(0)} s of tour and input)`);
console.log(`order conflicts: ${stats.conflicts} frames${stats.conflictFrames.length ? " (first at " + stats.conflictFrames.join(", ") + " s)" : ""}`);
console.log(`intersections: ${stats.collisions.size} pairs`);
for (const [key, n] of stats.collisions) console.log(`  ${key}  ${n} frames`);
if (RAYCAST) {
  console.log(`ray-cast depth order: ${ray.samples} sampled frames · ${ray.pairs} mover pairs · ${ray.wrong.length} drawn the wrong way · ${ray.cycles} interlocked`);
  for (const line of ray.wrong) console.log("  " + line);
}
process.exitCode = stats.conflicts || stats.collisions.size || ray.wrong.length || ray.cycles ? 1 : 0;
