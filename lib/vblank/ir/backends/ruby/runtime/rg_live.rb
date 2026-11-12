# The driver a game played live runs on (Ruby::LiveGame): the game is a Ruby object in the same
# process as whoever plays it, and at the end of every frame it hands them the picture and the
# frame's sound and takes back the buttons for the next pass, or nothing, which stops the play
# there.
#
# The game is told one frame went by each pass, whatever a clock shows: a pass that runs late makes
# the game run slow.

# What a game stops with when it does something its rules refuse (a push onto a full list); the
# words say what, and LiveGame raises them as IR::ProgramError.
class RgFault < StandardError; end

require "zlib"

# Plays the game for +player+ until the game ends, halts, or the player stops it. A game that
# stopped itself gives back the picture it stopped on, as the screen shows it, for the player to
# keep up; one the player stopped gives back nil. +match_seed+ is the seed machines in one match
# share for the game's random numbers, and +local_player+ which player the person here is, both nil
# when the game is played alone.
def rg_live_main(player, match_seed = nil, local_player = nil)
  @rg_live = player
  @rg_match_seed = match_seed
  @rg_local_player = local_player
  stopped_by = catch(:rg_live_stop) do
    rg_play_frames
    nil
  end
  stopped_by == :player ? nil : rg_screen_shown
end

# The sound of the frame the pass played is made first, before the next frame moves the music on.
# The picture is shown as it stands once the next frame has begun, the way the screen shows it
# once the frame boundary has passed, and the buttons the player answers are read for the pass
# that starts.
def rg_driver_wait_vblank
  rg_live_serve_state_request
  rg_live_mix_match_seed
  left, right = rg_sound_render_frame
  rg_frame_begins
  buttons = @rg_live.buttons_after(rg_screen_shown, left, right)
  throw :rg_live_stop, :player if buttons.nil?

  rg_buttons_read(buttons)
end

# A SAVE OR LOAD THE PLAYER ASKED FOR, done where the headless run does its own (rg_headless.rb's
# rg_headless_state_at_boundary): as the game's frame ends, before its sound is made and the next frame
# begins. That is the one moment every routine is stopped at its wait, so a state written now is the
# game whole, and one read back puts the game where it was. A state this build cannot read is
# refused before anything changes, in the words the runtime gives, and the game plays on.
def rg_live_serve_state_request
  request = @rg_live.take_state_request
  return if request.nil?

  if request.action == :save
    @rg_live.state_saved(request.slot, rg_state_write)
    return
  end
  text = @rg_live.state_to_load(request.slot)
  return if text.nil?

  problem = rg_state_header_problem(text)
  return @rg_live.state_refused(problem) if problem

  rg_state_read(text)
  @rg_live.state_loaded(request.slot)
end

# The match's seed goes into the game's random numbers once, at the end of the first pass, which is
# the one the game sets itself up in. A game that sets `seed 7` has done so by then, so the match
# seed is added to what it chose and not lost to it; every machine adds the same number.
def rg_live_mix_match_seed
  return if @rg_match_seed.nil?

  rg_game_mix_seed
  @rg_match_seed = nil
end

def rg_driver_halt = throw(:rg_live_stop)
def rg_driver_fault(message) = raise(RgFault, message)

# The keys and gamepad buttons the game adds to the window's layout, as IR::ComputerControls.runtime_numbers
# lays them out (Live::Settings reads them).
def rg_live_controls = @rg_game_controls

# The most players the build seats (`players:`), 0 for none named (Live::Seats).
def rg_live_seats = @rg_game_seats[0]

# THE SAVE MEMORY, for whoever keeps it in a file (Live::Session): its size, its bytes as a String, and
# the file's bytes put into it as the game starts.
def rg_live_save_size = rg_save_size
def rg_live_save_bytes = rg_save_bytes.pack("C*")
def rg_live_load_save(bytes) = rg_save_load_from_file(bytes)

# A short number standing for the game's whole state, for machines in a match to compare. The game
# prints its state through rg_game_dump_state, a line a variable and a line a list, exactly as the
# windowless run does, and the number is the CRC-32 of those lines. The same text is written by the
# JavaScript and C runtimes, so one game gives one number on every one of them.
def rg_live_state_crc
  @rg_state_text = +""
  rg_game_dump_state
  text = @rg_state_text
  @rg_state_text = nil
  Zlib.crc32(text)
end

# The game's state by name: +vars+ is { name => number } and +lists+ is { name => items oldest first }. The
# names are the game's own, which is why those two are Hashes.
RgLiveState = Data.define(:vars, :lists)

# Every variable and list the game keeps, by name, as they stand now (an RgLiveState). It is what a bot reads
# (Bots::GameView), and it is the same state the number above is made from. With +byte_lists_packed+ a
# list of bytes is given as a binary String, a byte an item, rather than an Array of numbers eight times
# its size: what a data pack's build reads its pack from.
def rg_live_state(byte_lists_packed = false)
  @rg_state_snapshot = RgLiveState.new(vars: {}, lists: {})
  @rg_byte_lists_packed = byte_lists_packed
  rg_game_dump_state
  snapshot = @rg_state_snapshot
  @rg_state_snapshot = nil
  @rg_byte_lists_packed = false
  snapshot
end

# A game played live prints nothing, but while it works out its state (as a number, or by name) the lines
# go there.
def rg_driver_dump_variable(name, value)
  @rg_state_text << "var #{name} #{value}\n" if @rg_state_text
  @rg_state_snapshot.vars[name.to_s] = value if @rg_state_snapshot
end

def rg_driver_dump_list(list)
  return unless @rg_state_text || @rg_state_snapshot

  @rg_state_text << "list #{list.name}\t#{list.items_in_order.join(' ')}\n" if @rg_state_text
  @rg_state_snapshot.lists[list.name.to_s] = list.items_for_state(@rg_byte_lists_packed) if @rg_state_snapshot
end

def rg_driver_sound_logged(_line); end
