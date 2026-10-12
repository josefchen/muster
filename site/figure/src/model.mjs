export const AGENTS = ["claude", "codex", "cursor"];
export const AGENT_NAMES = { claude: "Claude", codex: "Codex", cursor: "Cursor" };
export const ROWS = ["needs", "working", "done"];
export const ROW_NAMES = { needs: "needs you", working: "working", done: "done" };

export const SESSIONS = [
  { id: "passkeys", agent: "claude", title: "Migrate auth to passkeys", state: "needs", cost: 41, prompt: "Wants to run npm run migrate -- --env staging" },
  { id: "parser", agent: "codex", title: "Port the parser to Rust", state: "working", cost: 20 },
  { id: "onboarding", agent: "cursor", title: "Polish the onboarding flow", state: "working", cost: null },
  { id: "ci", agent: "claude", title: "Fix flaky CI on macOS runners", state: "working", cost: 141 },
  { id: "notes", agent: "codex", title: "Write the 2.4 release notes", state: "done", cost: 0.74 },
  { id: "profile", agent: "claude", title: "Profile the image pipeline", state: "done", cost: 608 },
  { id: "tokens", agent: "cursor", title: "Add dark mode tokens", state: "done", cost: null },
];

export const L = {
  can: { r: 5.8, h: 22 },
  cols: [-90, -60, -30],
  rows: { needs: { y: 8, seat: 7.5 }, working: { y: -18, seat: 15.5 }, done: { y: -44, seat: 23.5 } },
  tubes: [-90, -56, -22],
  cupY: -74,
  cupSeat: 6,
  mouth: 104,
  hidden: 128,
  padRest: 70,
  arm: 11,
  beam: { y0: -82, y1: 18, half: 5, z0: 80, z1: 90 },
  carriage: { y0: -92, y1: -82, half: 9, z0: 78, z1: 92 },
  head: { x0: 5, x1: 17, half: 6, z0: 76, z1: 98, top: 101.4, gland: 73 },
};

export const PARK = [L.cols[2], L.rows.needs.y];

export const seatOf = (place) => {
  if (place.at === "slot") return [L.cols[place.col], L.rows[place.row].y, L.rows[place.row].seat];
  if (place.at === "cup") return [L.tubes[place.tube], L.cupY, L.cupSeat];
  return null;
};

const homeOf = (session) => {
  const row = session.state;
  const col = SESSIONS.filter((s) => s.state === row).indexOf(session);
  return { at: "slot", row, col };
};

export const costOf = (sessions) => sessions.reduce((sum, s) => sum + (s.cost ?? 0), 0);

export function createWorld() {
  return {
    cans: SESSIONS.map((s) => ({ id: s.id, agent: s.agent, tube: AGENTS.indexOf(s.agent), place: homeOf(s), lit: s.state === "needs", stamped: false, z: 0 })),
    g: { x: { x: PARK[0], v: 0 }, y: { x: PARK[1], v: 0 }, e: { x: 0, v: 0 } },
    goal: { x: PARK[0], y: PARK[1], e: 0 },
    held: null,
    press: 0,
    queue: [],
    task: null,
    clock: 0,
    blocks: 0,
    committed: -1,
  };
}

export const canById = (world, id) => world.cans.find((c) => c.id === id);
export const waitingOf = (world) => world.cans.filter((c) => c.lit);
export const busy = (world) => !!world.task || world.queue.length > 0;

export function headAt(world) {
  return { x: world.g.x.x, y: world.g.y.x, pad: L.padRest - world.g.e.x };
}

export function canPosition(world, can) {
  if (can.place.at === "held") {
    const h = headAt(world);
    return [h.x, h.y, h.pad - L.can.h];
  }
  if (can.place.at === "lift") return [L.tubes[can.place.tube], L.cupY, can.z];
  if (can.place.at === "tube") return [L.tubes[can.place.tube], L.cupY, L.hidden + 40];
  return seatOf(can.place);
}

const extFor = (seat) => L.padRest - (seat + L.can.h);

export function slotsInUrgency(world) {
  const order = [];
  for (const row of ROWS) for (let col = 0; col < L.cols.length; col++) {
    const can = world.cans.find((c) => c.place.at === "slot" && c.place.row === row && c.place.col === col);
    if (can) order.push(can);
  }
  return order;
}

const freeCol = (world, row) => {
  for (let col = 0; col < L.cols.length; col++) if (!world.cans.some((c) => c.place.at === "slot" && c.place.row === row && c.place.col === col)) return col;
  return -1;
};

const over = ([x, y]) => ({ k: "move", x, y });

export function pickAndPlace(from, to) {
  const a = seatOf(from);
  const b = seatOf(to);
  return [
    { k: "ext", e: 0 },
    over(a),
    { k: "ext", e: extFor(a[2]) },
    { k: "grab", from },
    { k: "ext", e: 0 },
    over(b),
    { k: "ext", e: extFor(b[2]) },
    { k: "put", to },
    { k: "ext", e: 0 },
  ];
}

export function arrive(world, id) {
  const can = canById(world, id);
  if (can.place.at !== "tube") return [];
  const cup = { at: "cup", tube: can.tube };
  const row = "needs";
  const col = freeCol(world, row);
  return [{ k: "ext", e: 0 }, { k: "move", x: PARK[0], y: PARK[1] }, { k: "drop", id }, { k: "wait", s: 0.35 }, ...pickAndPlace(cup, { at: "slot", row, col })];
}

export function allow(world, id) {
  const can = canById(world, id);
  if (can.place.at !== "slot" || !can.lit) return [];
  const at = seatOf(can.place);
  const cup = { at: "cup", tube: can.tube };
  const carry = pickAndPlace(can.place, cup);
  return [
    { k: "ext", e: 0 },
    over(at),
    { k: "ext", e: extFor(at[2]) },
    { k: "press", id },
    { k: "wait", s: 0.28 },
    ...carry.slice(3),
    { k: "move", x: PARK[0], y: PARK[1] },
    { k: "rise", id },
  ];
}

export function select(world, can) {
  const at = seatOf(can.place);
  return [{ k: "ext", e: 0 }, over(at)];
}

export function tourNext(world) {
  const can = canById(world, "passkeys");
  if (can.place.at === "slot" && can.lit) return [{ k: "wait", s: 2.6 }, { k: "then", make: (w) => allow(w, can.id) }];
  if (can.place.at === "tube") return [{ k: "wait", s: 2.4 }, { k: "then", make: (w) => arrive(w, can.id) }];
  return [{ k: "wait", s: 1 }];
}

export function enqueue(world, tasks) {
  const block = ++world.blocks;
  world.queue.push(...tasks.map((task) => ({ ...task, block })));
  return block;
}

export function interrupt(world) {
  if (world.task && world.task.block === world.committed) {
    world.queue = world.queue.filter((task) => task.block === world.task.block);
    return;
  }
  world.task = null;
  world.queue = [];
}

export const allowPending = (world) => [world.task, ...world.queue].some((task) => task && (task.k === "press" || (task.k === "then" && task.allow)));

const settle = (s, target, dt, seconds, calm) => {
  if (calm) {
    s.x = target;
    s.v = 0;
    return false;
  }
  const w = 1 / seconds;
  const h = dt / 4;
  for (let i = 0; i < 4; i++) {
    s.v += (w * w * (target - s.x) - 2 * w * s.v) * h;
    s.x += s.v * h;
  }
  if (Math.abs(target - s.x) < 0.01 && Math.abs(s.v) < 0.01) {
    s.x = target;
    s.v = 0;
    return false;
  }
  return true;
};

const LIFT_TIME = 1.5;
const easeIn = (t) => t * t;
const easeOut = (t) => 1 - (1 - t) * (1 - t);

function begin(world, task) {
  task.age = 0;
  if (task.k === "then") {
    world.queue.unshift(...task.make(world).map((t) => ({ ...t, block: task.block })));
    return;
  }
  if (task.k === "grab" || task.k === "press" || task.k === "drop") world.committed = task.block;
  if (task.k === "move") Object.assign(world.goal, { x: task.x, y: task.y });
  if (task.k === "ext") world.goal.e = task.e;
  if (task.k === "drop") {
    const can = canById(world, task.id);
    can.place = { at: "lift", tube: can.tube };
    can.z = L.hidden;
    can.lit = true;
    can.stamped = false;
  }
  if (task.k === "rise") {
    const can = canById(world, task.id);
    can.place = { at: "lift", tube: can.tube };
    can.z = L.cupSeat;
  }
  if (task.k === "grab") {
    const can = world.cans.find((c) => c.place.at === task.from.at && c.place.row === task.from.row && c.place.col === task.from.col && c.place.tube === task.from.tube);
    if (can) {
      can.place = { at: "held" };
      world.held = can.id;
    }
  }
  if (task.k === "put") {
    const can = canById(world, world.held);
    if (can) can.place = { ...task.to };
    world.held = null;
  }
  if (task.k === "press") {
    const can = canById(world, task.id);
    can.stamped = true;
    can.lit = false;
    world.press = 1;
  }
}

function run(world, task, dt, calm) {
  task.age += dt;
  if (task.k === "wait") return calm || task.age >= task.s;
  if (task.k === "drop" || task.k === "rise") {
    const can = canById(world, task.id);
    const t = calm ? 1 : Math.min(1, task.age / LIFT_TIME);
    if (task.k === "drop") can.z = L.hidden + (L.cupSeat - L.hidden) * easeOut(t);
    else can.z = L.cupSeat + (L.hidden - L.cupSeat) * easeIn(t);
    if (t < 1) return false;
    can.place = task.k === "drop" ? { at: "cup", tube: can.tube } : { at: "tube", tube: can.tube };
    return true;
  }
  const near = (s, target, d, v) => Math.abs(s.x - target) < d && Math.abs(s.v) < v;
  if (task.k === "move") return near(world.g.x, world.goal.x, 0.4, 3) && near(world.g.y, world.goal.y, 0.4, 3) && near(world.g.e, world.goal.e, 0.1, 2);
  if (task.k === "ext") return near(world.g.e, world.goal.e, 0.1, 2) && near(world.g.x, world.goal.x, 0.4, 3) && near(world.g.y, world.goal.y, 0.4, 3);
  return true;
}

const advance = (world, dt, calm) => {
  const x = settle(world.g.x, world.goal.x, dt, 0.26, calm);
  const y = settle(world.g.y, world.goal.y, dt, 0.26, calm);
  const e = settle(world.g.e, world.goal.e, dt, 0.115, calm);
  return x || y || e;
};

export function step(world, dt, calm = false) {
  world.clock += dt;
  const moving = advance(world, dt, calm);
  world.press = calm ? 0 : Math.max(0, world.press - dt / 0.6);
  for (let guard = 0; guard < 64; guard++) {
    if (!world.task) {
      if (!world.queue.length) break;
      world.task = world.queue.shift();
      begin(world, world.task);
      if (calm) advance(world, 0, true);
    }
    if (!run(world, world.task, dt, calm)) break;
    world.task = null;
    dt = 0;
  }
  return moving || busy(world) || world.press > 0;
}

export function readout(world, sessions = SESSIONS) {
  const waiting = waitingOf(world).length;
  return `${sessions.length} sessions · ${waiting} waiting · ≈ $${Math.round(costOf(sessions))} at API rates`;
}
