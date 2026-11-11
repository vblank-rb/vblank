# What the runtime promises the game — the buttons, the frames, the timers, the cartridge's clock,
# stopping — handed to the driver the game runs on where the machine matters. Nothing here knows
# whether there is a window: the driver is the methods named rg_driver_*, which the driver's own
# file gives the game's class (rg_headless.rb, the one with no window).

# Every button a program can name (IR::Buttons), a bit each. That is the same buttons on every
# console: a console with fewer has a build that refuses the ones it lacks before there is a game
# to play, so nothing here needs to know which console it is. Each connected player's buttons are
# a number of their own, in a list, the first player's first (IR::Buttons.masks).
RG_ONE_PLAYERS_BUTTONS = 0x1FFF # Thirteen, as IR::Buttons::NAMES has: the Genesis's C is the last
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

# A button's bit in +buttons+, or any of the first player's for -1. The buttons are numbered in the
# order the console's key register holds them: a, b, select, start, right, left, up, down, r, l.
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

  alias [] getbyte
  alias []= setbyte
end

class RgSignedBytes < RgBytes
  def [](index)
    byte = getbyte(index)
    byte && byte >= 0x80 ? byte - 0x100 : byte
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

# The pixels of a pose whose pieces are in the file (rg_runtime.h, rg_start_file_fill_pose). The
# game's pixels are frozen, so an unfrozen copy takes their place, as a picture's fill does.
def rg_start_file_fill_pose(rules)
  kind, _total, start, width, height, turn, colors_at, colors_count, swapped_count, entry_at, records_at, origin_x, origin_y,
    tiles_at, tile_count = rules
  tile_format = RG_FILL_POSE_HEADER_NUMBERS
  color_format = tile_format + RG_TILE_FORMAT_NUMBERS
  held_colors = color_format + RG_COLOR_FORMAT_NUMBERS
  swapped = held_colors + (colors_at.negative? ? colors_count : 0)
  count, first = rg_start_file_frame_pieces(entry_at, records_at)
  places = Array.new(width * height, 0)
  count.times do |piece|
    rg_start_file_paint_piece(places, width, height, first + (piece * RG_FRAME_PIECE_BYTES), rules, tile_format, origin_x, origin_y,
                              tiles_at, tile_count)
  end
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
end

# The tiles of a background whose map is in the file (rg_runtime.h, rg_start_file_fill_background).
# The game's tile pixels are frozen, so an unfrozen copy takes their place, as a picture's fill does.
def rg_start_file_fill_background(rules)
  _total, start, map_at, cells, across, side, map_high_byte_first, tile_bits, mirror_bit, flip_bit, bank_at, bank_bits, row_tiles,
    tiles_at, tile_count, colors_at, bank_count, bank_size, sets, held, cell_bytes = rules
  tile_format = RG_FILL_BACKGROUND_HEADER_NUMBERS
  color_format = tile_format + RG_TILE_FORMAT_NUMBERS
  lists = color_format + RG_COLOR_FORMAT_NUMBERS
  columns = across * side
  set_tiles = held + (columns * (cells / across) * side)
  tile_bytes = rules[tile_format + RG_TILE_BYTES_AT]
  @rg_game_tile_pixels = @rg_game_tile_pixels.dup if @rg_game_tile_pixels.frozen?
  pixels = @rg_game_tile_pixels
  # A cell is two bytes, or one: a map of bytes, each a tile's number.
  kept_as = if cell_bytes == 1 then "C*"
            else map_high_byte_first == 1 ? "n*" : "v*"
            end
  words = @rg_start_file.byteslice(map_at, cells * cell_bytes).unpack(kept_as)
  words.each_with_index do |word, cell|
    first_tile = word & ((1 << tile_bits) - 1)
    mirrored = word[mirror_bit] == 1
    upside_down = word[flip_bit] == 1
    bank = (word >> bank_at) & ((1 << bank_bits) - 1)
    side.times do |down|
      side.times do |along|
        tile = first_tile + ((upside_down ? side - 1 - down : down) * row_tiles) + (mirrored ? side - 1 - along : along)
        number = ((((cell / across) * side) + down) * columns) + ((cell % across) * side) + along
        places = Array.new(64) do |at|
          next 0 unless tile < tile_count

          row = at / 8
          column = at % 8
          rg_start_file_place(tiles_at + (tile * tile_bytes), rules, tile_format, 1,
                              upside_down ? 7 - row : row, mirrored ? 7 - column : column)
        end
        sets.times do |set|
          list = lists + (((set * bank_count) + bank) * (1 + bank_size))
          drawn = start + (((set * set_tiles) + held + number) * 64)
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
