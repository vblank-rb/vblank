# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Reference
        # A GAME'S OWN STATE, READ BACK BY THE NAMES THE GAME GAVE IT: a list, one field of a
        # pool, or all of it at once. The interpreter answers these, and so does a game run as C
        # (Native::HeadlessRun), from the same code — so the two answer the same question the
        # same way, in the same words when the name is wrong.
        #
        # Whoever includes this defines what it holds: #raw_var, a variable's stored number by its
        # name; #list_items, a list's items oldest first by its name (nil for a list it has none
        # of); #list_names, every list's name, the framework's own among them; #variables_now,
        # every variable's stored number by name; and #read_program, the program it plays (nil for
        # a tree with no program at its root, or a cartridge with no build record).
        #
        # EVERY NUMBER COMES BACK IN THE GAME'S UNITS. A variable or list the game keeps fractions
        # in holds the number multiplied up (DSL::Fraction), and the program says by how much
        # (Program#var_in_game_units), so 12.5 reads as 12.5 and not as what the console stores.
        # #raw_var is the stored number, for a test about how it is kept.
        module ReadingBack
          # A variable's number now, by the name the game gave it (0 if it was never written).
          def var(name) = var_in_game_units(name, raw_var(name))
          def [](name) = var(name)

          # A sprite by the name the game reads it by (its `called:`, or its picture's): an
          # IR::SpriteState with its +x+, +y+, whether it is #shown?, and the +pose+ it is showing.
          def sprite(name)
            refuse_no_program!("its sprites") unless read_program
            read_program.sprite_state(name, method(:raw_var))
          end

          # Read a list: everything in it now, oldest first, under the name the game declared.
          # An Array, so a test asks for an item, the length, or the whole thing as it likes.
          def list(name)
            items = list_items(name) or raise ArgumentError, no_such_message("list", name, declared_lists)
            list_in_game_units(name, items)
          end

          # Read one field of a pool: an entry per slot, the value where an instance is live and
          # nil where the slot is free, so a test can ask about the one it spawned first.
          #
          # A pool keeps each field as a list of its own, beside a column saying which slots are
          # live. Those are named after the pool, and nothing a game writes should have to know
          # how — so this is asked by pool and field, the two names the game used.
          def pool(name, field)
            live = list_items(pool_live_list(name)) or raise ArgumentError, no_such_message("pool", name, pools)
            field_list = Messages::MadeNames.make(:pool_field, pool: name, field: field)
            values = list_items(field_list)
            raise ArgumentError, no_such_message("field", field, pool_fields(name), of: " in pool :#{name}") if values.nil?

            list_in_game_units(field_list, values).zip(live).map { |value, up| value if up.to_i.nonzero? }
          end

          # Everything the game declared, as it stands now: each variable's value, each list
          # read the way #list reads it, and each pool field the way #pool reads it —
          #
          #   { vars: { hearts: 3 }, lists: { trail: [3, 3] }, pools: { guard: { x: [nil, 10] } } }
          #
          # Plain Hashes, so two of them compare with == and a test that compares two moments
          # compares the whole game, including whatever it declares after the test is written.
          # What the framework keeps for itself is named with two underscores and left out: it
          # is how the game is run, not what the game is.
          def game_state
            { vars: variables_now.reject { |name, _| framework_own?(name) }
                                 .to_h { |name, raw| [name, var_in_game_units(name, raw)] },
              lists: declared_lists.to_h { |name| [name, list(name)] },
              pools: pools.to_h { |name| [name, pool_fields(name).to_h { |field| [field, pool(name, field)] }] } }
          end

          private

          # A run of a tree with no program at its root has no names but its variables' and lists'.
          def refuse_no_program!(what)
            raise ArgumentError, "This run played no whole program, so nothing says #{what}. Run a program " \
                                 "(`VBlank.game`, or `program(...)`) to read #{what} by name."
          end

          # A stored number, and a list's stored items, as the game's; as they are with no program.
          def var_in_game_units(name, stored) = read_program ? read_program.var_in_game_units(name, stored) : stored
          def list_in_game_units(name, items) = read_program ? read_program.list_in_game_units(name, items) : items

          # A pool's field is a list, and so is what the pool keeps for itself beside its fields:
          # which slots are live, which are free, the order they were spawned in. The two are
          # spelled apart (see Messages::MadeNames), so a list's name shows which it is, and of
          # which pool.

          # The list saying which slots of +pool+ are live.
          def pool_live_list(pool) = Messages::MadeNames.make(:pool_part, pool: pool, part: :active)

          # The lists the game declared itself; the framework's own are named with two
          # underscores in front.
          def declared_lists = list_names.reject { |name| framework_own?(name) }

          def framework_own?(name) = name.start_with?("__")

          def pools
            list_names.filter_map do |key|
              kind, parts = Messages::MadeNames.read(key)
              parts[:pool].to_sym if kind == :pool_part && parts[:part] == "active"
            end
          end

          # The fields of +pool+.
          def pool_fields(pool)
            list_names.filter_map do |key|
              kind, parts = Messages::MadeNames.read(key)
              parts[:field].to_sym if kind == :pool_field && parts[:pool] == pool.to_s
            end
          end

          def no_such_message(what, name, there, of: "")
            listed = there.empty? ? "There are none." : "There #{there.size == 1 ? 'is' : 'are'} #{there.map { |n| ":#{n}" }.join(', ')}."
            "There is no #{what} :#{name}#{of}. #{listed}"
          end
        end
      end
    end
  end
end
