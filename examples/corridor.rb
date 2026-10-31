#!/usr/bin/env ruby
# frozen_string_literal: true

# Corridor — a first-person crawl with a status bar, and the example that runs CLOSE TO THE
# LINE on purpose.
#
# Every other example here is comfortable: the heaviest of them uses under half the frame.
# This one is genuinely near the edge. It casts twice as many rays as examples/raycaster.rb,
# draws them into a letterboxed view with a status bar underneath, and spends most of a frame
# doing it. Build it and run `rom.profile` — how little of each frame is left over is the
# point of the example.
#
# WHAT A FRAME IS SPENT ON, and it is not what people guess. Nearly all of it is the ray
# casting: sixty rays, each marching until it meets a wall, each one a handful of table reads
# and a divide. The DRAWING is cheap by comparison — the sky and the floor are one transfer
# each, and a wall column is one fill however tall it is. If you want the frame back, cast
# fewer rays (NUM_COLS below); everything else is rounding. Cast MORE and it stops fitting:
# eighty rays does not hold a frame, and `rom.profile` shows the rate drop when you run it.
#
# `inside` IS WHY THE STATUS BAR IS FREE. The view is drawn inside a 240x128 window, so the
# thirty-two rows under it are never touched by the sky, the floor or a wall column — those
# pixels are not drawn and then covered, they are not drawn. Without it a near wall paints the
# full height of the screen and the bar goes on top, and you pay for every pixel underneath.
#
# Walk with UP / DOWN, turn with LEFT / RIGHT. Gold is scattered through the maze; step on a
# cell to take it, and the bar counts what you have. Build it:
#   ruby examples/corridor.rb

require_relative "../lib/vblank"

module Corridor
  MAP_W = 8 # an 8x8 maze: a solid border ring with a few inner walls
  MAP = Ractor.make_shareable([
    1, 1, 1, 1, 1, 1, 1, 1,
    1, 0, 0, 0, 0, 0, 0, 1,
    1, 0, 1, 1, 0, 0, 0, 1,
    1, 0, 0, 0, 0, 1, 0, 1,
    1, 0, 0, 1, 0, 1, 0, 1,
    1, 0, 0, 1, 0, 0, 0, 1,
    1, 0, 0, 0, 0, 0, 0, 1,
    1, 1, 1, 1, 1, 1, 1, 1
  ])

  # The cells holding gold, as map indices. Walk onto one to take it.
  GOLD = [17, 22, 41, 46, 51, 54].freeze

  NUM_COLS = 60 # sixty strips across the view, four pixels each: 240 wide
  COL_W = 4
  STEPS_PER_CELL = 10         # a ray advances a tenth of a cell at a time...
  STEP = 1.0 / STEPS_PER_CELL
  STEPS = 50                  # ...50 times, so it sees five cells before it gives up

  # The view is the top of the screen; the status bar has the rest.
  VIEW_H = 128
  BAR_H = 160 - VIEW_H
  HORIZON = VIEW_H / 2        # the eye line: wall columns are centered here
  WALK = 0.09                 # how far a step of walking moves, in cells

  # The direction tables. A full turn is 512 angle units. Cosine is the same curve read
  # a quarter turn (128) later.
  TURN = 512
  QUARTER = TURN / 4
  SIN = Ractor.make_shareable((0...TURN).map { |a| Math.sin(a * 2 * Math::PI / TURN) })

  # How tall a wall one cell away stands in the view. The band keeps a wall you are
  # nose-to-nose with from filling the world, and one at the far end from vanishing.
  WALL_SCALE = 72
  SOFTEN = 0.5
  MAX_H = VIEW_H - 8
  MIN_H = 6

  SKY = Ractor.make_shareable(VBlank::Graphics::Color.rgb(4, 6, 11))
  FLOOR = VBlank::Graphics::Color.rgb(10, 7, 4)
  NEAR = Ractor.make_shareable(VBlank::Graphics::Color.rgb(29, 26, 20))
  MID = VBlank::Graphics::Color.rgb(19, 17, 13)
  FAR = Ractor.make_shareable(VBlank::Graphics::Color.rgb(10, 9, 8))
  BAR = VBlank::Graphics::Color.rgb(2, 2, 4)
  GOLD_C = VBlank::Graphics::Color.rgb(31, 27, 6)
  WALL_SHADES = [NEAR, MID, FAR].freeze

  # The game, with the ray count left as a parameter. It is a parameter because it is the one
  # knob that decides whether this fits in a frame, and the example is about that: at the
  # sixty rays it ships with the console spends about four fifths of a frame, and at eighty it
  # does not fit at all. A test plays both sides on the console to show it.
  def self.game(name: "CORRIDOR", cols: NUM_COLS, col_w: COL_W)
    VBlank.game(name, consoles: %i[gba]) do
      screen :bitmap, tear_free: true # double-buffered: the whole view is repainted each frame
      enable_sound
      define_sound :chime, frequency: 1400, duty: :half, decay: :fast

      sin = table :sin, SIN
      world = table :world, MAP, width: :byte
      gold_at = table :gold_at, GOLD, width: :byte
      taken = list :taken, capacity: GOLD.length, width: :byte

      view = 0    # the way the player faces (0..511, wraps freely)
      px = 3.5      # standing in the middle of cell (3, 3)
      py = 3.5
      score = 0

      step_x = var :_step_x, 0.0 # this frame's walking step
      step_y = var :_step_y, 0.0
      nx = var :_nx, 0.0    # where a step would put the player
      ny = var :_ny, 0.0
      cell = var :_cell, 0  # the map index the player stands on
      ang = var :_ang, 0    # this column's ray angle
      dx = var :_dx, 0.0    # the ray's step in x and y
      dy = var :_dy, 0.0
      rx = var :_rx, 0.0    # the ray's current position
      ry = var :_ry, 0.0
      hit = var :_hit, 0    # has this ray met a wall yet?
      dist = var :_dist, 0.0 # how far it got, in cells
      seen = var :_seen, 0.0 # ...and how far that is once the fan is corrected for
      col_h = var :_col_h, 0
      top = var :_top, 0

      # One slot per piece of gold, 0 until it is taken. Filled once, at boot.
      GOLD.each_index { taken << 0 }

      game_loop do
        # The status bar first, so the view is painted over a clean strip either way.
        dma_fill_rect 0, VIEW_H, 240, BAR_H, BAR

        inside 0, 0, 240, VIEW_H do
          # The room: sky down to the eye line, boards below it. Two block fills, so the
          # backdrop costs the same however much of it a wall ends up covering.
          dma_fill_rect 0, 0, 240, HORIZON, SKY
          dma_fill_rect 0, HORIZON, 240, VIEW_H - HORIZON, FLOOR

          repeat(cols) do |col|
            # Fan the rays across the view: this column looks a little left or right of center,
            # centered on the odd number in between so no ray points exactly straight ahead.
            ang = view
            ang += col * 2
            ang -= cols - 1

            # Step vector for this ray. cos(ang) = sin[ang + QUARTER]; a quarter cell per step.
            dx = sin[ang + QUARTER] * STEP
            dy = sin[ang] * STEP

            rx = px
            ry = py
            hit = 0
            dist = STEPS * STEP # if nothing is hit in range, treat it as far away

            # March until the ray meets a wall, and stop there. This loop is the frame.
            repeat(STEPS, stop_when: hit == 1) do |step|
              rx += dx
              ry += dy
              if world[(ry.to_i * MAP_W) + rx.to_i] == 1
                hit = 1
                dist = step * STEP
              end
            end

            # Correct for the fan, so a flat wall reads flat instead of bowing outward.
            seen = dist * sin[(col * 2) + (QUARTER - (cols - 1))]

            # The perspective divide: a wall twice as far covers half as much of the view.
            col_h = (WALL_SCALE / (seen + SOFTEN)).to_i
            col_h.clamp! MIN_H, MAX_H
            top = HORIZON
            top -= col_h / 2

            # Shade by distance, which is what reads as depth. Exactly one band runs.
            if dist < 1.5
              draw_rect_at((col * col_w), top, col_w, col_h, NEAR)
            else
              if dist < 3.0
                draw_rect_at((col * col_w), top, col_w, col_h, MID)
              else
                draw_rect_at((col * col_w), top, col_w, col_h, FAR)
              end
            end
          end
        end

        # Turning and walking, the same as any first-person game: the step is WALK cells in the
        # direction the player faces, and it is only taken if the cell it lands in is empty.
        view -= 4 if held(:left)
        view += 4 if held(:right)

        step_x = sin[view + QUARTER] * WALK
        step_y = sin[view] * WALK
        step_x.flip! if held(:down)
        step_y.flip! if held(:down)

        if held(:up) || held(:down)
          nx = px
          nx += step_x
          ny = py
          ny += step_y
          if world[(ny.to_i * MAP_W) + nx.to_i] == 0
            px = nx
            py = ny
          end
        end

        # Gold: if the cell underfoot holds a piece nobody has taken, take it.
        cell = (py.to_i * MAP_W) + px.to_i
        repeat(GOLD.length) do |g|
          if gold_at[g] == cell && taken[g] == 0
            taken[g] = 1
            score += 1
            beep :chime
          end
        end

        # The bar: how much gold, out of how much there is.
        draw_text "GOLD", 8, VIEW_H + 9, :white
        draw_number :score, 46, VIEW_H + 10, GOLD_C, digits: 2, font: :tiny
        draw_text "OF", 66, VIEW_H + 9, :gray
        draw_number GOLD.length, 82, VIEW_H + 10, :white, digits: 2, font: :tiny
      end
    end
  end

  # The default corridor, built once per core rather than kept in a constant. `game` above
  # takes how many columns and how wide, so its block reaches for those — and a block that
  # reaches for anything around it belongs to the core that made it and cannot be shared.
  # One per core costs a build each and can be used from anywhere.
  def self.default = Ractor.store_if_absent(:corridor_game) { game }

  def self.program = default.program
  def self.build_rom(**kwargs) = default.build_rom(**kwargs)
end

Corridor.default.write_if_main
