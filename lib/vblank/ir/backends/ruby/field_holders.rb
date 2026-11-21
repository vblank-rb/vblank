# frozen_string_literal: true

require "prism"

module VBlank
  module IR
    module Backends
      class Ruby
        # The game's fields, split over holders small enough for Ruby to keep in place. Everything a
        # game built as Ruby keeps — its variables and lists, the tables the build writes, and every
        # field of the runtime's — is written as an instance variable of the one game object
        # (`@rg_pixels`, `@v_score`). Ruby keeps an object's instance variables at fixed places only
        # up to a number of them; past it the object keeps them in a hash, and a JIT then reads and
        # writes each about twice as slowly as before, slower than with no JIT at all. A game has a
        # couple of hundred from its first statement.
        #
        # So the class's body is rewritten before it is made: past what the game object can keep
        # itself (#moved_fields), each instance variable a method of the game reads or writes
        # becomes a field of a holder object, `@rg_clock_ticks` becoming `@rg_fields_2.rg_clock_ticks`,
        # reached through the holder's attribute reader and writer, which YJIT and ZJIT both compile
        # to a load from a fixed place, as for an instance variable of a small object. Neither the
        # game object, its holders counted, nor any holder holds more than FIELDS_KEPT_IN_PLACE.
        #
        # A holder sets every one of its fields as it is made, in one order, so every holder of a
        # class has one layout from the start: a Ractor that makes a game of a shared class
        # (LiveGame.shareable_class) never lays one out while another does.
        #
        # Only instance variables of the game object are moved: those inside a method defined at the
        # top of the class's body, blocks inside it included (a block's self is the game). A class the
        # runtime defines inside the game's (RgList, RgTimer), a block handed to Struct.new or
        # Data.define, and a method defined on the class itself keep theirs.
        class FieldHolders
          # The most instance variables Ruby keeps at fixed places in one object, less a margin. Ruby
          # 4.1's shape.h holds an object's count of fields in 7 bits:
          #
          #   #define SHAPE_ID_CAPACITY_BITS 7
          #   #define SHAPE_ID_CAPACITY_MAX ((1U << SHAPE_ID_CAPACITY_BITS) - 1)
          #
          # so 127 at most (ruby/ruby master, shape.h, at revision 3be2b028a7), and an object given
          # more is kept as a hash (ObjectSpace.dump names it "complex_shape"). It is a constant of
          # Ruby's C source, built in and not in RbConfig, so it is written here rather than asked as
          # the game runs. Ruby 4.0 has no such cap; there the holders only cost, which is why the
          # fields read most stay on the game object (FIELDS_READ_EVERY_PIXEL).
          FIELDS_KEPT_IN_PLACE = 100

          # The runtime's fields read for every pixel drawn (runtime/rg_screen.rb's rg_set_pixel and
          # the routines it calls), kept on the game object itself. Counted as a first-person view
          # plays, these are nearly all of a pass's reads and writes of fields, and each moved into a
          # holder slowed the whole game by a share Ruby 4.0 can see.
          FIELDS_READ_EVERY_PIXEL = Ractor.make_shareable(%w[rg_target rg_mixing rg_seen_through_answer
                                                             rg_picture_without_sprites rg_painting_sprite
                                                             rg_picture_touched rg_area rg_pixels rg_picture_mixes
                                                             rg_paint_fade rg_plain_layer rg_mixed_by rg_scenery
                                                             rg_scenery_mixes rg_game_picture_sizes
                                                             rg_game_see_through].to_set)

          # Raised when the body cannot be split: Ruby that does not parse, or a test of whether an
          # instance variable is set (`defined?(@x)`), which a holder's field cannot answer the same.
          class SplitError < BuildError; end

          # Each place an instance variable of the game is named: the bytes it spans, its name with no
          # @, and whether it is written inside a string as `#@name`, which needs braces once moved.
          Use = Data.define(:from, :past, :name, :in_string)

          # +text+, the body of the game's class, with its fields moved into holders, the holders'
          # classes after it, and rg_fields_make, which the game's initialize calls first.
          def self.split(text) = new(text).split

          def initialize(text)
            @text = text
          end

          def split
            parsed = Prism.parse(@text)
            raise SplitError, "the game's Ruby does not parse: #{parsed.errors.first&.message}" unless parsed.success?

            finder = UseFinder.new
            parsed.value.accept(finder)
            holders = holders_of(moved_fields(finder.uses))
            holder_of = {}
            holders.each_with_index { |fields, at| fields.each { |field| holder_of[field] = at + 1 } }

            [moved_text(finder.uses, holder_of), *holders.each_with_index.map { |fields, at| holder_class(at + 1, fields) },
             holders_made(holders.length)].join
          end

          private

          # The fields moved into holders; the rest stay on the game object itself. A field in a
          # holder costs a JIT one more load and test at each use than one on the game object, and
          # Ruby 4.0, with no cap, pays that for nothing. So the game object keeps as many as it can
          # beside its holders: first FIELDS_READ_EVERY_PIXEL, then those the text names most often.
          # The moved fields are dealt out in the order the text first names them, so each part's
          # sit together.
          def moved_fields(uses)
            counts = uses.map(&:name).tally # in the order the text first names each
            refuse_unnamed_pixel_fields!(counts)
            return [] if counts.length <= FIELDS_KEPT_IN_PLACE

            holders = 1
            holders += 1 until holders == MOST_HOLDERS ||
                               counts.length - (FIELDS_KEPT_IN_PLACE - holders) <= holders * FIELDS_KEPT_IN_PLACE
            order = counts.keys.each_with_index.to_h
            kept = counts.keys.max_by(FIELDS_KEPT_IN_PLACE - holders) do |name|
              [FIELDS_READ_EVERY_PIXEL.include?(name) ? 1 : 0, counts[name], -order[name]]
            end.to_set
            moved = counts.keys.reject { |name| kept.include?(name) }
            return moved if moved.length <= MOST_HOLDERS * FIELDS_KEPT_IN_PLACE

            # Too many for the holders: the ones named most fill them, and the rest go to the last.
            moved.sort_by { |name| [-counts[name], order[name]] }
          end

          # The most holders the game object keeps, leaving it room for the fields it keeps itself.
          MOST_HOLDERS = FIELDS_KEPT_IN_PLACE / 2

          # +moved+ dealt into holders of FIELDS_KEPT_IN_PLACE. Fields past what MOST_HOLDERS of them
          # hold all go to the last one, which Ruby then keeps as a hash: slower for those fields
          # alone, and only for a program of many thousands, such as an unpacking routine.
          def holders_of(moved)
            slices = moved.each_slice(FIELDS_KEPT_IN_PLACE).to_a
            return slices if slices.length <= MOST_HOLDERS

            [*slices.first(MOST_HOLDERS - 1), slices.drop(MOST_HOLDERS - 1).flatten]
          end

          # The list is of runtime/rg_screen.rb's fields, which every game carries, so one renamed
          # there and not here stops every build rather than going slow unseen.
          def refuse_unnamed_pixel_fields!(counts)
            missing = FIELDS_READ_EVERY_PIXEL.reject { |name| counts.key?(name) }
            return if missing.empty?

            raise SplitError, "FieldHolders::FIELDS_READ_EVERY_PIXEL names #{missing.join(', ')}, which the runtime never names"
          end

          # The text with each use of a moved field written as its holder's attribute.
          def moved_text(uses, holder_of)
            bytes = @text.b
            out = +"".b
            at = 0
            uses.select { |use| holder_of.key?(use.name) }.sort_by(&:from).each do |use|
              out << bytes.byteslice(at, use.from - at)
              moved = "@#{holder_name(holder_of.fetch(use.name))}.#{use.name}"
              out << (use.in_string ? "\#{#{moved}}" : moved)
              at = use.past
            end
            out << bytes.byteslice(at, bytes.bytesize - at)
            out.force_encoding(@text.encoding)
          end

          def holder_name(number) = "rg_fields_#{number}"
          def holder_class_name(number) = "RgFields#{number}"

          def holder_class(number, fields)
            ["\nclass #{holder_class_name(number)}\n",
             "  attr_accessor #{fields.map { |field| ":#{field}" }.join(', ')}\n\n",
             "  def initialize\n", *fields.map { |field| "    @#{field} = nil\n" }, "  end\nend\n"].join
          end

          def holders_made(count)
            ["\ndef rg_fields_make\n",
             *(1..count).map { |number| "  @#{holder_name(number)} = #{holder_class_name(number)}.new\n" }, "end\n"].join
          end

          # Finds every place a method of the game names one of its instance variables (see the
          # class's heading for which those are).
          class UseFinder < Prism::Visitor
            attr_reader :uses

            def initialize
              super
              @uses = []
              @scope = :top # :top, the class's body; :game, a method of the game; :other, anything else
            end

            def visit_class_node(node) = within(:other) { super }
            def visit_module_node(node) = within(:other) { super }
            def visit_singleton_class_node(node) = within(:other) { super }

            # A block keeps its method's self; one at the top of the body belongs to the call it is
            # handed to (Struct.new, Data.define), never to a game.
            def visit_block_node(node) = within(@scope == :top ? :other : @scope) { super }
            def visit_lambda_node(node) = within(@scope == :top ? :other : @scope) { super }

            def visit_def_node(node)
              within(node.receiver || @scope == :other ? :other : :game) { super }
            end

            def visit_instance_variable_read_node(node)
              note(node.location, node.name)
              super
            end

            def visit_instance_variable_target_node(node)
              note(node.location, node.name)
              super
            end

            def visit_instance_variable_write_node(node)
              note(node.name_loc, node.name)
              super
            end

            def visit_instance_variable_operator_write_node(node)
              note(node.name_loc, node.name)
              super
            end

            def visit_instance_variable_or_write_node(node)
              note(node.name_loc, node.name)
              super
            end

            def visit_instance_variable_and_write_node(node)
              note(node.name_loc, node.name)
              super
            end

            # `"#@name"`: the whole `#@name` is replaced, with braces round the holder's attribute.
            def visit_embedded_variable_node(node)
              return super unless @scope == :game && node.variable.is_a?(Prism::InstanceVariableReadNode)

              @uses << Use.new(from: node.location.start_offset, past: node.location.end_offset,
                               name: node.variable.name.to_s.delete_prefix("@"), in_string: true)
            end

            def visit_defined_node(node)
              if @scope == :game && node.value.is_a?(Prism::InstanceVariableReadNode)
                raise SplitError, "the game's Ruby asks defined?(#{node.value.name}), which a field kept in a holder " \
                                  "cannot answer the same way"
              end

              super
            end

            # A pattern that pins an instance variable (`in ^@x`) cannot pin a holder's field: `^` takes
            # a variable or a parenthesised expression, and `^@rg_fields_1.x` does not parse.
            def visit_pinned_variable_node(node)
              if @scope == :game && node.variable.is_a?(Prism::InstanceVariableReadNode)
                raise SplitError, "the game's Ruby pins #{node.variable.name} in a pattern, which a field kept in a " \
                                  "holder cannot be; write ^(#{node.variable.name}) instead"
              end

              super
            end

            private

            def within(scope)
              outside = @scope
              @scope = scope
              yield
            ensure
              @scope = outside
            end

            def note(location, name)
              return unless @scope == :game

              @uses << Use.new(from: location.start_offset, past: location.end_offset,
                               name: name.to_s.delete_prefix("@"), in_string: false)
            end
          end
        end
      end
    end
  end
end
