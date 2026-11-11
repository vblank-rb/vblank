# frozen_string_literal: true

module VBlank
  class Builder
    # A LIST OF SPRITE COLOURS THAT HOLDS OTHER COLOURS WHILE THE GAME RUNS. A concern of
    # {Builder}, mixed in so `recolor` stays a flat DSL verb.
    #
    # WHY IT EXISTS. A sprite's pixels are places in a list of sixteen colours, and the
    # console has sixteen such lists for all its sprites at once. `draw_with` picks which
    # list a sprite reads — and every list it could pick is in the console the whole time,
    # so a game whose things between them wear twenty different sets of colours does not
    # fit, though no two rooms of it show more than a handful. The console's own games get
    # round that by treating a list as a slot: the things in the room draw with a few
    # lists, and walking into the next room puts that room's colours in them.
    module ColorLists
      # What the build keeps about one list told to hold other colours: the statement that
      # declares it to the backends, the sets it can hold (a {DSL::Recolors}, the list
      # playing the part a sprite plays there), and the writes recorded where the game called
      # `recolor`, which are moved to the gap between frames once the program is whole.
      ChangingList = Struct.new(:node, :recolors, :shown, :live, :writes, keyword_init: true)

      # One set of lists `colors_in_use` named, the line that first named it, and which of
      # that line's sets it is, counting from 0 the way showing: does (nil for a line that
      # named one set).
      ListsInUse = Data.define(:names, :source, :place) do
        # The set in the author's words, for an error about it.
        def described
          names_said = names.map { |name| ":#{name}" }.join(", ")
          where = place ? "set #{place} of the sets at #{source}, counting from 0 as showing: does" : "the set at #{source}"
          "#{where}. It names #{names_said}"
        end
      end

      # The variable holding which set of lists is in use: a number counting through every
      # set named, in the order the game named them. A number naming none is the first set.
      LISTS_IN_USE = :__colors_in_use

      # SET WHICH LISTS OF SPRITE COLOURS ARE IN USE NOW, as the game enters a room.
      #
      #   colors_in_use [:door, :zelda]                                    # these, from now on
      #   colors_in_use [[:door, :zelda], [:octorok, :bush]], showing: room  # one of several sets
      #
      # Every list a sprite can `draw_with` takes one of the console's groups of sprite
      # colours for as long as its scene is up, so a scene whose things between them wear
      # more lists than there are groups does not fit, though no one room of it shows more
      # than a few. Named here, the lists of one set are the only ones that have to be in the
      # console at once: lists never in use together take turns in one group, and the
      # colours of the set in use are copied in between frames on the frame it changes. So it
      # is the biggest set that has to fit, not the scene.
      #
      # A sprite drawn with a list that is not in use shows whatever its group holds now:
      # the colours of another list. So a room's things are the ones to take away as the
      # room is left. Until the game first names one, the first set named is in use, and so it is
      # for a number naming no set.
      #
      # @param which [Array<Symbol>, Array<Array<Symbol>>] the lists in use, or several sets
      # @param showing [Value, Symbol, Integer, nil] which of several sets, counting from 0
      # @return [nil]
      def colors_in_use(which, showing: nil)
        sets = requested_lists_in_use!(which, showing)
        start = register_lists_in_use(sets, picked: !showing.nil?)
        choice = DSL::Value.new(self, Build.var_ref(LISTS_IN_USE), name: LISTS_IN_USE)
        if showing.nil?
          choice.store! start
        else
          write_picked_choice(choice, count: sets.length, start: start, showing: showing,
                                      outside: IR::Build::NO_RECOLOR, subject: "`colors_in_use`",
                                      verb: "use a set of lists")
        end
        nil
      end

      # SET WHICH COLOURS A LIST HOLDS NOW. Every sprite and every pool instance drawn with
      # the list shows them, from the frame its position and pose next change.
      #
      #   colors :slot, [:transparent, :gray, :white, :black]     # what it holds at power-on
      #   guards.each { |g| g.draw_with :slot }
      #   recolor :slot, :goblin                                  # one other set
      #   recolor :slot, [:goblin, :bat, :crow], showing: room    # one of several, by a number
      #   recolor :slot, :own                                     # the colours it was declared with
      #
      # The sets are lists declared with `colors`, each with a colour for every place the
      # list itself has. A number outside the set is the colours it was declared with.
      #
      # It sets which colours the list holds, the way `show_map` sets which map is showing:
      # so it can be called once, or every frame, from a branch or a scene, and the colours
      # are copied in the gap between frames on the frame the answer changed and no other.
      #
      # @param name [Symbol] a list declared with `colors`
      # @param which [Symbol, Array<Symbol>] the list to hold, several to pick from, or :own
      # @param showing [Value, Symbol, Integer, nil] which of several, counting from 0
      # @return [Symbol] the list's name
      def recolor(name, which, showing: nil)
        list = changing_color_list!(name)
        choice = DSL::Value.new(self, Build.var_ref(list.shown), name: list.shown)
        list.recolors.draw_with(choice, which, showing)
        list.writes << record(Build.color_list_holds(name, which: Build.var_ref(list.shown)))
        name
      end

      # THE STEPS OF A COLOUR WALK, each a list, for `draw_with` or `recolor` to show one at a time.
      #
      #   walk = color_walk :city, from: :black      # 32 lists, black first, :city's own last
      #   world.draw_with walk, showing: step
      #   recolor :letters, color_walk(:letters, from: :white), showing: step
      #
      # A fade mixes every colour toward another by a share of the way, so the dark colours of a
      # picture show almost at once. The console's own games walk instead, and this is that walk:
      # each channel of each colour moves one step of its 31 from one list to the next, and stops
      # at the far colour. So a bright channel starts first, a dim colour stays at the far end for
      # most of the walk, and every channel arrives on the last step together.
      #
      # It is lists and nothing more. The colours are worked out as the cartridge is built, so a
      # game pays for the lists and for naming which one shows, and only the lists it names move.
      # How fast it goes is how fast the game moves the number it hands to `showing:`.
      #
      # A LIST READ FROM THE DATA PACK AS THE GAME STARTS is walked too. The build does not hold
      # its colours, so each step's colours are made as the game starts, from the file's, by the
      # same sum (Graphics::Color.walked_toward; #walked_color).
      #
      # @param name [Symbol] a list declared with `colors`
      # @param from [Symbol, String, Integer] the colour the walk starts at
      # @param steps [Integer] how many steps from there to the list itself
      # @return [Array<Symbol>] the lists' names, the walk's start first and +name+'s colours last
      def color_walk(name, from:, steps: Graphics::Color::CHANNEL_STEPS)
        own = @color_lists.fetch(name) do
          raise ArgumentError, "color_walk :#{name} walks a list of colors, and no list has that name. " \
                               "To fix this, declare it first with `colors :#{name}, [:transparent, ...]`."
        end
        unless steps.is_a?(Integer) && steps.positive?
          raise ArgumentError, "color_walk :#{name} needs a positive whole number of steps. `steps:` is #{steps.inspect}."
        end

        far = Graphics::Color.resolve(from)
        (0..steps).map do |step|
          walked = :"#{name}_walk_#{from.to_s.delete_prefix('#')}_#{steps}_#{step}"
          @color_lists[walked] = own.each_with_index.map { |color, at| at.zero? ? color : walked_color(color, far, steps - step) }
          walked
        end
      end

      # +color+ with each of its three channels moved +steps+ toward +far+'s, and no further. A
      # colour the build holds is worked out here. One it reads from the data pack as the game
      # starts (a marker, IR::StartFile) is another colour made then, of the same sum.
      private def walked_color(color, far, steps)
        return Graphics::Color.walked_toward(color, far, steps) unless IR::StartFile.marker?(color)
        return color if steps.zero?

        start_file_color_marker(IR::StartFile::WalkedColor.new(of: IR::StartFile.entry_of(color), far: far, steps: steps))
      end

      # THE LIST THE GAME'S BACKDROP FOLLOWS: its name, the place of it the backdrop shows, the
      # colour at that place as declared (what the backdrop is at power-on), and the `screen`
      # that named it.
      BackdropList = Data.define(:name, :place, :color, :screen)

      # A BACKDROP THAT FADES WITH THE PICTURE. `screen :tiled, backdrop: :screen_colors` names a
      # `colors` list where a colour would go, the way `image ..., colors: :sea` and `draw_with :hurt`
      # name one, and the backdrop is then the list's colour at one place, whatever the list holds:
      # `recolor` it and the backdrop changes on the same frame as every sprite and background
      # drawn with it, through the same tint.
      #
      # WHY THE FIRST PLACE BY DEFAULT. A list's first place is the one a picture drawn from it does
      # not draw — its see-through place — and what shows through a see-through pixel is the
      # backdrop. So a list made for a screen's colours already has a natural home for the colour
      # behind them, and the console games that fade their backdrop keep it just there (a Genesis
      # points its backdrop at the first colour of a list). `backdrop_place:` picks any other.
      #
      # Nil when +backdrop+ is a colour rather than a list's name. A name is a list's only when
      # `colors` declared it before this line, as `colors:` asks; a list named like a colour would
      # leave the line meaning two things, and is refused.
      private def followed_backdrop_list(backdrop, place, mode)
        unless backdrop.is_a?(Symbol) && @color_lists.key?(backdrop)
          return nil if place.nil?

          raise ArgumentError, "`screen ... backdrop_place:` picks a color from a list of colors. backdrop: names " \
                               "no list, so there is no color to pick. To fix this, give backdrop: the name of a " \
                               "list from `colors`, or remove backdrop_place:."
        end

        refuse_backdrop_on_painted_screen!(mode)
        if Graphics::Color::PRESETS.key?(backdrop)
          raise ArgumentError, "`screen ... backdrop: :#{backdrop}` names a color and also a list of colors. " \
                               "To fix this, give the list a different name."
        end

        colors = @color_lists.fetch(backdrop)
        place = 0 if place.nil?
        unless place.is_a?(Integer) && place.between?(0, colors.length - 1)
          raise ArgumentError, "`screen ... backdrop: :#{backdrop}, backdrop_place: #{place.inspect}` asks for a place " \
                               "that :#{backdrop} does not have. :#{backdrop} has #{colors.length} colors, at places " \
                               "0 to #{colors.length - 1}. To fix this, use a place in that range."
        end

        # A colour read from the data pack as the game starts is kept as the marker it is.
        BackdropList.new(name: backdrop, place: place, color: list_color(colors.fetch(place)), screen: nil)
      end

      # Keep track of a sprite's or a pool's other colours, so the lists that change can
      # find who is drawn with them once the whole program is declared. Called by
      # {DSL::Recolors} as one is made.
      def remember_sprite_recolors(recolors)
        @sprite_recolors << recolors
      end

      # Keep track of a list a background is drawn with, so a background drawn with a list
      # that changes can be told to follow it. Called by {DSL::Background} as it takes the
      # list's colours.
      def remember_background_draws_with(name, background)
        (@lists_backgrounds_draw_with[name] ||= []) << background unless @lists_backgrounds_draw_with[name]&.include?(background)
      end

      private

      # A BACKGROUND DRAWN WITH A LIST THE GAME CHANGES SHOWS WHAT THE LIST HOLDS, as a sprite
      # drawn with it does. The background is told the sets the list can hold, counted as the
      # list counts them, and reads the list's own number for which one it shows (see
      # DSL::Background#follow_changing_list!). So the console writes the background's colours
      # on the same frame as the list's, from the same number, and a console whose sprites and
      # backgrounds read one table of colours can keep the two in one place of it.
      #
      # It runs before the backgrounds' colour writes are moved to the gap between frames, which
      # is where the background's is made. A program with no gap writes the background's colours
      # where the list was told what to hold, as it writes the list's.
      #
      # A background with tiles drawn from a changing list that was never told to draw with it
      # would show the list's power-on colours whatever it holds, so it is refused, naming the list.
      #
      # A BACKGROUND DRAWN WITH SEVERAL CHANGING LISTS is told all of them at once and keeps no sets:
      # each list's own write changes its tiles (DSL::Background#follow_changing_lists!).
      def link_backgrounds_to_changing_lists
        followers = @changing_color_lists.keys.to_h { |name| [name, @lists_backgrounds_draw_with.fetch(name, [])] }
        followers.each do |name, following|
          (@background_handles - following).each { |background| background.refuse_unfollowed_changing_list!(name) }
        end
        followed = followers.each_with_object({}) do |(name, following), lists|
          following.each { |background| (lists[background] ||= []) << name }
        end
        followed.each { |background, lists| background.follow_changing_lists!(lists) if lists.length > 1 }

        @changing_color_lists.each do |name, list|
          followers.fetch(name).each do |background|
            next if followed.fetch(background).length > 1


            background.follow_changing_list!(name, list.recolors.names_by_number, list.shown)
            next unless @frame_boundaries.empty?

            list.writes.each do |write|
              beside = Build.background_colors(background.name, which: Build.var_ref(list.shown))
              write.parent.children.insert(write.parent.children.index(write) + 1, beside)
              beside.parent = write.parent
            end
          end
        end
      end

      # ONCE THE WHOLE PROGRAM IS DECLARED: tell the list the backdrop follows that it does, so each
      # backend shows its colour at that place wherever the list is told to hold another set. That
      # write is the list's own, in the gap between frames on the frame the answer changed, so the
      # backdrop changes with the sprites and backgrounds drawn with the list and never apart from
      # them. A list the game never recolours holds its declared colours for good, and the backdrop
      # is that one colour, which the `screen` already names.
      #
      # It is the game's backdrop from power-on to the end, so it is named on the game's own `screen`
      # and is the backdrop of every screen. A painted screen draws every pixel and has none, so a
      # game with one is refused rather than given a backdrop that comes and goes.
      def finalize_backdrop_list
        return unless @backdrop_list

        refuse_backdrop_list_off_game_screen!
        @program.walk.each do |node|
          next unless node.kind == :screen && !node.equal?(@backdrop_list.screen)

          refuse_painted_screen_beside_backdrop_list!(node)
          refuse_scene_backdrop_beside_backdrop_list!(node)
        end
        followed = @changing_color_lists[@backdrop_list.name]
        followed.node.backdrop_place = @backdrop_list.place if followed
      end

      # The game's own `screen` is the first one outside every routine (IR::SceneHandover#game_backdrop).
      def refuse_backdrop_list_off_game_screen!
        game_screen = @program.children.find { |node| node.kind == :screen }
        return if game_screen.equal?(@backdrop_list.screen)

        raise ArgumentError, "`screen ... backdrop: :#{@backdrop_list.name}` at #{@backdrop_list.screen.source} is not " \
                             "on the first `screen` line of the game. A backdrop that takes its color from a list is " \
                             "the backdrop of the whole game. To fix this, write it on the first `screen` line, " \
                             "outside all scenes and routines."
      end

      def refuse_painted_screen_beside_backdrop_list!(node)
        return if %i[tiled rotozoom].include?(node.mode)

        raise ArgumentError, "The backdrop takes its color from the list :#{@backdrop_list.name}. The `screen` at " \
                             "#{node.source} is not a tiled screen. A bitmap screen has no backdrop. To fix this, " \
                             "use `screen :tiled` there, or give backdrop: a color."
      end

      def refuse_scene_backdrop_beside_backdrop_list!(node)
        return if node.backdrop_or_place_in_file.nil?

        raise ArgumentError, "The backdrop takes its color from the list :#{@backdrop_list.name} for the whole game. " \
                             "The `screen` at #{node.source} gives a backdrop of its own. To fix this, remove backdrop: " \
                             "from that `screen` line."
      end

      # Everything kept about the list +name+, made the first time it is told `recolor`.
      #
      # Two of its variables start out agreeing, both meaning "the colours it was declared
      # with", so a list told nothing on a frame writes nothing — the same pair a
      # background's colours are held in (see Builder#make_background_recolorable). The
      # third is a backend's own (see IR::Nodes::ColorList.source_var).
      def changing_color_list!(name)
        @changing_color_lists[name] ||= begin
          declared = @color_lists.fetch(name) do
            raise ArgumentError,
                  "`recolor` names :#{name}, which is not a list of colors. " \
                  "Declare it first with `colors :#{name}, [:transparent, ...]`."
          end
          shown = :"__colors_#{name}"
          live = :"__colors_#{name}_live"
          at_boot(Build.set(shown, Build.int(IR::Build::NO_RECOLOR)))
          at_boot(Build.set(live, Build.int(IR::Build::NO_RECOLOR)))
          at_boot(Build.set(IR::Nodes::ColorList.source_var(name), Build.int(0)))
          [shown, live, IR::Nodes::ColorList.source_var(name)].each { |var| ensure_var(var) }

          node = Build.color_list(name, colors: declared)
          words = DSL::Recolors::Words.new(verb: "recolor", told: "hold", call: "recolor :#{name}, ")
          sets = DSL::Recolors.new(self, subject: changing_list_subject(name), poses: nil, words: words,
                                         colors_for: ->(names) { colors_to_hold(names, list: name) })
          ChangingList.new(node: node, recolors: sets.attach_object(node), shown: shown, live: live, writes: [])
        end
      end

      def changing_list_subject(name) = "The list of colors :#{name}"

      # The sets a `colors_in_use` call named, checked before anything is written: one set
      # without showing:, several with it.
      def requested_lists_in_use!(which, showing)
        names_list = ->(set) { set.is_a?(Array) && !set.empty? && set.all?(Symbol) }
        sets = showing.nil? ? [which] : which
        unless sets.is_a?(Array) && !sets.empty? && sets.all?(names_list)
          raise ArgumentError, lists_in_use_shape_message(which, showing)
        end

        sets.each do |set|
          set.each do |name|
            next if @color_lists.key?(name)

            raise ArgumentError,
                  "`colors_in_use` names :#{name}, which is not a list of colors. " \
                  "Declare it first with `colors :#{name}, [:transparent, ...]`."
          end
        end
        sets.map(&:uniq)
      end

      def lists_in_use_shape_message(which, showing)
        if showing.nil? && which.is_a?(Array) && which.all?(Array)
          return "`colors_in_use` was given a list of sets and nothing to pick between them. " \
                 "Say which one with showing:, like `colors_in_use [[:goblin], [:bat]], showing: room`."
        end
        if showing.nil?
          return "`colors_in_use` was given #{which.inspect}. It needs the names of lists of colors, " \
                 "like `colors_in_use [:goblin, :bat]`."
        end

        "`colors_in_use` was given #{which.inspect} with showing:. showing: picks one of several sets, " \
          "so give it a list of sets, like `colors_in_use [[:goblin, :bat], [:crow]], showing: room`."
      end

      # Count +sets+ among every set named so far, and return where they start: the same
      # sets named again side by side are counted once, and new ones go on the end. So a pick
      # by a number the game works out is that number plus where they start. The first call
      # also declares the variable holding which set is in use, holding "the first" at boot.
      # +picked+ marks that the sets were given with showing:, which is how an error names one.
      def register_lists_in_use(sets, picked:)
        if @lists_in_use.empty?
          at_boot(Build.set(LISTS_IN_USE, Build.int(IR::Build::NO_RECOLOR)))
          ensure_var(LISTS_IN_USE)
        end
        named = @lists_in_use.map(&:names)
        found = (0..(named.length - sets.length)).find { |at| named[at, sets.length] == sets }
        return found if found

        at = @lists_in_use.length
        source = caller_source_location
        @lists_in_use.concat(sets.each_with_index.map do |set, place|
          ListsInUse.new(names: set, source: source, place: picked ? place : nil)
        end)
        at
      end

      # The colours of the `colors` lists +names+, for the list +list+ to hold. Each needs a
      # colour for every place +list+ has, since a sprite drawn with +list+ was checked
      # against that many places and no more.
      def colors_to_hold(names, list:)
        places = @color_lists.fetch(list).length
        names.map do |name|
          set = @color_lists.fetch(name) do
            raise ArgumentError,
                  "#{changing_list_subject(list)} was told to hold :#{name}, which is not a list of " \
                  "colors. Declare it first with `colors :#{name}, [:transparent, ...]`."
          end
          next set if set.length >= places

          raise ArgumentError,
                "#{changing_list_subject(list)} was told to hold :#{name}, which has #{set.length} " \
                "colors. :#{list} has #{places}, and each place in it needs a color at the same place in " \
                ":#{name}. Give :#{name} #{places} colors or more."
        end
      end

      # ONCE THE WHOLE PROGRAM IS DECLARED: tell every sprite drawn with a changing list to
      # hold the list's name rather than its colours, declare each such list to the
      # backends, and move the writes to the gap between frames.
      #
      # It waits until now because `draw_with` and `recolor` can come in either order, and
      # a sprite that drew with a list before anything recoloured it took the colours the
      # list was declared with.
      def finalize_changing_color_lists
        places = places_for_lists_in_use
        shared = shared_lists_in_use(places)
        followed_by_poses = keep_changing_lists_poses_follow
        return if @changing_color_lists.empty? && shared.empty?

        @changing_color_lists.each do |name, list|
          users = @sprite_recolors.select { |recolors| recolors.draws_with?(name) }
          followed = @backdrop_list&.name == name || followed_by_poses.include?(name)
          refuse_changing_list_without_sprites!(name) if users.empty? && !followed
          users.each { |user| refuse_sets_ambiguous_for!(user, name, list.recolors.names) }
          drawn_in_list = ->(pose) { list_drawn_from(pose).last == declared_colors(name) }
          users.each { |user| (boot = user.follow_changing_list_for_good(name, drawn_in_list)) && at_boot(boot) }
          prepend_to_program(list.node)
        end
        shared.each_value { |list| prepend_to_program(list.node) }

        held = @changing_color_lists.keys.to_h { |name| [name, name] }
        held.merge!(places)
        @sprite_recolors.each { |recolors| recolors.name_changing_lists!(held) }
        write_changed_colors_between_frames(@changing_color_lists.merge(shared))
      end

      # THE LISTS A SPRITE OF SEVERAL LISTS FOLLOWS (Images#follow_pose_lists), kept on each such
      # object only where the game changes the list: a list never told `recolor` holds the colours it
      # was declared with for good, which are the colours its poses were drawn in, so following it
      # is drawing them as drawn and the object names nothing. Those it names apart
      # (IR::Nodes::Object#follows_unchanging), for a target that keeps a pose's colours in the order
      # of its list. Hands back every list still followed.
      def keep_changing_lists_poses_follow
        (@pose_list_followers || []).uniq.flat_map do |node|
          kept, unchanging = node.follows_each.partition { |name| @changing_color_lists.key?(name) }
          node.follows_each = kept.empty? ? nil : kept
          node.follows_unchanging = unchanging.empty? ? nil : unchanging
          kept
        end.uniq
      end

      # THE LISTS THAT LISTS NEVER IN USE TOGETHER TAKE TURNS IN, from +places+ (see
      # #places_for_lists_in_use): shared name -> a ChangingList whose sets are, set by set,
      # the list it holds while that set is in use. Empty for a game that never calls
      # `colors_in_use`.
      #
      # A set that leaves a shared list out has it hold its resting list — the one it holds
      # for the first set, or failing that the first it holds at all — so moving to that set
      # puts back colours that list already showed rather than anything new.
      def shared_lists_in_use(places)
        places.values.uniq.to_h do |name|
          lists = places.select { |_list, shared| shared == name }.keys
          held = @lists_in_use.map { |set| (set.names & lists).first }
          resting = held.first || held.compact.first
          node = Build.color_list(name, colors: colors_padded_to_sixteen(resting),
                                        recolors: held.map { |list| colors_padded_to_sixteen(list || resting) })
          # What a build that runs out of room points at: the set that needs the most of the
          # lists taking turns alongside this one.
          node.busiest_set = @lists_in_use.max_by { |set| (set.names & alongside(places, name)).length }.described
          live = :"#{name}_live"
          at_boot(Build.set(live, Build.int(IR::Build::NO_RECOLOR)))
          at_boot(Build.set(IR::Nodes::ColorList.source_var(name), Build.int(0)))
          [live, IR::Nodes::ColorList.source_var(name)].each { |var| ensure_var(var) }
          [name, ChangingList.new(node: node, recolors: nil, shown: LISTS_IN_USE, live: live, writes: [])]
        end
      end

      # The lists placed with those that take turns in +name+: the same scene's, or the lists
      # every scene draws with.
      def alongside(places, name)
        family = IR::Nodes::ColorList.shared_family(name)
        places.select { |_list, shared| IR::Nodes::ColorList.shared_family(shared) == family }.keys
      end

      # The colours of the list +name+ with a colour at all sixteen places, the places past
      # its own end black. A shared list holds lists of different lengths, and a sprite left
      # standing from another room can read a place the list in use does not have; every
      # place having a colour means every build draws that sprite the same.
      def colors_padded_to_sixteen(name)
        colors = @color_lists.fetch(name)
        colors + ([0x0000] * (Images::PICTURE_COLORS - colors.length))
      end

      # WHICH SHARED LIST EACH LIST IN A SET IS DRAWN THROUGH: list name -> the shared list's
      # name. Empty for a game that never calls `colors_in_use`.
      #
      # The lists are placed scene by scene: the lists only one scene's sprites draw with take
      # turns among themselves, so the groups they take are that scene's while it is up and
      # every other scene's afterwards, the way a scene's own lists always are. The lists
      # sprites of several scenes draw with are placed together, and keep their groups in
      # every scene. Within each, two lists of one set never share, and as few shared lists
      # are used as can be — as many as the biggest set has of those lists, for any game whose
      # sets do not overlap in a ring.
      def places_for_lists_in_use
        return {} if @lists_in_use.empty?

        listed = names_in_use
        refuse_lists_in_use_without_sprites!(listed)
        refuse_recolored_lists_in_use!(listed)
        places = {}
        listed.group_by { |name| scene_drawn_in(name) }.values.each_with_index do |lists, family|
          numbers = numbers_for_lists(@lists_in_use.map { |set| set.names & lists })
          numbers.each { |list, number| places[list] = IR::Nodes::ColorList.shared_name(family, number) }
        end
        places
      end

      def names_in_use = @lists_in_use.flat_map(&:names).uniq

      # The one scene whose sprites draw with the list +name+, or nil for a list sprites of
      # several scenes draw with, or a sprite every scene shows.
      def scene_drawn_in(name)
        scenes = @sprite_recolors.select { |recolors| recolors.draws_with?(name) }.flat_map(&:scenes).uniq
        scenes.one? ? scenes.first : nil
      end

      # A number for each list in +sets+, counting from 0, that no list sharing a set with it
      # has. It is a search, trying the lists that share a set with the most others first,
      # and a small one: a game names a few dozen lists at most.
      def numbers_for_lists(sets)
        beside = Hash.new { |hash, name| hash[name] = [] }
        sets.each { |set| set.each { |name| beside[name] |= set - [name] } }
        order = beside.keys.sort_by { |name| -beside[name].length }
        (sets.map(&:length).max..order.length).each do |count|
          found = place_lists(order, beside, count, {})
          return found if found
        end
      end

      # Give each of +order+ a number below +count+ that none of the lists beside it has,
      # going back on a choice that leaves a later list nowhere. nil when there is no way.
      def place_lists(order, beside, count, places)
        return places if places.length == order.length

        name = order[places.length]
        taken = beside[name].filter_map { |other| places[other] }
        (0...count).each do |number|
          next if taken.include?(number)

          found = place_lists(order, beside, count, places.merge(name => number))
          return found if found
        end
        nil
      end

      # A list in a set that no sprite or pool draws with shows nothing in any room: a name
      # spelled two ways far more often than it is meant.
      def refuse_lists_in_use_without_sprites!(listed)
        listed.each do |name|
          next if @sprite_recolors.any? { |recolors| recolors.draws_with?(name) }

          raise ArgumentError,
                "`colors_in_use` names :#{name}, but no sprite or pool draws with it. So it shows in no " \
                "room. To fix this, tell a sprite `draw_with :#{name}`, or correct the name."
        end
      end

      # A list in a set is copied into a shared list as the set comes into use, colours as it
      # was declared; told to `recolor` as well, it would have two answers to what it holds.
      def refuse_recolored_lists_in_use!(listed)
        listed.each do |name|
          next unless @changing_color_lists.key?(name)

          raise ArgumentError,
                "`colors_in_use` names :#{name}, and :#{name} was told to hold other colors with `recolor`. " \
                "A list can do one of these, not both. To fix this, take :#{name} out of `colors_in_use`, or " \
                "give the sets it holds to `colors_in_use` in its place."
        end
      end

      # A list no sprite is drawn with shows nothing whatever it holds, which is a name
      # spelled two ways far more often than it is meant.
      def refuse_changing_list_without_sprites!(name)
        raise ArgumentError,
              "#{changing_list_subject(name)} was told to hold other colors, but no sprite or pool draws " \
              "with it. So nothing shows the colors it holds. To fix this, tell a sprite " \
              "`draw_with :#{name}`, or correct the name."
      end

      # Each set the list +name+ can hold recolours +user+'s pictures by place, the way a
      # list the sprite named itself does — so it is held to the same rule about a colour
      # the sprite's own list has at two places (see Images#refuse_ambiguous_color_places!).
      def refuse_sets_ambiguous_for!(user, name, sets)
        own = shared_pose_colors!(user.poses, user.subject)
        sets.each do |set|
          refuse_ambiguous_color_places!(own: own, swapped: @color_lists.fetch(set), name: set,
                                         poses: user.poses, subject: user.subject, through: name)
        end
      end

      # COPY A LIST'S COLOURS IN THE GAP BETWEEN FRAMES, and only on a frame where the answer
      # changed — the same bargain, held in the same two variables, as a background's (see
      # Builder#finalize_background_colors). The gap is what makes the colours change on the
      # frame the sprites' positions and poses do: both are written there.
      def write_changed_colors_between_frames(lists)
        writes = lists.each_value.flat_map(&:writes)
        write_between_frames(writes, lists) do |name, list|
          write_if_changed(requested: list.shown, in_force: list.live,
                           write: Build.color_list_holds(name, which: Build.var_ref(list.shown)))
        end
      end
    end
  end
end
