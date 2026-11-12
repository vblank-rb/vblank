# frozen_string_literal: true

# A part naming its game variables, brought in with `require_relative` rather than
# `VBlank.require_game_file`, so it is never read as game code.
class PartNamingWithoutGameFile
  game_variables :busy
end
