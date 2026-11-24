# frozen_string_literal: true

module VBlank
  module DSL
    module PlainRuby # :nodoc: all
      # A Ruby Array that game code changes, kept by the game as a list of its own (DSL::List).
      #
      #     trail = Array.new(capacity: 4)   # list :trail, capacity: 4
      #     ripple = Array.new(8, 0.0)       # list :ripple, capacity: 8, full_of: 0.0
      #     marks = [0, 0, 0]                # list :marks, capacity: 3, full_of: 0
      #
      # Which Arrays these are is decided once, by reading the whole block (LocalNames#game_array?):
      # an Array written out and given to a local that game code changes with an Array verb (`<<`,
      # `shift`, `[]=` ...). An Array only read by game code, or changed only while building, stays
      # Ruby's. The rewrite then hands the line here in place of making the Array, so Ruby never
      # runs `Array.new(capacity: 4)`, which it would refuse.
      #
      # A console sets a list's memory aside before the game starts, so the most items it can hold
      # is fixed. Ruby grows an Array as it is pushed to, and a list cannot: that is why `capacity:`
      # is the one setting VBlank adds to `Array.new`, and why an Array the game pushes to must say it.
      module Arrays
        # The Array verbs that change the Array they are called on. Game code calling one on a local
        # makes that local's Array a list; DSL::List refuses by name those it has no meaning for.
        # `copy_from` is List's own, not Ruby's: an Array it is called on can only mean a list.
        CHANGING_VERBS = %i[<< push append unshift prepend insert concat shift pop []= clear fill copy_from replace
                            delete delete_at delete_if keep_if slice! select! filter! reject! map! collect!
                            sort! sort_by! reverse! rotate! shuffle! uniq! compact! flatten!].freeze

        # ...and among them, those a list can do that add items, which it can do only into room set
        # aside. `unshift`, `insert` and `concat` change the Array too, and a list refuses them by name.
        GROWING_VERBS = %i[<< push append].freeze

        # What `Array.new` takes in game code besides Ruby's own size and start: Builder#list's
        # settings that change only what the list costs. Whether it holds fractions is read from
        # what the game puts in it (LocalNames#game_array_fraction_put), never written.
        LIST_SETTINGS = %i[width fast].freeze

        module_function

        # The values +node+, an Array verb called in game code, puts into the Array: what `<<`,
        # `push` and the like add, what `[]=` or `fill` writes, and what `+=` on an item adds.
        def put_values(node)
          return [node.value] if node.is_a?(Prism::IndexOperatorWriteNode)

          given = node.arguments&.arguments.to_a.reject { |argument| argument.is_a?(Prism::KeywordHashNode) }
          case node.name
          when :[]= then given.last(1)
          when :fill then given.first(1)
          when *GROWING_VERBS then given
          else []
          end
        end

        # Is +value+ an Array written out: `[...]` with no splat, or `Array.new(...)`?
        def makes_array?(value)
          case value
          when Prism::ArrayNode then !value.opening_loc.nil? && value.elements.none?(Prism::SplatNode)
          when Prism::CallNode
            value.name == :new && value.receiver.is_a?(Prism::ConstantReadNode) && value.receiver.name == :Array
          else false
          end
        end

        # What the rewrite read about one line that makes a game Array, from the whole block:
        # +name+ the list's (Rewriter#game_array_list_name), +local+ the local's, +grows+ whether
        # game code adds items to it, +source+ the block or file the line is in, +declared_at+ the
        # line itself, and +fraction_at+ the first line that puts a fraction into it
        # (LocalNames#game_array_fraction_put), or nil. Each place is as a message names one,
        # `game.rb:12`. +things+ is a lambda giving the classes of the things game code puts in it
        # (`Spark.new(...)`), or nil, and +thing_fractions+ the fields a put shows a fraction for,
        # by position or keyword (DSL::StructArray).
        Declaration = Data.define(:name, :local, :grows, :source, :declared_at, :fraction_at, :things, :thing_fractions)

        # `name = Array.new(given..., capacity:, settings...)`, as the list it makes. The arguments
        # are Ruby's: a size and the start of each item, or a size and a block that works each item
        # out while building. Items that are not all numbers stay a Ruby Array, as
        # #list_from_literal says: `Array.new(3) { |n| var :"shown#{n}", 0 }` is three variables.
        def list_from_new(owner, declaration, *given, capacity: nil, **settings, &block)
          # Run as plain Ruby on purpose (Builder::Session.running_as_plain_ruby): Ruby's Array,
          # which grows as it needs to.
          return ruby_array(*given, **settings, &block) if Builder::Session.plain_ruby?

          # `TABLE[i]` reads like `Spark[...]`, but TABLE is a table of numbers, not a class.
          if declaration.things&.call&.any?(Module)
            refuse_made_with_no_game!(owner, declaration.local)
            return StructArray.declare(owner, declaration, given, capacity, settings, block)
          end

          refuse_unknown_settings!(settings)
          size = given.first
          refuse_unknown_size!(declaration.local, size) unless given.empty?
          refuse_missing_start!(size) if given.length == 1 && block.nil?
          items = if given.empty? then []
                  elsif block then Array.new(size, &block)
                  else Array.new(size, given[1])
                  end
          return items unless list_items?(items)

          declare(owner, declaration, items, capacity, settings)
        end

        # `Array.new(capacity: 4)` that game code never changes: Ruby's own Array, which grows as
        # it needs to, so the settings for a game's Array are left out.
        def ruby_array(*given, capacity: nil, **settings, &block)
          refuse_unknown_settings!(settings.except(*StructArray::SETTINGS))
          Array.new(*given, &block)
        end

        # `name = [items...]`, as the list it makes, holding those items and room for no more.
        #
        # Only items that are numbers make a list. A local game code changes holds a number too
        # (`[a, b]`, with `a += 1` somewhere in game code): Ruby copies that number into the Array,
        # so the list starts from it at this line, and a write to an item leaves the local alone.
        #
        # An Array made only of places with a name of their own, `var` handles and the like
        # (`[var(:a, 1), var(:b, 1)]`, `[hero.x, hero.y]`), stays Ruby's, as an Array of sprites
        # does: a write to an item changes that place. An Array of anything else stays Ruby's too.
        def list_from_literal(owner, declaration, items)
          refuse_nested_items!(declaration.local, items)
          return items if !list_items?(items) || Builder::Session.plain_ruby?

          declare(owner, declaration, items, nil, {})
        end

        # Are +items+ numbers a list holds, and not all of them named places (#list_from_literal)?
        def list_items?(items)
          return false unless items.all? { |item| item.is_a?(Numeric) || item.is_a?(Value) }

          items.empty? || !items.all? { |item| named_place?(item) }
        end

        # A place the game named itself, which an Array keeps as it is: a game variable made by a
        # `var` line or a handle like `hero.x`, not one made for a local of plain Ruby.
        def named_place?(item) = Steps.variable?(item) && !item.made_with_no_var_line?

        # What `list.shift` or `list.pop` hands back where the line uses it: the item it drops, as
        # Ruby hands it back. A Ruby Array does its own.
        def taken(collection, verb)
          if collection.is_a?(List)
            collection.drop_returning_item(verb == :shift ? :front : :back)
          else
            verb == :shift ? collection.shift : collection.pop
          end
        end

        # The list, holding fractions where the start or a line of game code puts one in. Its items
        # then explain a number of the other kind by naming the line that decided (#kind_advice).
        def declare(owner, declaration, items, capacity, settings)
          name = declaration.local
          refuse_unknown_capacity!(name, capacity) unless capacity.nil?
          room = capacity || items.length
          refuse_no_room!(name) if room.zero? || (declaration.grows && capacity.nil?)
          refuse_nested_items!(name, items)
          refuse_too_many_items!(name, items.length, room)
          refuse_made_with_no_game!(owner, name)

          builder = owner.is_a?(Builder) ? owner : Builder::Session.builder
          owner = Builder::ListOwner.new(owner: [:array, declaration.source], at: declaration.declared_at)
          list_name = builder.plain_array_list_name(declaration.name, owner)
          fraction_at = declaration.fraction_at || (declaration.declared_at if items.any? { |item| fraction?(item) })
          settings = settings.merge(holds: 0.0) if fraction_at
          list = if one_number_filling?(items, room)
                   builder.declare_list(list_name, capacity: room, full_of: items.first, **settings)
                 else
                   builder.declare_list(list_name, capacity: room, **settings).tap { |made| items.each { |item| made.push(item) } }
                 end
          list.explain_kinds_with(**kind_advice(name, fraction_at))
        end

        def fraction?(item) = item.is_a?(Float) || (item.is_a?(Value) && item.fraction?)

        # What a number of the wrong kind put into the list is told: which line made the Array
        # hold fractions, or that nothing the build could see did.
        def kind_advice(name, fraction_at)
          declaring = lambda do |_given|
            "write `.to_f` after a number this game puts into `#{name}`, so the build can see that " \
              "the Array holds fractions"
          end
          mixing = lambda do |holds_fraction|
            if holds_fraction
              "`#{name}` holds numbers with a fraction, since the line at #{fraction_at} puts one into it. " \
                "This line puts in a whole number the game works out, and there is no way to tell what it " \
                "counts. To fix this, use `.to_f` on the whole number, or `.to_i` on the fraction at #{fraction_at}."
            else
              "`#{name}` holds whole numbers, since no line the build can see puts a fraction into it. This " \
                "line puts in a number with a fraction. To fix this, use `.to_i` on it, or write `.to_f` after " \
                "a number the game puts into `#{name}`, so the Array holds fractions."
            end
          end
          { declaring: declaring, mixing: mixing }
        end

        # Every slot of the room holds one number: one fill as the list is made, not a push each.
        def one_number_filling?(items, room)
          items.length == room && items.first.is_a?(Numeric) && items.all? { |item| item.eql?(items.first) }
        end

        def refuse_unknown_settings!(settings)
          unknown = settings.keys - LIST_SETTINGS
          return if unknown.empty?

          Steps.refuse_game_code!("In game code, `Array.new` does not take `#{unknown.first}:`. It takes a size, the " \
                                  "number each item starts as, and `capacity:`, `width:` and `fast:`.")
        end

        # A game's Array made while no game is being built: by a part made above `VBlank.game`,
        # in a constant as its file loads, or after a build ended. A Ruby Array in its place would
        # take the game's pushes once, while building, so it is refused.
        def refuse_made_with_no_game!(owner, name)
          return if owner.is_a?(Builder) || Builder::Session.builder

          Steps.refuse_game_code!("`#{name}` is made while no game is being built. The game keeps this Array only " \
                                  "when the line that makes it runs while the game is built. To fix this, make " \
                                  "the part inside the `VBlank.game` block.")
        end

        def refuse_unknown_size!(name, size)
          return if size.is_a?(Integer) && !size.negative?

          Steps.refuse_game_code!("`#{name}` gets its size from #{known_while_building_problem(size)}. The build must " \
                                  "know how many items the list starts with. To fix this, give a whole number or a " \
                                  "constant, for example `Array.new(8, 0)`.")
        end

        def refuse_unknown_capacity!(name, capacity)
          return if capacity.is_a?(Integer) && capacity.positive?

          Steps.refuse_game_code!("`#{name}` gets its capacity from #{known_while_building_problem(capacity)}. The " \
                                  "console sets aside the memory for a list before the game starts, so the build " \
                                  "must know the capacity. To fix this, give a whole number or a constant, for " \
                                  "example `capacity: 8`.")
        end

        def known_while_building_problem(number)
          return "a number the game works out as it plays" if number.is_a?(Value)

          "#{number.inspect}, which is not a whole number above 0"
        end

        def refuse_missing_start!(size)
          Steps.refuse_game_code!("`Array.new(#{size.inspect})` gives items of nil in Ruby, and a list item cannot be " \
                                  "nil. To fix this, give the number each item starts as: `Array.new(#{size.inspect}, " \
                                  "0)`. For an empty list with room for #{size.inspect}, write " \
                                  "`Array.new(capacity: #{size.inspect})`.")
        end

        def refuse_no_room!(name)
          Steps.refuse_game_code!("`#{name}` is an Array that game code changes, so the game keeps it as a list. A " \
                                  "console keeps a fixed number of items in a list, and this Array has no room set " \
                                  "aside to add items to. To fix this, give the most items it can hold: " \
                                  "`#{name} = Array.new(capacity: 8)`, or `#{name} = Array.new(4, 0, capacity: 8)` " \
                                  "to start with 4 items of 0.")
        end

        def refuse_nested_items!(name, items)
          return unless items.any? { |item| item.is_a?(Array) || item.is_a?(Hash) }

          Steps.refuse_game_code!("`#{name}` holds an Array or a Hash as an item. A list the game keeps holds " \
                                  "numbers only. To fix this, keep each row in an Array of its own, or keep things " \
                                  "with many numbers each as an Array of Structs.")
        end

        def refuse_too_many_items!(name, count, room)
          return if count <= room

          Steps.refuse_game_code!("`#{name}` starts with #{count} items and has room for #{room}. To fix this, " \
                                  "give a capacity of #{count} or more.")
        end
      end
    end
  end
end
