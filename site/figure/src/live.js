const MD_NS = "http://www.w3.org/2000/svg";

function mdMount(host) {
  if (!host || host.__mdMounted) return null;
  host.__mdMounted = true;
  if (!document.getElementById("md-dispatch-css")) {
    const style = document.createElement("style");
    style.id = "md-dispatch-css";
    style.textContent = MD_CSS;
    document.head.appendChild(style);
  }
  host.classList.add("iso", "md-root");
  host.setAttribute("data-theme", "dark");
  host.innerHTML = MD_HTML;

  const { L, sessions } = MD_DATA;
  const { iso, along, depth } = projector(MD_DATA.P);
  const shift = (v) => {
    const [x, y] = along(v);
    return `translate(${x.toFixed(2)} ${y.toFixed(2)})`;
  };
  const stage = host.querySelector(".md-stage");
  const svg = stage.querySelector("svg");
  const scene = svg.querySelector("[data-scene]");
  const readoutEl = host.querySelector("[data-readout]");
  const status = host.querySelector("[data-status]");
  const still = matchMedia("(prefers-reduced-motion: reduce)");
  const statics = [...scene.children].map((el, i) => ({ el, box: MD_DATA.boxes[i], screen: screenBox(MD_DATA.boxes[i], iso) }));
  const keyEls = Object.fromEntries([...scene.querySelectorAll("[data-key]")].map((el) => [el.dataset.key, el]));

  const group = (html, attrs = {}) => {
    const g = document.createElementNS(MD_NS, "g");
    for (const [k, v] of Object.entries(attrs)) g.setAttribute(k, v);
    g.innerHTML = html;
    return g;
  };
  const carriage = { el: group(MD_PARTS.carriage, { "data-m": "carriage" }) };
  const beam = { el: group(MD_PARTS.beam, { "data-m": "beam" }) };
  const head = { el: group(MD_PARTS.head, { "data-m": "head" }) };
  const column = { el: group(`<g data-ext><g data-carry></g>${MD_PARTS.pad}</g><g clip-path="url(#mdx-rod)"><g data-ext>${MD_PARTS.rod}</g></g>`, { "data-m": "column" }) };
  const carry = column.el.querySelector("[data-carry]");
  carry.setAttribute("transform", shift([L.arm, 0, L.padRest - L.can.h]));
  const extEls = [...column.el.querySelectorAll("[data-ext]")];
  const world = createWorld();
  const cans = world.cans.map((can) => ({ can, el: group(MD_PARTS.can, { class: "md-can", "data-id": can.id }), held: false }));
  const movers = [carriage, beam, head, column, ...cans];

  let selected = null;
  let touring = !still.matches;
  let driving = false;
  let visible = false;
  let frame = 0;
  let last = 0;
  let idleTimer = 0;
  let order = "";
  let lastText = "";
  const keyDown = {};

  const sessionOf = (id) => sessions.find((s) => s.id === id);
  const rowOf = (can) => (can.lit ? "needs you" : can.place.at === "slot" ? ROW_NAMES[can.place.row] : "working");
  const describe = (can) => {
    const s = sessionOf(can.id);
    return `${AGENT_NAMES[s.agent]} · ${s.title} · ${rowOf(can)}${s.cost != null ? ` · $${s.cost < 1 ? s.cost.toFixed(2) : s.cost}` : ""}`;
  };
  const say = (text) => {
    if (status.textContent !== text) status.textContent = text;
  };

  function place() {
    const boxes = moverBoxes(world, L);
    const h = boxes.head;
    const armShift = shift([boxes.bx, 0, 0]);
    carriage.el.setAttribute("transform", armShift);
    beam.el.setAttribute("transform", armShift);
    const headShift = shift([boxes.bx, h.y, 0]);
    head.el.setAttribute("transform", headShift);
    column.el.setAttribute("transform", headShift);
    const down = shift([0, 0, -world.g.e.x]);
    for (const el of extEls) el.setAttribute("transform", down);
    carriage.box = boxes.carriage;
    beam.box = boxes.beam;
    head.box = boxes.headBlock;
    column.box = boxes.column;
    for (const c of cans) {
      const held = c.can.place.at === "held";
      if (held !== c.held) {
        c.held = held;
        if (held) {
          carry.appendChild(c.el);
          c.el.removeAttribute("transform");
        }
      }
      c.box = boxes.cans[world.cans.indexOf(c.can)];
      if (!held) {
        if (c.el.parentNode !== scene) scene.appendChild(c.el);
        if (c.box) c.el.setAttribute("transform", shift(canPosition(world, c.can)));
        c.el.toggleAttribute("data-lift-hidden", !c.box);
      }
      c.el.toggleAttribute("data-stamped", c.can.stamped && c.can.place.at !== "tube");
      c.el.toggleAttribute("data-sel", selected === c.can.id && driving);
      const lit = c.can.lit;
      if (c.lit !== lit) {
        c.lit = lit;
        c.el.querySelectorAll(".iso-solid").forEach((solid) => solid.toggleAttribute("data-lit", lit));
      }
    }
    for (const m of movers) m.screen = screenBox(m.box, iso);
    const active = movers.filter((m) => m.box && m.el.parentNode === scene);
    const centre = (m) => depth([(m.box[0] + m.box[3]) / 2, (m.box[1] + m.box[4]) / 2, (m.box[2] + m.box[5]) / 2]);
    const { order: ids } = orderScene(statics, MD_DATA.edges, active, centre);
    const signature = ids.join(",");
    if (signature !== order) {
      order = signature;
      const wanted = ids.map((id) => (id < statics.length ? statics[id].el : active[id - statics.length].el));
      for (const c of cans) if (!c.box && c.el.parentNode === scene) wanted.push(c.el);
      wanted.forEach((el, index) => {
        if (scene.children[index] !== el) scene.insertBefore(el, scene.children[index] ?? null);
      });
    }
  }

  function readout() {
    const can = selected && driving ? canById(world, selected) : null;
    const text = can && can.place.at === "slot" ? describe(can) : mdReadout(world, sessions);
    if (text !== lastText) {
      lastText = text;
      readoutEl.textContent = text;
    }
  }

  function keyVisual(name) {
    const el = keyEls[name];
    if (!el) return;
    keyDown[name] = still.matches ? 0.05 : name === "bell" ? 0.22 : 0.16;
    el.setAttribute("transform", shift([0, 0, name === "bell" ? -1.2 : -MD_DATA.keyTravel]));
    el.setAttribute("data-down", "");
    run();
  }

  function tick(now) {
    const dt = last ? Math.min((now - last) / 1000, 1 / 30) : 1 / 60;
    last = now;
    const calm = still.matches;
    if (touring && !busy(world)) enqueue(world, tourNext(world));
    const before = waitingOf(world).map((c) => c.id).join();
    const moving = step(world, dt, calm);
    const after = waitingOf(world).map((c) => c.id).join();
    if (before !== after) {
      const can = canById(world, "passkeys");
      if (after) keyVisual("bell");
      say(after ? `${describe(can)}: ${sessionOf(can.id).prompt}` : `Allowed. ${AGENT_NAMES[can.agent]} gets the answer back on its own line.`);
    }
    if (selected) {
      const can = canById(world, selected);
      if (can.place.at !== "slot") selected = null;
    }
    let keysMoving = false;
    for (const name of Object.keys(keyDown)) {
      if (keyDown[name] <= 0) continue;
      keyDown[name] -= dt;
      keysMoving = true;
      if (keyDown[name] <= 0) {
        keyEls[name].removeAttribute("transform");
        keyEls[name].removeAttribute("data-down");
      }
    }
    place();
    readout();
    frame = visible && (moving || touring || keysMoving || busy(world)) ? requestAnimationFrame(tick) : 0;
  }
  function run() {
    if (!frame && visible) {
      last = 0;
      frame = requestAnimationFrame(tick);
    }
  }
  function pause() {
    clearTimeout(idleTimer);
    if (touring) {
      touring = false;
      interrupt(world);
    }
  }
  function resumeLater(ms = 3600) {
    clearTimeout(idleTimer);
    idleTimer = setTimeout(() => {
      if (still.matches || stage.matches(":hover")) return;
      driving = false;
      touring = true;
      run();
    }, ms);
  }
  function takeOver() {
    pause();
    driving = true;
    resumeLater();
  }

  function selectStep(dir) {
    const list = slotsInUrgency(world);
    if (!list.length) return false;
    const index = selected ? list.findIndex((c) => c.id === selected) : -1;
    const next = index < 0 ? (dir > 0 ? 0 : list.length - 1) : index + dir;
    if (next < 0 || next >= list.length) return false;
    selected = list[next].id;
    enqueue(world, select(world, list[next]));
    say(describe(list[next]));
    return true;
  }
  function allowWaiting() {
    const waiting = waitingOf(world)[0];
    if (!waiting) {
      say("Nothing is waiting for you.");
      return;
    }
    if (allowPending(world)) return;
    selected = waiting.id;
    enqueue(world, [{ k: "then", allow: true, make: (w) => allow(w, waiting.id) }]);
  }

  stage.addEventListener("keydown", (event) => {
    if (event.key === "Tab" && !event.altKey && !event.metaKey && !event.ctrlKey) {
      takeOver();
      keyVisual("tab");
      if (selectStep(event.shiftKey ? -1 : 1)) event.preventDefault();
      else {
        selected = null;
        driving = false;
      }
      run();
      return;
    }
    if (event.key === "Enter" && !event.metaKey && !event.ctrlKey) {
      event.preventDefault();
      takeOver();
      if (event.altKey) keyVisual("opt");
      keyVisual("enter");
      allowWaiting();
      run();
    }
    if (event.key === "Alt") keyVisual("opt");
  });
  stage.addEventListener("pointerenter", () => {
    pause();
    run();
  });
  stage.addEventListener("pointerleave", () => resumeLater());
  stage.addEventListener("focus", () => {
    pause();
    say(readoutEl.textContent);
  });
  stage.addEventListener("blur", () => resumeLater());
  svg.addEventListener("click", (event) => {
    const key = event.target.closest("[data-key]");
    const canEl = event.target.closest(".md-can");
    if (key) {
      takeOver();
      keyVisual(key.dataset.key);
      if (key.dataset.key === "tab") selectStep(1) || ((selected = null), selectStep(1));
      else if (key.dataset.key !== "bell") allowWaiting();
    } else if (canEl) {
      const can = canById(world, canEl.dataset.id);
      if (can.place.at === "slot") {
        takeOver();
        selected = can.id;
        enqueue(world, select(world, can));
        say(describe(can));
      }
    } else return;
    stage.focus({ preventScroll: true });
    run();
  });
  still.addEventListener?.("change", () => {
    touring = !still.matches && !driving;
    run();
  });

  new IntersectionObserver(
    (entries) => {
      visible = entries[entries.length - 1].isIntersecting;
      if (visible) run();
      else if (frame) {
        cancelAnimationFrame(frame);
        frame = 0;
      }
    },
    { rootMargin: "120px 0px" },
  ).observe(stage);

  for (const m of movers) scene.appendChild(m.el);
  place();
  readout();
  return { world };
}

const mdReadout = readout;
export const mount = mdMount;
for (const el of document.querySelectorAll("#dispatch, [data-muster-dispatch]")) mdMount(el);
