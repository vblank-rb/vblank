# frozen_string_literal: true

module VBlank
  module Original
    module Packing
      # A PACKED FORMAT AN UNPACKING ROUTINE CAN READ: a module that extends this, names the
      # format, and writes its routine with a BlockKit. The library's own formats
      # (Packing::GBA, Packing::Genesis) are written this way and no other, so a port writes a
      # format the library lacks the same way, and names it in `data_pack formats: [...]`:
      #
      #   module Sorcery
      #     extend VBlank::Original::Packing::Format
      #     unpacks :sorcery                 # gives the copy `unpack_sorcery at:, into:, start:`
      #
      #     def self.routine(block)          # game code, written into the unpacking once
      #       at = block.variable(:at)
      #       at.store!(block.from)
      #       ...
      #       block.write(block.byte(at))
      #     end
      #   end
      #
      # A format with settings names each with its default (`unpacks :enigma, base: 0`), and the
      # copy's verb takes them (`copy.unpack_enigma at:, into:, base: 0x2000`); the routine reads
      # each with `block.setting(:base)`. A routine's file is game code, as any part of a game is
      # (VBlank.require_game_file), so an `if` on a test the routine makes is a branch in it.
      module Format
        # Names the format: +name+ gives the copy `unpack_<name>`, and +settings+ are the settings
        # that verb takes besides at:, into: and start:, each with its default.
        def unpacks(name, **settings)
          refuse_settings_named_as_places!(name, settings)
          @format_name = name.to_sym
          # Shareable, since a test may unpack in a Ractor and these are a module's.
          @format_settings = Ractor.make_shareable(settings)
        end

        # What a person calls the format, in an error that names it: +words+, or the name.
        def called(words) = @format_words = Ractor.make_shareable(words.to_s.dup)

        def format_name = @format_name

        def format_settings = @format_settings || {}

        def format_words = @format_words || @format_name.to_s

        private

        def refuse_settings_named_as_places!(name, settings)
          taken = settings.keys & %i[at into start]
          return if taken.empty?

          raise ArgumentError, "Format :#{name} names the setting #{taken.map(&:inspect).join(', ')}. at:, into: and " \
                               "start: are every format's. Give the setting another name."
        end
      end
    end
  end
end
