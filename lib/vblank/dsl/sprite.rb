# frozen_string_literal: true

module VBlank
  module DSL
    # Sprites on a painted screen
    #
    # A sprite is a named picture with a place of its own that moves round the screen and
    # leaves no trail. On `screen :bitmap`, `sprite :heart, at: [x, y]` hands one of these back
    # (on `screen :tiled` it is a HardwareSprite, which the console draws itself).
    #
    # ```ruby
    # hero = sprite :heart, at: [100, 60]
    # game_loop do
    #   wait_vblank
    #   hero.x -= 2 if held(:left)    # steer it the way any number is changed
    #   hero.x += 2 if held(:right)
    # end
    # ```
    #
    # There is no draw call to write. Once a frame, in the short gap between frames when the
    # screen is safe to change, the framework puts back what each sprite covered and draws it
    # where it is now. A sprite remembers the pixels under itself, so it works over any picture
    # and never smears a trail, and the game never has to clear and draw the whole screen
    # again. Sprites can pass over and touch each other: every one is taken off before any is
    # drawn again. Moving a sprite is changing its `x` and `y`, and the move shows on the next
    # frame.
    #
    # `hide` puts back what the sprite covered and stops drawing it; `show` brings it back
    # where it is. A sprite can slide half off a side of the screen. What a painted sprite
    # cannot do is stay stacked over another in a set order: that is what the console's own
    # sprites on `screen :tiled` are for.
    #--
    # The repaint is injected after each `wait_vblank` and goes in two passes over all the
    # sprites (see #erase_node and #draw_node), so each captures clean background and never a
    # neighbour that has not been erased yet.
    #++
    class Sprite
      include Bounds       # gains overlaps? from left / top / right / bottom (its collision box)
      include PixelBounds  # ...and makes that overlaps? shape-accurate (per-pixel) by default

      Build = IR::Build

      # Built by Builder#sprite, which allocates the hidden variables and the backing
      # store and wires the boot-time draw. All the names it passes are hidden state
      # the player never sees; the position pair is what `x`/`y` expose.
      #
      # @param builder [Builder] the build these operations record into
      # @param image [Symbol] the defined image drawn for this sprite
      # @param x [Symbol] the variable holding the sprite's current x (exposed as #x)
      # @param y [Symbol] the variable holding its current y (exposed as #y)
      # @param old_x [Symbol] where it was last drawn, so a move can erase there first
      # @param old_y [Symbol] the y half of the last-drawn position
      # @param active [Symbol] 1 while shown, 0 while hidden (guards the repaint)
      # @param buffer [Symbol] the backing store holding the pixels under the sprite
      # @param hitbox [Array(Integer,Integer,Integer,Integer)] the collision box [x, y, w, h]
      #   relative to the sprite's top-left (by default the box around its visible pixels)
      # @param pixel_perfect [Boolean] collide on the drawn pixels (true) or just the box (false,
      #   set when the sprite was given an explicit hitbox:)
      # @param layer [Symbol, nil] the layer it was declared in — its place in the stack
      # @param source [String, nil] the line it was declared on ("hero.rb:42"), which the
      #   per-frame repaint carries so the cost report can trace that work to this sprite
      # @param painted [Symbol] the variable that is 1 while the sprite is on the picture, with
      #   what it covered remembered (see #erase_node)
      # @param painted_while [Array<Array(Symbol, Integer | Array<Integer>)>] variables and the
      #   value each must hold (or one of the values, for a list) for the sprite to be painted,
      #   on top of being shown — what a scene's sprite
      #   needs to stay off the picture while its scene is not the one running
      # @param scene [Symbol, nil] the scene it was declared inside, if any
      def initialize(builder, x:, y:, old_x:, old_y:, active:, buffer:, hitbox:, pixel_perfect: true,
                     image: nil, poses: nil, facing_var: nil, facing_dirs: nil,
                     frame_var: nil, frames_per_dir: 1,
                     clips: nil, clip_off_var: nil, clip_len_var: nil, layer: nil, source: nil,
                     painted:, painted_while: [], scene: nil)
        @builder = builder
        @source = source
        @painted = painted
        @painted_while = painted_while
        @scene = scene
        @show_nodes = [] # every `show` written so far, so #wait_to_paint can reach them
        @layer = layer             # the layer it was declared in, or nil if the game names none
        @image = image             # a plain sprite draws this one image
        @poses = poses             # a faceted sprite draws poses[pose index] instead
        @pixel_perfect = pixel_perfect
        @facing_var = facing_var   # the variable holding the facing (or the single pose selector)
        @facing_dirs = facing_dirs # direction -> facing index, for face / auto-facing move
        @frame_var = frame_var     # a directional-animation OR named-clip frame variable; nil otherwise
        @frames_per_dir = frames_per_dir # frames per direction (1 unless a directional animation)
        @clips = clips             # named animations from an Aseprite sheet (name -> {off, len}); nil otherwise
        @clip_off_var = clip_off_var # the current clip's start offset (a named-clip sprite)
        @clip_len_var = clip_len_var # the current clip's length
        @x_var = x
        @y_var = y
        @old_x = old_x
        @old_y = old_y
        @active = active
        @buffer = buffer
        @hit_x, @hit_y, @hit_w, @hit_h = hitbox # collision box, offset from the sprite's top-left
      end

      # Where this sprite sits in the stack — the layer it was declared in, or nil in a
      # game that names no layers. A software sprite is painted into the one framebuffer
      # rather than handed to stacking hardware, so its layer is the order it is painted
      # in; the name is what sets what that order has to be.
      attr_reader :layer # :nodoc:

      # The scene this sprite was declared inside, or nil for one every scene shows.
      attr_reader :scene # :nodoc:

      # What to call this sprite in a message. A software sprite has no name of its own —
      # it is named by the art it draws, which is the word the author typed.
      def picture_name = @image || @poses&.first # :nodoc:

      # What per-pixel collision (see PixelBounds) reads off this sprite: the build to
      # record into, its picture set, the pose it's showing now, and whether it collides
      # on its drawn pixels at all.
      def pixel_perfect? = @pixel_perfect # :nodoc:
      def collision_builder = @builder # :nodoc:
      def collision_poses = @poses || [@image] # :nodoc:
      def collision_pose = pose_index_node # :nodoc:

      # Where this sprite keeps its state, for reading it back under +name+ (IR::SpriteReading).
      def reading_named(name) # :nodoc:
        IR::SpriteReading.new(name: name, x: @x_var, y: @y_var, shown: @active, poses: @poses || [@image],
                              facing: @facing_var, frame: @frame_var, frames_per_facing: @frames_per_dir,
                              clip_start: @clip_off_var)
      end

      # Which pose to show right now, as a value node. A plain sprite is pose 0. A facing
      # or frames sprite is its selector. A directional animation composes the two, so the
      # frame animates within whichever direction the sprite faces (facing *
      # frames_per_direction + frame). A named-clip sprite (from Aseprite) is the current
      # clip's start offset plus the frame within it.
      def pose_index_node # :nodoc:
        return Build.binop(:+, Build.var_ref(@clip_off_var), Build.var_ref(@frame_var)) if @clip_off_var
        return Build.int(0) unless @facing_var
        return Build.var_ref(@facing_var) unless @frame_var

        Build.binop(:+, Build.binop(:*, Build.var_ref(@facing_var), Build.int(@frames_per_dir)),
                    Build.var_ref(@frame_var))
      end

      # The sprite's x, the left of its picture in pixels from the left of the screen, as a
      # number the game changes like any other.
      #
      # ```ruby
      # hero.x += 2 if held(:right)
      # hero.x = 0 if hero.x < 0
      # ```
      #
      # The framework reads it every frame to know where to draw the sprite.
      def x
        Value.new(@builder, Build.var_ref(@x_var), name: @x_var)
      end

      # The sprite's y, the top of its picture in pixels from the top of the screen, as a
      # number the game changes like any other.
      #
      # ```ruby
      # hero.y -= 2 if held(:up)
      # ```
      def y
        Value.new(@builder, Build.var_ref(@y_var), name: @y_var)
      end

      # The left edge of the sprite's collision box, in pixels from the left of the screen.
      #
      # The collision box is the rectangle round the sprite's visible pixels, or the `hitbox:`
      # the sprite was given. Its four edges are what Bounds#overlaps? and the screen-edge tests
      # read, so a sprite needs no box of its own.
      def left
        x + @hit_x
      end

      # The top edge of the sprite's collision box, in pixels from the top of the screen.
      def top
        y + @hit_y
      end

      # The right edge of the sprite's collision box: one pixel past its last column.
      def right
        x + @hit_x + @hit_w
      end

      # The bottom edge of the sprite's collision box: one pixel past its last row.
      def bottom
        y + @hit_y + @hit_h
      end

      # Moves the sprite a step in a direction, or by a number of pixels across and down, and
      # returns the sprite.
      #
      # A direction is one of `:up`, `:down`, `:left`, `:right`, `:up_left`, `:up_right`,
      # `:down_left` and `:down_right`, so pressing left reads "move left". A sprite given
      # `facing:` poses also turns to face the way it moves, when it has a pose for that way.
      #
      # ```ruby
      # hero.move :left             # one pixel left
      # hero.move :left, by: 2      # two pixels at a time
      # hero.move :up_right, by: 3  # diagonals too
      # hero.move 2, -1             # two right and one up, for a speed the game keeps
      # ```
      #
      # * `by:` - how many pixels a step in a direction is. It is 1 when left out.
      def move(direction_or_dx, dy = nil, by: 1)
        if direction_or_dx.is_a?(Symbol)
          step_x, step_y = Direction.unit(direction_or_dx)
          self.x += step_x * by unless step_x.zero?
          self.y += step_y * by unless step_y.zero?
          # A sprite with poses turns to face the way it moves — press left, move AND
          # face left in one call. (Only for a direction it actually has a pose for.)
          face(direction_or_dx) if faceted? && @facing_dirs.key?(direction_or_dx)
        else
          self.x += direction_or_dx
          self.y += dy if !dy.nil? && dy != 0
        end
        self
      end

      # Puts the sprite at an exact place, setting its `x` and `y` in one call, and returns the
      # sprite.
      #
      # ```ruby
      # ball.move_to 120, 80
      # ```
      def move_to(px, py)
        self.x = px
        self.y = py
        self
      end

      # Keeps the sprite wholly on the screen, and returns the sprite.
      #
      # It holds the sprite's place so that its collision box never crosses an edge, worked
      # out from the sprite's own size, so the game needs no numbers for the edges. Call it
      # after a move to keep a player inside the screen. A see-through margin round the picture
      # can still slide off. `stay_on_screen` is the same.
      #
      # ```ruby
      # hero.move :left if held(:left)
      # hero.clamp_to_screen
      # ```
      def clamp_to_screen
        width, height = @builder.console.screen_size
        x.clamp!(-@hit_x, width - @hit_x - @hit_w)
        y.clamp!(-@hit_y, height - @hit_y - @hit_h)
        self
      end
      alias stay_on_screen clamp_to_screen

      # Puts the sprite in the middle of the screen, worked out from its own size, and returns
      # the sprite.
      #
      # It centres the sprite's collision box, which is the box round its visible pixels unless
      # it was given a `hitbox:`, so a picture with a see-through margin still looks centred.
      #
      # ```ruby
      # logo.center_on_screen
      # ```
      def center_on_screen
        width, height = @builder.console.screen_size
        move_to(((width - @hit_w) / 2) - @hit_x, ((height - @hit_h) / 2) - @hit_y)
      end

      # Turns the sprite to the pose for a direction, where it stands, and returns the sprite.
      #
      # It is for a sprite given `facing:` poses, and for a direction it has a pose for. The
      # pose shows on the next frame. Given a list of poses and `showing:`, it shows the pose
      # the number picks, counting from 0; a number outside the list leaves the pose as it was.
      #
      # ```ruby
      # hero.face :left
      # hero.face [:idle, :step1, :step2], showing: step
      # ```
      #
      # * `showing:` - a number that picks one pose of the list given.
      def face(direction, showing: nil)
        unless faceted?
          raise ArgumentError,
                "this sprite has no poses to face with — give it `facing: { left: :img_l, right: :img_r, ... }`"
        end
        unless showing.nil?
          @builder.write_picked_pose(direction, showing, subject: "this sprite",
                                                         row_of: ->(name) { @facing_dirs[name] }) do |row|
            record(Build.set(@facing_var, row))
          end
          return self
        end
        index = @facing_dirs[direction] or
          raise ArgumentError, "this sprite cannot face #{direction.inspect} — it faces #{@facing_dirs.keys.join(', ')}"

        record(Build.set(@facing_var, Build.int(index)))
        self
      end

      # Refused: a sprite on a painted screen cannot turn to an angle.
      #
      # Turning needs a sprite the console draws: one on `screen :tiled`, or one declared with
      # `over_picture: true` (see HardwareSprite#face_angle). For a few fixed ways, give the
      # sprite `facing:` poses and use #face.
      #--
      # Turning needs the console's sprite rotate/scale; a bitmap sprite is drawn pixel by pixel.
      #++
      def face_angle(_degrees)
        raise ArgumentError, TURN_NEEDS_TILED
      end

      # Refused: a sprite on a painted screen cannot turn. See #face_angle.
      def turn(_degrees)
        raise ArgumentError, TURN_NEEDS_TILED
      end

      TURN_NEEDS_TILED = # :nodoc:
        "This sprite cannot turn to an angle. Turning needs a sprite the console draws: one on " \
        "`screen :tiled`, or one declared with `over_picture: true` on `screen :bitmap`. " \
        "Or face a few fixed ways with `facing:` poses and `face` instead."

      # Refused: a sprite on a painted screen cannot change size.
      #
      # Resizing needs a sprite the console draws, as turning does: one on `screen :tiled`, or
      # one declared with `over_picture: true` (see HardwareSprite#scale). Or draw the sizes
      # needed as separate pictures and swap between them with #face.
      #--
      # A bitmap sprite is copied to the screen pixel for pixel, with no step where a different
      # size could come out.
      #++
      def scale(_size = nil)
        raise ArgumentError, SCALE_NEEDS_TILED
      end

      SCALE_NEEDS_TILED = # :nodoc:
        "This sprite cannot change size. Resizing needs a sprite the console draws: one on " \
        "`screen :tiled`, or one declared with `over_picture: true` on `screen :bitmap`. " \
        "Or draw the sizes you need as separate `image`s and swap between them."

      # Plays a named animation from the sprite's Aseprite sheet, and returns the sprite.
      #
      # The animation is one of the sheet's tags. It runs from its first frame and loops until
      # the game plays another, showing from the next frame. It is for a sprite made with
      # `from_aseprite:`, and for a name the sheet has.
      #
      # ```ruby
      # hero = sprite :hero, at: [40, 80], from_aseprite: "hero.aseprite"
      # hero.play :run if held(:right)
      # ```
      def play(clip)
        raise ArgumentError, "this sprite has no named animations to play — make it with `sprite ..., from_aseprite: \"file.json\"`" unless @clips

        info = @clips[clip] or
          raise ArgumentError, "this sprite has no animation #{clip.inspect} — it has #{@clips.keys.join(', ')}"

        record(Build.set(@clip_off_var, Build.int(info[:off])))
        record(Build.set(@clip_len_var, Build.int(info[:len])))
        record(Build.set(@frame_var, Build.int(0)))
        self
      end

      # Takes the sprite off the screen, putting back the pixels it covered, and returns the
      # sprite.
      #
      # It stays where it is, and #show brings it back there. Hiding a hidden sprite does
      # nothing.
      #
      # ```ruby
      # coin.hide if hero.overlaps?(coin)
      # ```
      def hide
        record(take_off_picture)
        record(Build.set(@active, Build.int(0)))
        self
      end

      # Brings a hidden sprite back where it is, and returns the sprite.
      #
      # Showing a sprite that is showing does nothing.
      #
      # ```ruby
      # coin.move_to 100, 40
      # coin.show
      # ```
      #--
      # Re-captures the pixels there and draws it, then lets the per-frame repaint resume. A
      # scene's sprite shown while its scene may not paint yet is only marked as shown, and
      # the repaint before a later frame draws it (see Builder::Sprites#sprite_painting_state).
      #++
      def show
        @show_nodes << record(Build.if_(active_is(0), *show_nodes))
        self
      end

      # Make this sprite wait for +name+ to hold +value+ before it is painted, on top of
      # whatever it waits for already. For something only known once the whole game is
      # declared: that some scene draws on a screen with no picture to paint a sprite into
      # (see Builder::Sprites#finalize_scene_sprite_handover).
      #
      # A `show` paints on the spot, and the ones already written did not know to wait, so
      # each is given its statements again.
      def wait_to_paint(name, value) # :nodoc:
        @painted_while = [*@painted_while, [name, value]]
        @show_nodes.each do |shown|
          shown.children.clear
          show_nodes.each { |node| shown.add_child(node) }
        end
      end

      # Refused: a sprite on a painted screen cannot be drawn with other colours.
      #
      # A painted screen keeps a whole colour in every pixel, so the sprite has no list of
      # colours to swap. Use `screen :tiled`, where HardwareSprite#draw_with does this, or draw
      # a second picture in the other colours.
      def draw_with(*)
        raise ArgumentError,
              "A sprite on `screen :bitmap` cannot draw_with other colors. That screen keeps a whole color " \
              "in every pixel, so the sprite has no list of colors to swap. To fix this, use `screen :tiled`, " \
              "or draw a second picture in the other colors."
      end

      # Refused: a sprite on a painted screen cannot move to another layer.
      #
      # A painted screen paints its backgrounds into the picture once, so there is nothing for
      # the sprite to go behind later. Use `screen :tiled`, where HardwareSprite#put_in_layer
      # does this.
      #--
      # This sprite is painted into the one picture, back to front by the layer it was declared in.
      #++
      def put_in_layer(*, **)
        raise ArgumentError,
              "A sprite on `screen :bitmap` cannot put_in_layer. That screen paints its backgrounds into " \
              "the picture one time, so a sprite cannot move behind them later. To fix this, use `screen :tiled`."
      end

      # The per-frame repaint runs in two passes across every sprite (see
      # Builder#wait_vblank): first each sprite is erased from where it was, then each
      # is drawn where it is now. Splitting it this way is what lets sprites overlap
      # cleanly — every sprite is gone before any capture happens, so one never grabs
      # another's pixels (which would smear when it later moves off). These two nodes
      # are the two passes.

      # Both carry the line the sprite was declared on: nobody wrote these statements, and
      # the work they do is this sprite's, so that is where a cost report should point.
      #
      # Whether a sprite is shown and whether it is on the picture are two questions, and each
      # sprite keeps a variable for each. Shown is what the game sets with `hide` and `show`.
      # On the picture is a fact about the pixels: the sprite was drawn, what it covered is
      # remembered, and nothing has replaced that part of the picture since. They come apart
      # in two ways. A scene's sprite is shown the whole game and painted only while its scene
      # runs. And any sprite stops being on the picture the moment the game clears the screen
      # under it, though it is still shown and will be drawn again.
      #
      # Erasing asks the second, because only a sprite that is on the picture has pixels worth
      # putting back; put back after a clear, they are a square of the picture that went.
      # Drawing asks the first, and for a scene's sprite whether its scene is the one running.

      # Pass one: erase this sprite from where it was last drawn, restoring what it
      # covered. A no-op while the sprite is not on the picture.
      def erase_node # :nodoc:
        take_off_picture.default_source!(@source)
      end

      # Pass two: draw this sprite where it is now, remembering what's freshly under it
      # so the next frame's erase can put it back. A no-op while hidden.
      def draw_node # :nodoc:
        Build.if_(all_hold(@painted_while, active_is(1)), *paint_nodes).default_source!(@source)
      end

      # Mark this sprite as not on the picture any more, without putting back what it covered.
      # For a sprite whose picture was replaced under it: the game cleared the screen, or a
      # scene on another kind of screen took over, and the pixels it remembers belong to a
      # picture that is gone.
      def forget_painting_node # :nodoc:
        Build.set(@painted, Build.int(0)).default_source!(@source)
      end

      # Draw the sprite for the first time at its start (used by the sprite verb when
      # the sprite begins shown): capture what's under it and draw it there.
      def draw_initial # :nodoc:
        paint_nodes.each { |node| record(node) }
        self
      end

      private

      def faceted?
        !@poses.nil?
      end

      # Capture what's under the current spot, draw the sprite there, and record that
      # spot as where it was last drawn (so the next erase targets it).
      def save_and_draw_nodes
        [Build.save_region(@buffer, ref(@x_var), ref(@y_var)),
         blit_op(ref(@x_var), ref(@y_var)),
         Build.copy(@old_x, @x_var),
         Build.copy(@old_y, @y_var)]
      end

      # The draw op for the sprite's image: a plain blit, or — if it has poses — a
      # blit of whichever pose it's currently facing.
      def blit_op(x_node, y_node)
        if faceted?
          Build.blit_pose(@poses, pose_index_node, x_node, y_node)
        else
          Build.blit(@image, x_node, y_node)
        end
      end

      def record(node)
        @builder.record_statement(node)
      end

      def ref(name)
        Build.var_ref(name)
      end

      def active_is(value)
        Build.binop(:==, ref(@active), Build.int(value))
      end

      # The test that this sprite is drawn on the picture now, with what it covered remembered.
      def on_picture
        Build.binop(:==, ref(@painted), Build.int(1))
      end

      # One test that every variable in +pairs+ holds its value, and +first+ too when given. A
      # value given as a list is any one of them: a scene picked by more than one number.
      def all_hold(pairs, first = nil)
        tests = pairs.map { |name, value| any_held(name, Array(value)) }
        [first, *tests].compact.reduce { |all, test| Build.binop(:and, all, test) }
      end

      # The test that the variable +name+ holds one of +values+.
      def any_held(name, values)
        values.map { |value| Build.binop(:==, ref(name), Build.int(value)) }
              .reduce { |either, other| Build.binop(:or, either, other) }
      end

      # What `show` does to a hidden sprite: mark it shown, and paint it now if it may be.
      def show_nodes
        painting = @painted_while.empty? ? paint_nodes : [Build.if_(all_hold(@painted_while), *paint_nodes)]
        [Build.set(@active, Build.int(1)), *painting]
      end

      # Draw the sprite where it is now and mark it as on the picture.
      def paint_nodes
        [*save_and_draw_nodes, Build.set(@painted, Build.int(1))]
      end

      # Put back what the sprite covered, if it is on the picture, and mark that it no longer is.
      def take_off_picture
        Build.if_(on_picture, Build.restore_region(@buffer, ref(@old_x), ref(@old_y)),
                  Build.set(@painted, Build.int(0)))
      end
    end
  end
end
