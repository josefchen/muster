import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { gzipSync } from "node:zlib";
import * as k from "./kit/iso-kit.mjs";
import * as G from "./kit/lathe.mjs";
import { tubePieces, tubeSvg } from "./kit/tube.mjs";
import * as A from "./kit/audit.mjs";
import * as M from "./model.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const OUT = join(HERE, "..");
const { L } = M;

const W = 600;
const H = 470;
const AZIMUTH = 52;
const ELEVATION = 40;

const DESK = { x: -150, y: -132, w: 200, d: 214, r: 10 };
const DESK_H = 12;
const FOOT_H = 6;
const RUN_Z = 150;
const RISER_Y = -108;
const TUBE_R = 6;
const ELBOW_R = 8.6;
const SINK = Math.sqrt(ELBOW_R ** 2 - TUBE_R ** 2);
const HOOK = { x: -122, y: -128, w: 136, d: 38, r: 3 };
const HOOK_H = 32;
const RX = { flange: [120, 122, 9.2], body: [107, 120, 8.4], band: [L.mouth, 107, 8.8] };
const GANTRY_X = [-130, 28];
const RAIL = { x: -136, w: 170, y: -91, d: 8, z: 72, h: 6 };
const STEPS = [
  { row: "needs", plan: { x: -110, y: -5, w: 100, d: 27, r: 1.5 }, h: 6 },
  { row: "working", plan: { x: -110, y: -31, w: 100, d: 26, r: 1.5 }, h: 14 },
  { row: "done", plan: { x: -110, y: -57, w: 100, d: 26, r: 1.5 }, h: 22 },
];
const SEAT_R = 7.2;
const SEAT_H = 1.5;
const CONSOLE = { x: -64, y: 44, w: 92, d: 32, r: 4 };
const KEYS = [
  { name: "tab", plan: { x: -58, y: 52, w: 18, d: 14, r: 1.6 } },
  { name: "opt", plan: { x: -37, y: 52, w: 14, d: 14, r: 1.6 } },
  { name: "enter", plan: { x: -20, y: 52, w: 22, d: 14, r: 1.6 } },
];
const KEY_Z = 4;
const KEY_H = 4.6;
const KEY_TRAVEL = 1.8;
const BAND = { claude: "#ee8c33", codex: "#4585fa", cursor: "#9e66fa" };

const P = k.fitProjection(
  [...k.boxCorners(DESK, -DESK_H - FOOT_H, 0), ...L.tubes.flatMap((x) => [[x, RISER_Y, RUN_Z + ELBOW_R], [x, L.cupY, RUN_Z + ELBOW_R]]), [GANTRY_X[1] + 6, RAIL.y, 92]],
  W,
  H,
  { pad: 30, azimuth: AZIMUTH, elevation: ELEVATION },
);
const KS = G.scaleOf(P);
const at = (p) => k.iso(p, P);
const S = (paths, style) => k.solidSvg(paths, style);
const Ln = (d, style) => k.lineSvg(d, style);
const Dots = (points, style) => k.dotsSvg(points, style);
const path3 = (points, closed = false) => k.pathOf(points.map(at), closed);
const stepsFor = (r) => Math.max(14, Math.min(40, Math.round(r * 2.4)));
const round2 = (v) => Math.round(v * 100) / 100;

const R = A.recorder(P);
function put(name, ref, svg, shapes = [], { bias = 0, ...rest } = {}) {
  return R.put({ name, at: ref, bias, svg, shapes, piece: "desk", ...rest });
}
function box(name, plan, z, h, style = {}, { steps = 3, bevel = 0, extra = "", inner = "", bias = 0, attrs } = {}) {
  const shape = R.solid(A.slab(plan, z, h, { name }, steps));
  put(name, [plan.x + plan.w / 2, plan.y + plan.d / 2, z + h / 2], S(k.slabOf(plan, z, h, P, steps, bevel), { tone: "mid", ...style, inner }) + extra, [shape], { bias, attrs });
  return shape;
}
function cyl(name, cx, cy, r, z, h, style = {}, { bevel = 0, extra = "", inner = "", bias = 0, attrs, wrap } = {}) {
  const shape = R.solid(A.cylinder(cx, cy, r, z, h, { name }));
  const solid = S(k.cylinder(cx, cy, r, z, h, P, stepsFor(r), bevel), { tone: "mid", ...style, inner });
  put(name, [cx, cy, z + h / 2], (wrap ? wrap(solid) : solid) + extra, [shape], { bias, attrs });
  return shape;
}
function ball(name, c, r, style = {}) {
  const shape = R.solid(A.ball(c, r, { name }));
  put(name, c, S(G.sphereOf(c, r, P, { steps: 40 }), { tone: "mid", ...style }), [shape]);
  return shape;
}
function pipe(name, a, b, r, { touch, gaps = [] } = {}) {
  R.route(name, [a, b], r, { touch, gaps, piece: "desk" });
  tubePieces([a, b], r, P, { maxLength: 28, gaps }).forEach((piece, index) =>
    put(`${name}:${index}`, piece.mid, tubeSvg(piece, { tone: "mid" }), [A.tube(piece.points, piece.radii)], { route: name, chunk: index }),
  );
}
function cable(name, points, r, { bend = 6, touch = ["stand.desk"], bundle = "desk" } = {}) {
  const route = G.fillet(points, Math.max(bend, r * 2.6), 10, { P, tube: r });
  const total = G.pathLength(route);
  const SHELL = 3.2;
  const gaps = [[0, SHELL], [total - SHELL, total]];
  R.route(name, route, r, { gaps, limp: true, touch, bundle, rims: [r * 1.9, r * 1.9], piece: "desk" });
  tubePieces(route, r, P, { maxLength: 40, spacing: 1.2, gaps }).forEach((piece, index) =>
    put(`${name}:${index}`, piece.mid, tubeSvg(piece, { tone: "lo" }), [A.tube(piece.points, piece.radii)], { route: name, chunk: index }),
  );
  [0, 1].forEach((index) => {
    const end = index ? route[route.length - 1] : route[0];
    const tangent = G.tangentAlong(route, index ? total : 0);
    const F = G.frameAlong(end, tangent);
    const [s0, s1] = index ? [-SHELL, 0] : [0, SHELL];
    const shape = R.solid(A.disc(F, s0, s1, r * 1.9, { name: `${name}.shell${index}`, owner: name }));
    put(`${name}.shell${index}`, G.add3(end, G.mul3(tangent, (s0 + s1) / 2)), S(G.disc(s0, s1, r * 1.9, F, P, { steps: 18, bevel: 0.2 }), { tone: "mid" }), [shape], { bias: 0.1 });
  });
}

const faceOf = (y) => k.sideMatrix([0, y], 0, P, "left");
const sideOf = (x) => k.sideMatrix([x, 0], 0, P, "right");
const flatRect = (u0, z0, u1, z1, r = 0.6, steps = 3) => k.pathOf(k.roundedPlan({ x: u0, y: z0, w: u1 - u0, d: z1 - z0, r }, steps).map(([u, z]) => [u, -z]), true);
const ringDots = (cx, cy, r, z, count, phase = 0) => Array.from({ length: count }, (_, i) => at([cx + r * Math.cos(phase + (i / count) * Math.PI * 2), cy + r * Math.sin(phase + (i / count) * Math.PI * 2), z]));
const byDepth = (points) => [...points].sort((a, b) => k.depthOf([a[0], a[1], 0], P) - k.depthOf([b[0], b[1], 0], P));

const back = [];
function desk() {
  R.solid(A.slab(DESK, -DESK_H, DESK_H, { name: "stand.desk", ground: true }, 8));
  back.push(`<path class="iso-halo" d="${k.haloOf(DESK, -DESK_H - FOOT_H, DESK_H, P)}"/>`);
  for (const [x, y] of byDepth(k.corners(DESK, 24))) {
    back.push(S(k.cylinder(x, y, 8, -DESK_H - FOOT_H, 1.6, P, 32), { tone: "lo" }));
    back.push(S(k.cylinder(x, y, 6.2, -DESK_H - FOOT_H + 1.6, FOOT_H - 1.6, P, 28), { tone: "mid" }));
  }
  const front = DESK.y + DESK.d;
  const side = DESK.x + DESK.w;
  const vents = Array.from({ length: 9 }, (_, i) => flatRect(8 + i * 4.2, -8.6, 9.6 + i * 4.2, -3.4, 0.8)).join("");
  back.push(S(k.slabOf(DESK, -DESK_H, DESK_H, P, 8, 1.6), { tone: "mid", inner: Ln(k.sideSeam(DESK, -3.2, P, 8), { tone: "faint" }) }));
  back.push(`<g transform="${faceOf(front)}">${Ln(vents, { tone: "faint" })}</g>`);
  back.push(`<g transform="${sideOf(side)}">${Ln(flatRect(-40, -9, 60, -5.6, 1.6, 4), { tone: "faint" })}</g>`);
  back.push(Ln(k.planOutline(k.insetPlan(DESK, 5), 0, P), { tone: "lo" }));
  const screws = k.corners(DESK, 11);
  back.push(Ln(screws.map(([x, y]) => k.ring(x, y, 2.3, 0, P, 16)).join(""), { tone: "lo" }));
  back.push(Dots(screws.map(([x, y]) => at([x, y, 0])), { size: 0.55 }));
  const strip = { x: -122, y: 27, w: 116, d: 7, r: 1 };
  back.push(S(k.slabOf(strip, 0, 0.6, P, 3), { tone: "lo", crease: "none" }));
  const ticks = k.topTicks(strip.x + 4, strip.x + strip.w - 4, 6, 5, strip.y + 0.8, 0.6, [2, 3.8], P);
  back.push(Ln(ticks.minor, { tone: "lo" }), Ln(ticks.major, { tone: "mid" }));
  back.push(Dots([at([strip.x + 2, strip.y + 3.5, 0.6]), at([strip.x + strip.w - 2, strip.y + 3.5, 0.6])], { size: 0.45 }));
  const label = { x: -134, y: 50, w: 48, d: 11, r: 1.4 };
  back.push(S(k.slabOf(label, 0, 0.8, P, 3), { tone: "lo", crease: "none" }));
  back.push(Ln(k.planOutline(k.insetPlan(label, 1.6), 0.8, P, 3), { tone: "faint" }));
  back.push(Ln([30, 22, 26].map((w, i) => k.lineOnTop([label.x + 7, label.y + 3.4 + i * 2.2], [label.x + 7 + w, label.y + 3.4 + i * 2.2], 0.8, P)).join(""), { tone: "lo", free: true }));
  back.push(Dots([at([label.x + 3.6, label.y + label.d / 2, 0.8]), at([label.x + label.w - 3.6, label.y + label.d / 2, 0.8])], { size: 0.45 }));
}

function hookBox() {
  const side = HOOK.x + HOOK.w;
  const front = HOOK.y + HOOK.d;
  const slots = Array.from({ length: 6 }, (_, i) => flatRect(-(HOOK.y + 8.4 + i * 3.4), 9, -(HOOK.y + 7 + i * 3.4), 23, 0.7)).join("");
  const inner = Ln(k.sideSeam(HOOK, 6, P, 4), { tone: "faint" });
  const extra = `<g transform="${sideOf(side)}">${Ln(slots, { tone: "faint" })}</g>` + Ln(k.planOutline(k.insetPlan(HOOK, 3), HOOK_H, P, 4), { tone: "faint" }) + Dots(k.corners(HOOK, 6).map(([x, y]) => at([x, y, HOOK_H])), { size: 0.5 });
  box("hook.box", HOOK, 0, HOOK_H, { tone: "mid" }, { steps: 4, bevel: 0.8, inner, extra });
  const plate = { x: -60, y: front, w: 40, d: 0.8, r: 0.3 };
  const text = k.faceTextSvg(k.sideMatrix([-40, front + 0.8], 12.2, P, "left"), "127.0.0.1", { size: 4.4, tone: "mid", anchor: "middle" });
  box("hook.label", plate, 9, 10, { tone: "lo", crease: "none" }, { steps: 2, extra: text + Dots([at([plate.x + 2.4, front + 0.8, 14]), at([plate.x + plate.w - 2.4, front + 0.8, 14])], { size: 0.45 }) });
  L.tubes.forEach((x, i) => {
    cyl(`hook.gland.${M.AGENTS[i]}`, x, RISER_Y, 9.4, HOOK_H, 3.5, {}, { bevel: 0.4, extra: Dots(ringDots(x, RISER_Y, 7.8, HOOK_H + 3.5, 8, 0.4), { size: 0.45 }) });
    cyl(`hook.neck.${M.AGENTS[i]}`, x, RISER_Y, 7.3, HOOK_H + 3.5, 3.5, {}, { inner: Ln(k.sideArc(x, RISER_Y, 7.3, HOOK_H + 5.2, P, 24), { tone: "faint" }) });
  });
  for (const x of [-109, 7]) {
    box(`rear.foot.${x}`, { x: x - 2, y: -100, w: 10, d: 10, r: 1 }, HOOK_H, 1.4, { tone: "lo" }, { extra: Dots([at([x - 0.4, -95, HOOK_H + 1.4]), at([x + 6.4, -95, HOOK_H + 1.4])], { size: 0.4 }) });
    box(`rear.post.${x}`, { x, y: -98, w: 6, d: 6, r: 1 }, HOOK_H + 1.4, 136 - HOOK_H - 1.4, { tone: "mid" }, { inner: Ln(k.sideSeam({ x, y: -98, w: 6, d: 6, r: 1 }, 100, P, 3), { tone: "faint" }) });
  }
  const bar = { x: -113, y: -98, w: 126, d: 6, r: 1 };
  box("rear.crossbar", bar, 136, RUN_Z - TUBE_R - 136, { tone: "mid" }, { bevel: 0.4, extra: Dots([at([-106, -95, RUN_Z - TUBE_R]), at([10, -95, RUN_Z - TUBE_R])], { size: 0.45 }) });
}

function tubes() {
  L.tubes.forEach((x, i) => {
    const agent = M.AGENTS[i];
    const riser0 = HOOK_H + 7;
    const sleeve = [92, 97];
    pipe(`tube.${agent}.riser`, [x, RISER_Y, riser0], [x, RISER_Y, RUN_Z - SINK], TUBE_R, { gaps: [[sleeve[0] - riser0, sleeve[1] - riser0]] });
    const shape = R.solid(A.cylinder(x, RISER_Y, 7.4, sleeve[0], sleeve[1] - sleeve[0], { name: `tube.${agent}.sleeve`, owner: `tube.${agent}.riser` }));
    put(`tube.${agent}.sleeve`, [x, RISER_Y, (sleeve[0] + sleeve[1]) / 2], S(k.cylinder(x, RISER_Y, 7.4, sleeve[0], sleeve[1] - sleeve[0], P, stepsFor(7.4), 0.3), { tone: "mid", inner: Ln(k.sideArc(x, RISER_Y, 7.4, (sleeve[0] + sleeve[1]) / 2, P, 24), { tone: "faint" }) }) + Dots(ringDots(x, RISER_Y, 6.6, sleeve[1], 6, 0.4), { size: 0.38 }), [shape]);
    ball(`tube.${agent}.bend0`, [x, RISER_Y, RUN_Z], ELBOW_R);
    pipe(`tube.${agent}.run`, [x, RISER_Y + SINK, RUN_Z], [x, L.cupY - SINK, RUN_Z], TUBE_R, { touch: ["rear.crossbar"] });
    ball(`tube.${agent}.bend1`, [x, L.cupY, RUN_Z], ELBOW_R);
    pipe(`tube.${agent}.drop`, [x, L.cupY, RUN_Z - SINK], [x, L.cupY, RX.flange[1]], TUBE_R);
    const [f0, f1, fr] = RX.flange;
    cyl(`rx.${agent}.flange`, x, L.cupY, fr, f0, f1 - f0, {}, { bevel: 0.3, extra: Dots(ringDots(x, L.cupY, 7.8, f1, 8, 0.2), { size: 0.42 }) });
    const [b0, b1, br] = RX.body;
    cyl(`rx.${agent}.body`, x, L.cupY, br, b0, b1 - b0, {}, { inner: Ln([b0 + 4, b0 + 8.6].map((z) => k.sideArc(x, L.cupY, br, z, P, 28)).join(""), { tone: "faint" }) });
    const [m0, m1, mr] = RX.band;
    cyl(`rx.${agent}.mouth`, x, L.cupY, mr, m0, m1 - m0, {}, { attrs: ` class="md-band" data-agent="${agent}"` });
  });
}

function gantryStatic() {
  const py = RAIL.y + RAIL.d / 2;
  for (const px of GANTRY_X) {
    box(`gantry.foot.${px}`, { x: px - 7, y: py - 7, w: 14, d: 14, r: 2 }, 0, 2, { tone: "lo" }, { extra: Dots([at([px - 4.6, py + 4.6, 2]), at([px + 4.6, py - 4.6, 2]), at([px + 4.6, py + 4.6, 2])], { size: 0.42 }) });
    const post = { x: px - 4, y: py - 4, w: 8, d: 8, r: 1 };
    box(`gantry.post.${px}`, post, 2, RAIL.z - 2, { tone: "mid" }, { bevel: 0.4, inner: Ln(k.sideSeam(post, 12, P, 3), { tone: "faint" }) });
  }
  const rail = { x: RAIL.x, y: RAIL.y, w: RAIL.w, d: RAIL.d, r: 1 };
  const ticks = k.sideTicks(RAIL.x + 6, RAIL.x + RAIL.w - 6, 4, 5, RAIL.y + RAIL.d, RAIL.z + RAIL.h, [1.6, 3.2], P, "x");
  const extra = Ln(ticks.minor, { tone: "lo" }) + Ln(ticks.major, { tone: "mid" }) + Dots(GANTRY_X.map((px) => at([px, py, RAIL.z + RAIL.h])), { size: 0.5 });
  box("gantry.rail", rail, RAIL.z, RAIL.h, { tone: "mid" }, { bevel: 0.5, extra });
  for (const x of [RAIL.x, RAIL.x + RAIL.w - 3]) box(`gantry.stop.${x}`, { x, y: RAIL.y - 0.5, w: 3, d: RAIL.d + 1, r: 0.6 }, RAIL.z + RAIL.h, 4.4, { tone: "mid" }, { extra: Dots([at([x + 1.5, py, RAIL.z + RAIL.h + 4.4])], { size: 0.4 }) });
}

function rack() {
  for (const { row, plan, h } of STEPS) {
    const front = plan.y + plan.d;
    const visible = row === "needs" ? 0 : STEPS[STEPS.findIndex((s) => s.row === row) - 1].h;
    const z0 = visible + (h - visible) * 0.22;
    const z1 = visible + (h - visible) * 0.78;
    const holder = `<g transform="${faceOf(front)}">${Ln(flatRect(-106, z0, -97, z1, 0.6), { tone: "lo" })}</g>` + Dots([at([-108.2, front, (z0 + z1) / 2]), at([-94.8, front, (z0 + z1) / 2])], { size: 0.38 });
    const screws = Dots([at([plan.x + 3.2, plan.y + plan.d / 2, h]), at([plan.x + plan.w - 3.2, plan.y + plan.d / 2, h])], { size: 0.45 });
    box(`rack.step.${row}`, plan, 0, h, { tone: "mid" }, { bevel: 0.6, extra: holder + screws });
    for (const [x0, name] of [[plan.x - 4, "l"], [plan.x + plan.w, "r"]]) {
      const cheek = { x: x0, y: plan.y, w: 4, d: plan.d, r: 0.8 };
      box(`rack.cheek.${name}.${row}`, cheek, 0, h + 2, { tone: "mid" }, { bevel: 0.3, extra: Dots([at([x0 + 2, plan.y + 4, h + 2]), at([x0 + 2, plan.y + plan.d - 4, h + 2])], { size: 0.4 }) });
    }
    L.cols.forEach((x, col) => {
      const y = L.rows[row].y;
      cyl(`seat.${row}.${col}`, x, y, SEAT_R, h, SEAT_H, { tone: "lo" }, { extra: Ln(k.ring(x, y, L.can.r + 0.3, h + SEAT_H, P, 32), { tone: "faint" }) });
    });
  }
  L.tubes.forEach((x, i) => {
    cyl(`cup.base.${M.AGENTS[i]}`, x, L.cupY, 9.2, 0, 4, { tone: "lo" }, { bevel: 0.3, extra: Dots(ringDots(x, L.cupY, 8.3, 4, 6, 0.5), { size: 0.4 }) });
    cyl(`cup.seat.${M.AGENTS[i]}`, x, L.cupY, SEAT_R, 4, L.cupSeat - 4, { tone: "mid" }, { extra: Ln(k.ring(x, L.cupY, L.can.r + 0.3, L.cupSeat, P, 32), { tone: "faint" }) });
  });
}

function consolePlate() {
  const extra = Ln(k.planOutline(k.insetPlan(CONSOLE, 3), 4, P, 4), { tone: "faint" }) + Dots(k.corners(CONSOLE, 5.4).map(([x, y]) => at([x, y, 4])), { size: 0.5 });
  box("console.plate", CONSOLE, 0, KEY_Z, { tone: "mid" }, { steps: 6, bevel: 0.6, extra });
  for (const { name, plan } of KEYS) {
    const dish = Ln(k.planOutline(k.insetPlan(plan, 1.9), KEY_Z + KEY_H, P, 3), { tone: "faint" });
    box(`key.${name}`, plan, KEY_Z, KEY_H, { tone: "mid" }, { bevel: 0.4, extra: dish, attrs: ` data-key="${name}"` });
  }
}

const BELL = [15, 60];
function bell() {
  const [x, y] = BELL;
  const base = KEY_Z + 3.4;
  cyl("bell.base", x, y, 8.6, KEY_Z, base - KEY_Z, { tone: "mid" }, { bevel: 0.4, extra: Dots(ringDots(x, y, 7.8, base, 10, 0.3), { size: 0.4 }) });
  const R0 = 7.2;
  const HT = 6.4;
  const radius = (t) => R0 * Math.sqrt(Math.max(0, 1 - (t / HT) ** 2));
  const slope = (t) => (t >= HT ? -1e3 : (-R0 * t) / (HT * HT * Math.sqrt(Math.max(1e-6, 1 - (t / HT) ** 2))));
  const tip = HT * Math.sqrt(1 - (0.8 / R0) ** 2);
  const profile = Array.from({ length: 13 }, (_, i) => {
    const t = (i / 12) * tip;
    return i === 0 || i === 12 ? [t, radius(t)] : [t, radius(t), 1];
  });
  const F = G.frameOf([x, y, base], [0, 0, 1], [1, 0, 0], [0, 1, 0]);
  const shape = R.solid(A.solid(F, profile, { name: "bell.dome", radius }));
  put("bell.dome", [x, y, base + HT / 2], S(G.solidOf(profile, F, P, { smooth: { slope, radius }, rows: 5 }), { tone: "mid" }), [shape]);
  const stem0 = base + tip;
  const stem = R.solid(A.cylinder(x, y, 0.8, stem0, 2.8, { name: "bell.stem" }));
  const knob = R.solid(A.cylinder(x, y, 2.2, stem0 + 2.8, 1.4, { name: "bell.knob" }));
  put("bell.plunger", [x, y, stem0 + 2], S(k.cylinder(x, y, 0.8, stem0, 2.8, P, 12), { tone: "mid", crease: "none" }) + S(k.cylinder(x, y, 2.2, stem0 + 2.8, 1.4, P, 18, 0.2), { tone: "hi" }), [stem, knob], { attrs: ' data-key="bell"' });
}

desk();
hookBox();
bell();
const LANE = 1;
cable("cable.keys", [[4, CONSOLE.y, LANE * 1.9], [4, HOOK.y + HOOK.d, LANE * 1.9]], LANE, { touch: ["stand.desk", "console.plate", "hook.box"] });
tubes();
gantryStatic();
rack();
consolePlate();

A.settle(R, P);
R.items.sort((a, b) => a.key - b.key);

const boxOf = (shapes) => {
  if (!shapes.length) return null;
  const min = [Infinity, Infinity, Infinity];
  const max = [-Infinity, -Infinity, -Infinity];
  for (const shape of shapes) {
    const b = A.boundsOf(shape);
    for (let i = 0; i < 3; i++) (min[i] = Math.min(min[i], b.min[i])), (max[i] = Math.max(max[i], b.max[i]));
  }
  return [...min, ...max].map(round2);
};

function canisterSvg() {
  const { r, h } = L.can;
  const parts = [
    S(k.cylinder(0, 0, r, 0, 2.2, P, 22, 0.2), { tone: "mid", className: "md-c" }),
    S(k.cylinder(0, 0, r - 0.5, 2.2, 8.4, P, 22), { tone: "hi", crease: "lo", className: "md-c" }),
    S(k.cylinder(0, 0, r - 0.2, 10.6, 1.2, P, 22), { tone: "mid", className: "md-c md-ring" }),
    S(k.cylinder(0, 0, r - 0.5, 11.8, 8, P, 22), { tone: "hi", crease: "lo", className: "md-c" }),
    S(k.cylinder(0, 0, r, h - 2.2, 2.2, P, 22, 0.2), { tone: "mid", className: "md-c" }),
    `<path class="iso-line md-cap" data-tone="faint" d="${k.ring(0, 0, r - 1.6, h, P, 28)}"/>`,
    Dots([at([0, 0, h])], { size: 0.5, tone: "mid" }),
    `<g class="md-stamp">${Ln(k.ring(0, 0, 2.9, h, P, 24), { tone: "lit" })}${Ln(k.ring(0, 0, 1.5, h, P, 18), { tone: "lit" })}</g>`,
  ];
  return parts.join("");
}

function carriageSvg() {
  const { y0, y1, half, z0, z1 } = L.carriage;
  const plan = { x: -half, y: y0, w: half * 2, d: y1 - y0, r: 1.5 };
  const caps = Ln(k.sideRing([half, -89, 85], 1.8, "x", P, 18) + k.sideRing([half, -85, 85], 1.8, "x", P, 18), { tone: "lo" }) + Dots([at([half, -89, 85]), at([half, -85, 85])], { size: 0.45 });
  return S(k.slabOf(plan, z0, z1 - z0, P, 3, 0.5), { tone: "mid", inner: Ln(k.sideSeam(plan, z0 + 3, P, 3), { tone: "faint" }) }) + Dots([at([-5, y0 + 2.6, z1]), at([5, y0 + 2.6, z1])], { size: 0.42 }) + caps;
}

function beamSvg() {
  const { y0, y1, half, z0, z1 } = L.beam;
  const plan = { x: -half, y: y0, w: half * 2, d: y1 - y0, r: 1.2 };
  const strip = { x: -1.6, y: y0 + 4, w: 3.2, d: y1 - y0 - 8, r: 0.4 };
  const teeth = k.topTicks(strip.y + 1, strip.y + strip.d - 1, 2, 5, strip.x, z1 + 0.5, [3.2, 3.2], P, "y");
  const cap = { x: -half - 0.6, y: y1, w: half * 2 + 1.2, d: 2.4, r: 0.6 };
  return [
    S(k.slabOf(plan, z0, z1 - z0, P, 3, 0.5), { tone: "mid", inner: Ln(k.sideSeam(plan, z0 + 2.4, P, 3), { tone: "faint" }) }),
    S(k.slabOf(strip, z1, 0.5, P, 2), { tone: "lo", crease: "none" }),
    Ln(teeth.minor + teeth.major, { tone: "lo" }),
    S(k.slabOf(cap, z0 - 0.6, z1 - z0 + 1.2, P, 2, 0.3), { tone: "mid" }),
    Dots([at([0, y1 + 1.2, z1 + 0.6])], { size: 0.42 }),
  ].join("");
}

const ARM = L.arm;
function headSvg() {
  const { x0, x1, half, z0, z1, gland } = L.head;
  const block = { x: x0, y: -half, w: x1 - x0, d: half * 2, r: 2 };
  const panel = `<g transform="${sideOf(x1)}">${Ln(flatRect(-3.6, 81, 3.6, 93, 1.2, 3), { tone: "faint" })}</g>` + Dots([at([x1, -4.4, 95.6]), at([x1, 4.4, 95.6])], { size: 0.42 });
  return [
    S(k.cylinder(ARM, 0, 3.2, gland, z0 - gland, P, 20), { tone: "mid" }),
    S(k.slabOf(block, z0, z1 - z0, P, 3, 0.6), { tone: "mid", inner: Ln(k.sideSeam(block, z0 + 3, P, 3), { tone: "faint" }) }),
    panel,
    S(k.cylinder(ARM, 0, 4.4, z1, 3.4, P, 28, 0.3), { tone: "mid" }),
    Ln(k.knurl(ARM, 0, 4.4, z1, z1 + 3.4, 28, P), { tone: "lo" }),
    Dots([at([ARM, 0, z1 + 3.4])], { size: 0.55, tone: "hi" }),
  ].join("");
}

function columnParts() {
  const gland = at([ARM, 0, L.head.gland]);
  const clip = `<clipPath id="mdx-rod"><rect x="${round2(gland[0] - 4)}" y="${round2(gland[1])}" width="8" height="160"/></clipPath>`;
  const rod = S(k.cylinder(ARM, 0, 1.4, L.padRest + 2.4, 50, P, 14), { tone: "hi", crease: "none" });
  const pad = S(k.cylinder(ARM, 0, 4.6, L.padRest, 2.4, P, 28, 0.25), { tone: "mid" }) + Ln(k.sideArc(ARM, 0, 4.6, L.padRest + 1.2, P, 20), { tone: "faint" });
  return { clip, rod, pad };
}

const COLUMN = columnParts();
const DATA = {
  P: { origin: P.origin.map(round2), scale: P.scale, azimuth: AZIMUTH, elevation: ELEVATION },
  L,
  boxes: R.items.map((item) => boxOf(item.shapes)),
  names: R.items.map((item) => item.name),
  edges: [...new Set(R.settled.overlaps.pairs.map((pair) => {
    const a = R.items.indexOf(R.settled.items[pair.a]);
    const b = R.items.indexOf(R.settled.items[pair.b]);
    return a < b ? `${a},${b}` : `${b},${a}`;
  }))].map((text) => text.split(",").map(Number)),
  keyTravel: KEY_TRAVEL,
  sessions: M.SESSIONS,
};

const bandCss = Object.entries(BAND)
  .map(([agent, hex]) => {
    const mix = (t) => {
      const c = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16));
      const p = [8, 8, 11];
      return `#${c.map((v, i) => Math.round(p[i] + (v - p[i]) * t).toString(16).padStart(2, "0")).join("")}`;
    };
    return `.md-band[data-agent="${agent}"]{--anatomy-shade-0:${mix(0.2)};--anatomy-shade-1:${mix(0.26)};--anatomy-shade-2:${mix(0.32)};--anatomy-shade-3:${mix(0.38)};--anatomy-top:${mix(0.46)};--anatomy-mid:${mix(0.85)};--anatomy-faint:${mix(0.5)}}`;
  })
  .join("");

const ISO_CSS = k.ISO_CSS.trim();
const CSS = `${ISO_CSS}
.md-root{--anatomy-page:#08080b;--anatomy-card:#08080b;--anatomy-text:#8e8e96;--anatomy-strong:#f5f5f7;--anatomy-muted:#6a6a72;--anatomy-paper:#08080b;--anatomy-face:#111115;--anatomy-top:#16161b;--anatomy-shade-0:#0b0b0e;--anatomy-shade-1:#0e0e12;--anatomy-shade-2:#111115;--anatomy-shade-3:#141419;--anatomy-lit-top:#3b2611;--anatomy-lit-shade:#24170b;--anatomy-hi:#d6d6dc;--anatomy-mid:#76767f;--anatomy-lo:#43434b;--anatomy-faint:#29292f;--anatomy-lit:#ee8c33;--anatomy-halo:#000;--anatomy-halo-opacity:.95;--anatomy-dot:#e6e6ea;--anatomy-mono:ui-monospace,"SF Mono",Menlo,monospace;color:var(--anatomy-text)}
.md-root .iso-figure{margin:0}
.md-root .iso-plate{background:var(--anatomy-card);box-shadow:0 0 0 1px rgba(255,255,255,.08);border-radius:18px;padding:54px 22px}
.md-root .iso-plate-corner{font-size:11px}
.md-root .iso-plate-corner[data-corner="title"]{color:#f5f5f7}
.md-root .iso-legend{color:#8e8e96;font-size:13.5px;margin-top:16px}
.md-root .iso-swatch[data-mark="lit"] path{stroke:#ee8c33}
${bandCss}
.md-stage{position:relative;touch-action:pan-y;outline:none}
.md-stage:focus-visible{outline:1px solid rgba(255,255,255,.3);outline-offset:6px;border-radius:10px}
.md-stamp{opacity:0;transition:opacity .25s}
.md-can[data-stamped] .md-stamp{opacity:1}
.md-can[data-stamped] .md-ring>.iso-edge{stroke:var(--anatomy-lit)}
.md-can[data-stamped] .md-ring>.iso-shade,.md-can[data-stamped] .md-ring>.iso-top{fill:var(--anatomy-lit-shade)}
.md-can[data-sel] .md-cap{stroke:var(--anatomy-hi)}
.md-can[data-lift-hidden]{visibility:hidden}
.md-sr{position:absolute;width:1px;height:1px;overflow:hidden;clip-path:inset(50%);white-space:nowrap}
.md-root [data-key]{cursor:pointer}
.md-root [data-key][data-down] .iso-edge{stroke:var(--anatomy-hi)}
@media (max-width:560px){.md-root .iso-plate{padding:46px 8px 66px}}`;

const LABEL =
  "A pneumatic-tube dispatch desk. Three tubes, one each for Claude, Codex and Cursor, rise from a sealed box at the back of the desk and drop into receivers over three intake cups. A gantry carries a stamping head over a three-tier rack: needs you at the front, working in the middle, done at the back. The canister waiting for an answer glows orange; the head stamps it Allow and returns it to the cup under the tube it came from, and it goes back up that tube. No tube leaves the desk.";

const sizes = R.items.map((item) => [item.name, item.svg.length]).sort((a, b) => b[1] - a[1]);
if (process.argv.includes("--sizes")) console.log(sizes.slice(0, 25).map(([n, l]) => `${n} ${l}`).join("\n"), "\nparts", Object.fromEntries(Object.entries({ can: canisterSvg(), carriage: carriageSvg(), beam: beamSvg(), head: headSvg() }).map(([k, v]) => [k, v.length])), "back", back.join("").length);
const scene = R.items.map((item) => `<g${item.attrs ?? ""}>${item.svg}</g>`).join("");
const svg = k.figureSvg({
  width: W,
  height: H,
  label: LABEL,
  body: [
    `<defs>${COLUMN.clip}</defs>`,
    ...back,
    `<g data-scene>${scene}</g>`,
  ],
});

const body = k.plateHtml({
  fig: "Fig 1",
  title: "How Muster works",
  hint: "Tab to select · ⌥↩ to allow",
  readout: M.readout(M.createWorld()),
  keys: [
    { mark: "lit", label: "The session waiting for you" },
    { mark: "raised", label: "Sessions, sorted: needs you, working, done" },
    { mark: "edge", label: "One tube per agent, sealed inside the desk" },
  ],
  caption:
    "Muster reads the session files Claude, Codex and Cursor already write, without changing them, and sorts every session by urgency. When an agent asks permission, its hook sends the question to Muster on 127.0.0.1, and your answer goes back down the same line. Nothing leaves your Mac. Seven demo sessions, one waiting on npm run migrate -- --env staging.",
  body: `<div class="iso-stage md-stage" tabindex="0" role="group" aria-roledescription="figure" aria-label="How Muster works. Tab and Shift+Tab move the selector through the sessions; Option+Return or Enter allows the waiting request.">${svg}<span class="md-sr" role="status" aria-live="polite" data-status></span></div>`,
});

const tenthText = (t) => {
  const sign = t < 0 ? "-" : "";
  const a = Math.abs(t);
  const whole = Math.floor(a / 10);
  const frac = a % 10;
  return sign + (frac ? `${whole || ""}.${frac}` : `${whole}`);
};
function minifyPath(d) {
  const out = [];
  let cx = 0;
  let cy = 0;
  let sx = 0;
  let sy = 0;
  let last = "";
  const nums = (list) => {
    let text = "";
    for (const n of list) {
      const s = tenthText(n);
      text += text && !s.startsWith("-") && !(s.startsWith(".") && /\.\d*$/.test(text)) ? ` ${s}` : s;
    }
    return text;
  };
  for (const [, cmd, args] of d.matchAll(/([MLHVZ])([^MLHVZ]*)/g)) {
    const v = (args.match(/-?\d*\.?\d+/g) || []).map((n) => Math.round(parseFloat(n) * 10));
    if (cmd === "Z") {
      out.push("z");
      cx = sx;
      cy = sy;
      last = "z";
      continue;
    }
    if (cmd === "H") {
      for (const x of v) out.push(`h${nums([x - cx])}`), (cx = x);
      last = "h";
      continue;
    }
    if (cmd === "V") {
      for (const y of v) out.push(`v${nums([y - cy])}`), (cy = y);
      last = "v";
      continue;
    }
    for (let i = 0; i < v.length; i += 2) {
      const [x, y] = [v[i], v[i + 1]];
      if (cmd === "M" && i === 0) {
        out.push(out.length ? `m${nums([x - cx, y - cy])}` : `M${nums([x, y])}`);
        sx = x;
        sy = y;
        last = "m";
      } else {
        const piece = nums([x - cx, y - cy]);
        if (last === "l") out.push((piece.startsWith("-") ? "" : " ") + piece);
        else out.push(`l${piece}`);
        last = "l";
      }
      cx = x;
      cy = y;
    }
  }
  return out.join("");
}
const minify = (markup) => markup.replace(/ d="([^"]*)"/g, (_, d) => ` d="${minifyPath(d)}"`);

const modelSource = readFileSync(join(HERE, "model.mjs"), "utf8").replace(/^export /gm, "");
const orderSource = readFileSync(join(HERE, "order.mjs"), "utf8").replace(/^import .*$/gm, "").replace(/^export /gm, "");
const live = readFileSync(join(HERE, "live.js"), "utf8");
const parts = { can: canisterSvg(), carriage: carriageSvg(), beam: beamSvg(), head: headSvg(), rod: COLUMN.rod, pad: COLUMN.pad };

const js = `// Generated by figure/src/build.mjs. Do not edit by hand.
const MD_CSS = ${JSON.stringify(CSS)};
const MD_HTML = ${JSON.stringify(minify(body))};
const MD_PARTS = ${JSON.stringify(Object.fromEntries(Object.entries(parts).map(([key, value]) => [key, minify(value)])))};
const MD_DATA = ${JSON.stringify(DATA)};
${modelSource}
${orderSource}
${live}
`;
writeFileSync(join(OUT, "dispatch.js"), js);

const preview = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>How Muster works · figure preview</title>
<style>html{background:#08080b;color:#f5f5f7}body{margin:0;font:17px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text",Inter,system-ui,sans-serif;-webkit-font-smoothing:antialiased}main{max-width:760px;margin:64px auto 96px;padding:0 20px}</style>
</head><body><main><div id="dispatch"></div></main>
<script type="module" src="./dispatch.js"></script>
</body></html>
`;
writeFileSync(join(OUT, "preview.html"), preview);

const gz = gzipSync(js, { level: 9 }).length;
console.log(`wrote dispatch.js ${(js.length / 1024).toFixed(1)} KB (gzip ${(gz / 1024).toFixed(1)} KB) · ${R.items.length} static items · ${R.solids.length} solids · ${R.tubes.length} tube runs`);

A.auditOrExit(R, P, {});
export { R, P, DATA, parts, ARM };
