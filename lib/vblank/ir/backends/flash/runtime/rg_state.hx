/*
 * The state image, as the native runtime's rg_state.c writes and reads it: one line a field, "name", a tab, the count and
 * then the numbers, all as decimal whole numbers, a run of one number as one word "times*number". Writing visits every
 * field and prints it; reading visits every field again with the image's numbers to hand. The same text is written and
 * read by every build, so a state from one reads in another. A port of the JavaScript runtime's rg_state.js.
 *
 * The numbers a field holds are floats where a whole number may pass 32 bits (a clock's seconds, how far a timer has
 * ticked), and ints otherwise: rg_state_numbers takes the one, rg_state_float_numbers the other.
 */

static var rg_state_lines:Array<String> = null;   /* the lines of the image being written, while one is */
static var rg_state_fields:Map<String, RgStateField> = null; /* the image being read: name to its numbers, while one is */

static function rg_state_visit_all():Void {
  rg_game_visit_state();
  rg_runtime_visit_state();
  rg_save_visit_state();
  rg_screen_visit_state();
  rg_sound_visit_state();
}

static function rg_state_reading():Bool { return rg_state_fields != null; }

/* The whole state as text. */
static function rg_state_write():String {
  rg_state_lines = ["vblank-state " + RG_STATE_VERSION + "\n", "build " + RG_GAME_CONSOLE + " " + RG_GAME_BUILD + "\n"];
  var text = "";
  try {
    rg_state_visit_all();
    text = rg_state_lines.join("");
  } catch (stopped:Dynamic) {
    rg_state_lines = null;
    throw stopped;
  }
  rg_state_lines = null;
  return text;
}

static inline var RG_STATE_SHORTEST_RUN:Int = 4; /* the shortest run of one number written as "times*number" (rg_state.h) */

static var state_whole:EReg = ~/^\d+$/;
static var state_run:EReg = ~/^(\d+)\*(-?\d+)$/;
static var state_number:EReg = ~/^-?\d+$/;
static var state_spaces:EReg = ~/\s+/g; // with the g, split cuts at every match and not the first alone
static var state_version_line:EReg = ~/^vblank-state (\d+)$/;
static var state_build_line:EReg = ~/^build (\S+) (\S+)$/;

/* One line, "name<TAB>count n1 n2 ...", as a field; null for one that is not. A word "times*number" is a run of one
 * number. */
static function rg_state_parse_line(line:String):RgStateField {
  var tab = line.indexOf("\t");
  if (tab < 0) return null;
  var words = state_spaces.split(StringTools.trim(line.substr(tab + 1)));
  if (!state_whole.match(words[0])) return null;
  var count = Std.parseInt(words[0]);
  var values:Array<Float> = [];
  for (at in 1...words.length) {
    var word = words[at];
    if (state_run.match(word)) {
      var times = Std.parseInt(state_run.matched(1));
      var value = Std.parseFloat(state_run.matched(2));
      if (times < 1 || values.length + times > count) return null;
      for (i in 0...times) values.push(value);
    } else if (state_number.match(word)) {
      values.push(Std.parseFloat(word));
    } else {
      return null;
    }
  }
  if (values.length != count) return null;
  return new RgStateField(line.substr(0, tab), count, values);
}

/* The numbers of a field as the words of its line: a run of RG_STATE_SHORTEST_RUN or more as one. */
static function rg_state_words(values:Array<Float>):Array<String> {
  var words:Array<String> = [];
  var i = 0;
  while (i < values.length) {
    var run = 1;
    while (i + run < values.length && values[i + run] == values[i]) run++;
    if (run >= RG_STATE_SHORTEST_RUN) {
      words.push(run + "*" + Std.string(values[i]));
      i += run;
    } else {
      words.push(Std.string(values[i]));
      i++;
    }
  }
  return words;
}

/* Stops the game saying the image is damaged, and what is wrong with it. */
static function rg_state_refuse_damaged(what:String):Void {
  rg_fault("This state is damaged: " + what + ". Load a state that this game wrote.");
}

/* The file's two first lines (Computer::StateFile): its version, then the build that wrote it, each refused in plain words
 * when it is not this build's (rg_state.c's image_after_header). Gives back the image's lines. */
static function rg_state_image_after_header(lines:Array<String>):Array<String> {
  var first = lines.length > 0 ? lines[0] : "";
  if (!state_version_line.match(first)) rg_fault("This is not a save state: it does not start with \"vblank-state\". Load a state that this game wrote.");
  var version = Std.parseInt(state_version_line.matched(1));
  if (version != RG_STATE_VERSION) {
    rg_fault("This state is version " + state_version_line.matched(1) + " of the save-state format, and this build reads version " + RG_STATE_VERSION + ". Load a state that this build wrote.");
  }
  var second = lines.length > 1 ? lines[1] : "";
  if (!state_build_line.match(second)) rg_fault("This state is damaged: its second line does not name the build that saved it. Load a state that this game wrote.");
  var console = state_build_line.matched(1);
  var build = state_build_line.matched(2);
  if (console != RG_GAME_CONSOLE || build != RG_GAME_BUILD) {
    rg_fault("This state is for another build of the game: build " + build.substr(0, 8) + " for the " + console + " saved it, and this is build " + RG_GAME_BUILD.substr(0, 8) + " for the " + RG_GAME_CONSOLE + ". Load a state that this build saved.");
  }
  return lines.slice(2);
}

/* The words for why +text+ cannot be read by this build (not a state, another version, another build), or null when its
 * first two lines are this build's. Changes nothing, so a page asks before it reads, and tells the player instead of
 * stopping the game. */
static function rg_state_header_problem(text:String):String {
  try {
    rg_state_image_after_header(text.split("\n"));
  } catch (stopped:RgStopped) {
    return stopped.message;
  }
  return null;
}

/* Puts +text+ back into the game and the runtime, field by field. */
static function rg_state_read(text:String):Void {
  var fields = new Map<String, RgStateField>();
  var order:Array<String> = [];
  for (line in rg_state_image_after_header(text.split("\n"))) {
    if (line == "") continue;
    var parsed = rg_state_parse_line(line);
    if (parsed == null || fields.exists(parsed.name)) rg_state_refuse_damaged("a line is not a name, a tab, a count and numbers");
    fields.set(parsed.name, parsed);
    order.push(parsed.name);
  }
  rg_state_fields = fields;
  try {
    rg_state_visit_all();
    for (name in order) {
      if (!fields.get(name).taken) rg_fault("This state is for another game: it holds \"" + name + "\", and this game has none. Load a state that this game wrote.");
    }
  } catch (stopped:Dynamic) {
    rg_state_fields = null;
    throw stopped;
  }
  rg_state_fields = null;
}

/* The image's field +name+, holding +count+ numbers. */
static function rg_state_field_named(name:String, count:Int):RgStateField {
  var field = rg_state_fields.get(name);
  if (field == null) rg_fault("This state is for another game: it has no \"" + name + "\". Load a state that this game wrote.");
  if (field.count != count) {
    rg_fault("This state is for another game: it holds " + field.count + " numbers for \"" + name + "\", and this game keeps " + count + ". Load a state that this game wrote.");
  }
  field.taken = true;
  return field;
}

/* A field of +values+ (whole numbers that may pass 32 bits): written as it stands, or overwritten from the image. */
static function rg_state_float_numbers(name:String, values:Array<Float>):Void {
  if (rg_state_lines != null) {
    var words = rg_state_words(values);
    words.unshift(Std.string(values.length));
    rg_state_lines.push(name + "\t" + words.join(" ") + "\n");
    return;
  }
  var field = rg_state_field_named(name, values.length);
  for (i in 0...values.length) values[i] = field.values[i];
}

/* A field of +values+ (whole numbers of 32 bits): written as it stands, or overwritten from the image. */
static function rg_state_numbers(name:String, values:Array<Int>):Void {
  var held:Array<Float> = [for (value in values) value];
  rg_state_float_numbers(name, held);
  for (i in 0...values.length) values[i] = Std.int(held[i]);
}

/* The first +count+ cells of +cells+ as a field. */
static function rg_state_cells(name:String, cells:Vector<Int>, count:Int):Void {
  var values:Array<Int> = [for (i in 0...count) cells[i]];
  rg_state_numbers(name, values);
  for (i in 0...count) cells[i] = values[i];
}

/* A field of one number: the number to keep, or the image's. */
static function rg_state_number(name:String, value:Int):Int {
  var held:Array<Int> = [value];
  rg_state_numbers(name, held);
  return held[0];
}

/* Where the oldest item is and how many there are, then every slot, used or not: the ring as it stands, so the game's
 * next push and shift land where they would have. */
static function rg_state_list(name:String, list:RgList):Void {
  var values:Array<Int> = [list.front, list.length];
  for (i in 0...list.capacity) values.push(list.items[i]);
  rg_state_numbers(name, values);
  if (values[0] < 0 || values[0] >= (list.capacity > 1 ? list.capacity : 1) || values[1] < 0 || values[1] > list.capacity) {
    rg_fault("This state is damaged: the list \"" + name + "\" has a place outside its " + list.capacity + " slots. Load a state that this game wrote.");
  }
  list.front = values[0];
  list.length = values[1];
  /* A narrow list keeps each number's low bits itself (rg_list.hx). */
  for (i in 0...list.capacity) list.items[i] = rg_list_slot_value(list, values[i + 2]);
}

/* What is not kept in a state image yet: stops the game in plain words if anything reaches it. */
static function rg_state_refuse():Void {
  rg_fault("the Flash build does not write or read this part of a state image yet");
}
