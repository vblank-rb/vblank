# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        # WHERE EVERYTHING GOES IN RAM, and the holes the assembler left filled in.
        #
        # A PlayStation program is loaded whole into main RAM before it starts, so there are no banks
        # and nothing to switch: the sections go one after the other from where the PS-X EXE is loaded
        # (+origin+: after what the game keeps, Memory#program_at), in the order they came, each a whole
        # number of words. A branch reaches 32K instructions either way, and a jump (J, JAL) any place
        # in the same 256 megabytes, which is all of RAM, so what is placed where only matters to a
        # branch.
        class Linker
          # Where a program with nothing kept before it is loaded.
          ORIGIN = Console::PS1Hardware::EXE_AT

          Linked = Data.define(:image, :places, :sections) do
            def address_of(label) = places.fetch(label.to_s)
          end

          class Error < StandardError; end

          # Raised when the GAME is more than RAM has room for. It names the game's parts by what they
          # are, never by the sections they went in.
          class TooBig < LoweringError; end

          Placed = Data.define(:section, :address)

          DOES_NOT_FIT = "This game does not fit in the PlayStation's memory."

          # +origin+ is where the program is loaded, and +room+ how many bytes it may take from there:
          # the rest of RAM is the stack's, and below +origin+ what the game keeps, +kept+ bytes of it.
          def initialize(sections, origin: ORIGIN, room: Console::PS1Hardware::PROGRAM_END - origin, kept: 0)
            @sections = sections
            @origin = origin
            @room = room
            @kept = kept
          end

          def link
            placed = place_sections
            places = label_places(placed)
            Linked.new(image: fill(placed, places), places: places, sections: placed.to_h { |one| [one.section.name, one] })
          end

          private

          def place_sections
            total = @sections.sum(&:size)
            refuse_too_big!(total) if total > @room
            address = @origin
            @sections.map do |section|
              Placed.new(section: section, address: address).tap { address += section.size }
            end
          end

          # The program and what the game keeps share the room, so the words give both, and by how
          # much the two together pass it. The fix named is for whichever of the two is bigger.
          def refuse_too_big!(total)
            if @sections.none?(&:holds)
              raise Error, "the framework's own code needs #{total} bytes, more than the #{@room} the program has"
            end

            shared = @room + @kept
            fix = if @kept > total
                    "give the game's lists smaller capacities, or use fewer variables"
                  else
                    Sections.biggest(@sections).fix
                  end
            raise TooBig, "#{DOES_NOT_FIT} What the game keeps in memory (its variables and lists) takes #{@kept} bytes, " \
                          "and its program takes #{total} bytes. The two share #{shared} bytes, so that is " \
                          "#{total + @kept - shared} bytes too many. Of what goes in the program, " \
                          "#{Sections.taken_words(@sections)}. To fix this, #{fix}."
          end

          def label_places(placed)
            placed.each_with_object({}) do |one, places|
              one.section.labels.each do |label, offset|
                raise Error, "label #{label} is defined twice" if places.key?(label)

                places[label] = one.address + offset
              end
            end
          end

          def fill(placed, places)
            image = "\0".b * placed.sum { |one| one.section.size }
            placed.each do |one|
              bytes = one.section.bytes.dup
              one.section.fixups.each { |fixup| patch(bytes, fixup, one, places) }
              image[one.address - @origin, bytes.bytesize] = bytes
            end
            image
          end

          def patch(bytes, fixup, placed, places)
            target = places.fetch(fixup.label) do
              raise Error, "#{placed.section.name} names #{fixup.label}, which no section defines"
            end
            target += fixup.plus
            at = placed.address + fixup.offset
            case fixup.kind
            when :abs32 then bytes[fixup.offset, 4] = [target].pack("V")
            when :branch16 then fill_field(bytes, fixup.offset, branch_distance(target, at, fixup, placed), 0xFFFF)
            when :jump26 then fill_field(bytes, fixup.offset, jump_field(target, at, fixup, placed), 0x3FF_FFFF)
            when :hi16 then fill_field(bytes, fixup.offset, target >> 16, 0xFFFF)
            when :lo16 then fill_field(bytes, fixup.offset, target & 0xFFFF, 0xFFFF)
            else raise Error, "unknown fixup #{fixup.kind}"
            end
          end

          def fill_field(bytes, offset, value, mask)
            word = bytes.byteslice(offset, 4).unpack1("V")
            bytes[offset, 4] = [(word & ~mask & 0xFFFF_FFFF) | (value & mask)].pack("V")
          end

          # Counted in instructions from the one after the branch (its delay slot), as the R3000 counts it.
          def branch_distance(target, at, fixup, placed)
            far = (target - (at + 4)) / 4
            unless far.between?(-0x8000, 0x7FFF)
              raise Error, "#{placed.section.name}: a branch to #{fixup.label} is #{far} instructions away, more than 32767"
            end

            far
          end

          def jump_field(target, at, fixup, placed)
            unless (target & 0xF000_0000) == ((at + 4) & 0xF000_0000)
              raise Error, "#{placed.section.name}: #{fixup.label} is outside the 256 megabytes a jump reaches"
            end

            (target >> 2) & 0x3FF_FFFF
          end
        end
      end
    end
  end
end
