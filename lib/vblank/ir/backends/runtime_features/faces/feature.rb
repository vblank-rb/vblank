# frozen_string_literal: true

# `place` and `draw_place`: the faces of a 3D shape filled with a picture, in perspective and lit.
# The screen never asks it anything; the game calls it.
VBlank::IR::Backends::RuntimeFeatures.declare(
  name: :faces,
  needed_by: %i[fill_face],
  hooks: %i[setup]
)
