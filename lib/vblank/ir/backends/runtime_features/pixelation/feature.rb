# frozen_string_literal: true

# `pixelate`: the picture in flat blocks. It names the block scenery and sprites are painted in, and
# reads a painted screen in them.
VBlank::IR::Backends::RuntimeFeatures.declare(
  name: :pixelation,
  needed_by: %i[pixelate],
  hooks: %i[setup screen_set block_size shown_plain shown_columns shown_row]
)
