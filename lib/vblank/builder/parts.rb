# frozen_string_literal: true

module VBlank
  class Builder
    # A NEW GAME. A game that ends and starts again needs its play back as it was declared —
    # the score at nought, three lives, the board empty — while what it keeps between games
    # (a high score, the random numbers, the options) stays as it is. Without help that is a
    # line for every variable the play has, which in a big game is hundreds, and the one
    # forgotten is a second game that starts with the last game's score.
    #
    #   best = save_var :best, 0
    #   part :play                 # what is declared from here on is the play
    #   score = var :score, 0
    #   lives = var :lives, 3
    #   ...
    #   if lives == 0
    #     best = score if score > best
    #     start_over :play         # everything in the part back as declared, on this pass
    #   end
    #
    # `part :play` works like Ruby's `private`: alone, it holds from its line to the next
    # `part` (or the end of the game); given a block, it holds inside the block. The block form
    # cannot hand back the locals made inside it, which is why the plain form is there — a game
    # that builds its play as a row of objects, each declaring its own state, says `part :play`
    # once above the row. A scene names a part too: what its body declares.
    #
    # A ROUTINE BELONGS WHERE IT IS WRITTEN. A `func`, a scene, a pool's `func` and an
    # `each_pass` job have their bodies built at the end, when every `part` line has long been
    # read, so what a body declares belongs to the parts and the scene in force on the line the
    # routine was written — kept for it then and handed to its body when the body is built.
    #
    # WHAT GOES BACK, and how: each is put back the way power-on set it up, in the order the
    # game declared it, so a start worked out from a variable declared before it reads that
    # variable's start, as it did at power-on.
    #   - a variable is set to its start (a fraction, a narrow one and one holding a name alike:
    #     the start is the number power-on stored). A start worked out as the game runs is worked
    #     out again, now: from a variable outside the part it takes that variable as it is, and
    #     `var :x, rand(1..6)` rolls again.
    #   - a list is made again as declared: empty, or full of its `full_of:` value.
    #   - a pool is emptied the way power-on leaves it, every slot free.
    #   - an `every` or `after` counts from nought again, so an `after` fires again.
    #   - an `each_pass` job is stopped.
    #   - a sprite goes back to its `at:`, its first pose and its first frame, shown or hidden
    #     as it was declared. A sprite painted into the picture (a bitmap screen) is moved there
    #     the way `move_to` moves it: the next repaint puts back what it covered where it stood.
    # A `save_var`, the random numbers and the author's `_` scratch names are left out. So is
    # the framework's own state other than the above, which keeps going across a new game: a
    # menu's cursor, a `pulse` under way, what a `keep_showing` picture has still to paint, a
    # sprite's turn, size, colours and layer, and a hardware `timer` (which starts again when
    # its line runs).
    #
    # WHAT IT COSTS. The putting back is one routine of the game's, built once the whole game is
    # read, and `start_over` is a call to it: it all happens on the pass that calls it, however
    # many things the part has. On the console each variable is a store of a number the code
    # carries, a couple of instructions; a list is its length set again (and a full one filled
    # by the copying engine); a pool is its free slots pushed back, one short loop. A game that
    # never says `start_over` has no such routine, and builds the same cartridge it always did.
    #
    # Why not one block copy of the starts from the cartridge into memory? That wants the part's
    # variables side by side in memory, and where each variable lives is each console's own
    # choice (on the Advance by its distance from the start of the quick memory, on the Color
    # packed a byte or two wide). The stores ask nothing of any console, so every lowering
    # plays them as it plays any other line of the game.
    module Parts
      # One thing a part puts back: +kind+ is :var (a variable's name), :list (a list's name),
      # :pool (the pool) or :shown (a SpriteShown).
      Member = Data.define(:kind, :thing)

      # A sprite painted into the picture, and whether it was declared shown: put back with its
      # own `show` or `hide`, which paint it or take it off the picture as well as set the flag.
      SpriteShown = Data.define(:sprite, :shown)

      # Say which part what the game declares belongs to: from this line on, or, given a block,
      # inside the block.
      #
      # @param name [Symbol] the part's name, which `start_over` takes
      def part(name)
        refuse_bad_part_name!(name)
        part_names << name
        return @part_open = name unless block_given?

        around = @part_open
        @part_open = name
        begin
          yield
        ensure
          @part_open = around
        end
        nil
      end

      # Put every variable, list and pool of the parts or scenes named back as declared, on this
      # pass. What is not in them is left as it is.
      #
      # @param names [Array<Symbol>] parts declared with `part`, or scenes
      def start_over(*names)
        refuse_unnamed_start_over!(names)
        at = Messages::AuthorSource.at_author_line
        names.uniq.each do |name|
          routine = Messages::MadeNames.make(:start_over, part: name)
          unless @functions.key?(routine)
            declare_func(routine) { emit_start_over(name, at) }
            build_last(routine)
          end
          record(Build.call(routine))
        end
        nil
      end

      private

      # A variable, list or pool the game just declared, as a member of every part and scene in
      # force here. Called by `var`, `list` and `pool`, where a name that starts with `_` is the
      # author's scratch and left out; the framework's own state that a new game puts back (a
      # timer's count, a job's running flag, a sprite's place) says +framework+.
      def add_part_member(kind, thing, framework: false)
        return if !framework && thing.is_a?(Symbol) && thing.start_with?("_")

        member = Member.new(kind: kind, thing: thing)
        part_owners_here.each do |owner|
          members = (part_members[owner] ||= [])
          members << member unless members.include?(member)
        end
      end

      # A sprite just declared: the variables power-on starts it with, put back as they are,
      # and for a sprite painted into the picture whether it shows, put back by its own verbs.
      def add_sprite_to_part(vars, painted: nil)
        vars.compact.each { |var| add_part_member(:var, var, framework: true) }
        add_part_member(:shown, painted, framework: true) if painted
      end

      # The parts and scene in force on this line: the part `part` opened, the scene whose body
      # is being built, and those the routine being built was written in.
      def part_owners_here = [*@owners_written_in, @part_open, scene_being_built].compact.uniq

      # Keep the parts and scene in force where routine +name+ is written, for its body.
      def remember_part_owners_of_routine(name)
        owners = part_owners_here
        (@routine_owners ||= {})[name] = owners unless owners.empty?
      end

      # Build a routine's body with the parts and scene in force where it was written. A `part`
      # line inside the body holds to the body's end.
      def with_part_owners_of_routine(name)
        around = [@owners_written_in, @part_open]
        @owners_written_in = @routine_owners&.[](name)
        @part_open = nil
        yield
      ensure
        @owners_written_in, @part_open = around
      end

      def part_names = (@part_names ||= Set.new)

      # Part or scene name → its Members, in the order declared.
      def part_members = (@part_members ||= {})

      def scene_being_built
        routine = @building_routine.to_s
        routine.delete_prefix("_scene_").to_sym if routine.start_with?("_scene_")
      end

      def scene_names = @functions.keys.filter_map { |name| name.to_s.delete_prefix("_scene_").to_sym if name.to_s.start_with?("_scene_") }

      # The body of the routine `start_over :name` calls: each member put back as power-on set
      # it up. Built last, once every line of the game is read, so every member is known.
      def emit_start_over(name, at)
        refuse_unknown_part!(name, at)
        part_members.fetch(name, []).each do |member|
          case member.kind
          when :var then emit_variable_start(member.thing)
          when :list then record(Build.list_new_like(declared_list_node(member.thing)))
          when :pool then pool_refill_nodes(member.thing).each { |node| record(node) }
          when :shown then member.thing.shown ? member.thing.sprite.show : member.thing.sprite.hide
          end
        end
      end

      # The variable set to what power-on set it to. The start is the node power-on stored,
      # copied, since a node belongs to one place in the program.
      def emit_variable_start(name)
        start = @boot_inits.find { |node| node.kind == :set && node.var == name }&.value
        record(Build.set(name, start ? start.copy : Build.int(0)))
      end

      # A PART IS NAMED LIKE A SAVE RECORD — letters and digits, with one underscore between
      # words — because its routine is named after it the same way (Messages::MadeNames).
      def refuse_bad_part_name!(name)
        return if name.is_a?(Symbol) && Messages::MadeNames::RECORD_NAME.match?(name)

        raise ArgumentError, "part #{name.inspect}: this name cannot name a part. A part name is letters and " \
                             "digits, with one underscore between words (for example :play or :red_field). " \
                             "Use a name of that form."
      end

      # A part and a scene of one name would be one name for two sets of things, and
      # `start_over` could not tell which the game meant. Asked once every scene is declared.
      def refuse_parts_named_like_scenes!
        name = part_names.find { |part| scene_names.include?(part) } or return

        raise ArgumentError, "This game has part :#{name} and scene :#{name}. start_over takes one name for one " \
                             "set of things. To fix this, give the part another name."
      end

      def refuse_unnamed_start_over!(names)
        if names.empty?
          raise ArgumentError, "start_over needs the name of a part or a scene, like `start_over :play`. " \
                               "To make a part, write `part :play` above what the play declares."
        end
        stray = names.find { |name| !name.is_a?(Symbol) } or return
        raise ArgumentError, "start_over takes names of parts or scenes, like `start_over :play`. " \
                             "It was given #{stray.inspect}."
      end

      def refuse_unknown_part!(name, at)
        return if part_names.include?(name) || scene_names.include?(name)

        raise ArgumentError, "#{start_over_member_name_message(name)}#{at}" if persisted?(name) || member_kind(name)

        known = part_names.map { |part| "part :#{part}" } + scene_names.map { |scene| "scene :#{scene}" }
        has = known.empty? ? "The game has no parts or scenes." : "The game has #{known.join(', ')}."
        raise ArgumentError, "start_over names :#{name}, and the game has no part or scene :#{name}#{at}. #{has} " \
                             "To fix this, use one of those names, or write `part :#{name}` above what it declares."
      end

      # Why the name of a save_var, a variable, a list or a pool is not one start_over takes.
      def start_over_member_name_message(name)
        if persisted?(name)
          return ":#{name} is a save_var. A save_var keeps its number between games, so start_over does not " \
                 "put it back. To fix this, remove :#{name} from start_over."
        end

        kind = member_kind(name)
        owner = part_names.find { |part| part_members.fetch(part, []).any? { |member| member_name(member) == name } }
        fix = owner ? "It is in part :#{owner}, so write `start_over :#{owner}`." : "To put it back, declare it below a `part` line and name that part."
        ":#{name} is a #{kind}, not a part or a scene. start_over puts back everything a part declares. #{fix}"
      end

      # The name the game gave a member: a variable's or list's, or a pool's.
      def member_name(member) = member.thing.is_a?(DSL::Pool) ? member.thing.name : member.thing

      # What the game declared +name+ as — "variable", "list" or "pool" — or nil.
      def member_kind(name)
        return "variable" if @variables.include?(name)
        return "pool" if declared_pools.any? { |pool| pool.name == name }

        "list" if declared_list_node(name)
      end
    end
  end
end
