# The driver a game played live runs on (Ruby::LiveGame): the game is a Ruby object in the same
# process as whoever plays it, and at the end of every frame it hands them the picture and the
# frame's sound and takes back the buttons for the next pass, or nothing, which stops the play
# there.
#
# The game is told one frame went by each pass, whatever a clock says: a pass that runs late makes
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
    rg_game_main
    nil
  end
  stopped_by == :player ? nil : rg_screen_shown
end

# The sound of the frame the pass played is made first, before the next frame moves the music on.
# The picture is shown as it stands once the next frame has begun, the way the screen shows it
# once the frame boundary has passed, and the buttons the player answers are read for the pass
# that starts.
def rg_driver_wait_vblank
  rg_live_mix_match_seed
  left, right = rg_sound_render_frame
  rg_frame_begins
  buttons = @rg_live.buttons_after(rg_screen_shown, left, right)
  throw :rg_live_stop, :player if buttons.nil?

  rg_buttons_read(buttons)
end

# The match's seed goes into the game's random numbers once, at the end of the first pass, which is
# the one the game sets itself up in. A game that says `seed 7` has done so by then, so the match
# seed is added to what it chose and not lost to it; every machine adds the same number.
def rg_live_mix_match_seed
  return if @rg_match_seed.nil?

  rg_game_mix_seed
  @rg_match_seed = nil
end

def rg_driver_halt = throw(:rg_live_stop)
def rg_driver_fault(message) = raise(RgFault, message)

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

# A game played live prints nothing, but while it works out its state number the lines go there.
def rg_driver_dump_variable(name, value)
  @rg_state_text << "var #{name} #{value}\n" if @rg_state_text
end

def rg_driver_dump_list(list)
  return unless @rg_state_text

  items = Array.new(list.length) { |i| list.items[rg_list_slot(list, i)] }
  @rg_state_text << "list #{list.name}\t#{items.join(' ')}\n"
end

def rg_driver_sound_logged(_line); end
