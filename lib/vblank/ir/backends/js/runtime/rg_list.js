/*
 * A game's list (`list :trail, capacity: 64`), as the native runtime's rg_list.h keeps one: the
 * items in an array as long as the capacity, used as a ring, so dropping the oldest moves where
 * the front is rather than every item. A narrow list keeps each number's low bits, so 200 in a
 * byte reads back as -56. What the interpreter refuses stops the game with the same words.
 *
 * Each item takes the room its width says, as rg_list.h keeps it: a list of bytes is an
 * Int8Array, a byte an item, so a port's pack of hundreds of megabytes costs its own size in the
 * browser and not four times it (a typed array that big can be refused outright). A typed array
 * keeps the low bits of a number put in it and reads them back sign and all, which is what
 * rg_to_byte and rg_to_half do, so nothing here fits a number to its slot.
 */

/* What keeps a list's items, by how many bytes a slot takes. */
const RG_LIST_ITEM_ARRAYS = { 1: Int8Array, 2: Int16Array, 4: Int32Array };

function rg_list_new(capacity, width, name) {
  return { items: new RG_LIST_ITEM_ARRAYS[width](Math.max(capacity, 1)), capacity, width, front: 0, length: 0, name };
}

/* Where item +index+ sits in the ring. */
function rg_list_slot(list, index) { return (list.front + index) % list.capacity; }

function rg_list_check_index(list, index) {
  if (index >= 0 && index < list.length) return;
  if (list.length === 0) rg_fault(`index ${index} is out of range: list :${list.name} is empty`);
  rg_fault(`index ${index} is out of range for list :${list.name} (valid indexes are 0..${list.length - 1})`);
}

/* A list declared where the program reaches it starts again, empty. */
function rg_list_empty(list) {
  list.front = 0;
  list.length = 0;
}

/* ...or, declared full of a value (`full_of:`), starts again holding its capacity of it. */
function rg_list_full(list, value) {
  list.front = 0;
  list.length = list.capacity;
  list.items.fill(value, 0, list.capacity);
}

function rg_list_length(list) { return list.length; }

function rg_list_push(list, value) {
  if (list.length >= list.capacity) {
    rg_fault(`list :${list.name} is full (capacity ${list.capacity}): drop an item first, or give it a larger capacity`);
  }
  list.items[rg_list_slot(list, list.length)] = value;
  list.length++;
}

/* Drops the oldest item (+front+ not nought) or the newest. */
function rg_list_drop(list, front) {
  if (list.length === 0) rg_fault(`list :${list.name} is empty: there is nothing to ${front ? "shift" : "pop"}`);
  if (front) list.front = rg_list_slot(list, 1);
  list.length--;
}

/* One item read or written, the check and the ring's slot in one function with no remainder: the
 * front and the index are each inside the capacity, so their sum is past it by less than a
 * capacity, and one subtraction comes round. A routine that loops over a list by an index it works
 * out reads it on every turn, and a printed routine long enough that V8 calls these rather than
 * putting them in place paid a divide at each. */
function rg_list_get(list, index) {
  if (index >= 0 && index < list.length) {
    const slot = list.front + index;
    return list.items[slot < list.capacity ? slot : slot - list.capacity];
  }
  rg_list_check_index(list, index);
}

/* The index of a list read the printer writes in place (JS::Printer#list_read_in_place), and the
 * fault it stops the game with when the index is outside the list. */
let rg_list_at = 0;
function rg_list_index_fault_at(list, index) { rg_list_check_index(list, index); }

function rg_list_set(list, index, value) {
  if (index >= 0 && index < list.length) {
    const slot = list.front + index;
    list.items[slot < list.capacity ? slot : slot - list.capacity] = value;
    return;
  }
  rg_list_check_index(list, index);
}

/* Every item from +from+ for +count+ items set to +value+; both ends checked before anything is
 * written. */
function rg_list_fill(list, from, count, value) {
  if (count <= 0) return;
  rg_list_check_index(list, from);
  rg_list_check_index(list, rg_add(from, count - 1));
  for (let i = 0; i < count; i++) list.items[rg_list_slot(list, from + i)] = value;
}

/* Every item put in order by the number +by+ holds at it, the smallest first (the biggest when
 * +descending+), as rg_list.h's rg_list_sort: an insertion sort, moving an item back only past a
 * number strictly beyond its own, so level items keep their order. */
function rg_list_sort(list, by, descending) {
  for (let at = 1; at < list.length; at++) {
    const item = list.items[rg_list_slot(list, at)];
    const key = rg_list_get(by, item);
    let to = at;
    while (to > 0) {
      const before = list.items[rg_list_slot(list, to - 1)];
      const other = rg_list_get(by, before);
      if (descending ? other >= key : other <= key) break;
      list.items[rg_list_slot(list, to)] = before;
      to--;
    }
    list.items[rg_list_slot(list, to)] = item;
  }
}

/* rg_list_sort with +shown+, 1 at each place of +by+ whose item shows, as rg_list.h's
 * rg_list_sort_shown: an item not showing goes behind every item showing, keeping the order the
 * items not showing stood in. */
function rg_list_sort_shown(list, by, descending, shown) {
  for (let at = 1; at < list.length; at++) {
    const item = list.items[rg_list_slot(list, at)];
    const showing = shown[item] === 1;
    const key = showing ? rg_list_get(by, item) : 0;
    let to = at;
    while (to > 0) {
      const before = list.items[rg_list_slot(list, to - 1)];
      if (shown[before] !== 1) break;
      if (showing) {
        const other = rg_list_get(by, before);
        if (descending ? other >= key : other <= key) break;
      }
      list.items[rg_list_slot(list, to)] = before;
      to--;
    }
    list.items[rg_list_slot(list, to)] = item;
  }
}

/* How a table's entries are kept. Each table is a typed array of the width the game declared, so
 * reading an entry already gives the whole number, and the kind is only checked. */
const RG_TABLE_INT8 = 0, RG_TABLE_UINT8 = 1, RG_TABLE_INT16 = 2, RG_TABLE_UINT16 = 3, RG_TABLE_INT32 = 4;

/* The list made to hold exactly +count+ entries of a table, from entry +at+ on, held so the whole
 * run is inside the table. */
function rg_list_copy(list, table, kept, table_length, at, count) {
  if (count > list.capacity) rg_fault(`a copy of ${count} entries does not fit list :${list.name} (capacity ${list.capacity})`);
  if (count > table_length) rg_fault(`a copy of ${count} entries is longer than its table (${table_length} entries)`);
  const start = rg_clamp(at, 0, table_length - count);
  list.front = 0;
  list.length = count;
  for (let i = 0; i < count; i++) list.items[i] = table[start + i];
}
