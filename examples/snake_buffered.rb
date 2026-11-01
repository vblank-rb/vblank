#!/usr/bin/env ruby
# frozen_string_literal: true

# Snake, drawn the simple way — because the screen is double-buffered.
#
# This is the same game as examples/snake.rb, with one deliberate difference in how
# it draws. The other Snake is careful: it paints the board once and then, every
# step, touches only the few cells that change (new head, old head, vacated tail).
# It has to be, because on a single-buffered screen redrawing the whole board every
# frame does too much work to finish in the brief safe window, and the picture
# tears once the snake gets long.
#
# Here we don't bother. Every frame just clears the screen and repaints everything —
# walls, food, the entire snake body, the score — the obvious way you'd want to
# write it. It stays perfectly clean no matter how long the snake grows, because
# `screen :bitmap, tear_free: true` draws to a hidden screen and shows it all at
# once, so a half-finished frame is never visible. The only cost of doing more work
# is a lower frame rate, never a torn image.
#
# That's the whole point: remove that one flag and this identical code goes back to
# tearing in direct-color Mode 3. Double buffering is what lets you write the naive
# version.
#
# The rules are unchanged: d-pad steers, eat the red food to grow and score, hit a
# wall or yourself and it's game over, START to play.
#
# Run it to build examples/snake_buffered.gba:
#   ruby examples/snake_buffered.rb

require_relative "../lib/vblank"

module BufferedSnake
  # --- Build-time constants (plain Ruby, resolved before any code is emitted) ---
  SCREEN_W = 240
  SCREEN_H = 160

  CELL = 8                     # an 8x8 cell — cells land on even columns, which the
  COLS = SCREEN_W / CELL       # buffered screen needs (it writes two pixels at once)
  ROWS = SCREEN_H / CELL

  HEADER_ROWS = 2
  MIN_COL = 1
  MAX_COL = COLS - 2
  MIN_ROW = HEADER_ROWS + 1
  MAX_ROW = ROWS - 2

  TOP_WALL_Y    = HEADER_ROWS * CELL
  BOTTOM_WALL_Y = (ROWS - 1) * CELL
  RIGHT_WALL_X  = (COLS - 1) * CELL
  WALL_H        = SCREEN_H - TOP_WALL_Y

  # The header readout: a "SCORE" label with its figures one gap past the end of the
  # word, wherever the font puts that (see `score_num_x` in the build).
  SCORE_LABEL_X = 8
  SCORE_GAP     = 12
  SCORE_Y       = 4

  # The game-over screen puts a label and its number either side of the middle — the
  # word pushed up against it from the left, the figures from the right of it.
  STAT_GAP    = 6
  STAT_LABEL  = (0...(SCREEN_W / 2))
  STAT_NUMBER = (((SCREEN_W / 2) + STAT_GAP)...SCREEN_W)

  BODY_CAP = (MAX_COL - MIN_COL + 1) * (MAX_ROW - MIN_ROW + 1)

  STEP = 6                     # frames between moves
  START_ROW   = (MIN_ROW + MAX_ROW) / 2
  START_CELLS = Ractor.make_shareable([[5, START_ROW], [6, START_ROW], [7, START_ROW], [8, START_ROW]])
  FOOD_TRIES = 8

  # The snake on the title: a strip of skin 32 columns wide, each column drawn two pixels across,
  # with a diagonal stripe so that it reads as a body sliding along.
  SKIN_W = 32
  SKIN = Ractor.make_shareable(Array.new(8) { |row| Array.new(SKIN_W) { |col| ((col + row) % 8) < 2 ? "o" : "#" }.join }.join("\n"))
  SKIN_X = (SCREEN_W - (SKIN_W * 2)) / 2
  SKIN_Y = 66
  SKIN_TALL = 12 # the strip is drawn 8 rows high and stretched to this

  # How far down each column hangs, one wave of it over 16 columns, 0 to 8 pixels.
  SWAY = Ractor.make_shareable((0...16).map { |i| ((Math.sin(i * 2 * Math::PI / 16) + 1) * 4).round })

  GAME = VBlank.game("SNAKEBUF", consoles: %i[gba]) do
    screen :bitmap, tear_free: true # <-- the whole difference. Remove it and it tears.
    enable_sound

    image :skin, "#" => :green, "o" => :yellow do
      SKIN
    end
    sway = table :sway, SWAY, width: :byte
    wriggle = 0 # how far the wave has travelled along the title's snake

    # One gap past the end of the word, whatever the word is — the font is the only
    # thing that knows how wide "SCORE" comes out.
    score_num_x = SCORE_LABEL_X + text_width("SCORE") + SCORE_GAP

    define_sound :eat, frequency: 880, duty: :quarter, decay: :fast
    define_sound :die, frequency: 140, duty: :half, decay: :medium

    # The body: two parallel lists, one entry per cell (xs[i], ys[i]).
    xs = list :xs, capacity: BODY_CAP
    ys = list :ys, capacity: BODY_CAP

    state    = 0    # 0 = title, 1 = playing, 2 = game over
    blink    = true
    dx       = 1
    dy       = 0
    ndx      = 1
    ndy      = 0
    hx       = 0
    hy       = 0
    food_x   = var :food_x, 0
    food_y   = var :food_y, 0
    score    = 0
    self_hit = false
    placed   = false # Pick a random empty cell for the food (placement only; drawing happens in the
    # every-frame repaint). Tries a handful of random cells, keeping the first that
    # isn't under the snake.
    func :spawn_food do
      placed = false
      FOOD_TRIES.times do
        unless placed
          roll :food_x, MIN_COL..MAX_COL
          roll :food_y, MIN_ROW..MAX_ROW
          placed = true
          repeat(xs.length) do |i|
            placed = false if xs[i] == food_x && ys[i] == food_y
          end
        end
      end
    end

    # Repaint the ENTIRE board from scratch. This is the whole demo: on a single-
    # buffered screen this would tear once the body grew; here it can't, so we just
    # do it every frame instead of tracking what changed.
    func :draw_all do
      clear_screen :black
      draw_text "SCORE", SCORE_LABEL_X, SCORE_Y, :gray
      dma_fill_rect 0, TOP_WALL_Y, SCREEN_W, CELL, :gray            # top wall
      dma_fill_rect 0, BOTTOM_WALL_Y, SCREEN_W, CELL, :gray         # bottom wall
      dma_fill_rect 0, TOP_WALL_Y, CELL, WALL_H, :gray             # left wall
      dma_fill_rect RIGHT_WALL_X, TOP_WALL_Y, CELL, WALL_H, :gray  # right wall
      draw_number score, score_num_x, SCORE_Y, :white, digits: 3
      draw_rect_at food_x * CELL, food_y * CELL, CELL, CELL, :red
      repeat(xs.length) do |i|
        draw_rect_at xs[i] * CELL, ys[i] * CELL, CELL, CELL, :green
      end
      draw_rect_at xs.last * CELL, ys.last * CELL, CELL, CELL, :white # head
    end

    # Start a fresh game: reset the body, face right, zero the score, place the food.
    # No board painting here — the playing scene repaints every frame anyway.
    func :new_game do
      list :xs, capacity: BODY_CAP
      list :ys, capacity: BODY_CAP
      START_CELLS.each do |cx, cy|
        xs.push cx
        ys.push cy
      end
      dx = 1
      dy = 0
      ndx = 1
      ndy = 0
      score = 0
      call :spawn_food
      state = 1
    end

    # Advance the snake one cell — pure game logic, no drawing (draw_all handles the
    # picture). Commit the buffered turn, work out the new head, then die, eat, or
    # slide.
    func :step_snake do
      dx = ndx
      dy = ndy
      hx = xs.last + dx
      hy = ys.last + dy

      self_hit = false
      repeat(xs.length) do |i|
        self_hit = true if xs[i] == hx && ys[i] == hy
      end

      dead = hx < MIN_COL || hx > MAX_COL || hy < MIN_ROW || hy > MAX_ROW || self_hit
      if dead
        state = 2
        beep :die
      else
        xs.push hx
        ys.push hy
        if hx == food_x && hy == food_y
          score += 1
          beep :eat
          call :spawn_food
        else
          xs.shift
          ys.shift
        end
      end
    end

    scene :title do
      clear_screen :black
      draw_text "SNAKE", :center, 56, :green

      # The snake under the word. `draw_column_at` draws one column of a picture at a place and
      # a height the game works out, so giving every column of the skin its own place along a
      # wave is all it takes to make a stiff strip wriggle. The wave moves along a column a
      # frame; `slice:` says which column of the picture, and `width:` how many pixels across.
      wriggle += 1
      repeat(SKIN_W) do |col|
        draw_column_at :skin, slice: col, x: SKIN_X + (col * 2), top: SKIN_Y + sway[(col + wriggle) & 15],
                              height: SKIN_TALL, width: 2
      end

      every(0.5, :seconds) do
        if blink
          blink = false
        else
          blink = true
        end
      end
      draw_text "PRESS START", :center, 96, :gray if blink
      randomize
      call :new_game if pressed(:start)
    end

    scene :playing do
      if held(:up)
        if dy == 0
          ndx = 0
          ndy = -1
        end
      end
      if held(:down)
        if dy == 0
          ndx = 0
          ndy = 1
        end
      end
      if held(:left)
        if dx == 0
          ndx = -1
          ndy = 0
        end
      end
      if held(:right)
        if dx == 0
          ndx = 1
          ndy = 0
        end
      end

      every(STEP) { call :step_snake }
      call :draw_all # repaint the whole board, every frame — safe because buffered
    end

    scene :game_over do
      clear_screen :black
      draw_text "GAME OVER", :center, 52, :red
      draw_text "SCORE", :right, 80, :gray, within: STAT_LABEL
      draw_number score, :left, 80, :white, digits: 3, within: STAT_NUMBER
      every(0.5, :seconds) do
        if blink
          blink = false
        else
          blink = true
        end
      end
      draw_text "PRESS START", :center, 110, :gray if blink
      call :new_game if pressed(:start)
    end

    game_loop do
      case_var :state do
        when_val 0, :title
        when_val 1, :playing
        when_val 2, :game_over
      end
    end
  end

  def self.program = GAME.program
  def self.build_rom(**kwargs) = GAME.build_rom(**kwargs)
end

BufferedSnake::GAME.write_if_main
