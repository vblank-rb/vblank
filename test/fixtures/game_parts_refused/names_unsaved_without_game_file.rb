# frozen_string_literal: true

# A part marking its game variables as never saved, brought in with `require_relative` rather
# than `VBlank.require_game_file`, so it is never read as game code.
class PartNamingUnsavedWithoutGameFile
  game_variables :busy, wait: :part_wait, saved: false
end
