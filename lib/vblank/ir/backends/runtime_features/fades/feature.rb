# frozen_string_literal: true

# `fade` and `tint`: the display's fade toward black or white (over the whole screen, held to a
# rectangle, placed in the stack or walking the colours) and a tint toward a colour.
VBlank::IR::Backends::RuntimeFeatures.declare(
  name: :fades,
  needed_by: %i[fade tint],
  hooks: %i[setup screen_set fade_filter paint_fade_for blend_held_by_fade]
)
