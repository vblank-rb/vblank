# frozen_string_literal: true

# THE THINGS A GAME HOLDS A HANDLE TO. A verb on Builder hands one of these back — a Value, a
# Sprite, a List, a Pool — and the game then talks to it. So this is the half of the surface a
# game names directly, along with the kinds of thing those handles are made of.

require_relative "dsl/whole" # a plain whole number, and what one can do
require_relative "dsl/fraction" # ...and a number with a fractional part, kept in the low bits
require_relative "dsl/name_set" # the names a variable or a pool field can hold
require_relative "dsl/scale"
require_relative "dsl/changing_word"
require_relative "dsl/value"
require_relative "dsl/condition"
require_relative "dsl/branch"
require_relative "dsl/plain_ruby" # a game block in normal Ruby, read with Prism and rewritten
require_relative "dsl/plain_ruby_names" # ...what each local name in that block is
require_relative "dsl/plain_ruby_checks" # ...what that block is refused
require_relative "dsl/plain_ruby_steps" # ...what the rewritten block calls as it runs
require_relative "dsl/plain_ruby_writes" # ...and what a write in it does
# A handle that does its work in game words is written in normal Ruby, as a game is, so it comes in
# the way a part of a game does. Everything above this line is what that needs.
VBlank.require_game_file "dsl/bounds"
VBlank.require_game_file "dsl/pixel_bounds"
require_relative "dsl/box"
require_relative "dsl/list"
require_relative "dsl/save_data"
require_relative "dsl/random_numbers" # the random-number stream, for a save_data record to keep
require_relative "dsl/table"
require_relative "dsl/field_ref"
VBlank.require_game_file "dsl/pool"
require_relative "dsl/direction"
require_relative "dsl/grid"
VBlank.require_game_file "dsl/sprite"
VBlank.require_game_file "dsl/recolors" # the other colours a sprite or a pool can be drawn with
require_relative "dsl/picture_groups" # a scene's sprite pictures in groups, some of them up at a time
VBlank.require_game_file "dsl/hardware_sprite"
require_relative "dsl/mark" # a picture over a sprite, with no place of its own
require_relative "dsl/place" # a place made of flat faces, to be seen from a viewer
require_relative "dsl/viewer" # ...and the spot it is seen from, and which way that faces
require_relative "dsl/screen_spot" # ...and where one of its points lands on the screen
require_relative "dsl/timer"
require_relative "dsl/clock" # the date and time, as the cartridge's clock keeps them
VBlank.require_game_file "dsl/pass_job" # a step an effect takes once a pass, started and stopped by the game
VBlank.require_game_file "dsl/spotlight" # the game's light, and the darkness outside it
require_relative "dsl/sample"
require_relative "dsl/instrument"
require_relative "dsl/score_list"
require_relative "dsl/song_list"
require_relative "dsl/sound_effect_list"
VBlank.require_game_file "dsl/background"
VBlank.require_game_file "dsl/status_bar"
require_relative "dsl/tile_run" # tiles whose pixels the game paints, in a list of its own
require_relative "dsl/tile_picture_group" # ...and tiles taking turns through pictures in the cartridge
require_relative "dsl/sprite_tile_set" # sprite tiles the game loads from the cartridge, for poses drawn from them
VBlank.require_game_file "dsl/canvas" # ...and a picture the game draws into with words, built on them
VBlank.require_game_file "dsl/list_text" # ...and words held in a list, drawn on a painted screen
require_relative "dsl/data_pack" # the original's data, read through the pack made from the player's copy
