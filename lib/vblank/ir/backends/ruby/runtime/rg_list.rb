# A game's list (`list :trail, capacity: 64`): a row of numbers it pushes onto, drops from either
# end and reads by position. Pools are built out of these too, a list per field.
#
# The items sit in an array as long as the list's capacity, used as a ring: dropping the oldest
# item moves where the front is rather than moving every item along, which is also how the
# console keeps a list it shifts. A narrow list (`width: :byte` or `:half`) keeps each number the
# way the console's narrow stores do, so 200 in a byte reads back as -56.
#
# What the interpreter refuses — pushing onto a full list, dropping from an empty one, reading
# past the last item — stops the game with the interpreter's words, through rg_fault. A run that
# carried on past one of those would be answering a different question.
#
# A LIST OF BYTES (`width: :byte`) IS KEPT AS BYTES, an RgByteList over a binary String, one byte
# a slot. An Array keeps every item as a Ruby number of eight bytes, and a data pack's unpacking
# writes its whole pack into one list of bytes: a pack of hundreds of megabytes held that way
# would want gigabytes. The two classes answer the same few methods, so nothing else knows which
# it holds.

class RgList
  attr_reader :capacity, :width, :name
  attr_accessor :front, :length

  # The list for the build's ListStorage: kept as bytes when +width+ is 1.
  def self.build(capacity, width, name) = (width == 1 ? RgByteList : RgList).new(capacity, width, name)

  # +width+ is the bytes a slot takes, 1, 2 or 4; +name+ is the game's name for the list.
  def initialize(capacity, width, name)
    @items = blank_slots(capacity < 1 ? 1 : capacity)
    @capacity = capacity
    @width = width
    @name = name
    @front = 0
    @length = 0
  end

  # The number in ring slot +slot+, and setting it to +value+, already fitted to the width.
  def item(slot) = @items[slot]
  def set_item(slot, value) = (@items[slot] = value)

  # Every slot set to +value+, already fitted to the width.
  def fill_items(value) = @items.fill(value, 0, @capacity)

  # Every slot as the ring stands, used or not.
  def slots = @items.first(@capacity)

  # The items oldest first, the order the game reads them in.
  def items_in_order = Array.new(@length) { |i| item((@front + i) % @capacity) }

  # The items oldest first for a snapshot of the game's state (rg_live_state): numbers, or with
  # +packed+ a list of bytes gives them as a binary String instead.
  def items_for_state(_packed) = items_in_order

  private

  # +count+ slots holding nought, as this list keeps them.
  def blank_slots(count) = Array.new(count, 0)
end

# A list of bytes (`width: :byte`), its slots one byte each of a binary String, read back signed.
class RgByteList < RgList
  def item(slot)
    byte = @items.getbyte(slot)
    byte >= 0x80 ? byte - 0x100 : byte
  end

  def set_item(slot, value) = @items.setbyte(slot, value)
  def fill_items(value) = @items.replace((value & 0xFF).chr * @items.bytesize)
  def slots = Array.new(@capacity) { |slot| item(slot) }

  # The items oldest first as a binary String, a byte each: what the build keeps of a data pack.
  def bytes_in_order
    ends_at = @front + @length
    return @items.byteslice(@front, @length) if ends_at <= @capacity

    @items.byteslice(@front, @capacity - @front) + @items.byteslice(0, ends_at - @capacity)
  end

  def items_for_state(packed) = packed ? bytes_in_order : items_in_order

  private

  def blank_slots(count) = "\0".b * count
end

def rg_list_fit(list, value)
  return rg_to_byte(value) if list.width == 1
  return rg_to_half(value) if list.width == 2

  value
end

# Where item +index+ sits in the ring.
def rg_list_slot(list, index) = (list.front + index) % list.capacity

def rg_list_check_index(list, index)
  return if index >= 0 && index < list.length

  rg_fault("index #{index} is out of range: list :#{list.name} is empty") if list.length == 0
  rg_fault("index #{index} is out of range for list :#{list.name} (valid indexes are 0..#{list.length - 1})")
end

# A list declared where the program reaches it starts again, empty.
def rg_list_empty(list)
  list.front = 0
  list.length = 0
end

# ...or, declared full of a value (`full_of:`), starts again holding its capacity of it.
def rg_list_full(list, value)
  list.front = 0
  list.length = list.capacity
  list.fill_items(rg_list_fit(list, value))
end

def rg_list_length(list) = list.length

def rg_list_push(list, value)
  if list.length >= list.capacity
    rg_fault("list :#{list.name} is full (capacity #{list.capacity}): drop an item first, or give it a larger capacity")
  end
  list.set_item(rg_list_slot(list, list.length), rg_list_fit(list, value))
  list.length += 1
end

# Drops the oldest item (+front+ not nought) or the newest.
def rg_list_drop(list, front)
  rg_fault("list :#{list.name} is empty: there is nothing to #{front != 0 ? 'shift' : 'pop'}") if list.length == 0
  list.front = rg_list_slot(list, 1) if front != 0
  list.length -= 1
end

def rg_list_get(list, index)
  rg_list_check_index(list, index)
  list.item(rg_list_slot(list, index))
end

def rg_list_set(list, index, value)
  rg_list_check_index(list, index)
  list.set_item(rg_list_slot(list, index), rg_list_fit(list, value))
end

# Every item from +from+ for +count+ items set to +value+; both ends are checked before anything
# is written, as the interpreter checks them.
def rg_list_fill(list, from, count, value)
  return if count <= 0

  rg_list_check_index(list, from)
  rg_list_check_index(list, rg_add(from, count - 1))
  fitted = rg_list_fit(list, value)
  count.times { |i| list.set_item(rg_list_slot(list, from + i), fitted) }
end

# Every item put in order by the number +by+ holds at it, the smallest first (the biggest when
# +descending+ is not nought), as rg_list.h's rg_list_sort: an insertion sort, moving an item back
# only past a number strictly beyond its own, so level items keep their order.
def rg_list_sort(list, by, descending)
  falling = descending != 0
  at = 1
  while at < list.length
    item = list.item(rg_list_slot(list, at))
    key = rg_list_get(by, item)
    to = at
    while to > 0
      before = list.item(rg_list_slot(list, to - 1))
      other = rg_list_get(by, before)
      break if falling ? other >= key : other <= key

      list.set_item(rg_list_slot(list, to), before)
      to -= 1
    end
    list.set_item(rg_list_slot(list, to), item)
    at += 1
  end
end

# The list made to hold exactly +count+ entries of a table, from entry +at+ on, held so the whole
# run is inside the table. The program sets how the table is kept (a byte, a half or a word,
# signed or not) because a C table is read at that width; every table here is an Array of the
# whole numbers it holds already, so that is not needed.
def rg_list_copy(list, table, _kept, table_length, at, count)
  rg_fault("a copy of #{count} entries does not fit list :#{list.name} (capacity #{list.capacity})") if count > list.capacity
  rg_fault("a copy of #{count} entries is longer than its table (#{table_length} entries)") if count > table_length
  start = rg_clamp(at, 0, table_length - count)
  list.front = 0
  list.length = count
  count.times { |i| list.set_item(i, rg_list_fit(list, table[start + i])) }
end
