# frozen_string_literal: true

# The enemies — another part of the game, in its own file. An Array of Structs, which the
# game keeps as a pool: one line says "up to this many of a thing with these fields", and
# `each` runs the same behaviour over whichever are alive. Nothing here keeps parallel
# arrays of positions and states that could fall out of step, because there is nothing to keep.
#
# They also FLAP, and turn to face the ship they are diving at. `drawn_as facing:` gives each
# a picture per direction and a list of frames for each, and `rate:` says how fast to run
# through them — the same words a single `sprite` takes, spelled the same way. What is
# different is that the direction and the place in the cycle belong to each INSTANCE: one
# test written once leaves three enemies leaning three different ways, and one respawned
# just now starts its flap where it starts rather than in step with the rest.
#
# Its per-frame entry point is `update`, the convention every collaborator follows. It
# takes the player and the HUD because that's who it interacts with — a shot that lands
# scores and frees the shot; a ship it touches costs a life. Plain method calls between
# plain objects.
module Shmup
  class Enemies
    LIVE = 3   # how many are in the air at once
    SPEED = 1
    SIZE  = 16

    # One enemy: where it is. It faces left or right, each a pair of pictures flapped through
    # every 8 frames, and which way it leans is its own.
    Enemy = Struct.new(:x, :y) do
      drawn_as facing: { left: %i[flap_l1 flap_l2], right: %i[flap_r1 flap_r2] }, rate: 8
    end

    # Two frames of a flap, and a mirrored pair so an enemy can lean the way it drifts.
    # A wing down...
    WINGS_DOWN = <<~ART
      ..############..
      .##############.
      ################
      ##.##########.##
      ##.##########.##
      ################
      ################
      ################
      ################
      ################
      .##############.
      ..##########.##.
      ...########.....
      ..#.######.#....
      .##..####..##...
      ###...##...###..
    ART

    # ...and a wing up: the same body with the tips raised.
    WINGS_UP = <<~ART
      ###..######..###
      .##.########.##.
      ..############..
      ..#.########.#..
      ..#.########.#..
      ..############..
      ..############..
      .##############.
      ################
      ################
      ################
      ..##########.##.
      ...########.....
      ....######......
      ....######......
      .....####.......
    ART

    def initialize(build)
      @build = build
      build.image(:flap_l1, "." => :transparent, "#" => :red) { WINGS_DOWN }
      build.image(:flap_l2, "." => :transparent, "#" => :red) { WINGS_UP }
      build.image(:flap_r1, "." => :transparent, "#" => :orange) { WINGS_DOWN }
      build.image(:flap_r2, "." => :transparent, "#" => :orange) { WINGS_UP }

      # One line for the whole flock: how many can be in the air. What each carries and the
      # pictures it shows are `Enemy`'s, below.
      @enemies = Array.new(capacity: LIVE)
      spawn_flock
    end

    def update(player, hud)
      @enemies.each do |enemy|
        enemy.y += SPEED                           # drift down
        # Turn to face the ship it is diving at. `face` is the same verb a single sprite
        # takes, and each instance holds its own direction — so this one test, written
        # once, leaves three enemies leaning three different ways in the same frame.
        if enemy.x < player.ship.x
          enemy.face :right
        else
          enemy.face :left
        end
        respawn enemy if enemy.below_bottom?   # off the bottom: come round again

        # A live shot that lands: score it, take the shot out of play, send this one back.
        if player.shot_live == 1
          if player.shot.overlaps?(enemy)
            hud.score_up
            @build.play_enemy_blast # a verb of the game's own (examples/shmup/blasts.rb)
            player.reclaim_shot
            respawn enemy
          end
        end

        # Touched the ship: cost a life, send this one back. A ship just lost cannot be hit
        # for a moment, so an enemy flies straight through it then.
        if player.hittable && player.ship.overlaps?(enemy)
          hud.hit
          @build.play_ship_blast
          player.hurt
          respawn enemy
        end
      end
    end

    # The opening flock, spread across the screen, put in while the flock is empty: the scene
    # makes this part on every pass, and a push onto a full Array stops the game. A new game
    # finds it empty again, which `start_over` does with the rest of the play.
    def spawn_flock
      LIVE.times { |i| @enemies << Enemy.new(36 + (i * 72), i * 52) } if @enemies.empty?
    end

    private

    def respawn(enemy)
      enemy.x = @build.rand(0..(240 - SIZE)) # a fresh column, back at the top
      enemy.y = 0
    end
  end
end
