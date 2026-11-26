/*
 * The menu over a web page's game, and what a player keeps: the keys and controller buttons, the
 * window's own keys (hotkeys), the sound and the speed of fast forward. What it holds is the library's
 * (Live::WindowMenu, here as RG_PAGE_MENU), and how it behaves is Live::Menu and Live::Settings
 * written again, line for line: change one and change the other, or test_js_page_menu.rb says where
 * they part. A browser lays out text itself, so this gives what the menu holds and page_menu_draw
 * puts that in a part of the page over the canvas, which is all a page needs of Live::Menu's drawing.
 *
 * This file is inside createGame(host), as rg_page.js is, and rg_page.js says when it is used: a page
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
/* F5 saves the quick state and F9 loads it, as in an emulator (Live::WindowMenu::QUICK_SAVE_KEY and QUICK_LOAD_KEY). */
const PAGE_STATE_KEYS = { F5: "save", F9: "load" };
const PAGE_MENU_MOVES = { ArrowUp: "up", ArrowDown: "down", ArrowLeft: "left", ArrowRight: "right", Enter: "enter", Escape: "close" };

/* The keys the page keeps for itself, in Settings::HOTKEYS's order. A page has F for fullscreen,
 * since a browser keeps F11. */
const PAGE_HOTKEYS = ["pause", "step", "frame_rate", "fullscreen", "mute", "menu", "fast_forward"];
const PAGE_HOTKEY_KEYS = ["KeyP", "KeyN", "F3", "KeyF", "KeyM", "F1", "Tab"];

/* A controller's buttons in the browser's standard layout, by number, as the settings file names them. */
const PAGE_PAD_NAMES = { 0: "south", 1: "east", 2: "west", 3: "north", 4: "left shoulder", 5: "right shoulder", 8: "back", 9: "start",
  6: "left trigger", 7: "right trigger", 10: "left stick", 11: "right stick", 12: "d-pad up", 13: "d-pad down", 14: "d-pad left",
  15: "d-pad right", 16: "guide" };

/* When a state was taken, as the menu shows it: the day and the minute, by the page's own clock. */
function page_time_words(milliseconds) {
  const at = new Date(milliseconds);
  const two = (number) => String(number).padStart(2, "0");
  return `${at.getFullYear()}-${two(at.getMonth() + 1)}-${two(at.getDate())} ${two(at.getHours())}:${two(at.getMinutes())}`;
}

/* What a player calls a key: the browser's name for it, as SDL names it on a computer. */
function page_key_name(code) {
  if (code === null || code === undefined) return "none";
  const special = { Enter: "Return", ShiftRight: "Right Shift", ShiftLeft: "Left Shift", ControlLeft: "Left Ctrl", ControlRight: "Right Ctrl",
    AltLeft: "Left Alt", AltRight: "Right Alt", Backquote: "`" };
  if (special[code]) return special[code];
  return code.replace(/^Key/, "").replace(/^Digit/, "").replace(/^Arrow/, "");
}

/* Everything a player keeps (+storage+ is the browser's, or null to keep nothing), and the rules
 * for changing keys: Live::Settings. +game+ is the keys and controller buttons the game adds
 * (page_game_controls): where the keys start and where Reset puts them, added again over what is
 * kept wherever nothing else has them, and never kept themselves, since what is kept is every game's
 * on the site. */
function page_settings(storage, on_change, game = { keys: [], pads: [] }) {
  /* The console's buttons: only they are read, shown and checked for a key two of them share. The
   * rest keep what they have, for a game of a console that has them (Live::Settings's +buttons+). */
  const console_buttons = PAGE_BUTTONS.filter(page_console_has);
  /* The game's own keys and controller buttons put in +keys+ and +pads+, each in its button's first
   * free place, wherever nothing else has it. */
  const add_game_keys = (keys, hotkeys) => {
    for (const [code, button] of game.keys) {
      if (!page_console_has(button)) continue;
      if (console_buttons.some((each) => keys[each].includes(code)) || Object.values(hotkeys).includes(code)) continue;
      const slot = keys[button].indexOf(null);
      if (slot >= 0) keys[button][slot] = code;
    }
  };
  const add_game_pads = (pads) => {
    for (const [number, button] of game.pads) {
      if (!page_console_has(button)) continue;
      if (console_buttons.some((each) => pads[each].includes(number))) continue;
      const slot = pads[button].indexOf(null);
      if (slot >= 0) pads[button][slot] = number;
    }
  };
  /* VBlank's keys, every button's, from PAGE_KEYS. */
  const layout_keys = () => {
    const keys = {};
    for (const button of PAGE_BUTTONS) keys[button] = [null, null];
    for (const [code, button] of Object.entries(PAGE_KEYS)) keys[button][keys[button][0] === null ? 0 : 1] = code;
    return keys;
  };
  const starting_pads = () => {
    const pads = Object.fromEntries(PAGE_PAD_BUTTONS.map(([number, button]) => [button, [number, null]]));
    add_game_pads(pads);
    return pads;
  };
  const starting_hotkeys = () => Object.fromEntries(PAGE_HOTKEYS.map((name, at) => [name, PAGE_HOTKEY_KEYS[at]]));
  const starting_keys = (hotkeys) => {
    const keys = layout_keys();
    add_game_keys(keys, hotkeys);
    return keys;
  };

  const now = { fast_forward_speed: 4, volume: 100, muted: false, frame_rate: false, frame_time: false, fullscreen: false,
    keys: starting_keys(starting_hotkeys()), pads: starting_pads(), hotkeys: starting_hotkeys() };
  let notice = null;
  let waiting = null;

  /* What was kept, read over the starting values, and what of it could not be used, a sentence each,
   * as Live::Settings#read gives what a settings file holds that it cannot use. A setting it cannot use
   * keeps its starting value. */
  function read_kept() {
    if (!storage) return [];
    const problems = [];
    const written = (value) => JSON.stringify(value);
    let kept = {};
    try {
      kept = JSON.parse(storage.getItem(PAGE_SETTINGS_KEY) || "{}");
    } catch (error) {
      kept = null;
    }
    if (kept === null || typeof kept !== "object" || Array.isArray(kept)) {
      problems.push("The stored settings are not in a form the page can read. The page uses its starting settings.");
      kept = {};
    }
    const read_number = (name, least, most) => {
      if (!(name in kept)) return;
      if (Number.isInteger(kept[name]) && kept[name] >= least && kept[name] <= most) now[name] = kept[name];
      else problems.push(`${name} is a whole number from ${least} to ${most}, not ${written(kept[name])}.`);
    };
    const read_flag = (name) => {
      if (!(name in kept)) return;
      if (typeof kept[name] === "boolean") now[name] = kept[name];
      else problems.push(`${name} is on or off, not ${written(kept[name])}.`);
    };
    read_number("fast_forward_speed", 2, 8);
    read_number("volume", 0, 100);
    for (const name of ["muted", "frame_rate", "frame_time"]) read_flag(name);
    /* The keys, controller buttons or hotkeys as a whole: one by its button or hotkey's name, or none. */
    const read_group = (name, what) => {
      const group = kept[name];
      if (group === undefined || (typeof group === "object" && group !== null && !Array.isArray(group))) return group || {};
      problems.push(`${name} is ${what} by name, not ${written(group)}, so all of them stay as they were.`);
      return {};
    };
    const keys = read_group("keys", "the keys of each button");
    const pads = read_group("pads", "the controller buttons of each button");
    for (const button of PAGE_BUTTONS) {
      const name = RG_PAGE_MENU.buttons[PAGE_BUTTONS.indexOf(button)];
      const codes = keys[button];
      if (Array.isArray(codes) && codes.every((code) => code === null || typeof code === "string")) {
        now.keys[button] = codes.slice(0, PAGE_KEYS_A_BUTTON).concat([null]).slice(0, PAGE_KEYS_A_BUTTON);
      } else if (button in keys) {
        problems.push(`keys.${button} is a list of keys, not ${written(codes)}, so ${name} keeps the keys it had.`);
      }
      /* A page kept one controller button for each before a button could have two. */
      const numbers = pads[button];
      if (Number.isInteger(numbers)) now.pads[button] = [numbers, null];
      else if (Array.isArray(numbers) && Number.isInteger(numbers[0])) now.pads[button] = [numbers[0], Number.isInteger(numbers[1]) ? numbers[1] : null];
      else if (button in pads) problems.push(`pads.${button} is a list of controller buttons, not ${written(numbers)}, so ${name} keeps the ones it had.`);
    }
    const hotkeys = read_group("hotkeys", "the key of each hotkey");
    for (const hotkey of PAGE_HOTKEYS) {
      if (!(hotkey in hotkeys)) continue;
      if (hotkeys[hotkey] === null || typeof hotkeys[hotkey] === "string") now.hotkeys[hotkey] = hotkeys[hotkey];
      else problems.push(`hotkeys.${hotkey} is a key's name, not ${written(hotkeys[hotkey])}, so it keeps the key it had.`);
    }
    add_game_keys(now.keys, now.hotkeys);
    add_game_pads(now.pads);
    return problems;
  }

  /* What is kept: everything but the game's own keys and controller buttons. */
  function kept_settings() {
    const { fullscreen, ...kept } = now;
    const game_key = (button, code) => game.keys.some(([each, owner]) => each === code && owner === button);
    const game_pad = (button, number) => game.pads.some(([each, owner]) => each === number && owner === button);
    const keys = Object.fromEntries(PAGE_BUTTONS.map((button) => {
      const own = now.keys[button].filter((code) => code !== null && !game_key(button, code));
      return [button, own.concat([null, null]).slice(0, PAGE_KEYS_A_BUTTON)];
    }));
    const pads = Object.fromEntries(PAGE_BUTTONS.map((button) => {
      const [first, ...more] = now.pads[button];
      const own = more.filter((number) => number !== null && !game_pad(button, number));
      return [button, [first, ...own].concat([null]).slice(0, 2)];
    }));
    return { ...kept, keys, pads };
  }

  function write_kept() {
    on_change();
    if (!storage) return;
    try {
      storage.setItem(PAGE_SETTINGS_KEY, JSON.stringify(kept_settings()));
    } catch (error) {
      /* a browser that keeps nothing for this page plays on with what it has */
    }
  }

  const button_of_key = (code) => console_buttons.find((button) => now.keys[button].includes(code));
  const hotkey_of_key = (code) => PAGE_HOTKEYS.find((name) => now.hotkeys[name] === code);

  /* Why +code+ cannot be given to the button or hotkey asking, written in the notice, or null. */
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

  /* The button's first controller button. One another console button has as its first swaps with
   * it; one another has as its second is taken off it. */
  function bind_pad(button, number) {
    const was = now.pads[button][0];
    for (const each of console_buttons) {
      if (each !== button && now.pads[each][0] === number) now.pads[each][0] = was;
      if (now.pads[each][1] === number) now.pads[each][1] = null;
    }
    now.pads[button][0] = number;
    notice = null;
    write_kept();
  }

  return {
    now, read_kept, write_kept, button_of_key, hotkey_of_key,
    get notice() { return notice; },
    capture_for_button(place) { notice = null; waiting = ["button", place]; },
    capture_for_hotkey(place) { notice = null; waiting = ["hotkey", place]; },
    capture_cancel() { waiting = null; },
    /* Something the window did on its own (a state saved or refused), written in the notice the menu shows. */
    say(words) { notice = words; },
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
      const keys = layout_keys();
      add_game_keys(keys, now.hotkeys);
      const kept_by_hotkey = [];
      for (const button of console_buttons) {
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
      const pads = now.pads[button].filter((number) => number !== null).map((number) => PAGE_PAD_NAMES[number] || number);
      return `${keys.length ? keys.join(", ") : "none"} / ${pads.join(", ")}`;
    },
    hotkey_text(place) { return page_key_name(now.hotkeys[PAGE_HOTKEYS[place]]); },
  };
}

/* How the menu behaves: Live::Menu. +does+ names what the page does for a line: fullscreen, quit, and for save
 * states +state(action, slot)+ (action "save" or "load", slot 0 the quick one) and +state_text(slot)+, the words
 * for a slot. A page with no storage gives no state_text, and has no Save or Load heading. */
function page_menu(settings, does) {
  const headings = does.state_text ? RG_PAGE_MENU.headings : RG_PAGE_MENU.headings.filter((heading) => !heading.states);
  let open = false, heading = 0, row = -1;
  /* The window of the game's variables (Live::WindowMenu::VARIABLE_ROWS): whether it is open, the
   * letters typed into it, and the first of the lines it finds that it shows. */
  let variables_open = false, filter = "", variables_scroll = 0;
  /* What the page could not use of what it kept, shown over the picture until a button answers it. */
  let problems = null;

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
    else if (line.kind === "state") {
      does.state(line.action, line.place);
      open = false;
    } else if (line.does === "variables") {
      /* The window opened or shut from its line, and the menu closed so the game plays under it. */
      variables_open = !variables_open;
      open = false;
    } else if (line.does === "resume") open = false;
    else if (line.does === "quit") does.quit();
    else if (line.does === "reset_keys") settings.reset_keys();
    else if (line.does === "reset_hotkeys") settings.reset_hotkeys();
  }
  function right_of(line) {
    if (line.kind === "button" || line.kind === "hotkey") {
      if (settings.capture_place(line.kind) === line.place) return settings.capture_prompt;
      return line.kind === "button" ? settings.button_text(line.place) : settings.hotkey_text(line.place);
    }
    if (line.kind === "state") return line.shortcut || does.state_text(line.place);
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
    get variables_open() { return variables_open; },
    /* Up, down or close, pressed while the window of variables is open and the menu is not: up and
     * down scroll it a line, and close shuts it. Gives whether the key was the window's. */
    press_on_variables(key) {
      if (!variables_open || open) return false;
      if (key === "up") variables_scroll = Math.max(variables_scroll - 1, 0);
      else if (key === "down") variables_scroll += 1;
      else if (key === "close") variables_open = false;
      else return false;
      return true;
    },
    /* A key (the browser's name for it) pressed while the window of variables is open and the menu is
     * not: a letter, digit or underscore goes on the end of what the window finds, and Backspace takes
     * the last off. Gives whether the key was the window's. */
    type_key(code) {
      if (!variables_open || open) return false;
      if (code === "Backspace") {
        filter = filter.slice(0, -1);
      } else {
        const letter = page_typed_letter(code);
        if (letter === null) return false;
        if (filter.length < RG_PAGE_MENU.filter_most) filter += letter;
      }
      variables_scroll = 0;
      return true;
    },
    /* What the page could not use of what it kept, as lines of words, or none. */
    set problems(lines) { problems = lines.length ? lines.join("\n") : null; },
    /* A console button was pressed: what was shown over the picture has been seen. */
    answer_messages() { problems = null; },
    get messages_shown() { return problems !== null; },
    /* What the menu shows, for page_menu_draw and for a test: the menu's own lines, and what is over
     * the game besides (+over+, every word in the order Live::Menu#drawing writes them). */
    get shown() {
      const variables = variables_open ? variables_shown(does.variables()) : null;
      const status = does.status();
      const message = problems === null ? null
        : { title: RG_PAGE_MENU.problems.title, texts: [RG_PAGE_MENU.problems.intro, problems], close: RG_PAGE_MENU.problems.close };
      const over = [];
      if (variables) over.push(variables.title, variables.filter, "Name", "Value", ...variables.rows.flat(), variables.footer);
      over.push(...status);
      if (message) over.push(message.title, ...message.texts, "OK", message.close);
      return { open, heading: open ? headings[heading].name : null, chosen: open && row >= 0 ? lines()[row].label : null,
        headings: headings.map((each) => each.name), lines: lines().map((line) => [line.label, right_of(line)]), row, notice: settings.notice,
        variables, status, message, over, frame_work: does.frame_work() };
    },
  };

  /* The window of variables as Live::Menu#draw_variables words it: the lines the letters typed find,
   * from the one scrolled to, and which lines those are. +read+ is the game's variables, name and
   * value pairs. */
  function variables_shown(read) {
    const rows = RG_PAGE_MENU.variable_rows;
    const found = read.filter(([name]) => name.toLowerCase().includes(filter));
    variables_scroll = Math.min(Math.max(variables_scroll, 0), Math.max(found.length - rows, 0));
    let footer = filter === "" ? "No variables" : "No name has these letters";
    if (found.length) footer = `${variables_scroll + 1} to ${Math.min(variables_scroll + rows, found.length)} of ${found.length}`;
    return { title: "Game variables", filter: filter === "" ? "Type letters to find a name" : filter, typed: filter !== "",
      rows: found.slice(variables_scroll, variables_scroll + rows).map(([name, value]) => [name, String(value)]), footer };
  }
}

/* The letter a key types into the window of variables (Live::WindowMenu.typed_letter), or null: A to Z,
 * the digits, and the key with the minus on it for the underscore names are written with. */
function page_typed_letter(code) {
  if (/^Key[A-Z]$/.test(code)) return code.slice(3).toLowerCase();
  if (/^Digit[0-9]$/.test(code)) return code.slice(5);
  return code === "Minus" ? "_" : null;
}

/* The part of the page that shows the menu and what the page is doing, over the canvas: made when
 * first needed, on a page with a document to make one in. */
function page_menu_draw(canvas, menu) {
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
  const top = shown.open ? 30 : 8;
  const framed = `background:${colors.box};border:1px solid ${colors.border};border-radius:4px;padding:8px`;
  if (shown.variables) {
    const words = shown.variables;
    const box = add(over, `position:absolute;left:8px;top:${top}px;min-width:260px;${framed}`);
    add(box, "", words.title);
    add(box, `color:${words.typed ? "inherit" : colors.dim}`, words.filter);
    const table = add(box, `display:grid;grid-template-columns:1fr auto;column-gap:30px;margin-top:4px;min-height:${(RG_PAGE_MENU.variable_rows + 1) * 18}px;align-content:start`);
    add(table, `color:${colors.dim};border-bottom:1px solid ${colors.border}`, "Name");
    add(table, `color:${colors.dim};border-bottom:1px solid ${colors.border};text-align:right`, "Value");
    for (const [name, value] of words.rows) {
      add(table, "", name);
      add(table, "text-align:right;font-variant-numeric:tabular-nums", value);
    }
    add(box, `color:${colors.dim}`, words.footer);
  }
  if (shown.status.length) {
    add(over, `position:absolute;right:8px;top:${top}px;padding:8px;background:${colors.status};border-radius:4px`, shown.status.join(" · "));
  }
  if (shown.message) {
    const message = shown.message;
    const box = add(over, `position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);width:min(520px,calc(100% - 16px));box-sizing:border-box;${framed}`);
    add(box, "", message.title);
    message.texts.forEach((text, index) => {
      add(box, `white-space:pre-wrap;overflow-wrap:anywhere;${index ? `border-top:1px solid ${colors.border};margin-top:4px;padding-top:4px` : ""}`, text);
    });
    const answer = add(box, "display:flex;flex-wrap:wrap;align-items:center;gap:8px;margin-top:6px");
    add(answer, `padding:1px 8px;border-radius:3px;background:${colors.chosen}`, "OK");
    add(answer, `color:${colors.dim}`, message.close);
  }
  if (shown.open) {
    const bar = add(over, `position:relative;display:flex;gap:14px;padding:3px 8px;background:${colors.bar}`);
    for (const name of shown.headings) {
      add(bar, `padding:0 4px;background:${name === shown.heading ? (shown.chosen ? colors.open : colors.chosen) : "none"}`, name);
    }
    const box = add(over, `position:relative;display:inline-block;padding:8px;min-width:200px;background:${colors.box};border:1px solid ${colors.border};border-radius:4px`);
    shown.lines.forEach(([label, right], index) => {
      const row = add(box, `display:flex;justify-content:space-between;gap:30px;padding:2px 4px;border-radius:3px;background:${index === shown.row ? colors.chosen : "none"}`);
      add(row, "", label);
      add(row, `color:${colors.dim}`, right);
    });
    if (shown.notice) add(box, `color:${colors.paused};max-width:480px`, shown.notice);
  }
}
