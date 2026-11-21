# frozen_string_literal: true

module VBlank
  module DSL
    # A field of one thing in a pool
    #
    # Inside a pool's walk, each thing's fields read and change like variables: `b.x`, `b.y`
    # and the rest. Each is a number (see Value), so it adds, compares and changes with `=`,
    # `+=` and `-=`, and the methods ending in `!` change that one thing's field.
    #
    # ```ruby
    # bullets.each do |b|
    #   b.y += b.dy
    #   b.x.clamp!(0, 232)
    # end
    # ```
    #
    # A field declared with a decimal point (`dy: 0.0`) holds a fraction, as a variable does.
    #--
    # A mutable handle to one field of one pool instance, at a run-time slot index. It reads
    # and writes that instance's slot in the field's backing list, so it behaves like an
    # ordinary variable Value even though it lives at a computed index rather than in a named
    # variable. This front-end handle is the whole trick that makes a pool read like game code:
    # `b.y += b.vy` is really `y[i] = y[i] + vy[i]`.
    #++
    class FieldRef < Value
      Build = IR::Build

      # @param builder [Builder] the build these operations record into
      # @param list [Symbol] the field's backing list (one list per field)
      # @param index [IR::Node] the value node for this instance's slot index
      # @param pool [Symbol] the pool this field belongs to, for its error messages
      # @param field [Symbol] the field's own name, likewise
      # @param fraction_bits [Integer, nil] what the field holds, from its declared default —
      #   a pool field written `vy: 0.0` carries a fraction the way a variable does
      # @param names [NameSet, nil] the names the field holds, for a field declared with one
      def initialize(builder:, list:, index:, pool:, field:, fraction_bits: nil, names: nil)
        @list_name = list
        @index_node = index
        @pool = pool
        @field = field
        # As a Value, this handle is a read of the slot — so it composes in expressions
        # (b.x + 5, b.y > 100) exactly like a variable read. It carries no variable name,
        # so the mutators below override Value's (which write to a named variable).
        super(builder, read, name: nil, fraction_bits: fraction_bits, names: names,
                             declaring: self.class.fraction_declaration_advice(pool, field),
                             mixing: self.class.mixed_kinds_advice(pool, field))
      end

      # A handle, not a working-out: it stands for one slot of one field, so writing one
      # down and doing nothing with it is as harmless as naming a variable. See Value#handle?.
      def handle? = true # :nodoc:

      # What a pool field keeps, without building a handle to ask. A pool checks the values
      # a `spawn` was given against the fields they are going into, and it has no instance
      # to hold a handle for — nor any need of one. On the class so that a field's own two
      # sentences are written once and both callers say the same thing.
      def self.scale(pool:, field:, bits:, names: nil) # :nodoc:
        Scale.new(bits: bits, declaring: fraction_declaration_advice(pool, field), mixing: mixed_kinds_advice(pool, field),
                  names: names)
      end

      # How to make this field hold a fraction: declare it in the default it is declared with,
      # which is the same way a variable declares it.
      def self.fraction_declaration_advice(pool, field) # :nodoc:
        lambda { |other|
          "declare the field with one — `pool :#{pool}, #{field}: #{other}` rather than " \
            "`#{field}: #{other.to_i}`"
        }
      end

      # How to say the other mismatch. A field has no left and right side, so the wording a
      # plain operator uses does not fit it.
      def self.mixed_kinds_advice(pool, field) # :nodoc:
        lambda { |field_holds_fraction|
          holds, given = if field_holds_fraction
                           ["numbers with a fraction", "a whole number the game works out"]
                         else
                           ["whole numbers", "a number with a fraction"]
                         end
          "`pool :#{pool}` keeps #{holds} in its #{field.inspect} field, and this is " \
            "#{given}. There is no way to tell what it counts. Use `.to_f` on the whole " \
            "number to give it a fraction, or `.to_i` on the other one to drop its fraction."
        }
      end

      # --- mutation: write back into this instance's slot ---

      # Each value on its way into the slot is checked against what the field holds.
      def store!(value) # :nodoc:
        write(node_matching(value, "hold"))
      end

      def increase!(amount) # :nodoc:
        write(Build.binop(:+, read, node_matching(amount, "add")))
      end

      def decrease!(amount) # :nodoc:
        write(Build.binop(:-, read, node_matching(amount, "subtract")))
      end

      # Holds this thing's field from `lo` to `hi`, as Value#clamp! holds a variable.
      #
      # ```ruby
      # b.x.clamp!(0, 232)
      # ```
      #--
      # The read-modify-write mutators round-trip through a scratch variable: load the slot,
      # apply the ordinary Value mutator, store it back. This reuses Value's whole mutation
      # vocabulary unchanged.
      #++
      def clamp!(lo, hi)
        via_scratch { |s| s.clamp!(lo, hi) }
      end

      # Moves this thing's field toward `target` by at most `step`, as Value#approach! moves a
      # variable.
      def approach!(target, step)
        via_scratch { |s| s.approach!(target, step) }
      end

      # Makes this thing's field its distance from 0, as Value#abs! does.
      def abs!
        via_scratch(&:abs!)
      end

      # Makes this thing's field minus its distance from 0, as Value#negate_abs! does.
      def negate_abs!
        via_scratch(&:negate_abs!)
      end

      # Turns this thing's field the other way round, as Value#flip! does.
      #
      # ```ruby
      # b.dx.flip! if b.x > 232
      # ```
      def flip!
        via_scratch(&:flip!)
      end

      private

      # A pool field is written through the instance a walk hands over, whose name this handle
      # never learns — so a message names the field.
      def name_as_written = @field.to_s

      # The value node that reads this instance's slot.
      def read
        Build.list_get(@list_name, @index_node)
      end

      # Store a value node into this instance's slot, returning self so calls chain.
      def write(value_node)
        @builder.record_statement(Build.list_set(@list_name, @index_node, value_node))
        self
      end

      # Load the slot into a reusable scratch variable, apply an ordinary Value mutation
      # to it, and store it back into the slot. The scratch carries the field's scale, so a
      # `clamp` or an `approach` on a field that holds a fraction follows the same rules.
      def via_scratch
        scratch = @builder.field_scratch_var
        @builder.record_statement(Build.set(scratch, read))
        yield Value.new(@builder, Build.var_ref(scratch), name: scratch, fraction_bits: fraction_bits)
        write(Build.var_ref(scratch))
      end

      def node_of(other)
        Value.node_for(other)
      end
    end
  end
end
