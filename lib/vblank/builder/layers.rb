# frozen_string_literal: true

module VBlank
  class Builder
    # Layers: what is in front of what
    #
    # A game is drawn in layers: the scenery, the characters, the score on top. `layers` gives
    # those depths names in one line, and `layer ... do ... end` puts things in them. Without
    # names, the only way to set what sits in front is the order the declarations happen to run
    # in, which is invisible and, in a game split across files, depends on which file loaded first.
    #
    # ```ruby
    # layers :sky, :world, :actors, :ui     # the stack, back to front
    #
    # scene :playing do
    #   layer :world  do background :level, tiles: :world_tiles, map: level end
    #   layer :actors do hero = sprite :hero, at: [100, 60] end
    #   layer :ui     do draw_number :score, 8, 8, :white end
    # end
    # ```
    #
    # The order is global, because "in front of" is a relation across the whole screen, and one
    # line answers the question a reader of somebody else's game has. The assignment is local, in a
    # block, so nothing has to carry a layer keyword.
    #
    # A layer holds things, not brushstrokes. It is not a surface you draw on, so there is no
    # "clear this layer" or "put a pixel on this layer". A layer orders the things the framework
    # draws again for you every frame, which are backgrounds, sprites and tiled text. Anything
    # that paints where it is called stays outside the layers.
    #
    # A scene and a layer are different axes. A scene is when, which state of the game shows
    # this. A layer is where in the stack, what is in front of what. A score can be in `:ui` and
    # in `:playing`, which is on top and only while playing.
    #--
    # Why a layer is not a surface: a bitmap screen has one framebuffer, and a tiled screen's
    # layers are grids of references to shared tiles rather than canvases of their own. Giving
    # each layer its own pixels would mean blending two full screens in software every frame,
    # which costs more than twice the time a frame has and eats the memory besides.
    #++
    module Layers
      # What a layer can hold, by the kind of node a verb records. Held things are the
      # ones the framework draws again every frame, so an order over them means
      # something. Painted ones happen where the call happens — by the time the next
      # frame is drawn they are already part of the picture, and no ordering can reach
      # back and change that.
      #
      # Locked against the whole drawing category by a test, so a new drawing kind has
      # to be classified here on purpose rather than falling into whichever answer the
      # lookup happens to default to.
      #
      # Painting is refused on either screen, and that is a decision rather than an
      # oversight. On a bitmap screen a layer block full of straight-line drawing could
      # be read as paint order and quietly allowed — but only while the same layer is
      # written in one place. Write it in two, with a branch between them, and honoring
      # the order would mean moving emitted drawing across that branch, which cannot be
      # done. One answer everywhere beats one that holds until a game grows.
      IN_A_LAYER = {  # :nodoc:
        # held — declared once, drawn again every frame, so a layer can order them
        object: :held,
        background: :held,

        # painted — these happen where the call happens
        pixel: :painted,
        fill_rect: :painted,
        draw_rect_at: :painted,
        draw_column_at: :painted,
        fill_face: :painted,
        draw_place: :painted,
        clear_screen: :painted,
        blit: :painted,
        draw_text: :painted,
        draw_digit: :painted,

        # the whole screen — these describe what the display shows, not one thing in it
        camera: :whole_screen,
        fade: :whole_screen,
        tint: :whole_screen,
        pixelate: :whole_screen,
        hide_sprites: :whole_screen,

        # nothing a layer has an opinion about: the display mode, a background's window,
        # and the painting the framework itself does to put a software sprite on screen
        # and take it off again. A handle's own painting reaches the tree by another
        # route (Builder#record_statement) and never asks this question, so these are
        # here for completeness rather than because a layer block can meet one.
        screen: :free,
        present_objects: :free,
        scroll_background: :free,
        place_bar: :free,
        box_background: :free,
        # ...and one cell of it (or a block of cells) becoming a different tile, or the whole of it becoming
        # another map. Both change a background that already has a depth of its own, so
        # neither is itself at one.
        set_tile: :free,
        set_tile_block: :free,
        show_map: :free,
        show_held_tiles: :free,
        # ...or a run of its tiles painted from a list, which changes pixels, not depth.
        copy_tiles: :free,
        copy_owed_tiles: :free,
        # ...or sprite tiles loaded, which change pixels of every pose drawn from them.
        load_sprite_tiles: :free,
        background_colors: :free,
        # ...or a list of colours holding other colours, which reaches every sprite drawn
        # with it, at whatever depth each one is.
        color_list_holds: :free,
        # ...or a group of sprite pictures put up, which reaches every sprite showing one of
        # them, at whatever depth each one is.
        show_picture_group: :free,
        affine_background: :free,
        scroll_rows: :free,
        # ...and a light, which darkens the finished picture wherever its circle is not,
        # whatever depth each thing there sits at.
        shade_outside: :free,
        # ...or worked out again for the picture being drawn.
        show_light_now: :free,
        blit_pose: :free,
        save_region: :free,
        restore_region: :free,
        # ...and how see-through the see-through layer is, which the framework puts at the
        # frame boundary. It already knows the layer it is about, so it belongs to none.
        see_through: :free,
      }.freeze

      # Declares the stack of layers, backmost first. This one line sets what is in front of what.
      #
      # ```ruby
      # layers :sky, :world, :actors, :ui
      # ```
      #
      # Every layer that a `layer` block names has to be in here. Declaring the stack changes
      # nothing on its own: it names depths, and things put themselves in them.
      #
      # Two neighbours can share a level, written as a list of their own inside the line. Every
      # background has a level of its own otherwise, and the console stacks only a few, so four
      # backgrounds and sprites behind all of them is one level too many. The console can put two
      # backgrounds at one level and still tell them apart, so the list still sets which is in
      # front: the later one, as anywhere else in the stack. What it cannot do is put a sprite
      # between the two. A sprite at that level is drawn in front of both, so a sprite goes in the
      # list's last layer or somewhere else in the stack, never in an earlier layer of the list.
      #
      # ```ruby
      # layers :stairs, [:ground, :scenery], :walking, :panel
      # ```
      #
      # A stack written as one list (`layers %i[sky world ui]`) is the stack, not three layers
      # sharing one level.
      #
      # * `names` - the layers as symbols, back to front. A list of symbols inside the line is a
      #   shared level.
      #
      # Returns the stack.
      def layers(*names)
        names = names.first if names.length == 1 && names.first.is_a?(Array)
        check_stack_not_declared!
        shared = names.select { |name| name.is_a?(Array) }
        shared.each { |group| check_shared_level!(group) }
        names = names.flatten
        check_stack_names!(names)

        @layer_stack = names
        @shared_levels = shared
        # Held so a `layer` block can mark later that its layer is see-through: the stack
        # is one thing and it is declared here, but which of its layers you can see
        # through is written where that layer is opened.
        @layers_node = record(Build.layers(names, shared: shared))
        names
      end

      # Puts everything the block declares in one layer, and returns what the block ends on.
      #
      # The block runs as the rest of the game does, so every verb is available inside it and
      # the pattern of building parts of a game in other files works. Only the things that have a
      # depth, such as backgrounds and sprites, take this layer's depth. A layer holding one thing
      # reads as one line, and one holding several is written like anything else with a block.
      #
      # ```ruby
      # hero = layer(:actors) { sprite :hero, at: [100, 60] }
      #
      # layer :actors do
      #   hero = sprite :hero, at: [100, 60]
      #   enemies = Enemies.new(self)
      # end
      # ```
      #
      # `transparency:` sets how much of what is behind the layer shows through it, as water,
      # glass, fog or a dimmed backdrop behind a menu does. 0 is solid and 100 is invisible.
      # Whatever sits directly under the layer at a pixel shows through it, anything in front of
      # it draws solid, and where the layer itself has a see-through tile, what is behind shows
      # plain. Nothing is redrawn, so it costs nothing however much is on screen.
      #
      # ```ruby
      # layer :water, transparency: 40 do
      #   background :surface, tiles: :ripples, map: water
      # end
      # ```
      #
      # The amount can be something the game works out, such as fog that thickens or a menu
      # backdrop that dims in. Write a variable where you would write a number. A number is sent
      # to the display once, and an amount that can change is sent again before every frame.
      #
      # ```ruby
      # mist = var :mist, 0
      # layer :air, transparency: 100 - mist do
      #   background :fog, tiles: :weather, map: sky
      # end
      # ```
      #
      # To show the layer and what is behind it by different amounts, give `shows:` and
      # `shows_behind:` instead. Past 100 together, the mix is brighter than either side and stops
      # at full brightness: a window that glows over its backdrop, or a shaft of light that lifts
      # the forest under it. The display mixes in sixteenths, so each amount is taken to the
      # nearest one.
      #
      # ```ruby
      # layer :window, shows: 94, shows_behind: 63 do
      #   background :box, tiles: :frame, map: BOX
      # end
      # ```
      #
      # A screen has one see-through layer, and a layer sets its amounts once. A game can have one
      # on each of its screens, in scenes that never show together. A see-through layer needs
      # `screen :tiled`: a bitmap screen paints its whole picture into one place before the
      # display sees it, so there is nothing left to see through.
      #
      # * `name` - a layer named in `layers`.
      # * `transparency:` - how much of what is behind shows through, from 0 to 100: a number, or
      #   something the game works out.
      # * `shows:` - how much of the layer itself shows, from 0 to 100.
      # * `shows_behind:` - how much of what is behind it shows, from 0 to 100.
      def layer(name, transparency: nil, shows: nil, shows_behind: nil, &block)
        raise ArgumentError, "`layer :#{name}` needs a block: `layer :#{name} do ... end`." unless block

        check_layer_can_open!(name)
        amounts = see_through_amounts(name, transparency, shows, shows_behind)
        make_layer_transparent(name, amounts) if amounts

        @current_layer = name
        begin
          run_block(&block)
        ensure
          @current_layer = nil
        end
      end

      private

      # The layer being declared into right now, or nil outside a `layer` block. What
      # the declaring verbs read to put their handle at a depth.
      attr_reader :current_layer

      # Put a node in the layer that is open, or refuse it. Called for every statement
      # the DSL records, so a verb never has to remember to ask.
      def place_in_layer(node)
        return refuse_deferred_layer!(node) unless @current_layer

        case IN_A_LAYER.fetch(node.kind, :free)
        when :held
          refuse_sprite_behind_shared_level!("The sprite :#{node.name}", @current_layer) if node.kind == :object
          node.layer = @current_layer
        when :painted then refuse_painting_in_layer!(node)
        when :whole_screen then refuse_whole_screen_in_layer!(node)
        end
      end

      # A picture is normally scenery at the back and everything that moves in front of
      # it, and something that named no layer is left in that arrangement. Put a
      # background in front of a sprite and the arrangement is gone, and with it the
      # answer for anything that named no layer — there is no longer a "where it always
      # was" to leave it in. So that picture has to place everything.
      def refuse_unlayered_when_scenery_in_front!
        return if @layer_stack.empty?

        picture = IR::Stacking.picture(@program)
        return unless IR::Stacking.scenery_over_objects?(picture.depths,
                                                         scenery: picture.scenery,
                                                         objects: picture.objects)

        # A status bar takes no layer: it is in front of the backgrounds and behind the sprites.
        homeless = (picture.scenery.reject(&:bar?) + picture.objects).reject { |node| @layer_stack.include?(node.layer) }
        return if homeless.empty?

        raise ArgumentError,
              "This picture puts a background in front of a sprite, and #{homeless.length} thing" \
              "#{'s' if homeless.length > 1} in it name no layer. When a background is in front of " \
              "a sprite, every background and every sprite must say where it sits, or there is no " \
              "way to know what is in front of it. To fix this, put each one in a `layer` block. " \
              "The stack is #{list_of(@layer_stack)}, back to front."
      end

      # An effect can be placed in the stack instead of covering the whole screen —
      # `fade :black, 100, under: :ui` fades the game and leaves the score showing. What
      # it names has to be a layer, and the screen has to be one that has a stack.
      #
      # A bitmap screen does not. Everything on it — the scenery, the software sprites,
      # the text — is painted into one picture before the display ever sees it, so by
      # the time an effect could apply there is nothing left to tell apart.
      def check_effect_layer!(verb, name)
        unless name.is_a?(Symbol)
          raise ArgumentError,
                "`#{verb}` takes a layer name after `under:`, like `under: :ui`. You gave " \
                "#{name.inspect}."
        end

        if @screen_mode != :tiled
          raise ArgumentError,
                "`#{verb} ... under: :#{name}` needs `screen :tiled`. On a bitmap screen the " \
                "whole picture is painted into one place before the display sees it, so an " \
                "effect cannot leave one part of it alone. To fix this, use `#{verb}` with no " \
                "`under:`, which changes the whole screen."
        end

        check_layer_named!(name)
      end

      # Record that this layer is see-through, and refuse every way of asking for one the
      # console cannot show.
      #
      # A game can have several, one to a screen — which is checked once the whole game is
      # built, since only then is it known which screen a layer's things are on (see
      # Guardrails::Checks::SeeThroughPerScreen).
      #
      # +amounts+ is what #see_through_amounts made of the words the author wrote.
      def make_layer_transparent(name, amounts)
        check_transparency_screen!(name, amounts.word)
        @transparency_written ||= {}
        return if transparency_repeated!(name, amounts)

        layer = if amounts.split
                  Build.see_through_split(name, DSL::Value.node_for(amounts.behind))
                else
                  Build.see_through_layer(name, shows: DSL::Value.node_for(amounts.shows),
                                                behind: DSL::Value.node_for(amounts.behind))
                end
        @layers_node.see_through = @layers_node.see_through + [layer]
        @transparency_written[name] = amounts
        [amounts.shows, amounts.behind].compact.each { |amount| ensure_var(amount) }
      end

      # What the author wrote about how see-through a layer is, as they wrote it: +word+ is
      # the keyword to name in a message, and +split+ is the one-number form.
      SeeThroughWords = Data.define(:word, :shows, :behind, :split)  # :nodoc:

      # The amounts a `layer` block was given, checked, or nil for a layer that is not
      # see-through. One number, or two that go together, and never both.
      def see_through_amounts(name, transparency, shows, behind)
        return nil if transparency.nil? && shows.nil? && behind.nil?

        unless transparency.nil?
          refuse_transparency_with_shows!(name) unless shows.nil? && behind.nil?
          check_transparency_amount!(name, "transparency", transparency)
          return SeeThroughWords.new(word: "transparency", shows: nil, behind: transparency, split: true)
        end

        refuse_unpaired_shows!(name, shows.nil? ? "shows_behind" : "shows") if shows.nil? || behind.nil?
        check_transparency_amount!(name, "shows", shows)
        check_transparency_amount!(name, "shows_behind", behind)
        SeeThroughWords.new(word: "shows", shows: shows, behind: behind, split: false)
      end

      def refuse_transparency_with_shows!(name)
        raise ArgumentError,
              "`layer :#{name}` was given `transparency:` and `shows:` or `shows_behind:`. They " \
              "are two ways to say one thing. To fix this, use `transparency:` alone, or use " \
              "`shows:` and `shows_behind:` together."
      end

      def refuse_unpaired_shows!(name, given)
        missing = given == "shows" ? "shows_behind" : "shows"
        raise ArgumentError,
              "`layer :#{name}` was given `#{given}:` but not `#{missing}:`. The two go " \
              "together: `shows:` is how much of the layer shows, and `shows_behind:` is how " \
              "much of what is behind it shows. To fix this, give both. If they add to 100, " \
              "`transparency:` alone says the same thing."
      end

      def check_transparency_amount!(name, word, amount)
        fixed = DSL::Value.fixed_number(amount)
        return if fixed.nil? && value_like?(amount) # the game works it out — checked as it runs
        return if fixed && (0..100).cover?(fixed)

        unless fixed
          raise ArgumentError,
                "`layer :#{name}, #{word}:` takes a whole number from 0 to 100, or " \
                "something the game works out (a variable, or a sum of them). You gave " \
                "#{amount.inspect}."
        end

        raise ArgumentError, "`layer :#{name}, #{word}: #{fixed}` is outside 0 to 100. #{amount_range_hint(word)}"
      end

      def amount_range_hint(word)
        case word
        when "transparency" then "0 is solid and 100 lets everything behind show through."
        when "shows" then "0 is none of the layer and 100 is all of it."
        else "0 is none of what is behind and 100 is all of it."
        end
      end

      def value_like?(amount)
        amount.is_a?(Symbol) || amount.is_a?(DSL::Value) || amount.is_a?(IR::Node)
      end

      # How see-through the layer was asked to be, as the author wrote it — a number, or
      # the name of what the game works it out from. For a message about it.
      def transparency_as_written(words)
        return "#{as_written(words.behind)} see-through" if words.split

        "showing #{as_written(words.shows)} of itself and #{as_written(words.behind)} of what is behind"
      end

      def as_written(amount) = (DSL::Value.fixed_number(amount) || Messages::PlainWords.words_for_given(amount)).to_s

      # A bitmap screen paints its scenery, its sprites and its text into one picture
      # before the display ever sees it. By the time an effect could apply there is
      # nothing left to tell apart, so there is nothing to see through. Same shape of
      # answer as `fade ... under:` already gives.
      def check_transparency_screen!(name, word)
        return if @screen_mode == :tiled

        raise ArgumentError,
              "`layer :#{name}, #{word}:` needs `screen :tiled`. On a bitmap screen the " \
              "whole picture is painted into one place before the display sees it, so there is " \
              "nothing left behind a layer to see through. To fix this, use `screen :tiled`, or " \
              "draw the see-through art into the picture yourself."
      end


      # Has this layer already set how see-through it is? The same thing set twice is one
      # fact given twice, and is let through. Compared as the author wrote it, since two
      # reads of the same variable build two equal-but-distinct nodes.
      def transparency_repeated!(name, amounts)
        was = @transparency_written[name]
        return false unless was
        return true if same_see_through_words?(was, amounts)

        raise ArgumentError,
              "The layer :#{name} is already #{transparency_as_written(was)}, and now asks for " \
              "something else. A layer says how see-through it is one time. To fix this, say " \
              "it on one of the `layer :#{name}` blocks."
      end

      def same_see_through_words?(was, now)
        was.split == now.split && was.shows.equal?(now.shows) && was.behind.equal?(now.behind)
      end

      def check_stack_not_declared!
        return if @layer_stack.empty?

        raise ArgumentError,
              "The layers are already declared: #{list_of(@layer_stack)}. A program declares " \
              "its stack one time. To fix this, put every layer in that one `layers` line."
      end

      def check_stack_names!(names)
        if names.empty?
          raise ArgumentError,
                "`layers` needs at least one name, like `layers :world, :ui`. Name them " \
                "back to front."
        end

        unless names.all?(Symbol)
          raise ArgumentError,
                "`layers` takes names, like `layers :world, :ui`. You gave " \
                "#{names.reject { |n| n.is_a?(Symbol) }.map(&:inspect).join(', ')}."
        end

        repeated = names.tally.select { |_name, count| count > 1 }.keys
        return if repeated.empty?

        raise ArgumentError,
              "`layers` names #{list_of(repeated)} more than one time. Each layer has its " \
              "own name and its own place in the stack. To fix this, remove the repeat."
      end

      def check_shared_level!(group)
        return if group.length >= 2 && group.all?(Symbol)

        raise ArgumentError,
              "A list inside `layers` names the layers that share one level, like " \
              "`layers :stairs, [:ground, :scenery], :panel`. The list must name two layers or more, " \
              "and only names. You gave #{group.inspect}."
      end

      # The layer in front of +name+ in a shared level, or nil when +name+ is the front one of
      # its level or shares none. A sprite at a shared level is drawn in front of both
      # backgrounds, so in any layer but the front one it would not be where the stack puts it.
      def shared_layer_in_front_of(name)
        group = @shared_levels.find { |names| names.include?(name) }
        group && group.last != name ? group.last : nil
      end

      def refuse_sprite_behind_shared_level!(subject, name)
        front = shared_layer_in_front_of(name)
        return unless front

        raise ArgumentError,
              "#{subject} is in the layer :#{name}, and :#{name} shares a level with :#{front}. " \
              "A sprite at a shared level is in front of both backgrounds. To fix this, put the " \
              "sprite in :#{front}, or in a layer that does not share a level."
      end

      def check_layer_can_open!(name)
        if @current_layer
          raise ArgumentError,
                "A `layer` block cannot hold another `layer` block. The stack is one list, " \
                "from back to front. To fix this, close the `layer :#{@current_layer}` block, " \
                "then open `layer :#{name}`."
        end

        check_layer_named!(name)
      end

      # Is this a layer the program declared? Asked by everything that names one — a
      # `layer` block, and an effect placed with `under:`.
      def check_layer_named!(name)
        if @layer_stack.empty?
          raise ArgumentError,
                "This program declares no layers, so :#{name} is not one. To fix this, declare " \
                "the stack first: `layers :#{name}`. Name every layer in that one line, back " \
                "to front."
        end

        return if @layer_stack.include?(name)

        raise ArgumentError,
              "There is no layer named :#{name}. The stack is #{list_of(@layer_stack)}, back " \
              "to front. To fix this, use one of those names, or add :#{name} to the `layers` line."
      end

      # A scene cannot go inside a layer, and the reason is about what the two are rather
      # than about when a body is built. A scene is a state of the game and a state holds
      # things at many depths; a layer is one depth. So this is refused where it is
      # written, whatever the scene turns out to declare.
      def refuse_scene_in_layer!
        return unless @current_layer

        raise ArgumentError,
              "A `scene` cannot go inside a `layer` block. A scene is a state of the game, " \
              "and a state holds things at many depths. A layer is one depth. To fix this, " \
              "put the `layer :#{@current_layer}` block inside the scene."
      end

      # A routine's body is built later, when the `layer` block it was written inside has
      # closed, so anything in it that wants a depth would quietly get none. That is the
      # silent wrong picture this whole feature exists to remove.
      #
      # The refusal is on what actually happened, not on where the routine was written,
      # and that distinction is the whole design. Refusing every routine declared inside
      # a layer would refuse `pulse coin` on the line after the coin — which is exactly
      # where a game writes it — because `pulse`, `camera_follows`, `fade_out` and
      # `shake_screen` are all built on the public `once_a_frame` and a pack cannot be told
      # from an author by the verb it calls. Asking instead whether the body declared
      # something with a depth lets every one of them through, since a per-frame body is
      # behavior and declares nothing that sits in the picture. It also lets a plain
      # `func` that declares nothing drawable live beside the sprite it moves.
      #
      # A `game_loop` inside a layer block never reaches here, and that is right: its
      # body runs where it is written, so the layer does reach it and a sprite declared
      # inside gets the depth it looks like it gets.
      def refuse_deferred_layer!(node)
        return if @deferred_layer.nil? || IN_A_LAYER.fetch(node.kind, :free) != :held

        layer, wrote = @deferred_layer
        raise ArgumentError,
              "#{HELD_THING.fetch(node.kind)} declared inside `#{wrote}` cannot take the " \
              "layer :#{layer}. The body of `#{wrote}` is built later, when the ROM is made, " \
              "and the layer is not in force then — so this would sit at no depth at all. " \
              "To fix this, #{deferred_layer_fix(wrote, layer)}"
      end

      # What a held node is, in the words the message needs. Text on a tiled screen is one
      # little sprite per character, so a glyph really is a sprite here.
      HELD_THING = { object: "A sprite", background: "A background" }.freeze  # :nodoc:

      # The way round that works, which is not the same for the two. A declaration inside
      # a per-frame body runs once wherever it is put, so moving it out is both the fix
      # and what the author meant. A func's body is the routine, so the layer goes in it.
      def deferred_layer_fix(wrote, layer)
        return "put the `layer` block inside the func:\n  #{wrote} do\n    layer :#{layer} do ... end\n  end" \
          if wrote.start_with?("func")

        "declare it outside the `#{wrote}` block. A per-frame body is behavior, and a " \
          "declaration in it runs one time wherever you put it."
      end

      def refuse_painting_in_layer!(node)
        # A verb drawing its own text names itself here: a `menu`'s rows really cannot
        # belong to a layer on a bitmap screen, and the author wrote `menu`, not the
        # `draw_text` underneath it (see Text#with_text_owned_by).
        verb = @verb_owns_text || Messages::PlainWords.verb_written(node)
        raise ArgumentError,
              "`#{verb}` paints where you call it#{bitmap_screen_suffix(node)}, so it cannot " \
              "belong to the layer :#{@current_layer}. A layer holds the things the framework " \
              "draws again every frame — a `background`, a `sprite`, tiled text. To fix this, " \
              "call `#{verb}` outside the `layer` block."
      end

      # Text is the one verb whose nature changes with the screen. On a tiled screen the
      # console draws each character for you every frame, so it is layerable and records
      # objects; on a bitmap screen it paints into the framebuffer and reaches here. Say
      # which of the two the author is in, or the rule looks arbitrary.
      def bitmap_screen_suffix(node)
        %i[draw_text draw_digit].include?(node.kind) ? " on a `screen :bitmap`" : ""
      end

      # An effect is placed, not contained — which is a different thing from belonging to
      # a layer, and the difference is worth teaching here rather than leaving somebody to
      # find it. A layer holds things; a fade is not a thing in the picture, it is
      # something done to the picture from a place in the stack.
      def refuse_whole_screen_in_layer!(node)
        verb = Messages::PlainWords.verb(node.kind)
        raise ArgumentError,
              "`#{verb}` changes the whole screen, so it cannot belong to the layer " \
              ":#{@current_layer}. To fix this, call `#{verb}` outside the `layer` " \
              "block.#{placed_fade_hint(node)}"
      end

      def placed_fade_hint(node)
        if node.kind == :pixelate
          return " To leave :#{@current_layer} as drawn, give it the layer outside the block: " \
                 "`pixelate 8, under: :#{@current_layer}`."
        end
        return "" unless node.kind == :fade

        " A fade can still sit at a place in the stack: `fade :black, 100, " \
          "under: :#{@current_layer}` fades everything behind :#{@current_layer} and " \
          "leaves :#{@current_layer} alone."
      end

      def list_of(names)
        names.map { |name| ":#{name}" }.join(", ")
      end
    end
  end
end
