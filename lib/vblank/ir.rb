# frozen_string_literal: true

require_relative "ir/int32"
require_relative "ir/constant_divisor"      # Dividing by a number written in the game, by multiplying
require_relative "ir/program_error"         # A game that goes wrong, as every backend reports it
require_relative "ir/faults"                # The sentence a program error is reported in
require_relative "ir/buttons"
require_relative "ir/clock"                 # What a game reads of the date and time, on every backend
require_relative "ir/clock_calendar"        # The calendar a cartridge adds to a time the game set
require_relative "ir/frames"                # How many frames a pass of the game loop took
require_relative "ir/rumble"                # How a rumble's pattern is read, a frame at a time
require_relative "ir/node"                  # What every node can do; names no kind
require_relative "ir/nodes"                 # One class per kind, each declaring its own operands
require_relative "ir/fields"                # The operand tables, read from the classes
require_relative "ir/font_table"            # Which font a name means to one program
require_relative "ir/remembered"            # What a build works out from a picture, kept for the next build
require_relative "ir/assets"                # What a declared image or recording is, for every backend
require_relative "ir/format_reading"        # An original's tiles, colours and numbers, read in a console's layout
require_relative "ir/start_file"            # A file a program is handed as it starts, holding some of its data
require_relative "ir/saved_var"             # A variable that survives power-off
require_relative "ir/save_layout"           # Where save data lives in save memory
require_relative "ir/save_image"            # Save memory held in Ruby, laid out the same way
require_relative "ir/tile_map"              # How big a grid a background scrolls over, for every backend
require_relative "ir/build"
require_relative "ir/place_drawing"         # How a place made of flat faces is drawn, as statements every target runs
require_relative "ir/viewer_motion"         # How the viewer moves and turns
require_relative "ir/reciprocals"           # How far a point on a face is, for a picture in perspective
require_relative "ir/kept_widths"           # A variable kept a byte or two wide, on every backend
require_relative "ir/sprite_reading"        # Where a named sprite's state is kept, for reading it back
require_relative "ir/background_reading"    # Where a background's state is kept, for reading it back
require_relative "ir/reading_by_name"       # A running game's state asked by its names, on every reader
require_relative "ir/unchanging"            # Which values change nothing by being worked out
require_relative "ir/reach"                 # What a run can reach: its routines and variables
require_relative "ir/parity"
require_relative "ir/affine"
require_relative "ir/modes"
require_relative "ir/stacking"              # The one rule turning declared layers into a drawing order
require_relative "ir/scene_handover"        # What a scene does to the screen as it takes over
require_relative "ir/late_pages"            # When a page finished too late is shown
require_relative "ir/sprites_over_picture"  # Whether sprites show over a picture the scene paints
require_relative "ir/movement"              # Which stacked things move, so the rest need not be redrawn
require_relative "ir/sprite_rows"           # Which sprites of scenes never up together share a row of the table
require_relative "ir/picture_group_places"  # Where pictures grouped by room go in sprite memory
require_relative "ir/see_through"           # The layers a program can be seen through, and their mix
require_relative "ir/fading"                # The one rule saying which part of the display a fade uses
require_relative "ir/light_scenes"          # Which scenes a light is off in, to let one of those have it
require_relative "ir/tunes"                 # Which tunes a program plays, and the mixer voices they keep
require_relative "ir/mixing"                # How recordings are added together into one stream
require_relative "ir/rules_only"            # A program with nothing to see or hear, for a bot to play fast
require_relative "ir/verifier"
require_relative "ir/portability"
require_relative "ir/backends"
require_relative "ir/guardrails"
require_relative "ir/printer"               # What a report is written through
require_relative "ir/glyph_usage"
require_relative "ir/palette"
require_relative "ir/dump"

module VBlank
  # The intermediate representation (IR): the plain-Ruby op-tree the DSL builds
  # instead of emitting target code directly.
  #
  # The DSL constructs an {IR::Node} tree (see {IR::Build} for readable
  # constructors); a validation pass then walks it to catch footguns *before*
  # any code exists, and a lowering pass turns it into code for a concrete
  # target. Keeping the program as inspectable data — rather than output emitted
  # on the fly — is what makes those passes, and forward references, possible.
  #
  # The IR is deliberately target-agnostic: it describes *what the program does*,
  # not how one machine runs it. ARM/GBA is the current lowering backend, but
  # nothing here assumes it — another backend (e.g. JavaScript) could lower the
  # same tree. Target-specific detail belongs in the lowering pass, not here.
  module IR
  end
end
