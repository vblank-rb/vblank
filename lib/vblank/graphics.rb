# frozen_string_literal: true

# WHAT A PICTURE IS MADE OF: colours, letters, and the images themselves — including the
# readers that take art in the shape somebody else's tool left it, and the writer that puts a
# picture out as a file a person can open.

require_relative "graphics/color"
require_relative "graphics/font"       # A bitmap font: glyphs and metrics
require_relative "graphics/fonts"      # The built-in fonts, registered by name
require_relative "graphics/menu_font"  # The window menu's letters, drawn smooth at the screen's own pixels
require_relative "graphics/image"
require_relative "graphics/border"     # The picture round a game's screen inside a bigger one
require_relative "graphics/aseprite"   # Art read from an Aseprite file
require_relative "graphics/png"        # A picture written as a PNG file
