/*
 * A game's list (`list :trail, capacity: 64`), as the JavaScript runtime's rg_list.js keeps one: the
 * items in an array as long as the capacity, used as a ring, so dropping the oldest moves where the front
 * is rather than every item. A narrow list keeps each number's low bits, so 200 in a byte reads back as
 * -56. What the interpreter refuses stops the game with the same words.
 */

static function rg_list_new(capacity:Int, width:Int, name:String):RgList {
  return new RgList(capacity, width, name);
}

/* A number as a slot of +list+ keeps it: its low bits, with the slot's top bit as the sign. */
static function rg_list_slot_value(list:RgList, value:Int):Int {
  return list.width == 1 ? rg_to_byte(value) : (list.width == 2 ? rg_to_half(value) : value);
}

/* Where item +index+ sits in the ring. */
static function rg_list_slot(list:RgList, index:Int):Int {
  return (list.front + index) % list.capacity;
}

static function rg_list_check_index(list:RgList, index:Int):Void {
  if (index >= 0 && index < list.length) return;
  if (list.length == 0) rg_fault("index " + index + " is out of range: list :" + list.name + " is empty");
  rg_fault("index " + index + " is out of range for list :" + list.name + " (valid indexes are 0.." + (list.length - 1) + ")");
}

/* A list declared with several capacities takes the one its declaration gives before it starts again. */
static function rg_list_set_capacity(list:RgList, capacity:Int):Void { list.capacity = capacity; }

/* A list declared where the program reaches it starts again, empty. */
static function rg_list_empty(list:RgList):Void {
  list.front = 0;
  list.length = 0;
}

/* ...or, declared full of a value (`full_of:`), starts again holding its capacity of it. */
static function rg_list_full(list:RgList, value:Int):Void {
  list.front = 0;
  list.length = list.capacity;
  var kept = rg_list_slot_value(list, value);
  for (i in 0...list.capacity) list.items[i] = kept;
}

static function rg_list_length(list:RgList):Int { return list.length; }

/* The game stops: +name+, holding +capacity+, is full (IR::Faults.list_full's words), or, +in_walk+ not
 * nought, full only of items a walk took out (IR::Faults.full_in_walk's). */
static function rg_stop_full(name:String, capacity:Int, in_walk:Int):Void {
  if (in_walk != 0) {
    rg_fault("`" + name + "` has no room yet: it has room for " + capacity + " items, and an item taken out inside a " +
      "walk of it gives its place back only when the walk ends. To fix this, add the new item after the walk, " +
      "or give it a larger capacity.");
  }
  rg_fault("`" + name + "` is full: it has room for " + capacity + " items, and a console cannot make it bigger. " +
    "To fix this, take an item out or test its size before you add one, or give it a larger capacity.");
}

static function rg_list_push(list:RgList, value:Int):Void {
  if (list.length >= list.capacity) rg_stop_full(list.name, list.capacity, 0);
  list.items[rg_list_slot(list, list.length)] = rg_list_slot_value(list, value);
  list.length++;
}

/* Drops the oldest item (+front+ not nought) or the newest. */
static function rg_list_drop(list:RgList, front:Int):Void {
  if (list.length == 0) rg_fault("list :" + list.name + " is empty: there is nothing to " + (front != 0 ? "shift" : "pop"));
  if (front != 0) list.front = rg_list_slot(list, 1);
  list.length--;
}

static function rg_list_get(list:RgList, index:Int):Int {
  if (index >= 0 && index < list.length) {
    var slot = list.front + index;
    return list.items[slot < list.capacity ? slot : slot - list.capacity];
  }
  rg_list_check_index(list, index);
  return 0;
}

static function rg_list_set(list:RgList, index:Int, value:Int):Void {
  if (index >= 0 && index < list.length) {
    var slot = list.front + index;
    list.items[slot < list.capacity ? slot : slot - list.capacity] = rg_list_slot_value(list, value);
    return;
  }
  rg_list_check_index(list, index);
}

/* Every item from +from+ for +count+ items set to +value+; both ends checked before anything is written. */
static function rg_list_fill(list:RgList, from:Int, count:Int, value:Int):Void {
  if (count <= 0) return;
  rg_list_check_index(list, from);
  rg_list_check_index(list, rg_add(from, count - 1));
  var kept = rg_list_slot_value(list, value);
  for (i in 0...count) list.items[rg_list_slot(list, from + i)] = kept;
}

/* Every item put in order by the number +by+ holds at it, the smallest first (the biggest when
 * +descending+): an insertion sort, moving an item back only past a number strictly beyond its own, so
 * level items keep their order. */
static function rg_list_sort(list:RgList, by:RgList, descending:Int):Void {
  for (at in 1...list.length) {
    var item = list.items[rg_list_slot(list, at)];
    var key = rg_list_get(by, item);
    var to = at;
    while (to > 0) {
      var before = list.items[rg_list_slot(list, to - 1)];
      var other = rg_list_get(by, before);
      if (descending != 0 ? other >= key : other <= key) break;
      list.items[rg_list_slot(list, to)] = before;
      to--;
    }
    list.items[rg_list_slot(list, to)] = item;
  }
}

/* rg_list_sort with +shown+, 1 at each place of +by+ whose item shows: an item not showing goes behind every
 * item showing, keeping the order the items not showing stood in. */
static function rg_list_sort_shown(list:RgList, by:RgList, descending:Int, shown:Vector<Int>):Void {
  for (at in 1...list.length) {
    var item = list.items[rg_list_slot(list, at)];
    var showing = shown[item] == 1;
    var key = showing ? rg_list_get(by, item) : 0;
    var to = at;
    while (to > 0) {
      var before = list.items[rg_list_slot(list, to - 1)];
      if (shown[before] != 1) break;
      if (showing) {
        var other = rg_list_get(by, before);
        if (descending != 0 ? other >= key : other <= key) break;
      }
      list.items[rg_list_slot(list, to)] = before;
      to--;
    }
    list.items[rg_list_slot(list, to)] = item;
  }
}

/* The list made to hold exactly +count+ entries of a table, from entry +at+ on, held so the whole run is
 * inside the table. */
static function rg_list_copy(list:RgList, table:Vector<Int>, kept:Int, table_length:Int, at:Int, count:Int):Void {
  if (count > list.capacity) rg_fault("a copy of " + count + " entries does not fit list :" + list.name + " (capacity " + list.capacity + ")");
  if (count > table_length) rg_fault("a copy of " + count + " entries is longer than its table (" + table_length + " entries)");
  var start = rg_clamp(at, 0, table_length - count);
  list.front = 0;
  list.length = count;
  for (i in 0...count) list.items[i] = rg_list_slot_value(list, table[start + i]);
}
