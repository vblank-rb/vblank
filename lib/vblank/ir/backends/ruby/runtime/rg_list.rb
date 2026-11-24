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
# A list of bytes (`width: :byte`) IS KEPT AS BYTES, an RgByteList over a binary String, one byte
# a slot. An Array keeps every item as a Ruby number of eight bytes, and a data pack's unpacking
# writes its whole pack into one list of bytes: a pack of hundreds of megabytes held that way
# would want gigabytes. The two classes answer the same few methods, so nothing else knows which
# it holds.
#
# A read or write of one item is one call (#get, #set), which the printer writes where the game
# reads or writes (Printer#list_item_call): the check of the index and the ring's slot worked out
# inside it, on the list's own instance variables. An unrolled routine paid for a few reads; a
# routine that loops over a list by an index it works out as it runs pays for one at every turn,
# and the chain of small calls it was before (rg_list_get, rg_list_check_index, rg_list_slot,
# #item, each asking the list for its length, front or capacity) cost YJIT a call apiece, where
# one method reads them as instance variables. An index outside the list gives nil and is kept
# (#refused_index), and the printed code hands the list to rg_list_index_fault, which stops the
# game in the interpreter's words; a list item is never nil, so nothing else reads as a refusal.

class RgList
  attr_reader :width, :name, :refused_index
  attr_accessor :capacity # set again by a declaration of another capacity (rg_list_set_capacity)
  attr_accessor :front, :length

  # The list for the build's ListStorage: kept as bytes when +width+ is 1, and fitting each number
  # to a half when it is 2.
  def self.build(capacity, width, name)
    kind = case width
           when 1 then RgByteList
           when 2 then RgHalfList
           else RgList
           end
    kind.new(capacity, width, name)
  end

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

  # Item +index+, oldest first, or nil (the index kept) when the list has no such item. The front
  # and the index are each inside the capacity, so their sum is past it by less than a capacity,
  # and one subtraction comes round the ring where a remainder would divide.
  def get(index)
    if index >= 0 && index < @length
      slot = @front + index
      @items[slot < @capacity ? slot : slot - @capacity]
    else
      @refused_index = index
      nil
    end
  end

  # Item +index+ set to +value+, giving true, or nil (the index kept) when the list has no such
  # item. A list of words keeps the number as it is.
  def set(index, value)
    if index >= 0 && index < @length
      slot = @front + index
      @items[slot < @capacity ? slot : slot - @capacity] = value
      true
    else
      @refused_index = index
      nil
    end
  end

  # Every slot set to +value+, already fitted to the width.
  def fill_items(value) = @items.fill(value, 0, @capacity)

  # Every slot as the ring stands, used or not.
  def slots = @items.first(@capacity)

  # The items oldest first, the order the game reads them in.
  def items_in_order = Array.new(@length) { |i| item((@front + i) % @capacity) }

  # The items oldest first for a snapshot of the game's state (rg_live_state): numbers, or with
  # +packed+ a list of bytes gives them as a binary String instead.
  def items_for_state(_packed) = items_in_order

  # Called once a state read in has put back the list's front, length and slots (rg_state_list).
  def state_read = nil

  private

  # +count+ slots holding nought, as this list keeps them.
  def blank_slots(count) = Array.new(count, 0)
end

# A list of bytes (`width: :byte`), its slots one byte each of a binary String, read back signed.
#
# The String is the same one for the list's whole life, its capacity long from the start, and is
# only ever changed in place. So the printer reads and writes an item of a list that is always full
# as the String's own byte (+items+, Printer#byte_item_in_place), having tested the index against
# the list's length: such a list never moves its front from the first slot.
class RgByteList < RgList
  attr_reader :items

  def item(slot)
    byte = @items.getbyte(slot)
    byte >= 0x80 ? byte - 0x100 : byte
  end

  def set_item(slot, value) = @items.setbyte(slot, value)

  def get(index)
    if index >= 0 && index < @length
      slot = @front + index
      byte = @items.getbyte(slot < @capacity ? slot : slot - @capacity)
      byte >= 0x80 ? byte - 0x100 : byte
    else
      @refused_index = index
      nil
    end
  end

  # String#setbyte keeps the low byte of any number, as a byte slot keeps it.
  def set(index, value)
    if index >= 0 && index < @length
      slot = @front + index
      @items.setbyte(slot < @capacity ? slot : slot - @capacity, value)
      true
    else
      @refused_index = index
      nil
    end
  end

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

# A list of halves (`width: :half`): its numbers kept as rg_to_half keeps them.
class RgHalfList < RgList
  def set(index, value)
    if index >= 0 && index < @length
      slot = @front + index
      @items[slot < @capacity ? slot : slot - @capacity] = ((value & 0xFFFF) ^ 0x8000) - 0x8000
      true
    else
      @refused_index = index
      nil
    end
  end
end

# A list that is always full: one the game only ever declares full of a number (`full_of:`), and
# never pushes onto, drops from or copies into, so it holds its whole capacity from its declaration
# on, its first item in its first slot (Printer#always_full_lists picks these, of numbers wider
# than a byte). A port keeps its chip's operators so, a list a field, and reads them at an index it
# works out on every sample.
#
# Its Array holds no slots until the declaration, and then all of them, so the Array's own length
# is the list's, and the printer reads an item as the Array's own `[]` (Printer#list_item_in_place),
# which gives nil past the end, with no call: the game holds the Array itself as well as the list
# (+items+, the same Array for the list's whole life, filled in place). Before the declaration every
# slot reads as nought, as a ring's does, for a state written then.
class RgFullList < RgList
  attr_reader :items

  def item(slot) = @items[slot] || 0
  def fill_items(value) = @items.replace(Array.new(@capacity, value))
  def slots = Array.new(@capacity) { |slot| item(slot) }

  def set(index, value)
    if index >= 0 && index < @length
      @items[index] = @width == 2 ? ((value & 0xFFFF) ^ 0x8000) - 0x8000 : value
      true
    else
      @refused_index = index
      nil
    end
  end

  # A state read in puts every slot back, which a list not yet declared does not hold.
  def state_read
    @items.clear if @length == 0
  end

  private

  def blank_slots(_count) = []
end

# Stops the game for the index +list+ refused just now (RgList#get, #set), in the interpreter's words.
def rg_list_index_fault(list) = rg_list_check_index(list, list.refused_index)

# ...and for +index+, outside an always-full list the printer read or wrote in place.
def rg_list_index_fault_at(list, index) = rg_list_check_index(list, index)
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

# A list declared with several capacities takes the one its declaration gives before it starts
# again; its items have room for the most of them.
def rg_list_set_capacity(list, capacity)
  list.capacity = capacity
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

# The game stops: +name+, holding +capacity+, is full (IR::Faults.list_full's words), or, +in_walk+
# not nought, full only of items a walk took out (IR::Faults.full_in_walk's). Raised by a push onto
# a full list, and by a full pool told to stop (IR::Nodes::StopFull).
def rg_stop_full(name, capacity, in_walk)
  if in_walk != 0
    rg_fault("`#{name}` has no room yet: it has room for #{capacity} items, and an item taken out inside a walk " \
             "of it gives its place back only when the walk ends. To fix this, add the new item after the walk, " \
             "or give it a larger capacity.")
  end
  rg_fault("`#{name}` is full: it has room for #{capacity} items, and a console cannot make it bigger. " \
           "To fix this, take an item out or test its size before you add one, or give it a larger capacity.")
end

def rg_list_push(list, value)
  rg_stop_full(list.name, list.capacity, 0) if list.length >= list.capacity
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

# rg_list_sort with +shown+, 1 at each place of +by+ whose item shows, as rg_list.h's
# rg_list_sort_shown: an item not showing goes behind every item showing, keeping the order the
# items not showing stood in.
def rg_list_sort_shown(list, by, descending, shown)
  falling = descending != 0
  at = 1
  while at < list.length
    item = list.item(rg_list_slot(list, at))
    showing = shown[item] == 1
    key = showing ? rg_list_get(by, item) : 0
    to = at
    while to > 0
      before = list.item(rg_list_slot(list, to - 1))
      break if shown[before] != 1
      break if showing && (falling ? rg_list_get(by, before) >= key : rg_list_get(by, before) <= key)

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
