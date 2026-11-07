# frozen_string_literal: true

# `sprite` and `draw_in_order`: sprites on screen (taken off and put back, kept for a rebuild, turned,
# in crowded lines, over a painted screen, in blocks), the order a draw order places them in, and
# the collision test that reads their pictures.
VBlank::IR::Backends::RuntimeFeatures.declare(
  name: :sprites,
  needed_by: %i[object present_objects pixels_overlap],
  after: %i[tiled],
  hooks: %i[setup screen_crossed paint_level drawn_count drawn_sprite any_sprite_kept front_layer]
)
