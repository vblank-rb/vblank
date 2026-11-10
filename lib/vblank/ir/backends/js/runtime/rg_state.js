/*
 * THE STATE IMAGE, as the native runtime's rg_state.c writes and reads it: one line a field, "name",
 * a tab, the count and then the numbers, all as decimal whole numbers, a run of one number as one word
 * "times*number". Writing visits every field and
 * prints it; reading visits every field again with the image's numbers to hand. The same text is
 * written and read by the C, JavaScript and Ruby builds, so a state from one reads in another.
 */

let rg_state_lines = null;   /* the lines of the image being written, while one is */
let rg_state_fields = null;  /* the image being read: name to { count, values, taken }, while one is */

function rg_state_visit_all() {
  rg_game_visit_state();
  rg_runtime_visit_state();
  rg_save_visit_state();
  rg_screen_visit_state();
  rg_sound_visit_state();
}

function rg_state_reading() { return rg_state_fields !== null; }

/* The whole state as text. */
function rg_state_write() {
  rg_state_lines = [`vblank-state ${RG_STATE_VERSION}\n`, `build ${RG_GAME_CONSOLE} ${RG_GAME_BUILD}\n`];
  try {
    rg_state_visit_all();
    return rg_state_lines.join("");
  } finally {
    rg_state_lines = null;
  }
}

const RG_STATE_SHORTEST_RUN = 4; /* the shortest run of one number written as "times*number" (rg_state.h) */

/* One line, "name<TAB>count n1 n2 ...", as [name, count, numbers]; null for one that is not. A word
 * "times*number" is a run of one number. */
function rg_state_parse_line(line) {
  const tab = line.indexOf("\t");
  if (tab < 0) return null;
  const words = line.slice(tab + 1).trim().split(/\s+/);
  if (!/^\d+$/.test(words[0])) return null;
  const count = Number(words[0]);
  const values = [];
  for (const word of words.slice(1)) {
    const run = /^(\d+)\*(-?\d+)$/.exec(word);
    if (run) {
      const times = Number(run[1]);
      if (times < 1 || values.length + times > count) return null;
      for (let i = 0; i < times; i++) values.push(Number(run[2]));
    } else if (/^-?\d+$/.test(word)) {
      values.push(Number(word));
    } else {
      return null;
    }
  }
  if (values.length !== count) return null;
  return [line.slice(0, tab), count, values];
}

/* The numbers of a field as the words of its line: a run of RG_STATE_SHORTEST_RUN or more as one. */
function rg_state_words(values) {
  const words = [];
  for (let i = 0; i < values.length;) {
    let run = 1;
    while (i + run < values.length && values[i + run] === values[i]) run++;
    if (run >= RG_STATE_SHORTEST_RUN) {
      words.push(`${run}*${values[i]}`);
      i += run;
    } else {
      words.push(String(values[i]));
      i++;
    }
  }
  return words;
}

/* Stops the game saying the image is damaged, and what is wrong with it. */
function rg_state_refuse_damaged(what) {
  rg_fault(`This state is damaged: ${what}. Load a state that this game wrote.`);
}

/* The file's two first lines (Computer::StateFile): its version, then the build that wrote it,
 * each refused in plain words when it is not this build's (rg_state.c's image_after_header). Gives
 * back the image's lines. */
function rg_state_image_after_header(lines) {
  const version = /^vblank-state (\d+)$/.exec(lines[0] || "");
  if (!version) rg_fault('This is not a save state: it does not start with "vblank-state". Load a state that this game wrote.');
  if (Number(version[1]) !== RG_STATE_VERSION) {
    rg_fault(`This state is version ${version[1]} of the save-state format, and this build reads version ${RG_STATE_VERSION}. Load a state that this build wrote.`);
  }
  const build = /^build (\S+) (\S+)$/.exec(lines[1] || "");
  if (!build) rg_fault("This state is damaged: its second line does not name the build that saved it. Load a state that this game wrote.");
  if (build[1] !== RG_GAME_CONSOLE || build[2] !== RG_GAME_BUILD) {
    rg_fault(`This state is for another build of the game: build ${build[2].slice(0, 8)} for the ${build[1]} saved it, and this is build ${RG_GAME_BUILD.slice(0, 8)} for the ${RG_GAME_CONSOLE}. Load a state that this build saved.`);
  }
  return lines.slice(2);
}

/* The words for why +text+ cannot be read by this build (not a state, another version, another
 * build), or null when its first two lines are this build's. Changes nothing, so a page asks
 * before it reads, and tells the player instead of stopping the game. */
function rg_state_header_problem(text) {
  try {
    rg_state_image_after_header(text.split("\n"));
    return null;
  } catch (error) {
    if (error instanceof RgStopped) return error.message;
    throw error;
  }
}

/* Puts +text+ back into the game and the runtime, field by field. */
function rg_state_read(text) {
  const fields = new Map();
  for (const line of rg_state_image_after_header(text.split("\n"))) {
    if (line === "") continue;
    const parsed = rg_state_parse_line(line);
    if (parsed === null || fields.has(parsed[0])) {
      rg_state_refuse_damaged("a line is not a name, a tab, a count and numbers");
    }
    fields.set(parsed[0], { count: parsed[1], values: parsed[2], taken: false });
  }
  rg_state_fields = fields;
  try {
    rg_state_visit_all();
    for (const [name, field] of fields) {
      if (!field.taken) rg_fault(`This state is for another game: it holds "${name}", and this game has none. Load a state that this game wrote.`);
    }
  } finally {
    rg_state_fields = null;
  }
}

/* The image's field +name+, holding +count+ numbers. */
function rg_state_field_named(name, count) {
  const field = rg_state_fields.get(name);
  if (field === undefined) {
    rg_fault(`This state is for another game: it has no "${name}". Load a state that this game wrote.`);
  }
  if (field.count !== count) {
    rg_fault(`This state is for another game: it holds ${field.count} numbers for "${name}", and this game keeps ${count}. Load a state that this game wrote.`);
  }
  field.taken = true;
  return field;
}

/* A field of +values+ (an array of whole numbers): written as it stands, or overwritten from the image. */
function rg_state_numbers(name, values) {
  if (rg_state_lines !== null) {
    rg_state_lines.push(`${name}\t${[values.length, ...rg_state_words(values)].join(" ")}\n`);
    return;
  }
  const field = rg_state_field_named(name, values.length);
  for (let i = 0; i < values.length; i++) values[i] = field.values[i];
}

/* A field of one number: the number to keep, or the image's. */
function rg_state_number(name, value) {
  const held = [value];
  rg_state_numbers(name, held);
  return held[0] | 0;
}

/* Where the oldest item is and how many there are, then every slot, used or not: the ring as it
 * stands, so the game's next push and shift land where they would have. */
function rg_state_list(name, list) {
  const values = [list.front, list.length, ...list.items.subarray(0, list.capacity)];
  rg_state_numbers(name, values);
  if (values[0] < 0 || values[0] >= Math.max(list.capacity, 1) || values[1] < 0 || values[1] > list.capacity) {
    rg_fault(`This state is damaged: the list "${name}" has a place outside its ${list.capacity} slots. Load a state that this game wrote.`);
  }
  list.front = values[0];
  list.length = values[1];
  for (let i = 0; i < list.capacity; i++) list.items[i] = rg_list_fit(list, values[i + 2]);
}
