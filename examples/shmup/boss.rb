# frozen_string_literal: true

# The boss — the one sprite in this game that is BIGGER than anything the console draws.
#
# The console has twelve rectangles to draw a sprite with and the largest of them is 64x64.
# This cruiser is 96x48. Written against the hardware that means several objects, each with
# its own position, all nudged in step every frame — and every one of the sprite verbs
# (`move`, `face`, `overlaps?`) written out again per piece, because the hardware has no
# idea they belong together. Here it is one `sprite` with one picture at the size it was
# drawn, and the framework works out the cut. Nothing below says a word about pieces:
# the boss moves, banks, takes fire and dies as one thing, because it IS one thing.
#
# Two things a picture this big cannot do, and both are friendly build errors that name it:
# it cannot TURN (`turn` / `face_angle`) and it cannot RESIZE (`scale`). The console spins
# each object about its own middle, so a turned boss would pull apart. A boss that wants to
# lean does it the way this one does — with a pose, mirrored.
#
# `rom.profile` says how many of the console's 128 sprites it spends, and how many the rest
# of the game has left.
module Shmup
  class Boss
    W = 96
    H = 48

    WAVE   = 90   # frames of enemies before one comes, and between one and the next
    HITS   = 5    # shots it takes before it goes down
    BONUS  = 100  # what killing it is worth, over and above the hits

    SWEEP = 2     # how fast it slides along the top — fast enough to turn before it dives
    DIVE  = 3     # how fast it comes down at you
    TOP   = 12    # the row it settles on between dives
    EDGE  = 240 - W # the far column it can slide to and still be fully on screen
    FUSE  = 100   # frames of sliding before it drops

    HURT = 12     # frames of glowing warm after a shot lands
    DEATH = 48    # ...and of flickering out after the last one
    JOLT = 12     # how big the blocks are, in pixels, when the kill shakes the picture apart

    # The cruiser, banking left: a long gun arm under the left shoulder and a stub fin on
    # the right, so the two directions are pictures you can tell apart. `#` is the hull,
    # `=` the core and the engine glow.
    HULL = <<~ART
      .........................................#####.....#####........................................
      .........................................#####.....#####........................................
      .........................................#####.....#####........................................
      .........................................#####.....#####........................................
      .....................................#########.....#########....................................
      .....................................#########.....#########....................................
      .....................................#########.....#########....................................
      .....................................#########.....#########....................................
      ...............................###############.....###############..............................
      ...............................###############.....###############..............................
      ...............................###################################..............................
      ...............................###################################..............................
      .......................###################################################......................
      .......................#####################=========#####################......................
      .......................#####################=========#####################......................
      .......................##################===============##################......................
      ..............###########################===============###########################.............
      ..............########################=====================########################.............
      ..............########################=====================########################.............
      ..............########################=====================########################.............
      ..####################################=====================####################################.
      ..####################################=====================####################################.
      ..####################################=====================####################################.
      ..####################################=====================####################################.
      .########################################===============#######################################.
      .########################################===============#######################################.
      .###########################################=========####################################.......
      .###################..######################=========######################........######.......
      ...###############...#######################################################.......######.......
      ...###############..#########################################################......#####........
      ...###############.###########################################################........##........
      ...###############.###########################################################........##........
      ...###############.###########################################################........#.........
      ...###############.###########################################################........#.........
      ...###############.........###########################################................#.........
      ...###############.........###########################################..........................
      ...###############.........###########################################..........................
      ...###############.........###########################################..........................
      ...####=======####................#############################.................................
      ...####=======####................#############################.................................
      ...####=======####................#############################.................................
      ...####=======####................#############################.................................
      .....###########.......................##===============##......................................
      .....###########.......................##===============##......................................
      .......#######.........................##===============##......................................
      .......#######.........................##===============##......................................
      ...........................................##=======##..........................................
      ...........................................##=======##..........................................
    ART

    # It takes the ship and the HUD up front — the two things it interacts with — because
    # its behaviour is a set of `func`s declared once here, not a block re-run every frame.
    def initialize(build, player, hud)
      @build = build
      @player = player
      @hud = hud

      # Given its own list of colours, in order, so a shot that lands can swap them for the
      # warm pulse place by place: the hull's colour for the pulse's second, the core's for
      # its third.
      build.image(:boss_left, "." => :transparent, "#" => :magenta, "=" => :green,
                              colors: [:transparent, :magenta, :green]) { HULL }
      # Drawn banking left, and facing right is that same picture reflected — `mirror`
      # turns it about the WHOLE canvas, so the gun arm swaps sides instead of each piece
      # flipping where it stands. The reflected direction stores no pixels of its own.
      @boss = build.sprite(:boss, at: [EDGE, -H], shown: false,
                           facing: { left: :boss_left, right: build.mirror(:boss_left) })

      # A variable that holds a NAME rather than a number, so what the boss is doing reads
      # the way you'd say it out loud. `call` runs the routine of that name, which is
      # exactly one of the five below per frame — no dispatch table to keep in step.
      @phase = build.var(:boss_phase, :away)
      @hits  = build.var(:boss_hits, 0)
      @drift = build.var(:boss_drift, -SWEEP)
      @fuse  = build.var(:boss_fuse, FUSE)
      @flash = build.var(:boss_flash, 0)
      @rammed = build.var(:boss_rammed, 0) # so one swoop through the ship costs one life
      @due = build.var(:boss_due, WAVE) # frames until the next one turns up
      @blocks = build.var(:boss_blocks, 1) # how big the picture's blocks are, 1 being as drawn

      # THE KILL SHAKES THE PICTURE APART. `pixelate` shows the screen in flat blocks of a size
      # the game says, and the console does that as it draws, so nothing is repainted. It reaches
      # the field and leaves the score sharp, because it is placed under :ui as the game's dim is.
      # The blocks shrink back a step at a time, and `each_pass` is the verb for that: it does
      # nothing until `start`, then takes one step a pass, and the step stops it when it arrives.
      @shaking = build.each_pass(:boss_shake) do |job|
        @blocks -= 1
        build.pixelate @blocks, under: :ui
        job.stop if @blocks <= 1
      end

      declare_phases
    end

    def update
      @build.call @phase
      # Taking fire is the same wherever the boss is, so it sits out here and is built once
      # rather than in each of the phases that can be shot at. No hits left means no boss:
      # none has arrived yet, or one is breaking up.
      take_fire if @hits > 0
    end

    # Back to a fresh game: no boss, and a full wave to run before the next one.
    def reset
      @boss.hide
      @phase = :away
      @hits = 0
      @due = WAVE
    end

    private

    def declare_phases
      b = @build
      b.func(:away)     { wait_out_the_wave }
      b.func(:arriving) { come_down }
      b.func(:sweeping) { slide_along_the_top }
      b.func(:diving)   { drop_on_the_ship }
      b.func(:dying)    { break_up }
    end

    # Nothing on screen: let the wave of enemies run, and enter when it is over.
    def wait_out_the_wave
      @due -= 1
      if @due <= 0
        @boss.move_to EDGE, -H
        @boss.face :left
        @drift = -SWEEP
        @hits = HITS
        @flash = 0
        @rammed = 0
        @boss.show
        @phase = :arriving
      end
    end

    # Down from above the screen until it settles on its row.
    def come_down
      @boss.y += DIVE
      if @boss.y >= TOP
        @fuse = FUSE
        @phase = :sweeping
      end
      glow_while_hurt
    end

    # Along the top, banking the way it goes, until the fuse runs out.
    def slide_along_the_top
      @boss.x += @drift
      if @boss.x <= 0
        @drift = SWEEP
        @boss.face :right
      end
      if @boss.x >= EDGE
        @drift = -SWEEP
        @boss.face :left
      end
      @fuse -= 1
      @phase = :diving if @fuse <= 0
      glow_while_hurt
    end

    # Straight down the screen. Dodge sideways or lose a ship — and `overlaps?` reads the
    # boss's whole picture, so the left arm hits you as surely as the middle does.
    def drop_on_the_ship
      @boss.y += DIVE
      if @rammed == 0 && @player.hittable && @player.ship.overlaps?(@boss)
        @hud.hit
        @player.hurt
        @rammed = 1
      end
      climb_back if @boss.below_bottom?
      glow_while_hurt
    end

    # Out of the bottom of the screen and round to the top again.
    def climb_back
      @boss.move_to EDGE, -H
      @rammed = 0
      @phase = :arriving
    end

    # The last shot landed: flicker out, pay the bonus, and start the next wave of enemies.
    # Hiding and showing reach every part of the picture, so the whole cruiser blinks rather
    # than a corner of it.
    def break_up
      glow_while_hurt
      if (@flash % 8) < 4
        @boss.show
      else
        @boss.hide
      end
      if @flash <= 0
        @boss.hide
        @hud.bonus BONUS
        @due = WAVE
        @phase = :away
      end
    end

    # A shot that lands scores, frees the shot, and knocks a hit off. The last one starts
    # the break-up instead.
    def take_fire
      if @player.shot_live == 1
        if @player.shot.overlaps?(@boss)
          @hud.score_up
          @player.reclaim_shot
          @hits -= 1
          @flash = HURT
          if @hits <= 0
            @flash = DEATH
            @phase = :dying
            @blocks = JOLT
            @shaking.start
          end
        end
      end
    end

    # Glow warm while it is hurt, and in its own colours the rest of the time. The pulse
    # steps every other frame, and like hiding and showing, the colours reach every part of
    # the picture at once.
    def glow_while_hurt
      if @flash > 0
        @flash -= 1
        @boss.draw_with WARM, showing: (@flash >> 1) & 3
      else
        @boss.draw_with :own
      end
    end
  end
end
