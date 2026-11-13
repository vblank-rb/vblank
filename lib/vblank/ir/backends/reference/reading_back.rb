# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Reference
        # A GAME'S OWN STATE, READ BACK BY THE NAMES THE GAME GAVE IT: a variable, a sprite, a
        # background and the music (IR::ReadingByName, which every reader shares), and here a list,
        # one field of a pool, or all of it at once. The interpreter answers these, and so does a
        # game run as C (Native::HeadlessRun), from the same code — so the two answer the same
        # question the same way, in the same words when the name is wrong.
        #
        # Whoever includes this defines what IR::ReadingByName asks (#raw_var, #read_program) and
        # what it holds besides: #list_items, a list's items oldest first by its name (nil for a
        # list it has none of); #list_names, every list's name, the framework's own among them; and
        # #variables_now, every variable's stored number by name.
        #
        # EVERY NUMBER COMES BACK IN THE GAME'S UNITS. A variable or list the game keeps fractions
        # in holds the number multiplied up (DSL::Fraction), and the program says by how much
        # (Program#var_in_game_units), so 12.5 reads as 12.5 and not as what the console stores.
        # #raw_var is the stored number, for a test about how it is kept.
        module ReadingBack
          include IR::ReadingByName

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

          # What the game's save_data records keep, as it stands now: #game_state holding only the
          # variables, lists and pools some record keeps, read the same way, so a test compares the
          # moment a game saved with the same game after a load and asks whether everything came back.
          # Public for a game's own test of a save made in the middle of play. Working room a save
          # never keeps is not in it: a scratch name starting with _, a part's `game_variables ...,
          # saved: false`, a name saves_keep_everything leaves out.
          #
          # It is read from the records as the build laid them out (Program#save_data_records), not
          # from a second copy of the rule, so it holds what the saves really keep. A pool kept one
          # field at a time holds that field alone. A `save_var` saves itself and is in no record.
          #
          # NOT EVERYTHING A RECORD KEEPS IS HERE: only what #game_state holds. The random numbers a
          # record keeps are the framework's own variable, and a pool's facing, animation and colours
          # are kept beside its fields; #game_state holds none of them, so a load that lost one of
          # them does not show in this reading.
          def saved_state
            kept = save_data_kept
            state = game_state
            fields_kept = kept.pool_fields.to_h { |pool, fields| [pool, state[:pools].fetch(pool).slice(*fields)] }
            { vars: state[:vars].slice(*kept.vars),
              lists: state[:lists].slice(*kept.lists),
              pools: fields_kept.merge(state[:pools].slice(*kept.pools)) }
          end

          # The names the save_data records keep: +vars+, +lists+ and +pools+ (kept whole) as lists
          # of names, and +pool_fields+ the fields kept one at a time, by the pool's name.
          SavedNames = Data.define(:vars, :lists, :pools, :pool_fields)

          private

          # The SavedNames of the program's save_data records. Each kept entry is one of
          # Builder::Saves#laid_out_records's; the random numbers are passed over (see #saved_state).
          def save_data_kept
            records = named_program("what its saves keep").save_data_records
            if records.empty?
              raise ArgumentError, "This game declares no save_data record, so a save keeps nothing. " \
                                   "Read game_state instead, or declare a record with save_data."
            end

            entries = records.flat_map(&:last)
            names_of = ->(kind) { entries.filter_map { |one, name| name.to_sym if one == kind } }
            fields = entries.select { |kind, _| kind == :pool_field }
                            .group_by { |_, pool, _| pool.to_sym }
                            .transform_values { |kept| kept.map { |_, _, field| field.to_sym } }
            SavedNames.new(vars: names_of.call(:var), lists: names_of.call(:list), pools: names_of.call(:pool),
                           pool_fields: fields)
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
