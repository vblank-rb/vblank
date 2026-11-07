# frozen_string_literal: true

# `spotlight` and `iris_out`: a light that darkens the picture outside one span of each row.
VBlank::IR::Backends::RuntimeFeatures.declare(
  name: :light,
  needed_by: %i[shade_outside],
  hooks: %i[setup dim_filter]
)
