import { headAt, canById, canPosition } from "./model.mjs";

export function projector(P) {
  const a = (P.azimuth * Math.PI) / 180;
  const e = (P.elevation * Math.PI) / 180;
  const sinA = Math.sin(a);
  const cosA = Math.cos(a);
  const sinE = Math.sin(e);
  const cosE = Math.cos(e);
  const k = P.scale * Math.sqrt(1.6);
  const iso = ([x, y, z]) => [P.origin[0] + (x * sinA - y * cosA) * k, P.origin[1] + ((x * cosA + y * sinA) * sinE - z * cosE) * k];
  const along = ([x, y, z]) => [(x * sinA - y * cosA) * k, ((x * cosA + y * sinA) * sinE - z * cosE) * k];
  const depth = ([x, y, z]) => (x * cosA + y * sinA) * cosE + z * sinE;
  return { iso, along, depth };
}

export function screenBox(box, iso) {
  if (!box) return null;
  let x0 = Infinity;
  let y0 = Infinity;
  let x1 = -Infinity;
  let y1 = -Infinity;
  for (let i = 0; i < 8; i++) {
    const [sx, sy] = iso([box[i & 1 ? 3 : 0], box[i & 2 ? 4 : 1], box[i & 4 ? 5 : 2]]);
    if (sx < x0) x0 = sx;
    if (sx > x1) x1 = sx;
    if (sy < y0) y0 = sy;
    if (sy > y1) y1 = sy;
  }
  return [x0, y0, x1, y1];
}

const EPS = 0.05;
const MARGIN = 0.3;
export const overlaps = (a, b) => !!a && !!b && a[0] < b[2] - MARGIN && b[0] < a[2] - MARGIN && a[1] < b[3] - MARGIN && b[1] < a[3] - MARGIN;

export function rel(a, b) {
  let behind = false;
  let front = false;
  for (let i = 0; i < 3; i++) {
    if (a[i + 3] <= b[i] + EPS) behind = true;
    if (b[i + 3] <= a[i] + EPS) front = true;
  }
  if (behind === front) return 0;
  return behind ? -1 : 1;
}

export function orderScene(statics, edges, movers, depth) {
  const n = statics.length;
  const total = n + movers.length;
  const next = Array.from({ length: total }, () => []);
  const indeg = new Int32Array(total);
  const key = new Float64Array(total);
  const link = (a, b) => {
    next[a].push(b);
    indeg[b]++;
  };
  for (let i = 0; i < n; i++) key[i] = i;
  for (const [a, b] of edges) link(a, b);
  movers.forEach((m, index) => {
    const id = n + index;
    let lo = -1;
    for (let i = 0; i < n; i++) {
      const s = statics[i];
      if (!s.box || !overlaps(m.screen, s.screen)) continue;
      const r = rel(s.box, m.box);
      if (r < 0) {
        link(i, id);
        if (i > lo) lo = i;
      } else if (r > 0) link(id, i);
    }
    key[id] = lo + 0.5 + depth(m) * 1e-6;
  });
  for (let a = 0; a < movers.length; a++)
    for (let b = 0; b < movers.length; b++)
      if (a !== b && overlaps(movers[a].screen, movers[b].screen) && rel(movers[a].box, movers[b].box) < 0) link(n + a, n + b);
  const done = new Uint8Array(total);
  const order = [];
  for (let step = 0; step < total; step++) {
    let best = -1;
    for (let i = 0; i < total; i++) if (!done[i] && indeg[i] === 0 && (best < 0 || key[i] < key[best])) best = i;
    if (best < 0) break;
    done[best] = 1;
    order.push(best);
    for (const j of next[best]) indeg[j]--;
  }
  const conflicts = total - order.length;
  if (conflicts) for (const i of [...key.keys()].filter((i) => !done[i]).sort((a, b) => key[a] - key[b])) order.push(i);
  return { order, conflicts };
}

export function moverBoxes(world, L) {
  const h = headAt(world);
  const bx = h.x - L.arm;
  const C = L.carriage;
  const B = L.beam;
  const Hd = L.head;
  const held = world.held && canById(world, world.held);
  const r = L.can.r;
  const cans = world.cans.map((can) => {
    if (can.place.at === "held" || can.place.at === "tube") return null;
    const [x, y, z] = canPosition(world, can);
    if (can.place.at === "lift" && z >= L.mouth - 0.01) return null;
    return [x - r, y - r, z, x + r, y + r, can.place.at === "lift" ? Math.min(z + L.can.h, L.mouth) : z + L.can.h];
  });
  return {
    bx,
    head: h,
    carriage: [bx - C.half, C.y0, C.z0, bx + C.half, C.y1, C.z1],
    beam: [bx - B.half, B.y0, B.z0, bx + B.half, B.y1 + 2.4, B.z1 + 0.6],
    headBlock: [bx + Hd.x0, h.y - Hd.half, Hd.gland, bx + Hd.x1, h.y + Hd.half, Hd.top],
    column: [h.x - r, h.y - r, h.pad - (held ? L.can.h : 0), h.x + r, h.y + r, Hd.gland],
    cans,
  };
}
