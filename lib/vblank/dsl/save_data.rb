# frozen_string_literal: true

module VBlank
  module DSL
    # A record kept in save memory
    #
    # What Builder#save_data hands back: a record of the game's state kept in save memory, in one
    # or more copies, such as the files on a file screen. Index it for one of its copies,
    # `files[slot]`, where the number may be one the game works out. Each copy is a SaveDataCopy.
    #
    # ```ruby
    # files = save_data :files, copies: 3
    # files.keep hearts, level
    # files[slot].save if pressed(:a)
    # draw_text "Saved!", 80, 70, :white if files.finished?
    # ```
    class SaveData
      def initialize(builder, saves, layout)
        @builder = builder # what the numbers and conditions handed back build program through
        @saves = saves     # the record's routines and state (see Builder::Saves)
        @layout = layout
      end

      # One copy of the record, as a SaveDataCopy, counted from 0.
      #
      # A number written in the program has to be one the record has. One the game works out
      # that names no copy does nothing: it saves nothing, loads nothing, and reads as empty, the
      # same as a map number that names no map.
      #
      # ```ruby
      # files[0].load
      # files[slot].save
      # ```
      def [](copy)
        if copy.is_a?(Integer) && !copy.between?(0, @layout.copies - 1)
          raise ArgumentError, "save_data :#{@layout.name} has #{@layout.copies} " \
                               "#{@layout.copies == 1 ? 'copy' : 'copies'}, counted from 0, so it has " \
                               "no copy #{copy}. To fix this, use a number from 0 to #{@layout.copies - 1}."
        end

        SaveDataCopy.new(@builder, @saves, @layout, Value.node_for(copy))
      end

      # Adds variables and lists to what the record keeps, after the ones it already keeps.
      #
      # The code that owns them can write this anywhere in the program. So a file screen can be
      # declared first and use the record, and the gameplay declared after it names what goes
      # in. The order things are kept in is the record's shape, and a save made with another
      # shape reads as empty.
      #
      # ```ruby
      # files.keep hearts, score
      # files.keep part: :play      # all of the part named play, in one word
      # ```
      #
      # * `part:` - a part, or a scene's declared state, to keep whole by its name, as
      #   Builder#start_over puts it back.
      def keep(*things, part: nil)
        things += [Builder::SaveRecords::KeptPart.new(name: part)] if part
        @saves.save_data_keep(@layout.name, things)
        self
      end

      # Copies one copy of the record over another, as a file screen's copy choice does.
      #
      # Only a good copy is copied, and the one written over keeps its last good save until the
      # whole of the new one is in.
      #
      # ```ruby
      # files.copy 0, to: 2
      # ```
      #
      # * `to:` - the number of the copy to write over.
      def copy(from, to:)
        [from, to].each { |copy| self[copy] if copy.is_a?(Integer) } # the written-number check
        @saves.emit_save_data_copy_call(@layout, Value.node_for(from), Value.node_for(to))
      end

      # Puts every kept thing back as it was declared, for a new game.
      #
      # Only the game's state changes; nothing in save memory does.
      #
      # ```ruby
      # files.reset
      # ```
      def reset = @saves.emit_save_data_call(@layout, :reset, IR::Build.int(0))

      # Whether the last save, erase or copy did not read back as it should have, because the
      # chip did not keep it.
      #
      # The answer holds until the next save, erase or copy.
      #
      # ```ruby
      # draw_text "Save failed", 60, 70, :red if files.failed?
      # ```
      def failed? = Condition.new(@builder, @saves.save_data_failed(@layout))

      # Whether a save, erase or copy of this record is still being written.
      #
      # Saves are written a piece a pass while the game goes on, so this holds for a few passes
      # after one is asked for: the time to show that the game is saving, however the game likes
      # to show it.
      #
      # ```ruby
      # draw_text "Saving", 80, 70, :white if files.saving?
      # ```
      def saving? = Condition.new(@builder, @saves.save_data_saving(@layout))

      # Whether a save, erase or copy of this record has just been written.
      #
      # It is true for the one pass after, so a game can show that the save is done there
      # without keeping count of anything.
      #
      # ```ruby
      # draw_text "Saved!", 80, 70, :white if files.finished?
      # ```
      def finished? = Condition.new(@builder, @saves.save_data_finished(@layout))
    end

    # One copy of a save record
    #
    # One copy of a SaveData record, as `files[slot]` hands it back: save the game into it, load
    # it into the game, erase it, and ask what it holds.
    #
    # ```ruby
    # files[slot].load if files[slot].good?
    # files[slot].erase if pressed(:select)
    # ```
    class SaveDataCopy
      Build = IR::Build # :nodoc:

      def initialize(builder, saves, layout, copy)
        @builder = builder
        @saves = saves
        @layout = layout
        @copy = copy
      end

      # Writes the game's state into this copy.
      #
      # Until the whole of it is written the copy is still the last good save, so the power
      # going off half way loses nothing.
      #
      # ```ruby
      # files[slot].save
      # ```
      def save = @saves.emit_save_data_call(@layout, :save, @copy)

      # Puts this copy back into the game's state, when the copy is good.
      #
      # When it is not, nothing changes, so loading a game's settings at power-on needs no test
      # around it.
      #
      # ```ruby
      # settings[0].load
      # ```
      def load = @saves.emit_save_data_call(@layout, :load, @copy)

      # Marks this copy erased.
      #
      # It then reads as erased rather than empty: a game that never saved there and one that
      # saved and threw it away are two different things to know.
      #
      # ```ruby
      # files[slot].erase
      # ```
      def erase = @saves.emit_save_data_call(@layout, :erase, @copy)

      # What this copy holds: one of the names `:empty`, `:erased`, `:good` or `:damaged`.
      #
      # Compare it with a name, or ask SaveDataCopy#good?, #empty?, #erased? or #damaged?.
      #
      # ```ruby
      # draw_text "NEW", 20, row_y, :white if files[n].state == :empty
      # ```
      def state
        names = NameSet.new("the state of a save_data copy")
        IR::SaveLayout::STATES.each { |name| names.number_for(name) }
        Value.new(@builder, @saves.save_data_state_after_jobs(@layout, @copy), names: names)
      end

      # Whether this copy holds a whole save that reads back as it was written.
      #
      # ```ruby
      # files[slot].load if files[slot].good?
      # ```
      def good? = state_is?(:good)

      # Whether nothing was ever saved in this copy.
      #
      # ```ruby
      # draw_text "NEW GAME", 20, row_y, :white if files[n].empty?
      # ```
      def empty? = state_is?(:empty)

      # Whether this copy was saved and then erased with SaveDataCopy#erase.
      #
      # ```ruby
      # draw_text "ERASED", 20, row_y, :gray if files[n].erased?
      # ```
      def erased? = state_is?(:erased)

      # Whether this copy holds a save that does not read back as it was written.
      #
      # ```ruby
      # draw_text "DAMAGED", 20, row_y, :red if files[n].damaged?
      # ```
      def damaged? = state_is?(:damaged)

      # A variable or list the record keeps, as this copy holds it, read from save memory with
      # the game's own state left alone.
      #
      # A file screen shows each file's hearts this way. A copy that is not good reads as 0. A
      # kept list reads the same way, item by item and its length. An item past what the copy
      # holds reads as 0. It hands back a SaveDataPeek.
      #
      # ```ruby
      # draw_number files[n].peek(:hearts), 100, row_y, :white
      # draw_number files[n].peek(:items).length, 140, row_y, :white
      # ```
      #
      # The thing can be named before the record keeps it, such as `peek(:hearts)` on a file
      # screen declared ahead of the gameplay that keeps the hearts. It is checked once the
      # whole program is declared.
      def peek(thing)
        SaveDataPeek.new(@builder, @saves, @layout, @copy, thing.is_a?(Symbol) ? thing : thing.name)
      end

      private

      def state_is?(name)
        Condition.new(@builder, Build.binop(:==, @saves.save_data_state_after_jobs(@layout, @copy),
                                            Build.int(IR::SaveLayout::STATES.index(name))))
      end
    end

    # A kept thing read from a save
    #
    # A kept thing as one copy holds it, read from save memory with the game's own state left
    # alone. SaveDataCopy#peek hands one back. A kept variable is this number. A kept list is
    # read through it, item by item and its length.
    #
    # ```ruby
    # draw_number files[n].peek(:hearts), 100, row_y, :white
    # draw_number files[n].peek(:items)[0], 120, row_y, :white
    # ```
    #
    # Where the game reads it, which of the two the thing is may not be known yet, so it is both.
    # A reading of the wrong one is a friendly error once it is known.
    class SaveDataPeek < Value
      def initialize(builder, saves, layout, copy, name)
        @saves = saves
        @layout = layout
        @copy = copy
        @kept_name = name
        super(builder, saves.peek_stand_in(layout, copy, name, :number))
      end

      # One item of a kept list as this copy holds it, counted from 0.
      #
      # An item past what the copy holds reads as 0.
      #
      # ```ruby
      # draw_number files[n].peek(:items)[i], 120, row_y, :white
      # ```
      def [](index) = peek_list_value(:item, index: Value.node_for(index))

      # How many items a kept list holds in this copy.
      #
      # ```ruby
      # draw_number files[n].peek(:items).length, 140, row_y, :white
      # ```
      def length = peek_list_value(:length)

      private

      # Read as a list, the number this stands for is not the reading, so it is no expression
      # somebody forgot to keep. It is taken out by identity: `delete` would ask every held
      # expression `==`, and on a Value that builds a comparison rather than answering.
      def peek_list_value(shape, index: nil)
        @builder.expressions.delete_if { |held| held.equal?(self) } if @builder.respond_to?(:expressions)
        Value.new(@builder, @saves.peek_stand_in(@layout, @copy, @kept_name, shape, index: index))
      end
    end
  end
end
