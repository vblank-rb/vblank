# frozen_string_literal: true

module VBlank
  module DSL
    # Sprites the console draws
    #
    # On `screen :tiled`, `sprite :hero, at: [x, y]` hands back one of these: a moving picture
    # the console draws over the backgrounds itself. From the game's side it works as a Sprite
    # on a painted screen does, so the same code steers either.
    #
    # ```ruby
    # screen :tiled
    # background :room, tiles: :dungeon, map: ROOM
    # hero = sprite :hero, at: [100, 60]
    # game_loop do
    #   wait_vblank
    #   hero.x += 2 if held(:right)   # steer it the way any number is changed
    # end
    # ```
    #
    # There is no draw call to write: once a frame, in the short gap between frames, the
    # framework tells the console where each sprite is, and it shows on the next frame. The
    # console draws the whole picture again every frame, so a sprite costs nothing to move and
    # leaves no trail. It can also turn to any angle (#face_angle), change size (#scale), be
    # drawn with other colours (#draw_with) and move between layers (#put_in_layer).
    #
    # On `screen :bitmap` a game gets one of these with `sprite ..., over_picture: true`. It is
    # then in front of all of the painted picture.
    #--
    # Builder#wait_vblank lists every hardware sprite's object for the per-frame draw.
    #++
    class HardwareSprite
      include Bounds       # gains overlaps? from left / top / right / bottom (its collision box)
      include PixelBounds  # ...and makes that overlaps? shape-accurate (per-pixel) by default

      Build = IR::Build

      # Built by Builder#hardware_sprite, which reserves the object name, boots the
      # position/visibility variables, and records the object declaration. The names
      # passed here are hidden state the player never sees; `x`/`y` expose the position.
      #
      # @param builder [Builder] the build these operations record into
      # @param object_name [Symbol] the declared object this handle steers
      # @param x [Symbol] the variable holding the sprite's current x (exposed as #x)
      # @param y [Symbol] the variable holding its current y (exposed as #y)
      # @param active [Symbol] 1 while shown, 0 while hidden
      # @param hitbox [Array(Integer,Integer,Integer,Integer)] the collision box [x, y, w, h]
      #   relative to the sprite's top-left (by default the box around its visible pixels)
      # @param poses [Array<Symbol>] the sprite's picture(s), for the per-pixel collision test
      # @param pixel_perfect [Boolean] collide on the drawn pixels (true) or just the box (false,
      #   set when the sprite was given an explicit hitbox:)
      # @param facing_var [Symbol, nil] the variable holding which pose is showing (faceted only)
      # @param facing_dirs [Hash{Symbol=>Integer}, nil] direction -> pose index (faceted only)
      def initialize(builder, object_name:, x:, y:, active:, hitbox:, poses:, pixel_perfect:,
                     object_node: nil, facing_var: nil, facing_dirs: nil, frame_var: nil, frames_per_dir: 1,
                     clips: nil, clip_off_var: nil, clip_len_var: nil)
        @builder = builder
        @object_name = object_name
        @object_node = object_node # the IR object node; turning it swaps in a variable angle
        @angle_var = nil           # allocated the first time the sprite is told to turn
        @scale_var = nil           # ...and this the first time it is told to resize
        @x_var = x
        @y_var = y
        @active = active
        @hit_x, @hit_y, @hit_w, @hit_h = hitbox # collision box, offset from the sprite's top-left
        @poses = poses             # the picture(s) the per-pixel collision test reads
        @pixel_perfect = pixel_perfect
        @facing_var = facing_var   # the variable the object's pose selector reads (facing, or single pose)
        @facing_dirs = facing_dirs # direction -> facing index, for face / auto-facing move
        @frame_var = frame_var     # a directional-animation OR named-clip frame variable; nil otherwise
        @frames_per_dir = frames_per_dir # frames per direction (1 unless a directional animation)
        @clips = clips             # named animations from an Aseprite sheet (name -> {off, len}); nil otherwise
        @clip_off_var = clip_off_var # the current clip's start offset (a named-clip sprite)
        @clip_len_var = clip_len_var # the current clip's length
        @walls = nil               # solid-tile Boxes this sprite is blocked by (nil until blocked_by)
      end

      # What per-pixel collision (see PixelBounds) reads off this sprite: the build to
      # record into, its picture set, the pose it's showing now, and whether it collides
      # on its drawn pixels at all.
      def pixel_perfect? = @pixel_perfect # :nodoc:
      def collision_builder = @builder # :nodoc:
      def collision_poses = @poses # :nodoc:
      def collision_pose = pose_index_node # :nodoc:

      # Where this sprite keeps its state, for reading it back under +name+ (IR::SpriteReading).
      def reading_named(name) # :nodoc:
        IR::SpriteReading.new(name: name, x: @x_var, y: @y_var, shown: @active, poses: @poses,
                              facing: @facing_var, frame: @frame_var, frames_per_facing: @frames_per_dir,
                              clip_start: @clip_off_var, angle: @angle_var, scale: @scale_var)
      end

      # Which pose is showing right now, as a value node — the same composition the object's
      # pose selector uses, so per-pixel collision reads the frame the console is drawing. A
      # plain sprite is pose 0, a facing/frames sprite is its selector, and a directional
      # animation is facing * frames_per_direction + frame.
      def pose_index_node # :nodoc:
        return Build.binop(:+, Build.var_ref(@clip_off_var), Build.var_ref(@frame_var)) if @clip_off_var
        return Build.int(0) unless @facing_var
        return Build.var_ref(@facing_var) unless @frame_var

        Build.binop(:+, Build.binop(:*, Build.var_ref(@facing_var), Build.int(@frames_per_dir)),
                    Build.var_ref(@frame_var))
      end

      # The object this handle drives — Builder#wait_vblank lists it for the per-frame
      # draw.
      attr_reader :object_name # :nodoc:

      # The object node itself, for the build to read where the sprite sits — its layer, its
      # scene — when it puts sprites in an order (see Builder#draw_in_order).
      attr_reader :object_node # :nodoc:

      # Where this sprite sits in the stack — the layer it was declared in, or nil in a
      # game that names no layers. It's read off the object itself rather than kept here
      # as well, so the handle and the program can never disagree about it.
      def layer = @object_node.layer # :nodoc:

      # The sprite's x, the left of its picture in pixels from the left of the screen, as a
      # number the game changes like any other.
      #
      # ```ruby
      # hero.x += 2 if held(:right)
      # ```
      #
      # The framework reads it every frame to know where the console draws the sprite.
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
      # `:down_left` and `:down_right`. A sprite given `facing:` poses also turns to face the
      # way it moves, when it has a pose for that way. After #blocked_by, a step that would
      # put the sprite into a wall does not happen.
      #
      # ```ruby
      # hero.move :left              # one pixel left
      # hero.move :up_right, by: 3   # diagonals, three pixels at a time
      # hero.move 2, -1              # two right and one up, for a speed the game keeps
      # ```
      #
      # * `by:` - how many pixels a step in a direction is. It is 1 when left out.
      def move(direction_or_dx, dy = nil, by: 1)
        if direction_or_dx.is_a?(Symbol)
          step_x, step_y = Direction.unit(direction_or_dx)
          step(:x, step_x * by) unless step_x.zero?
          step(:y, step_y * by) unless step_y.zero?
          # A sprite with poses turns to face the way it moves — press left, move AND
          # face left in one call (only for a direction it has a pose for).
          face(direction_or_dx) if faceted? && @facing_dirs.key?(direction_or_dx)
        else
          step(:x, direction_or_dx) if direction_or_dx != 0
          step(:y, dy) if !dy.nil? && dy != 0
        end
        self
      end

      # Stops the sprite moving into a background's walls, the tiles its tileset marked
      # `solid:`, and returns the sprite.
      #
      # From then on #move is checked: a step that would put the sprite into a wall does not
      # happen, so it slides along walls and stops at them with no collision code of the
      # game's own. #can_move? asks before a move, to do something else when the way is
      # blocked. Setting `x` and `y` or calling #move_to is never checked, so a game can still
      # put the sprite anywhere.
      #
      # ```ruby
      # world = background :maze, tiles: :bricks, map: MAZE   # bricks marked solid:
      # hero  = sprite :hero, at: [24, 24]
      # hero.blocked_by world
      # game_loop do
      #   wait_vblank
      #   hero.move :right if held(:right)   # walks until a wall, then stops
      # end
      # ```
      def blocked_by(background)
        @solid_cells = background.solid_lookup
        @walls = @solid_cells ? [] : background.solid_boxes
        self
      end

      # Tests whether the sprite could take a step in a direction without going into a wall.
      #
      # The walls are the ones #blocked_by named, so call that first. The answer is a test, as
      # a comparison is, so write it after `if`.
      #
      # ```ruby
      # if hero.can_move?(:left)
      #   hero.move :left
      # else
      #   bump
      # end
      # ```
      #
      # * `by:` - how many pixels the step is. It is 1 when left out.
      def can_move?(direction, by: 1)
        if @walls.nil? && @solid_cells.nil?
          raise ArgumentError, "call blocked_by(background) before can_move? — it needs to know the walls"
        end

        step_x, step_y = Direction.unit(direction)
        clear_of_walls(x + (step_x * by), y + (step_y * by))
      end

      # Puts the sprite at an exact place, setting its `x` and `y` in one call, and returns the
      # sprite.
      #
      # ```ruby
      # hero.move_to 24, 24
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
      # It is where a hero stands in a game whose world scrolls under them, or where a logo
      # sits on a title screen. It centres the sprite's collision box, which is the box round
      # its visible pixels unless it was given a `hitbox:`, so a picture with a see-through
      # margin still looks centred.
      #
      # ```ruby
      # hero = sprite :guy, at: [0, 0]
      # hero.center_on_screen
      # ```
      def center_on_screen
        width, height = @builder.console.screen_size
        move_to(((width - @hit_w) / 2) - @hit_x, ((height - @hit_h) / 2) - @hit_y)
      end

      # Turns the sprite to the pose for a direction, where it stands, and returns the sprite.
      #
      # It is for a sprite given `facing:` poses, and for a direction it has a pose for. The
      # pose shows on the next frame. Given a list of poses and `showing:`, it shows the pose
      # a number the game works out picks, such as an animation step or a state, counting from
      # 0. That costs the same whatever the number of poses, and a number outside the list
      # leaves the pose as it was.
      #
      # ```ruby
      # hero.face :left
      # hero.face [:walk0, :walk1, :walk2], showing: step
      # ```
      #
      # * `showing:` - a number that picks one pose of the list given.
      #--
      # See Builder#write_picked_pose.
      #++
      def face(direction, showing: nil)
        unless faceted?
          raise ArgumentError,
                "this sprite has no poses to face with — give it `facing: { left: :img_l, right: :img_r, ... }`"
        end
        unless showing.nil?
          @builder.write_picked_pose(direction, showing, subject: "sprite :#{@object_name}",
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

      # Turns the sprite to point at an exact angle, in degrees clockwise from upright, about
      # its own middle, and returns the sprite.
      #
      # Where #face swaps between a few fixed poses, this turns the picture itself to any
      # angle: a ship that points wherever it aims, a key that turns. The angle can be a number
      # written in the game or one it works out as it runs. It wraps, so 370 is the same as 10
      # and -90 the same as 270. A sprite that never turns is drawn upright and costs nothing
      # more.
      #
      # ```ruby
      # ship.face_angle 90    # point to the right
      # ship.face_angle aim   # point the way `aim` holds
      # ```
      #--
      # The first turn makes this a rotating sprite (see #ensure_rotatable); the console
      # rotates it in hardware.
      #++
      def face_angle(degrees)
        ensure_rotatable
        fixed = Value.fixed_number(degrees)
        if fixed
          record(Build.set(@angle_var, Build.int(fixed % 360)))
        else
          self.angle = degrees
          wrap_angle
        end
        self
      end

      # Turns the sprite by a number of degrees from the way it points now, and returns the
      # sprite.
      #
      # A positive number turns it clockwise and a negative one the other way. Call it every
      # frame to spin steadily or to steer. The angle wraps, so it can keep turning either way
      # (see #face_angle).
      #
      # ```ruby
      # ship.turn(-3) if held(:left)
      # ship.turn 3 if held(:right)
      # ```
      def turn(degrees)
        ensure_rotatable
        self.angle += degrees
        wrap_angle
        self
      end

      # The way the sprite points, in degrees clockwise from upright, from 0 to 359, as a
      # number to read and compare.
      #
      # ```ruby
      # ship.x += 1 if ship.angle == 90   # pointing right
      # ```
      #
      # Reading it makes the sprite one that can turn, as #face_angle does.
      def angle
        ensure_rotatable
        Value.new(@builder, Build.var_ref(@angle_var), name: @angle_var)
      end

      # Draws the sprite bigger or smaller about its own middle, and returns the sprite; with
      # no size, returns the size as a number to read and change.
      #
      # 1.0 is the size it was drawn at, 2.0 twice as big and 0.5 half: a boss that swells, a
      # coin that pops when it is picked up, an enemy that shrinks into the distance. The size
      # can hold a fraction, and a sprite can turn (#face_angle) and change size at once for
      # the cost of either. Twice the drawn size is the most: the console gives a turned sprite
      # a box twice as wide and tall to swing its corners through, and past that the picture's
      # edges are cut off.
      #
      # ```ruby
      # coin.scale 1.6                    # half again as big
      # coin.scale size                   # whatever `size` holds this frame
      # coin.scale.approach! 1.0, 0.05    # ease it back to its own size
      # ```
      def scale(size = nil)
        ensure_scalable
        return scale_value if size.nil?

        if size.is_a?(Numeric) && size <= 0
          raise ArgumentError,
                "a sprite's size must be more than 0. You gave #{size.inspect}. " \
                "1.0 is the size it was drawn at, 0.5 is half. To make it vanish, use `hide`."
        end
        self.scale_value = size
        self
      end

      # The size variable as a handle. It carries a fraction, so `scale.approach! 2.0, 0.1`
      # and `scale * 2` mean what they read as.
      def scale_value # :nodoc:
        Value.new(@builder, Build.var_ref(@scale_var), name: @scale_var,
                            fraction_bits: Fraction::DEFAULT_BITS)
      end

      # Plays a named animation from the sprite's Aseprite sheet, and returns the sprite.
      #
      # The animation is one of the sheet's tags. It runs from its first frame and loops until
      # the game plays another, showing from the next frame. It is for a sprite made with
      # `from_aseprite:`, and for a name the sheet has.
      #
      # ```ruby
      # bird = sprite :bird, at: [40, 80], from_aseprite: "bird.aseprite"
      # bird.play :flap if pressed(:a)
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

      # Takes the sprite off the screen from the next frame, and returns the sprite.
      #
      # It keeps its place and its place in the layers, and #show brings it back there. Hiding
      # a hidden sprite does nothing.
      #
      # ```ruby
      # coin.hide if hero.overlaps?(coin)
      # ```
      #--
      # Setting the flag is all it takes: the per-frame draw reads it and marks the object's
      # table slot unused.
      #++
      def hide
        record(Build.set(@active, Build.int(0)))
        self
      end

      # Brings a hidden sprite back where it is from the next frame, and returns the sprite.
      #
      # Showing a sprite that is showing does nothing.
      #
      # ```ruby
      # coin.show if respawn_timer == 0
      # ```
      def show
        record(Build.set(@active, Build.int(1)))
        self
      end

      # Draws the sprite with a different list of colours from now on, and returns the sprite.
      #
      # The lists are declared with `colors`, see-through first, and matched to the sprite's
      # own `colors:` list by place, so the shape and shading stay as drawn and only the
      # colours change. Given a list of lists and `showing:`, it draws with the one a number
      # picks, counting from 0; a number outside the list draws the sprite in its own colours.
      # `:own` goes back to its own colours. The change shows on the frame the sprite's place
      # and pose next do, never before or after them.
      #
      # ```ruby
      # ship.draw_with :hurt                                     # one list
      # ship.draw_with [:warm1, :warm2, :warm3], showing: step   # one of several, by a number
      # ship.draw_with :own                                      # back to its own colours
      # ```
      #
      # A sprite whose poses are drawn from several lists shows each pose in its own list's
      # colours, and no one other list lines up with them all. Given a hash, it can follow its
      # lists: name each list it follows, drawn with itself, and a pose drawn from that list
      # shows what the list holds now, whatever the game sets it to hold with `recolor`. A list
      # left out stays as drawn. Or the hash can draw every one of its lists with one other
      # list, place for place: a flash of white for an enemy whatever its kind's colours.
      #
      # ```ruby
      # part.draw_with({ title_1: :title_1, title_2: :title_2 })   # follow both lists
      # enemy.draw_with({ crawler: :white, flyer: :white })        # every list drawn white
      # ```
      #
      # * `showing:` - a number that picks one list of the list given.
      def draw_with(which, showing: nil)
        subject = "The sprite :#{@object_node.declared || @poses.first}"
        # A list a pose's frame picks as the game starts (Builder#list_chosen_at_start?) is
        # followed, as the build that holds the pack draws the sprite with the list it names.
        which = { which => which } if which.is_a?(Symbol) && @builder.list_chosen_at_start?(which)
        if which.is_a?(Hash) && @builder.one_list_for_pose_lists?(which)
          refuse_following_and_swapping!(subject) if @object_node.follows_each
        elsif which.is_a?(Hash)
          one_list = @builder.follow_pose_lists(@object_node, which, poses: @poses, showing: showing, subject: subject)
          refuse_following_and_swapping!(subject) if @recolors && one_list.nil?
          return self unless one_list

          which = one_list
        end
        recolors
        undo_drawn_with_from_start unless which.is_a?(Symbol) && which != Recolors::OWN && showing.nil?
        @recolors.draw_with(Value.new(@builder, Build.var_ref(@colors_var), name: @colors_var), which, showing)
        self
      end

      # The sprite drawn with the list +name+ from power-on (`sprite ..., draw_with: name`): its choice
      # of colours starts at that list, so it never shows its own colours, and its object says so
      # (IR::Nodes::Object#drawn_with_from_start). The list is checked as #draw_with checks it. A
      # later `draw_with :own`, or a list picked by a number, which can name none, takes the mark away.
      def draw_with_from_power_on(name) # :nodoc:
        start = recolors.number_of_list(name)
        @colors_boot.value = Build.int(start)
        @object_node.drawn_with_from_start = true
        self
      end

      # Puts the sprite in another of the declared layers from now on, and returns the sprite.
      #
      # It is for a sprite that goes behind a room's top layer on its ground floor, in front of
      # it upstairs, and behind every layer on a flight of stairs. Given a list of layers and
      # `showing:`, it puts the sprite in the one a number picks, counting from 0; a number
      # outside the list leaves it in the layer it was declared in. The change shows on the
      # frame the sprite's place and pose next do, never before or after them. A sprite shown
      # `over_picture: true` is in front of all of the painted picture, and is refused.
      #
      # ```ruby
      # hero.put_in_layer :walking                                   # one layer
      # hero.put_in_layer [:upper, :walking, :stairs], showing: floor # one of several, by a number
      # ```
      #
      # * `showing:` - a number that picks one layer of the list given.
      def put_in_layer(which, showing: nil)
        if @object_node.over_picture
          raise ArgumentError,
                "The sprite :#{@object_node.declared || @object_name} is shown over_picture: true, so it is in front " \
                "of all of the painted picture. It cannot put_in_layer. To put a sprite behind part of a picture, " \
                "use `screen :tiled` and layers."
        end
        @layer_var ||= :"#{@object_name}_layer"
        @builder.put_objects_in_layer([@object_node], @layer_var, which, showing: showing,
                                                                         subject: "The sprite :#{@object_node.declared || @object_name}")
        self
      end

      private

      # The lists the sprite can be drawn with, made the first time it is drawn with one.
      def recolors
        @recolors ||= begin
          @colors_var = :"#{@object_name}_colors"
          @colors_boot = @builder.make_object_recolorable(@object_node, @colors_var)
          Recolors.new(@builder, subject: "The sprite :#{@object_node.declared || @poses.first}", poses: @poses,
                                 choice_var: @colors_var)
                   .attach_object(@object_node)
        end
      end

      # A sprite drawn with a list from power-on (#draw_with_from_power_on) told its own colours, or a
      # list picked by a number, can show its own colours after all, from where that is written on.
      # It still starts in the list it was declared with.
      def undo_drawn_with_from_start = (@object_node.drawn_with_from_start = nil)

      # A sprite that follows its lists shows what each list holds, and one drawn with one other list
      # shows that list: it cannot be told both.
      def refuse_following_and_swapping!(subject)
        raise ArgumentError,
              "#{subject} was told to follow its lists, like `draw_with({ warm: :warm, cold: :cold })`, and to draw " \
              "them with one other list, like `draw_with({ warm: :white, cold: :white })`. A sprite can do one of " \
              "these, not both. To fix this, choose one. To change the colors of a list it follows, use `recolor`."
      end

      # Move +delta+ pixels along one axis. With no walls it's a plain nudge; blocked, it
      # happens only if the sprite's box at the destination is clear of every wall (each
      # axis checked on its own, so the sprite can still slide along a wall it's pressed
      # against).
      def step(axis, delta)
        var = axis == :x ? x : y
        if @solid_cells.nil? && (@walls.nil? || @walls.empty?)
          var.increase! delta
        else
          target_x = axis == :x ? x + delta : x
          target_y = axis == :y ? y + delta : y
          var.increase! delta if clear_of_walls(target_x, target_y)
        end
      end

      # A {Condition} true when the sprite's box, placed at (target_x, target_y), doesn't
      # overlap any wall. "Doesn't overlap" is separated on some axis — the destination
      # ends at or before a wall begins, or begins at or after it ends — so a sprite can
      # rest flush against a wall (touching isn't overlapping) yet never cross into one.
      def clear_of_walls(target_x, target_y)
        return emit_tile_check(target_x, target_y) if @solid_cells

        left = target_x + @hit_x
        top = target_y + @hit_y
        right = left + @hit_w
        bottom = top + @hit_h
        @walls.map do |wall|
          right <= wall.x || wall.right <= left || bottom <= wall.y || wall.bottom <= top
        end.reduce { |clear, test| clear && test }
      end

      # A {Condition} true when the sprite's box, placed at (target_x, target_y), is clear of
      # the background's solid tiles — asked of the grid rather than tested against every
      # rectangle the solid cells merge into.
      #
      # Why it is a routine and not written out here. The check is the same code wherever it
      # is used: the only things that change between one mover and the next are where it is
      # going, and those go in as arguments. Written out at each place that moves, a game
      # with eight movers emitted it sixteen times (each moves on two axes) and the game
      # loop stopped fitting in the console's quick memory — which slows down the whole
      # frame, not just the moving. Called, it is emitted once however many movers there are.
      def emit_tile_check(target_x, target_y)
        routine = @builder.tile_collision_routine(@solid_cells, @hit_x, @hit_y, @hit_w, @hit_h)
        @builder.store!(routine.x, Value.node_for(target_x))
        @builder.store!(routine.y, Value.node_for(target_y))
        @builder.call(routine.name)
        Value.new(@builder, Build.var_ref(routine.clear), name: routine.clear) == 1
      end

      def faceted?
        !@facing_var.nil?
      end

      # Allocate this sprite's rotation-angle variable and attach it to the object the
      # first time the sprite is told to turn — so an object that never turns keeps its
      # constant-0 angle and stays upright for free. Idempotent: later turns reuse it.
      def ensure_rotatable
        @angle_var ||= :"#{@object_name}_angle"
        @builder.make_object_rotatable(@object_node, @angle_var)
      end

      # The same idea for size: allocate the variable and attach it to the object the
      # first time the sprite is resized, so one that never is stays at its drawn size for
      # free. Idempotent.
      def ensure_scalable
        @scale_var ||= :"#{@object_name}_scale"
        @builder.make_object_scalable(@object_node, @scale_var)
      end

      # Fold the angle variable back into 0..359 after a set or turn. One truncated-
      # division modulo (a - (a / 360) * 360, the BIOS Div on hardware) lands it in
      # (-360, 360); a single conditional add of 360 then lifts a negative result into
      # range. Cheap, and it runs at most once per turn.
      def wrap_angle
        self.angle = angle - (angle / 360 * 360)
        self.angle += 360 if angle < 0
      end

      def record(node)
        @builder.record_statement(node)
      end
    end
  end
end
