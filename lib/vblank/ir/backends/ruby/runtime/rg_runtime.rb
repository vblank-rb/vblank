# What the runtime promises the game — the buttons, the frames, the timers, the cartridge's clock,
# stopping — handed to the driver the game runs on where the machine matters. Nothing here knows
# whether there is a window: the driver is the methods named rg_driver_*, which the driver's own
# file gives the game's class (rg_headless.rb, the one with no window).

# Every button a program can name (IR::Buttons), a bit each, is RG_ONE_PLAYERS_BUTTONS, written
# ahead of the runtime (Computer::ConsoleNumbers). That is the same buttons on every console: a
# console with fewer has a build that refuses the ones it lacks before there is a game to play, so
# nothing here needs to know which console it is. Each connected player's buttons are a number of
# their own, in a list, the first player's first (IR::Buttons.masks).
RG_MAX_TIMERS = 32
RG_SECONDS_A_DAY = 86400
RG_UNDATED_FIRST_DAY = 10957 # 1 January 2000, in days from the start of 1970

# The readings of the clock, in IR::Clock::READINGS's order, which is the number the game asks by.
RG_CLOCK_HOUR = 0
RG_CLOCK_MINUTE = 1
RG_CLOCK_SECOND = 2
RG_CLOCK_YEAR = 3
RG_CLOCK_MONTH = 4
RG_CLOCK_DAY = 5
RG_CLOCK_WEEKDAY = 6
RG_CLOCK_PRESENT = 7
RG_CLOCK_SET = 8

# The game's own state first, then each part of the runtime's.
def initialize
  rg_runtime_setup
  rg_screen_setup
  rg_sound_setup
  rg_save_setup
  rg_game_setup
end

def rg_runtime_setup
  @rg_held = [0]    # each connected player's buttons down now, a bit each
  @rg_seen = [0]    # ...and at the last frame boundary, to tell a press from a hold
  @rg_pressed = [0] # buttons that went down at the last frame boundary
  # One timer each (RgTimer), and the timers in the order each was first started, which is the
  # order the interpreter walks them in.
  @rg_timers = Array.new(RG_MAX_TIMERS) { RgTimer.new }
  @rg_timers_started = []
  @rg_ticking = -1
  @rg_clock_present = 0
  @rg_clock_set = 0
  @rg_clock_counts_frames = 0 # moved on a frame at each boundary, rather than told the time
  @rg_clock_seconds = 0       # the time now, as seconds from the start of 1970...
  @rg_clock_ticks = 0         # ...and the console's ticks into the next second
  @rg_clock_kept_days = 0
  @rg_clock_kept_seconds = 0
end

# --- the buttons ---

# A button counts as pressed on the one frame it goes down, however long it is then held — the
# edge the interpreter's read_buttons finds. A driver reports which are down at every frame boundary,
# as a list of one number per connected player (IR::Buttons.masks). The list never shortens: a
# player who is connected stays so, and one the driver leaves out holds nothing.
def rg_buttons_read(now)
  @rg_held = rg_players_buttons(now)
  @rg_pressed = @rg_held.each_with_index.map { |held, player| held & ~(@rg_seen[player] || 0) }
  @rg_seen = @rg_held
end

# Down before the first frame boundary and not yet seen there, so the first boundary still finds
# them going down — the interpreter's hold, and the console's keys from power-on.
def rg_buttons_held_from_power_on(now)
  @rg_held = rg_players_buttons(now)
end

# +now+ as each player's buttons, at least as many as are connected already.
def rg_players_buttons(now)
  held = now.map { |buttons| buttons & RG_ONE_PLAYERS_BUTTONS }
  held + ([0] * [@rg_held.length - held.length, 0].max)
end

# A button's bit in +buttons+, or any of the first player's for -1. The buttons are numbered in
# IR::Buttons::NAMES's order.
def rg_button_down(buttons, button)
  return (buttons & RG_ONE_PLAYERS_BUTTONS) != 0 ? 1 : 0 if button < 0

  (buttons >> button) & 1
end

def rg_held(button) = rg_button_down(@rg_held[0], button)
def rg_pressed(button) = rg_button_down(@rg_pressed[0], button)

# Whether any of the buttons in +mask+ is down for +player+ (1 and up), or for any connected player
# for 0, for a test that names a player.
def rg_held_by(player, mask) = rg_any_down_by(@rg_held, player, mask)
def rg_pressed_by(player, mask) = rg_any_down_by(@rg_pressed, player, mask)

def rg_any_down_by(buttons, player, mask)
  return buttons.any? { |held| (held & mask) != 0 } ? 1 : 0 if player.zero?

  ((buttons[player - 1] || 0) & mask) != 0 ? 1 : 0
end

# How many players are connected now: one for each number in the driver's list.
def rg_players_connected = @rg_held.length

# Which player the person at this machine is, from 1: the first unless a match gave another. It
# reaches only what the game draws (Builder#drawing_for_local_player).
def rg_local_player = @rg_local_player || 1

# The seed a match shared by several machines gives the game's random numbers, which the game
# adds to its own stream once it has set itself up (rg_game_mix_seed). Nought when it plays alone.
def rg_match_seed = @rg_match_seed || 0

# --- frames ---

# The frame the game drew has ended, whoever is driving and whether or not the run stops here. The
# game then hands the frame back (its routines are resumable, Computer::Resumable), and the driver
# takes the frame between calls of rg_game_main (#rg_play_frames).
def rg_wait_vblank
  rg_screen_frame_ended
end

# Plays the game a frame at a time: rg_game_main carries on from where it stopped and hands back 1
# while it waits for a frame, and the driver takes each frame between.
def rg_play_frames
  rg_driver_wait_vblank while rg_game_main == 1
end

# A routine the runtime asked for an answer cannot wait for a frame: the answer is wanted now.
def rg_wait_vblank_while_answering
  rg_fault("the game waited for the screen while working out an answer the picture or a timer asked for")
end

# What every driver does as a frame begins, after deciding to play it, in the interpreter's order
# (Reference#advance_frame): the picture is switched on, the timers tick, the sound features (the
# mix, then the tune, then every sounding note's shape), and then the frame is counted, which moves
# a clock started at a test's moment.
def rg_frame_begins
  rg_screen_frame_started
  rg_timers_frame
  rg_hook_sound_frame
  rg_hook_sound_frame_ended
  rg_motor_frame
  rg_clock_frame
end

# --- the motor (Reference#exec_rumble, #step_motor) ---

# The cartridge's motor, kept as the native runtime keeps it (rg_runtime.c says how a pattern is
# read), on a console whose cartridge carries one. Nothing here shakes a gamepad yet.
def rg_rumble(frames, pattern)
  return unless RG_CONSOLE_RUMBLES

  @rg_rumble_left = frames.clamp(0, 0xFFFF)
  @rg_rumble_bits = pattern & 0xFF
end

def rg_motor_frame
  unless (@rg_rumble_left || 0).positive?
    @rg_motor_on = false
    return
  end

  @rg_rumble_bits = ((@rg_rumble_bits >> 1) | (@rg_rumble_bits << 7)) & 0xFF
  @rg_motor_on = @rg_rumble_bits.odd?
  @rg_rumble_left -= 1
end

def rg_motor_on = @rg_motor_on ? 1 : 0

# --- the state image (rg_state.rb) ---

# The most players the image has room for: the same sixteen the C runtime keeps.
RG_STATE_MOST_PLAYERS = 16

# +buttons+, one number a connected player, as a field of sixteen numbers, the unused ones nought;
# read back, it is given the length it had.
def rg_state_buttons(name, buttons)
  numbers = buttons + ([0] * (RG_STATE_MOST_PLAYERS - buttons.length))
  rg_state_numbers(name, numbers)
  numbers.first(buttons.length)
end

# Every timer as five numbers: started, running, its rate, its frames a second, and how far it has
# ticked. Then the order they were first started in: how many, and the timers' numbers, -1 for the
# places not used.
def rg_state_timers
  numbers = @rg_timers.flat_map do |timer|
    [timer.started ? 1 : 0, timer.running ? 1 : 0, timer.ticks_a_second, timer.frames_a_second, timer.parts]
  end
  rg_state_numbers("runtime.timers", numbers)
  @rg_timers.each_with_index do |timer, i|
    started, running, timer.ticks_a_second, timer.frames_a_second, timer.parts = numbers[i * 5, 5]
    timer.started = started != 0
    timer.running = running != 0
  end
  order = [@rg_timers_started.length, *Array.new(RG_MAX_TIMERS) { |i| @rg_timers_started.fetch(i, -1) }]
  rg_state_numbers("runtime.timers.order", order)
  @rg_timers_started = order[1, order[0]]
end

# The runtime's own fields, in Computer::StateFields's order.
def rg_runtime_visit_state
  held = rg_state_buttons("runtime.buttons.held", @rg_held)
  seen = rg_state_buttons("runtime.buttons.seen", @rg_seen)
  pressed = rg_state_buttons("runtime.buttons.pressed", @rg_pressed)
  connected = rg_state_number("runtime.players.connected", @rg_held.length)
  # An image read here is told how many players it has only after their buttons, so each list is cut
  # or filled out to that now.
  shaped = [held, seen, pressed].map { |buttons| Array.new(connected) { |player| buttons.fetch(player, 0) } }
  @rg_held, @rg_seen, @rg_pressed = shaped
  rg_state_timers
  clock = [@rg_clock_present, @rg_clock_set, @rg_clock_counts_frames, @rg_clock_seconds, @rg_clock_ticks,
           @rg_clock_kept_days, @rg_clock_kept_seconds]
  rg_state_numbers("runtime.clock", clock)
  @rg_clock_present, @rg_clock_set, @rg_clock_counts_frames, @rg_clock_seconds, @rg_clock_ticks,
    @rg_clock_kept_days, @rg_clock_kept_seconds = clock
  motor = [@rg_rumble_left || 0, @rg_rumble_bits || 0, @rg_motor_on ? 1 : 0]
  rg_state_numbers("runtime.motor", motor)
  @rg_rumble_left, @rg_rumble_bits = motor
  @rg_motor_on = motor[2] != 0
end

# --- stopping ---

# The game stopped on purpose (`halt`), which stops the motor too. The driver never comes back.
def rg_halt
  @rg_rumble_left = 0
  @rg_motor_on = false
  rg_driver_halt
end

# The game did something the interpreter refuses: says so in +message+, and stops. The driver
# never comes back.
def rg_fault(message) = rg_driver_fault(message)

def rg_dump_variable(name, value) = rg_driver_dump_variable(name, value)
def rg_dump_list(list) = rg_driver_dump_list(list)

# --- the file the game is handed as it starts (the C runtime's rg_runtime.h says the rest) ---

# +bytes+, a String, is the file; until it is handed over there is none (@rg_start_file is nil).
def rg_start_file_hand(bytes)
  @rg_start_file = bytes.b
end

def rg_start_file_open(rules, missing, wrong_size, wrong_check)
  refusal = rg_start_file_refusal(@rg_start_file, rules, { missing: missing, wrong_size: wrong_size, wrong_check: wrong_check })
  rg_fault(refusal) if refusal
end

# How each way a table is kept (RG_TABLE_INT8...) reads its entries from the file, low byte first
# and high byte first.
# Must be shareable: a game made in a Ractor (a test's) cannot set a constant that is not.
RG_START_FILE_READS = Ractor.make_shareable([["c*", "C*", "s<*", "v*", "l<*"], ["c*", "C*", "s>*", "n*", "l>*"]])
RG_START_FILE_ENTRY_BYTES = [1, 1, 2, 2, 4].freeze

# A TABLE OF BYTES THE FILE FILLS IS KEPT AS BYTES: an RgBytes (an RgSignedBytes for signed ones), a
# binary String whose table[i] gives a number, as an Array's does. An Array would keep each byte as a Ruby
# number of eight bytes, and a data pack's unpacking reads the whole of the player's copy into one
# such table: hundreds of megabytes, wanting gigabytes. An unsigned table's [] is getbyte itself, so
# a read costs what an Array's does.
class RgBytes < String
  def initialize(count) = super("\0".b * count)

  # The table holding +bytes+, a binary String, one entry a byte.
  def self.of(bytes) = allocate.replace(bytes)

  alias [] getbyte
  alias []= setbyte
end

class RgSignedBytes < RgBytes
  def [](index)
    byte = getbyte(index)
    byte && byte >= 0x80 ? byte - 0x100 : byte
  end
end

# THE GAME'S ART AND SOUND ARE KEPT AS BYTES TOO: its pictures' and tiles' pixels, its maps' cells,
# its songs' notes and its recordings' samples (Printer::KEPT_AS_BYTES), each a binary String in
# the width the table is kept in, low byte first. A game's art is millions of numbers, and Ruby's
# garbage collector, whenever it marks everything, reads every slot of every Array: held as Arrays
# they made each such collection several frames long. A String is one object, whose bytes the
# collector never reads. A read is a method of a few byte reads, several times what an Array's read
# costs once YJIT has compiled both, so the loop that reads the most of them, painting a
# background, reads a tile's pixels from an Array they are copied into (RgHalves#cached_at).
#
# Sixteen bits an entry, unsigned (a tile's pixel, RG_SEE_THROUGH being 0xFFFF). A write keeps the
# low sixteen bits, as the C's table does; a table is written only once the runtime has put an
# unfrozen copy in place of the game's (the start file filling pixels, a background's tiles
# following a list).
class RgHalves < String
  # The most entries #cached_at keeps: the pixels of more tiles than a screen of backgrounds shows
  # at once, few enough that the one Array holding them costs a collection little.
  MOST_CACHED = 262_144

  # The cached entries, run after run, in one Array (#cached_at says where each run starts).
  attr_reader :cache

  # The table holding +bytes+, a binary String, two bytes an entry.
  def self.of(bytes) = allocate.replace(bytes).start_cache

  # A copy (String#dup, before the runtime writes the game's table) has a cache of its own.
  def initialize_copy(other)
    super
    start_cache
  end

  def [](index)
    at = index << 1
    getbyte(at) | (getbyte(at + 1) << 8)
  end

  def []=(index, value)
    at = index << 1
    setbyte(at, value & 0xFF)
    setbyte(at + 1, (value >> 8) & 0xFF)
    forget_cached_entries unless @cached.empty?
  end

  # +count+ entries from +index+ on, as an Array of their numbers.
  def entries(index, count) = Array.new(count) { |i| self[index + i] }

  # Where in #cache the +count+ entries from +index+ on are, copied there the first time they are
  # asked for and kept until the table is written: a tile's pixels, read by the screen's loops as
  # an Array's. Emptied when it would hold more than MOST_CACHED, so a game showing ever more tiles
  # keeps no more than that.
  def cached_at(index, count)
    key = (index << 16) | count # a run is a tile's pixels, far fewer than 65536
    at = @cached[key]
    return at if at

    forget_cached_entries if @cache.length + count > MOST_CACHED
    at = @cache.length
    i = 0
    while i < count
      @cache << self[index + i]
      i += 1
    end
    @cached[key] = at
  end

  # The cached entries are copied from the table again on their next read. Emptied in place: the
  # game's table is frozen, so what it holds can change but not which objects.
  def forget_cached_entries
    @cached.clear
    @cache.clear
  end

  # A cache of no entries, for a table just made: #forget_cached_entries empties it.
  def start_cache
    @cached = {}
    @cache = []
    self
  end

  # The bytes of +count+ entries from +index+ on, and putting such bytes in from +index+ on.
  def entry_bytes(index, count) = byteslice(index << 1, count << 1)

  # Only the cached runs it overlaps are made again: a background's tiles follow a list a tile at
  # a time, and the rest of the screen's tiles stay as they were.
  def put_entry_bytes(index, bytes)
    bytesplice(index << 1, bytes.bytesize, bytes)
    past = index + (bytes.bytesize >> 1)
    @cached.delete_if { |key, _| (key >> 16) < past && (key >> 16) + (key & 0xFFFF) > index }
  end

  # A table of +total+ entries, the first +held+ of them this one's and the rest +fill+.
  def grown(held, total, fill) = self.class.of(byteslice(0, held << 1) + ([fill].pack("v") * (total - held)))
end

# Sixteen bits an entry, signed (an image's pixel, RG_NOT_DRAWN being -1; a map's cell).
class RgSignedHalves < RgHalves
  def [](index)
    at = index << 1
    half = getbyte(at) | (getbyte(at + 1) << 8)
    half >= 0x8000 ? half - 0x10000 : half
  end
end

# Thirty-two bits an entry, signed (a song's notes). Never written: a table of words the start file
# fills is written by the game unfrozen, an Array.
class RgWords < String
  # The table holding +bytes+, a binary String, four bytes an entry.
  def self.of(bytes) = allocate.replace(bytes)

  def [](index)
    at = index << 2
    word = getbyte(at) | (getbyte(at + 1) << 8) | (getbyte(at + 2) << 16) | (getbyte(at + 3) << 24)
    word >= 0x8000_0000 ? word - 0x1_0000_0000 : word
  end
end

def rg_start_file_fill_table(table, kept, count, at, high_byte_first)
  bytes = @rg_start_file.byteslice(at, count * RG_START_FILE_ENTRY_BYTES[kept])
  return table.replace(bytes) if table.is_a?(RgBytes)

  table.replace(bytes.unpack(RG_START_FILE_READS[high_byte_first][kept]))
end

# +count+ bytes of +samples+ from index +at+, each the file's byte from +file_at+ on, as a signed number.
def rg_start_file_fill_bytes(samples, at, count, file_at)
  samples[at, count] = @rg_start_file.byteslice(file_at, count).unpack("c*")
end

RG_FILL_TILE = 0
RG_TURN_MIRRORED = 1
RG_TURN_UPSIDE_DOWN = 2

# The place of the pixel at +row+ and +column+ of a picture read from the file: +across+ tiles wide,
# from +places_at+ on, each tile kept in the layout set by the numbers of +rules+ from +tile+ on (rg_runtime.c's
# start_file_place).
def rg_start_file_place(places_at, rules, tile, across, row, column)
  tile_bytes = rules[tile + RG_TILE_BYTES_AT]
  row_bits = rules[tile + RG_TILE_ROW_BITS_AT]
  start = places_at + ((((row / 8) * across) + (column / 8)) * tile_bytes)
  place = 0
  rules[tile + RG_TILE_PLANES_AT].times do |plane|
    bit = rules[tile + RG_TILE_PLANE_BITS_AT + plane] + ((row % 8) * row_bits) + rules[tile + RG_TILE_COLUMN_BITS_AT + (column % 8)]
    place |= ((@rg_start_file.getbyte(start + (bit / 8)) >> (bit % 8)) & 1) << plane
  end
  place
end

# rg_runtime.c's start_file_channel.
def rg_start_file_channel(kept, at, bits)
  level = (kept >> at) & ((1 << bits) - 1)
  bits >= 5 ? level : (level << (5 - bits)) | (level >> ((2 * bits) - 5))
end

# Colour +place+ of the colours from +colors_at+ on, kept in the layout set by the numbers of +rules+ from +format+ on
# (rg_runtime.c's start_file_color).
def rg_start_file_color(colors_at, rules, format, place)
  kept = @rg_start_file.byteslice(colors_at + (place * 2), 2).unpack1(rules[format + RG_COLOR_HIGH_BYTE_FIRST_AT] == 1 ? "n" : "v")
  bits = rules[format + RG_COLOR_CHANNEL_BITS_AT]
  rg_start_file_channel(kept, rules[format + RG_COLOR_RED_AT], bits) |
    (rg_start_file_channel(kept, rules[format + RG_COLOR_GREEN_AT], bits) << 5) |
    (rg_start_file_channel(kept, rules[format + RG_COLOR_BLUE_AT], bits) << 10)
end

# Colours that are no part of a picture, into the game's own array of them (rg_runtime.h,
# rg_start_file_fill_colors).
def rg_start_file_fill_colors(colors, first, count, at, format)
  count.times { |place| colors[first + place] = rg_start_file_color(at, format, 0, place) }
end

# The levels of a shading read from the file (rg_runtime.h, rg_start_file_fill_places).
def rg_start_file_fill_places(numbers, first, count, at, places)
  @rg_start_file.byteslice(at, count).bytes.each_with_index do |place, i|
    numbers[first + i] = place < places ? place : 0
  end
end

# rg_runtime.c's start_file_walked_color.
def rg_start_file_walked_color(color, far, steps)
  walked = 0
  [0, 5, 10].each do |shift|
    own = (color >> shift) & 31
    limit = (far >> shift) & 31
    moved = own < limit ? [own + steps, limit].min : [own - steps, limit].max
    walked |= moved << shift
  end
  walked
end

# Colours made from entries before them (rg_runtime.h, rg_start_file_walk_colors).
def rg_start_file_walk_colors(colors, first, count, made)
  count.times do |entry|
    colors[first + entry] = rg_start_file_walked_color(colors[made[entry * 3]], made[(entry * 3) + 1], made[(entry * 3) + 2])
  end
end

# rg_runtime.c's start_file_counted_walk_color.
def rg_start_file_counted_walk_color(color, far, step, count, steps)
  walked = 0
  [0, 5, 10].each do |shift|
    height = (color >> shift) & 31
    level = (far >> shift) & 31
    toward = height > level ? 1 : -1
    (1..steps).each do |number|
      now = [count - (step * number), 0].max
      to_go = (height - level) * toward
      if to_go.negative?
        level -= toward * step
        level = height if ((height - level) * toward).positive?
      elsif to_go.positive? && to_go >= now
        level = (level + (toward * step)).clamp(0, 31)
      end
    end
    walked |= level << shift
  end
  walked
end

# Colours made by a walk that waits for a falling count (rg_runtime.h, rg_start_file_count_walk_colors).
def rg_start_file_count_walk_colors(colors, first, count, made)
  count.times do |entry|
    at = entry * 5
    colors[first + entry] = rg_start_file_counted_walk_color(colors[made[at]], made[at + 1], made[at + 2], made[at + 3], made[at + 4])
  end
end

# rg_runtime.c's start_file_marked, of the sixteen bits +held+.
def rg_start_file_marked(held) = held > RG_MARKED_COLOR && held != 0xFFFF

# +color+, or the entry of +colors+ it names where it is a marker (rg_runtime.h).
def rg_start_file_marked_color(colors, color)
  held = color & 0xFFFF
  rg_start_file_marked(held) ? colors[held - RG_MARKED_COLOR - 1] : color
end

# The pixels written as markers, put in their colours (rg_runtime.h,
# rg_start_file_fill_marked_pixels). A marker kept in sixteen signed bits is below zero, so its
# sixteen bits are read. The game's pixels are frozen, so an unfrozen copy takes their place, as a
# picture's fill does.
def rg_start_file_fill_marked_pixels(colors, kind, _total, start, count)
  if kind == RG_FILL_TILE
    @rg_game_tile_pixels = @rg_game_tile_pixels.dup if @rg_game_tile_pixels.frozen?
    pixels = @rg_game_tile_pixels
  else
    @rg_game_image_pixels = @rg_game_image_pixels.dup if @rg_game_image_pixels.frozen?
    pixels = @rg_game_image_pixels
  end
  (start...(start + count)).each do |at|
    held = pixels[at] & 0xFFFF
    pixels[at] = colors[held - RG_MARKED_COLOR - 1] if rg_start_file_marked(held)
  end
end

# The numbers of a table of colours written as markers, put in their colours (rg_runtime.h,
# rg_start_file_fill_marked_numbers). The game writes such a table unfrozen.
def rg_start_file_fill_marked_numbers(colors, table, _kept, start, count)
  (start...(start + count)).each do |at|
    held = table[at]
    table[at] = colors[held - RG_MARKED_COLOR - 1] if held.positive? && held <= 0xFFFF && rg_start_file_marked(held)
  end
end

# One picture's pixels (rg_runtime.h, rg_start_file_fill_picture). The game's pixels are frozen, so
# the first picture filled puts an unfrozen copy in their place; the picture reads them from there
# on. The +total+ in the rules is how many there are, which the C needs.
def rg_start_file_fill_picture(rules)
  kind, _total, start, width, height, turn, across, places_at, colors_at, colors_count, swapped_count, places_by_byte, see_through, row_bytes = rules
  tile_format = RG_FILL_RULES_HEADER_NUMBERS
  color_format = tile_format + RG_TILE_FORMAT_NUMBERS
  held_places = color_format + RG_COLOR_FORMAT_NUMBERS
  held_colors = held_places + (places_at.negative? ? width * height : 0)
  swapped = held_colors + (colors_at.negative? ? colors_count : 0)
  if kind == RG_FILL_TILE
    @rg_game_tile_pixels = @rg_game_tile_pixels.dup if @rg_game_tile_pixels.frozen?
    pixels = @rg_game_tile_pixels
  else
    @rg_game_image_pixels = @rg_game_image_pixels.dup if @rg_game_image_pixels.frozen?
    pixels = @rg_game_image_pixels
  end
  height.times do |row|
    width.times do |column|
      from_row = (turn & RG_TURN_UPSIDE_DOWN).zero? ? row : height - 1 - row
      from_column = (turn & RG_TURN_MIRRORED).zero? ? column : width - 1 - column
      place = if places_at.negative?
                rules[held_places + (from_row * width) + from_column]
              elsif places_by_byte == 1
                @rg_start_file.getbyte(places_at + (from_row * row_bytes) + from_column)
              else
                rg_start_file_place(places_at, rules, tile_format, across, from_row, from_column)
              end
      color = if place == see_through
                kind == RG_FILL_TILE ? RG_SEE_THROUGH : -1
              elsif place < swapped_count
                rules[swapped + place]
              elsif place >= colors_count
                0
              elsif colors_at.negative?
                rules[held_colors + place]
              else
                rg_start_file_color(colors_at, rules, color_format, place)
              end
      pixels[start + (row * width) + column] = color
    end
  end
end

# The number the two bytes from +at+ in the file hold, low byte first, 0 or more.
def rg_start_file_half(at) = @rg_start_file.getbyte(at) | (@rg_start_file.getbyte(at + 1) << 8)

# A FRAME OF A SPRITE IN THE FILE is a record of VBlank's own, one layout whatever the original:
# lib/vblank/original/frame_record.rb (Original::FrameRecord) is where it is written down, and its
# numbers (RG_FRAME_, RG_PIECE_) are written ahead of this file from there. Every number is low
# byte first: a frame is the pieces it holds and the pieces the original names, two bytes each,
# then RG_FRAME_PIECE_BYTES a piece.
#
# One piece of a pose's frame, its record from +at+ in the file, painted into +places+, behind what
# is there already (rg_runtime.c's start_file_paint_piece). +tile_format+ is where that layout
# starts in +rules+.
def rg_start_file_paint_piece(places, width, height, at, rules, tile_format, origin_x, origin_y, tiles_at, tile_count)
  left = origin_x + ((rg_start_file_half(at + RG_PIECE_X_AT) ^ 0x8000) - 0x8000)
  top = origin_y + ((rg_start_file_half(at + RG_PIECE_Y_AT) ^ 0x8000) - 0x8000)
  first_tile = rg_start_file_half(at + RG_PIECE_TILE_AT)
  column_step = rg_start_file_half(at + RG_PIECE_COLUMN_STEP_AT)
  row_step = rg_start_file_half(at + RG_PIECE_ROW_STEP_AT)
  columns = @rg_start_file.getbyte(at + RG_PIECE_COLUMNS_AT)
  rows = @rg_start_file.getbyte(at + RG_PIECE_ROWS_AT)
  turns = @rg_start_file.getbyte(at + RG_PIECE_TURNS_AT)
  mirrored = turns.anybits?(RG_PIECE_MIRRORED)
  upside_down = turns.anybits?(RG_PIECE_UPSIDE_DOWN)
  across = columns * 8
  tall = rows * 8
  tile_bytes = rules[tile_format + RG_TILE_BYTES_AT]
  tall.times do |y|
    down = top + y
    next if down.negative? || down >= height

    across.times do |x|
      along = left + x
      next if along.negative? || along >= width || places[(down * width) + along] != 0

      from_x = mirrored ? across - 1 - x : x
      from_y = upside_down ? tall - 1 - y : y
      column = from_x / 8
      row = from_y / 8
      tile = first_tile + (column * column_step) + (row * row_step)
      next if tile >= tile_count

      places[(down * width) + along] = rg_start_file_place(tiles_at + (tile * tile_bytes), rules, tile_format, 1, from_y % 8, from_x % 8)
    end
  end
end

# How many pieces the frame whose entry is at +entry_at+ holds, and where the first of them is in
# the file: [count, first] (rg_runtime.c's start_file_frame_pieces). The frame's entry says where
# its record starts, counted from +records_at+; 0 is a frame with no record. The file is the
# player's: a record is read while it is inside the file.
def rg_start_file_frame_pieces(entry_at, records_at)
  size = @rg_start_file.bytesize
  offset = entry_at + RG_FRAME_ENTRY_BYTES <= size ? rg_start_file_half(entry_at) | (rg_start_file_half(entry_at + 2) << 16) : 0
  return [0, 0] unless offset != 0 && records_at + offset + RG_FRAME_HEADER_BYTES <= size

  first = records_at + offset + RG_FRAME_HEADER_BYTES
  [[rg_start_file_half(first - RG_FRAME_HEADER_BYTES), (size - first) / RG_FRAME_PIECE_BYTES].min, first]
end

# Colours of a list the file chooses (rg_runtime.h, rg_start_file_choose_colors).
def rg_start_file_choose_colors(colors, first, count, rules)
  entry_at, records_at, colors_at, list_colors, lists, first_place = rules
  pieces, first_piece = rg_start_file_frame_pieces(entry_at, records_at)
  list = pieces.positive? ? rg_start_file_half(first_piece + RG_PIECE_BANK_AT) : 0
  count.times do |entry|
    colors[first + entry] = if list < lists
                              rg_start_file_color(colors_at + (list * list_colors * 2), rules, RG_CHOSEN_COLORS_HEADER_NUMBERS, first_place + entry)
                            else
                              0
                            end
  end
end

# The bank a frame's front piece names (rg_runtime.h, rg_start_file_frame_bank).
def rg_start_file_frame_bank(entry_at, records_at)
  pieces, first_piece = rg_start_file_frame_pieces(entry_at, records_at)
  pieces.positive? ? rg_start_file_half(first_piece + RG_PIECE_BANK_AT) : 0
end

# The pieces of a pose of sprite tiles whose pieces are a frame in the file (rg_runtime.h,
# rg_start_file_fill_tile_pose).
def rg_start_file_fill_tile_pose(pieces, rules)
  entry_at, records_at, origin_x, origin_y, first_tile, tile_count, width, height, room = rules
  count, first = rg_start_file_frame_pieces(entry_at, records_at)
  kept = 0
  count.times do |piece|
    at = first + (piece * RG_FRAME_PIECE_BYTES)
    left = origin_x + ((rg_start_file_half(at + RG_PIECE_X_AT) ^ 0x8000) - 0x8000)
    top = origin_y + ((rg_start_file_half(at + RG_PIECE_Y_AT) ^ 0x8000) - 0x8000)
    tile = rg_start_file_half(at + RG_PIECE_TILE_AT)
    column_step = rg_start_file_half(at + RG_PIECE_COLUMN_STEP_AT)
    row_step = rg_start_file_half(at + RG_PIECE_ROW_STEP_AT)
    turned = @rg_start_file.getbyte(at + RG_PIECE_TURNS_AT).anybits?(RG_PIECE_MIRRORED | RG_PIECE_UPSIDE_DOWN)
    @rg_start_file.getbyte(at + RG_PIECE_ROWS_AT).times do |row|
      @rg_start_file.getbyte(at + RG_PIECE_COLUMNS_AT).times do |column|
        dx = left + (column * 8)
        dy = top + (row * 8)
        shown = tile + (column * column_step) + (row * row_step) - first_tile
        next if turned || dx.negative? || dy.negative? || dx % 8 != 0 || dy % 8 != 0 || dx + 8 > width || dy + 8 > height ||
                shown.negative? || shown >= tile_count || kept >= room
        next if (0...kept).any? { |before| pieces[3 * before] == dx && pieces[(3 * before) + 1] == dy }

        pieces[3 * kept] = dx
        pieces[(3 * kept) + 1] = dy
        pieces[(3 * kept) + 2] = shown
        kept += 1
      end
    end
  end
  (kept...room).each { |left| pieces[3 * left, 3] = [0, 0, -1] }
end

# The pixels of a pose whose pieces are in the file (rg_runtime.h, rg_start_file_fill_pose). The
# game's pixels are frozen, so an unfrozen copy takes their place, as a picture's fill does.
def rg_start_file_fill_pose(rules)
  kind, _total, copies, width, height, turn, colors_at, colors_count, entry_at, records_at, origin_x, origin_y,
    tiles_at, tile_count, only_bank = rules
  tile_format = RG_FILL_POSE_HEADER_NUMBERS
  color_format = tile_format + RG_TILE_FORMAT_NUMBERS
  held_colors = color_format + RG_COLOR_FORMAT_NUMBERS
  copy = held_colors + (colors_at.negative? ? colors_count : 0)
  count, first = rg_start_file_frame_pieces(entry_at, records_at)
  places = Array.new(width * height, 0)
  count.times do |piece|
    at = first + (piece * RG_FRAME_PIECE_BYTES)
    next if !only_bank.negative? && rg_start_file_half(at + RG_PIECE_BANK_AT) != only_bank

    rg_start_file_paint_piece(places, width, height, at, rules, tile_format, origin_x, origin_y, tiles_at, tile_count)
  end
  if kind == RG_FILL_TILE
    @rg_game_tile_pixels = @rg_game_tile_pixels.dup if @rg_game_tile_pixels.frozen?
    pixels = @rg_game_tile_pixels
  else
    @rg_game_image_pixels = @rg_game_image_pixels.dup if @rg_game_image_pixels.frozen?
    pixels = @rg_game_image_pixels
  end
  # The frame painted once, written into each copy of the picture in that copy's colours.
  copies.times do
    start = rules[copy]
    swapped_count = rules[copy + 1]
    swapped = copy + 2
    height.times do |row|
      width.times do |column|
        from_row = (turn & RG_TURN_UPSIDE_DOWN).zero? ? row : height - 1 - row
        from_column = (turn & RG_TURN_MIRRORED).zero? ? column : width - 1 - column
        place = places[(from_row * width) + from_column]
        color = if place.zero?
                  kind == RG_FILL_TILE ? RG_SEE_THROUGH : -1
                elsif place < swapped_count
                  rules[swapped + place]
                elsif place >= colors_count
                  0
                elsif colors_at.negative?
                  rules[held_colors + place]
                else
                  rg_start_file_color(colors_at, rules, color_format, place)
                end
        pixels[start + (row * width) + column] = color
      end
    end
    copy = swapped + swapped_count
  end
end

# A tile the game holds that draws something the file does not fill, put into the room made for its
# background (rg_runtime.h, rg_start_file_put_tile_pixels).
def rg_start_file_put_tile_pixels(_total, start, count, pixels)
  @rg_game_tile_pixels = @rg_game_tile_pixels.dup if @rg_game_tile_pixels.frozen?
  table = @rg_game_tile_pixels
  count.times { |i| table[start + i] = pixels[i] }
end

# The pixels made +total+ long where the game holds the first +held+: room for what the file fills
# whole, which the game is written without (rg_screen.h, rg_screen_tile_pixels_room and
# rg_screen_image_pixels_room). Unfrozen, as a fill's copy is.
def rg_screen_tile_pixels_room(total, held)
  @rg_game_tile_pixels = @rg_game_tile_pixels.grown(held, total, RG_SEE_THROUGH)
end

def rg_screen_image_pixels_room(total, held)
  @rg_game_image_pixels = @rg_game_image_pixels.grown(held, total, RG_NOT_DRAWN)
end

# How String#unpack reads the cells of a map in the file: a byte each (a map of tile numbers), two
# bytes (a console's own cell), or four (VBlank's own record, Original::MapCell, low byte first).
def rg_start_file_cell_unpacking(cell_bytes, map_high_byte_first)
  case cell_bytes
  when 1 then "C*"
  when 4 then map_high_byte_first == 1 ? "N*" : "V*"
  else map_high_byte_first == 1 ? "n*" : "v*"
  end
end

# Which tiles of a background whose map is in the file are drawn from one list it follows
# (rg_runtime.h, rg_start_file_fill_followed_tiles). The game writes +followed+ unfrozen.
def rg_start_file_fill_followed_tiles(followed, rules, banks)
  map_at, cells, across, side, map_high_byte_first = rules[2, 5]
  bank_at, bank_bits = rules[10, 2]
  bank_count = rules[16]
  held, cell_bytes = rules[19, 2]
  columns = across * side
  kept_as = rg_start_file_cell_unpacking(cell_bytes, map_high_byte_first)
  count = followed[2]
  @rg_start_file.byteslice(map_at, cells * cell_bytes).unpack(kept_as).each_with_index do |word, cell|
    bank = (word >> bank_at) & ((1 << bank_bits) - 1)
    next if bank >= bank_count || bank > 30 || banks[bank].zero?

    side.times do |down|
      side.times do |along|
        followed[3 + count] = held + ((((cell / across) * side) + down) * columns) + ((cell % across) * side) + along
        count += 1
      end
    end
  end
  told_at, told_count, told_first = rules[21, 3]
  @rg_start_file.byteslice(told_at, told_count * cell_bytes).unpack(kept_as).each_with_index do |word, told|
    bank = (word >> bank_at) & ((1 << bank_bits) - 1)
    next if bank >= bank_count || bank > 30 || banks[bank].zero?

    followed[3 + count] = told_first + told
    count += 1
  end
  followed[2] = count
end

# The cells of such a background naming a tile that takes turns through pictures (rg_runtime.h,
# rg_start_file_fill_moving_cells).
def rg_start_file_fill_moving_cells(painted, rules, moving)
  map_at, cells, across, side, map_high_byte_first = rules[2, 5]
  held, cell_bytes, told_at, told_count, told_first = rules[19, 5]
  columns = across * side
  kept_as = rg_start_file_cell_unpacking(cell_bytes, map_high_byte_first)
  @rg_start_file.byteslice(map_at, cells * cell_bytes).unpack(kept_as).each_with_index do |word, cell|
    side.times do |down|
      side.times do |along|
        rg_start_file_mark_moving_tile(painted, rules, moving, word, down, along,
                                       held + ((((cell / across) * side) + down) * columns) + ((cell % across) * side) + along)
      end
    end
  end
  @rg_start_file.byteslice(told_at, told_count * cell_bytes).unpack(kept_as).each_with_index do |word, told|
    rg_start_file_mark_moving_tile(painted, rules, moving, word, 0, 0, told_first + told)
  end
end

# One tile of a cell of such a background, shown as a run's tile where it takes turns
# (rg_runtime.c's start_file_mark_moving_tile).
def rg_start_file_mark_moving_tile(painted, rules, moving, word, down, along, slot)
  side = rules[5]
  tile_bits, mirror_bit, flip_bit, bank_at, bank_bits, row_tiles = rules[7, 6]
  bank_count = rules[16]
  start, count = moving[0, 2]
  entry = 1 + (bank_count * 8)
  first_tile = word & ((1 << tile_bits) - 1)
  mirrored = word[mirror_bit]
  upside_down = word[flip_bit]
  bank = (word >> bank_at) & ((1 << bank_bits) - 1)
  return if bank >= bank_count

  tile = first_tile + ((upside_down == 1 ? side - 1 - down : down) * row_tiles) + (mirrored == 1 ? side - 1 - along : along)
  which = (0...count).find { |each| moving[2 + (each * entry)] == tile } or return
  shown = 2 + (which * entry) + 1 + (((bank * 4) + mirrored + (2 * upside_down)) * 2)
  painted[start + (2 * slot)] = moving[shown]
  painted[start + (2 * slot) + 1] = moving[shown + 1]
end

# Tiles of the file as a run of painted tiles keeps them (rg_runtime.h, rg_start_file_fill_painted_tiles).
def rg_start_file_fill_painted_tiles(table, tiles, rules)
  bytes = Array.new(tiles) do |tile|
    at = rules[RG_TILE_FORMAT_NUMBERS + (2 * tile)]
    turn = rules[RG_TILE_FORMAT_NUMBERS + (2 * tile) + 1]
    Array.new(32) do |byte|
      row = byte / 4
      column = (byte % 4) * 2
      from_row = turn.anybits?(RG_TURN_UPSIDE_DOWN) ? 7 - row : row
      near, far = turn.anybits?(RG_TURN_MIRRORED) ? [7 - column, 6 - column] : [column, column + 1]
      (rg_start_file_place(at, rules, 0, 1, from_row, near) & 0xF) | ((rg_start_file_place(at, rules, 0, 1, from_row, far) & 0xF) << 4)
    end
  end.flatten
  table.is_a?(RgBytes) ? table.replace(bytes.pack("C*")) : table.replace(bytes)
end

# The tiles of a background whose map is in the file (rg_runtime.h, rg_start_file_fill_background).
# The game's tile pixels are frozen, so an unfrozen copy takes their place, as a picture's fill does.
def rg_start_file_fill_background(rules)
  map_at, cells, across, side, map_high_byte_first = rules[2, 5]
  held, cell_bytes, told_at, told_count, told_first = rules[19, 5]
  columns = across * side
  @rg_game_tile_pixels = @rg_game_tile_pixels.dup if @rg_game_tile_pixels.frozen?
  kept_as = rg_start_file_cell_unpacking(cell_bytes, map_high_byte_first)
  @rg_start_file.byteslice(map_at, cells * cell_bytes).unpack(kept_as).each_with_index do |word, cell|
    side.times do |down|
      side.times do |along|
        rg_start_file_paint_cell_tile(rules, word, down, along,
                                      held + ((((cell / across) * side) + down) * columns) + ((cell % across) * side) + along)
      end
    end
  end
  return if told_count.zero?

  @rg_start_file.byteslice(told_at, told_count * cell_bytes).unpack(kept_as).each_with_index do |word, told|
    rg_start_file_paint_cell_tile(rules, word, 0, 0, told_first + told)
  end
end

# One tile of a cell of such a background, painted into tile +slot+ of each set of its tiles
# (rg_runtime.c's start_file_paint_cell_tile).
def rg_start_file_paint_cell_tile(rules, word, down, along, slot)
  _total, start, _map_at, cells, across, side, _high_byte_first, tile_bits, mirror_bit, flip_bit, bank_at, bank_bits, row_tiles,
    tiles_at, tile_count, colors_at, bank_count, bank_size, sets, held = rules
  tile_format = RG_FILL_BACKGROUND_HEADER_NUMBERS
  color_format = tile_format + RG_TILE_FORMAT_NUMBERS
  lists = color_format + RG_COLOR_FORMAT_NUMBERS
  set_tiles = held + (across * side * (cells / across) * side)
  tile_bytes = rules[tile_format + RG_TILE_BYTES_AT]
  pixels = @rg_game_tile_pixels
  first_tile = word & ((1 << tile_bits) - 1)
  mirrored = word[mirror_bit] == 1
  upside_down = word[flip_bit] == 1
  bank = (word >> bank_at) & ((1 << bank_bits) - 1)
  tile = first_tile + ((upside_down ? side - 1 - down : down) * row_tiles) + (mirrored ? side - 1 - along : along)
  places = Array.new(64) do |at|
    next 0 unless tile < tile_count

    row = at / 8
    column = at % 8
    rg_start_file_place(tiles_at + (tile * tile_bytes), rules, tile_format, 1,
                        upside_down ? 7 - row : row, mirrored ? 7 - column : column)
  end
  sets.times do |set|
    list = lists + (((set * bank_count) + bank) * (1 + bank_size))
    drawn = start + (((set * set_tiles) + slot) * 64)
    places.each_with_index do |place, at|
      pixels[drawn + at] = if place.zero?
                             RG_SEE_THROUGH
                           elsif bank >= bank_count
                             0
                           elsif rules[list].negative?
                             rules[list + 1 + place]
                           elsif rules[list] < bank_count
                             rg_start_file_color(colors_at + (rules[list] * bank_size * 2), rules, color_format, place)
                           else
                             0
                           end
    end
  end
end

# --- timers (Reference @timers) ---

# One timer: whether it has ever been started, whether it is running, its rate, and how far it has
# ticked since it was last started, in +frames_a_second+-ths of a tick — each frame adds its rate,
# and the whole ticks are how many whole +frames_a_second+ that comes to. Whole numbers, as the
# interpreter keeps them (Reference#accrue_timer), so the two cross a whole tick on the same frame.
class RgTimer
  attr_accessor :started, :running, :ticks_a_second, :frames_a_second, :parts

  def initialize
    @started = false
    @running = false
    @ticks_a_second = 0
    @frames_a_second = 0 # Nought until started, as in the C and JavaScript runtimes
    @parts = 0
  end

  # How many whole times it has ticked since it was started (Reference#whole_overflows).
  def whole_ticks = @parts / @frames_a_second
end

def rg_fault_unless_timer(timer)
  return if timer >= 0 && timer < RG_MAX_TIMERS

  rg_fault("timer number #{timer} is not one of the #{RG_MAX_TIMERS} there is room for")
end

# Reference#exec_timer_start: started again from nought.
def rg_timer_start(number, ticks_a_second, frames_a_second)
  rg_fault_unless_timer(number)
  timer = @rg_timers[number]
  @rg_timers_started << number unless timer.started
  timer.started = true
  timer.running = true
  timer.ticks_a_second = ticks_a_second
  timer.frames_a_second = frames_a_second
  timer.parts = 0
end

# Reference#exec_timer_stop: a timer never started has nothing to stop.
def rg_timer_stop(number)
  rg_fault_unless_timer(number)
  @rg_timers[number].running = false
end

# Reference#timer_ticks
def rg_timer_ticks(number)
  rg_fault_unless_timer(number)
  timer = @rg_timers[number]
  timer.started ? timer.whole_ticks % 65536 : 0
end

def rg_timer_ticking(timer) = timer == @rg_ticking ? 1 : 0

# Reference#accrue_timer, for every running timer: a frame's worth of ticks more, and the game's
# handler once for each whole tick crossed. How many that is is settled before the first of them
# runs, so a handler that stops its own timer, or starts it again, still finishes the ticks this
# frame crossed.
def rg_timers_frame
  @rg_timers_started.each do |number|
    timer = @rg_timers[number]
    next unless timer.running

    before = timer.whole_ticks
    timer.parts += timer.ticks_a_second
    crossed = timer.whole_ticks - before
    @rg_ticking = number
    crossed.times { rg_game_timer_ticks }
    @rg_ticking = -1
  end
end

# --- the cartridge's clock (Reference#value_of_clock) ---

# The windowless driver starts the clock at a moment of the test's: +seconds+ from the start of
# 1970 as such a clock counts them, +ticks+ more in cycles of the console's own clock
# (RG_CONSOLE_TICKS_A_SECOND), and whether the clock was ever set. From then it moves on one of
# the console's frames at each frame boundary.
#
# A CHIP THAT KEEPS NO DATE (RG_CLOCK_KEEPS_DATE false, the Color's; IR::Clock.undated) counts
# only the days and the time of day since it started, taken as that many days on from 1 January
# 2000: so it starts on that day, at the time of day it was started at.
def rg_clock_starts_at(seconds, ticks, set)
  @rg_clock_present = 1
  @rg_clock_set = set != 0 ? 1 : 0
  @rg_clock_counts_frames = 1
  @rg_clock_seconds = RG_CLOCK_KEEPS_DATE ? seconds : (RG_UNDATED_FIRST_DAY * RG_SECONDS_A_DAY) + (seconds % RG_SECONDS_A_DAY)
  @rg_clock_ticks = ticks
end

# The days from the start of 1970 to a date, and back. A calendar of plain arithmetic, so the
# computer's time zone never comes into it: every fourth year a leap year, but not every
# hundredth, but every four hundredth. The year is counted from March, so the leap day falls at
# the end of it, and the counting goes in whole 400-year cycles, which always hold the same
# number of days. Ruby's / rounds down, which is the rounding a moment before 1970 needs.
def rg_days_from_date(year, month, day)
  year -= 1 if month <= 2
  era = year / 400
  year_of_era = year - (era * 400)
  day_of_year = (((153 * (month > 2 ? month - 3 : month + 9)) + 2) / 5) + day - 1
  day_of_era = (year_of_era * 365) + (year_of_era / 4) - (year_of_era / 100) + day_of_year
  (era * 146097) + day_of_era - 719468
end

# [year, month, day]
def rg_date_from_days(days)
  days += 719468
  era = days / 146097
  day_of_era = days - (era * 146097)
  year_of_era = (day_of_era - (day_of_era / 1460) + (day_of_era / 36524) - (day_of_era / 146096)) / 365
  day_of_year = day_of_era - ((365 * year_of_era) + (year_of_era / 4) - (year_of_era / 100))
  from_march = ((5 * day_of_year) + 2) / 153
  day = day_of_year - (((153 * from_march) + 2) / 5) + 1
  month = from_march < 10 ? from_march + 3 : from_march - 9
  [year_of_era + (era * 400) + (month <= 2 ? 1 : 0), month, day]
end

# A window gives what the computer's own clock reads instead, before the game starts and as each
# frame boundary hands the game its next frame.
def rg_clock_reads(year, month, day, hour, minute, second)
  @rg_clock_present = 1
  @rg_clock_set = 1
  @rg_clock_counts_frames = 0
  @rg_clock_seconds = (rg_days_from_date(year, month, day) * RG_SECONDS_A_DAY) + (hour * 3600) + (minute * 60) + second
  @rg_clock_ticks = 0
end

# A frame of the console's later.
def rg_clock_frame
  return if @rg_clock_counts_frames == 0

  @rg_clock_ticks += RG_CONSOLE_TICKS_A_FRAME
  @rg_clock_seconds += @rg_clock_ticks / RG_CONSOLE_TICKS_A_SECOND
  @rg_clock_ticks %= RG_CONSOLE_TICKS_A_SECOND
end

# A chip that keeps no date has no date of its own to give, so it reads as never set until the
# game has set a time on it: an offset of anything but nought (IR::Clock.undated_set?).
def rg_clock_reading(reading, offset_days, offset_seconds)
  return 0 if @rg_clock_present == 0
  return 1 if reading == RG_CLOCK_PRESENT
  return 0 if @rg_clock_set == 0
  return 0 if !RG_CLOCK_KEEPS_DATE && offset_days == 0 && offset_seconds == 0
  return 1 if reading == RG_CLOCK_SET

  now = @rg_clock_seconds + (offset_days * RG_SECONDS_A_DAY) + offset_seconds
  days = now / RG_SECONDS_A_DAY
  into_day = now - (days * RG_SECONDS_A_DAY)
  year, month, day = rg_date_from_days(days)
  case reading
  when RG_CLOCK_HOUR then into_day / 3600
  when RG_CLOCK_MINUTE then (into_day / 60) % 60
  when RG_CLOCK_SECOND then into_day % 60
  when RG_CLOCK_YEAR then year
  when RG_CLOCK_MONTH then month
  when RG_CLOCK_DAY then day
  when RG_CLOCK_WEEKDAY then (days + 4) % 7 # 1 January 1970 was a Thursday
  else rg_fault("the clock has no reading numbered #{reading}")
  end
end

# SETTING THE CLOCK (Reference#exec_set_clock): how far the time set is from the clock's own, to
# the whole second, in days and the seconds left over, kept until the game takes the two parts
# into its saved numbers. The clock itself is never changed, and from then on it reads as set.
def rg_clock_set_to(year, month, day, hour, minute, second)
  return if @rg_clock_present == 0

  today = @rg_clock_seconds / RG_SECONDS_A_DAY
  days = rg_days_from_date(year, month, day) - today
  seconds = (hour * 3600) + (minute * 60) + second - (@rg_clock_seconds - (today * RG_SECONDS_A_DAY))
  if seconds < 0
    seconds += RG_SECONDS_A_DAY
    days -= 1
  end
  @rg_clock_kept_days = rg_i32(days)
  @rg_clock_kept_seconds = rg_i32(seconds)
  @rg_clock_set = 1
end

# The days and the seconds rg_clock_set_to kept — or +current+, the game's own number as it was,
# with no clock to have set.
def rg_clock_kept_days(current) = @rg_clock_present != 0 ? @rg_clock_kept_days : current
def rg_clock_kept_seconds(current) = @rg_clock_present != 0 ? @rg_clock_kept_seconds : current
