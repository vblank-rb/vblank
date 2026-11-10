/*
 * THE STATE IMAGE, as the native runtime's rg_state.c writes and reads it: one line a field, "name",
 * a tab, the count and then the numbers, all as decimal whole numbers. Writing visits every field and
 * prints it; reading visits every field again with the image's numbers to hand. The same text is
 * written and read by the C, JavaScript and Ruby builds, so a state from one reads in another.
 */

let rg_state_lines = null;   /* the lines of the image being written, while one is */
let rg_state_fields = null;  /* the image being read: name to { count, values, taken }, while one is */

function rg_state_visit_all() {
  rg_game_visit_state();
  rg_runtime_visit_state();
  rg_save_visit_state();
}

function rg_state_reading() { return rg_state_fields !== null; }

/* The whole state as text. */
function rg_state_write() {
  rg_state_lines = [];
  try {
    rg_state_visit_all();
    return rg_state_lines.join("");
  } finally {
    rg_state_lines = null;
  }
}

/* One line, "name<TAB>count n1 n2 ...", as [name, count, numbers]; null for one that is not. */
function rg_state_parse_line(line) {
  const tab = line.indexOf("\t");
  if (tab < 0) return null;
  const words = line.slice(tab + 1).trim().split(/\s+/);
  if (!words.every((word) => /^-?\d+$/.test(word))) return null;
  const count = Number(words[0]);
  if (count < 0 || words.length !== count + 1) return null;
  return [line.slice(0, tab), count, words.slice(1).map(Number)];
}

/* Puts +text+ back into the game and the runtime, field by field. */
function rg_state_read(text) {
  const fields = new Map();
  for (const line of text.split("\n")) {
    if (line === "") continue;
    const parsed = rg_state_parse_line(line);
    if (parsed === null || fields.has(parsed[0])) {
      rg_fault("This state is damaged: a line is not a name, a tab, a count and numbers. Load a state that this game wrote.");
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
    rg_state_lines.push(`${name}\t${values.length} ${values.join(" ")}`.trimEnd() + "\n");
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
