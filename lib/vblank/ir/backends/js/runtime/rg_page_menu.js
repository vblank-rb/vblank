/*
 * THE MENU OVER A WEB PAGE'S GAME, AND WHAT A PLAYER KEEPS: the keys and controller buttons, the
 * window's own keys (hotkeys), the sound and the speed of fast forward. What it holds is the library's
 * (Live::WindowMenu, here as RG_PAGE_MENU), and how it behaves is Live::Menu and Live::Settings
 * written again, line for line: change one and change the other, or test_js_page_menu.rb says where
 * they part. A browser lays out text itself, so this gives what the menu holds and page_menu_draw
 * puts that in a part of the page over the canvas, which is all a page needs of Live::Menu's drawing.
 *
 * THIS FILE IS INSIDE createGame(host), as rg_page.js is, and rg_page.js says when it is used: a page
 * VBlank wrote, or a host that sets menu: true.
 *
 * What is kept is one line of JSON in the browser's storage, one for all the games a site has, as
 * the file every game shares is on a computer. It is read over the starting values, and anything in
 * it that cannot be used is left at its starting value: a page never fails to open for it.
 */

const PAGE_SETTINGS_KEY = "vblank-settings";
const PAGE_ESCAPE = "Escape";
const PAGE_KEYS_A_BUTTON = 2;
const PAGE_MENU_OPEN_KEYS = ["Backquote"];
const PAGE_MENU_MOVES = { ArrowUp: "up", ArrowDown: "down", ArrowLeft: "left", ArrowRight: "right", Enter: "enter", Escape: "close" };

/* The keys the page keeps for itself, in Settings::HOTKEYS's order. A page has F for fullscreen,
 * since a browser keeps F11. */
const PAGE_HOTKEYS = ["pause", "step", "frame_rate", "fullscreen", "mute", "menu", "fast_forward"];
const PAGE_HOTKEY_KEYS = ["KeyP", "KeyN", "F3", "KeyF", "KeyM", "F1", "Tab"];

/* A controller's buttons in the browser's standard layout, by number, as the settings file names them. */
const PAGE_PAD_NAMES = { 0: "south", 1: "east", 2: "west", 3: "north", 4: "left shoulder", 5: "right shoulder", 8: "back", 9: "start",
  10: "left stick", 11: "right stick", 12: "d-pad up", 13: "d-pad down", 14: "d-pad left", 15: "d-pad right", 16: "guide" };

/* What a player calls a key: the browser's name for it, as SDL names it on a computer. */
function page_key_name(code) {
  if (code === null || code === undefined) return "none";
  const special = { Enter: "Return", ShiftRight: "Right Shift", ShiftLeft: "Left Shift", ControlLeft: "Left Ctrl", ControlRight: "Right Ctrl",
    AltLeft: "Left Alt", AltRight: "Right Alt", Backquote: "`" };
  if (special[code]) return special[code];
  return code.replace(/^Key/, "").replace(/^Digit/, "").replace(/^Arrow/, "");
}

/* Everything a player keeps (+storage+ is the browser's, or null to keep nothing), and the rules
 * for changing keys: Live::Settings. */
function page_settings(storage, on_change) {
  const starting_keys = () => {
    const keys = {};
    for (const button of PAGE_BUTTONS) keys[button] = [null, null];
    for (const [code, button] of Object.entries(PAGE_KEYS)) keys[button][keys[button][0] === null ? 0 : 1] = code;
    return keys;
  };
  const starting_pads = () => Object.fromEntries(PAGE_PAD_BUTTONS.map(([number, button]) => [button, number]));
  const starting_hotkeys = () => Object.fromEntries(PAGE_HOTKEYS.map((name, at) => [name, PAGE_HOTKEY_KEYS[at]]));

  const now = { fast_forward_speed: 4, volume: 100, muted: false, frame_rate: false, fullscreen: false,
    keys: starting_keys(), pads: starting_pads(), hotkeys: starting_hotkeys() };
  let notice = null;
  let waiting = null;

  function read_kept() {
    if (!storage) return;
    try {
      const kept = JSON.parse(storage.getItem(PAGE_SETTINGS_KEY) || "{}");
      if (Number.isInteger(kept.fast_forward_speed)) now.fast_forward_speed = Math.min(8, Math.max(2, kept.fast_forward_speed));
      if (Number.isInteger(kept.volume)) now.volume = Math.min(100, Math.max(0, kept.volume));
      if (typeof kept.muted === "boolean") now.muted = kept.muted;
      if (typeof kept.frame_rate === "boolean") now.frame_rate = kept.frame_rate;
      for (const button of PAGE_BUTTONS) {
        if (Array.isArray(kept.keys && kept.keys[button])) now.keys[button] = kept.keys[button].slice(0, PAGE_KEYS_A_BUTTON).concat([null]).slice(0, PAGE_KEYS_A_BUTTON);
        if (kept.pads && Number.isInteger(kept.pads[button])) now.pads[button] = kept.pads[button];
      }
      for (const name of PAGE_HOTKEYS) if (kept.hotkeys && name in kept.hotkeys) now.hotkeys[name] = kept.hotkeys[name];
    } catch (error) {
      /* something that is not settings: the page starts as a new one does */
    }
  }

  function write_kept() {
    on_change();
    if (!storage) return;
    try {
      const { fullscreen, ...kept } = now;
      storage.setItem(PAGE_SETTINGS_KEY, JSON.stringify(kept));
    } catch (error) {
      /* a browser that keeps nothing for this page plays on with what it has */
    }
  }

  const button_of_key = (code) => PAGE_BUTTONS.find((button) => now.keys[button].includes(code));
  const hotkey_of_key = (code) => PAGE_HOTKEYS.find((name) => now.hotkeys[name] === code);

  /* Why +code+ cannot be given to the button or hotkey asking, said in the notice, or null. */
  function refusal(code, button, hotkey) {
    const owner = button_of_key(code);
    if (owner !== undefined && owner !== button) {
      const name = RG_PAGE_MENU.buttons[PAGE_BUTTONS.indexOf(owner)];
      return (notice = `${page_key_name(code)} is already the ${name} button. Clear it there first, then it can be used here.`);
    }
    const taken = hotkey_of_key(code);
    if (taken === undefined || taken === hotkey) return null;
    const name = RG_PAGE_MENU.hotkeys[PAGE_HOTKEYS.indexOf(taken)];
    return (notice = `${page_key_name(code)} is the hotkey for "${name}". Change that hotkey first, then this key can be used here.`);
  }

  function bind_key(button, slot, code) {
    const why = refusal(code, button, null);
    if (why) return why;
    now.keys[button].forEach((key, other) => { if (other !== slot && key === code) now.keys[button][other] = null; });
    now.keys[button][slot] = code;
    notice = null;
    write_kept();
    return null;
  }

  function bind_hotkey(name, code) {
    const why = refusal(code, null, name);
    if (why) return why;
    now.hotkeys[name] = code;
    notice = null;
    write_kept();
    return null;
  }

  /* A controller button another console button has swaps with it. */
  function bind_pad(button, number) {
    const was = now.pads[button];
    for (const each of PAGE_BUTTONS) if (each !== button && now.pads[each] === number) now.pads[each] = was;
    now.pads[button] = number;
    notice = null;
    write_kept();
  }

  return {
    now, read_kept, write_kept, button_of_key, hotkey_of_key,
    get notice() { return notice; },
    capture_for_button(place) { notice = null; waiting = ["button", place]; },
    capture_for_hotkey(place) { notice = null; waiting = ["hotkey", place]; },
    capture_cancel() { waiting = null; },
    get capturing() { return waiting !== null; },
    capture_place(kind) { return waiting && waiting[0] === kind ? waiting[1] : null; },
    get capture_prompt() {
      if (!waiting) return null;
      if (waiting[0] === "button") return `Press a key or a gamepad button for ${RG_PAGE_MENU.buttons[waiting[1]]} (Escape to give up)...`;
      return `Press a key for "${RG_PAGE_MENU.hotkeys[waiting[1]]}" (Escape to give up)...`;
    },
    /* A key pressed for the choice waiting. Escape gives up; one refused is said, and the wait goes on. */
    capture_key(code) {
      if (!waiting) return false;
      if (code === PAGE_ESCAPE) {
        waiting = null;
        return true;
      }
      const why = waiting[0] === "button" ? bind_key(PAGE_BUTTONS[waiting[1]], 0, code) : bind_hotkey(PAGE_HOTKEYS[waiting[1]], code);
      if (!why) waiting = null;
      return true;
    },
    capture_pad(number) {
      if (!waiting || waiting[0] !== "button") return false;
      bind_pad(PAGE_BUTTONS[waiting[1]], number);
      waiting = null;
      return true;
    },
    reset_keys() {
      const keys = starting_keys();
      const kept_by_hotkey = [];
      for (const button of PAGE_BUTTONS) {
        keys[button] = keys[button].map((code) => {
          if (code === null || hotkey_of_key(code) === undefined) return code;
          kept_by_hotkey.push(page_key_name(code));
          return null;
        });
      }
      now.keys = keys;
      now.pads = starting_pads();
      notice = kept_by_hotkey.length ? `Keys are back as they were, but for ${kept_by_hotkey.join(" and ")}, which a hotkey has.` : null;
      write_kept();
    },
    reset_hotkeys() {
      const hotkeys = starting_hotkeys();
      for (const name of PAGE_HOTKEYS) if (button_of_key(hotkeys[name]) !== undefined) hotkeys[name] = null;
      now.hotkeys = hotkeys;
      notice = null;
      write_kept();
    },
    button_text(place) {
      const button = PAGE_BUTTONS[place];
      const keys = now.keys[button].filter((code) => code !== null).map(page_key_name);
      return `${keys.length ? keys.join(", ") : "none"} / ${PAGE_PAD_NAMES[now.pads[button]] || now.pads[button]}`;
    },
    hotkey_text(place) { return page_key_name(now.hotkeys[PAGE_HOTKEYS[place]]); },
  };
}

/* How the menu behaves: Live::Menu. +does+ names what the page does for a line: resume, fullscreen. */
function page_menu(settings, does) {
  const headings = RG_PAGE_MENU.headings;
  let open = false, heading = 0, row = -1;

  const lines = () => headings[heading].lines;
  function toggle() {
    open = !open;
    heading = 0;
    row = -1;
    settings.capture_cancel();
  }
  function move_heading(key) {
    heading = (heading + (key === "right" ? 1 : -1) + headings.length) % headings.length;
    row = -1;
  }
  function slide(line, direction) {
    const value = settings.now[line.setting] + direction * line.step;
    settings.now[line.setting] = Math.min(line.most, Math.max(line.least, value));
    settings.write_kept();
  }
  function enter(line) {
    if (line.kind === "check") {
      settings.now[line.setting] = !settings.now[line.setting];
      if (line.setting === "fullscreen") does.fullscreen();
      settings.write_kept();
    } else if (line.kind === "button") settings.capture_for_button(line.place);
    else if (line.kind === "hotkey") settings.capture_for_hotkey(line.place);
    else if (line.does === "resume") open = false;
    else if (line.does === "quit") does.quit();
    else if (line.does === "reset_keys") settings.reset_keys();
    else if (line.does === "reset_hotkeys") settings.reset_hotkeys();
  }
  function right_of(line) {
    if (line.kind === "button" || line.kind === "hotkey") {
      if (settings.capture_place(line.kind) === line.place) return settings.capture_prompt;
      return line.kind === "button" ? settings.button_text(line.place) : settings.hotkey_text(line.place);
    }
    if (line.kind === "check") return settings.now[line.setting] ? "✓" : "";
    if (line.kind === "slider") return `${settings.now[line.setting]}${line.written === "times" ? "x" : "%"}`;
    return line.shortcut || "";
  }

  return {
    toggle,
    get open() { return open; },
    press(key) {
      if (key === "close") return toggle();
      if (row < 0) {
        if (key === "left" || key === "right") move_heading(key);
        else if (key === "down" || key === "enter") row = 0;
        return undefined;
      }
      const line = lines()[row];
      if (key === "up") row -= 1;
      else if (key === "down") row = (row + 1) % lines().length;
      else if (key === "enter") enter(line);
      else if (line.kind === "slider") slide(line, key === "right" ? 1 : -1);
      else move_heading(key);
      return undefined;
    },
    /* What the menu shows, for page_menu_draw and for a test. */
    get shown() {
      return { open, heading: open ? headings[heading].name : null, chosen: open && row >= 0 ? lines()[row].label : null,
        headings: headings.map((each) => each.name), lines: lines().map((line) => [line.label, right_of(line)]), row, notice: settings.notice };
    },
  };
}

/* The part of the page that shows the menu and what the page is doing, over the canvas: made when
 * first needed, on a page with a document to make one in. */
function page_menu_draw(canvas, menu, status) {
  if (typeof document === "undefined" || !document.createElement || !canvas.parentNode) return;
  let over = canvas.vblank_menu;
  if (!over) {
    over = canvas.vblank_menu = document.createElement("div");
    over.style.cssText = "position:absolute;left:0;top:0;right:0;font:14px system-ui,sans-serif;color:#fff;pointer-events:none;z-index:10";
    const holder = canvas.parentNode;
    if (getComputedStyle(holder).position === "static") holder.style.position = "relative";
    holder.appendChild(over);
  }
  const colors = RG_PAGE_MENU.colors;
  const shown = menu.shown;
  const add = (parent, css, text) => {
    const part = document.createElement("div");
    part.style.cssText = css;
    if (text !== undefined) part.textContent = text;
    parent.appendChild(part);
    return part;
  };
  over.textContent = "";
  if (shown.open) {
    const bar = add(over, `display:flex;gap:14px;padding:3px 8px;background:${colors.bar}`);
    for (const name of shown.headings) {
      add(bar, `padding:0 4px;background:${name === shown.heading ? (shown.chosen ? colors.open : colors.chosen) : "none"}`, name);
    }
    const box = add(over, `display:inline-block;padding:8px;min-width:200px;background:${colors.box};border:1px solid ${colors.border};border-radius:4px`);
    shown.lines.forEach(([label, right], index) => {
      const row = add(box, `display:flex;justify-content:space-between;gap:30px;padding:2px 4px;border-radius:3px;background:${index === shown.row ? colors.chosen : "none"}`);
      add(row, "", label);
      add(row, `color:${colors.dim}`, right);
    });
    if (shown.notice) add(box, `color:${colors.paused};max-width:480px`, shown.notice);
  }
  if (status.length) {
    add(over, `position:absolute;right:8px;top:${shown.open ? 30 : 8}px;padding:8px;background:${colors.status};border-radius:4px`, status.join(" · "));
  }
}
