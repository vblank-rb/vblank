# frozen_string_literal: true

# `pixelate`: the picture in flat blocks. It names the block scenery is painted in, paints a kept
# sprite in blocks while they are bigger than a pixel, and reads a painted screen in them.
VBlank::IR::Backends::RuntimeFeatures.declare(
  name: :pixelation,
  needed_by: %i[pixelate],
  hooks: %i[setup screen_set scenery_block_size paint_kept_sprite shown_plain shown_columns shown_row]
)
