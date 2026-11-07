# frozen_string_literal: true

# `draw_column_at`: one column of a picture stretched to a height worked out as the game runs. The
# screen never asks it anything; the game calls it.
VBlank::IR::Backends::RuntimeFeatures.declare(
  name: :columns,
  needed_by: %i[draw_column_at],
  hooks: []
)
