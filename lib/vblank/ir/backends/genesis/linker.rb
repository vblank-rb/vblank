# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        # WHERE EVERYTHING GOES IN THE CARTRIDGE, and the holes the assembler left filled in.
        #
        # A Genesis cartridge is one flat run of bytes the 68000 reads at addresses 0 to $3FFFFF: no
        # banks, no mapper, nothing to switch. The first 512 bytes are the vectors and the header
        # (Cartridge::GenesisROM writes them), so the sections go one after the other from $200, in the
        # order they came, each starting at an even address (an assembler's section ends on one). A
        # call or a jump to any place in the cartridge is a long address, and a branch inside a
        # section is a signed 16-bit distance, so what is placed where only matters to the distance a
        # branch can reach.
        class Linker
          ORIGIN = Console::GenesisHardware::CODE_AT
          MOST_BYTES = Console::GenesisHardware::CARTRIDGE_END - ORIGIN

          # Where each label went: its address in the processor's view. +image+ is the sections' bytes
          # from $200 on, with every hole filled in.
          Linked = Data.define(:image, :places, :sections) do
            def address_of(label) = places.fetch(label.to_s)
          end

          class Error < StandardError; end

          # Raised when the GAME is more than the cartridge has room for. It names the game's parts by
          # what they are, never by the sections they went in.
          class TooBig < LoweringError; end

          # Where one section went: the address of its first byte.
          Placed = Data.define(:section, :address)

          DOES_NOT_FIT = "This game does not fit in a Genesis cartridge."

          def initialize(sections)
            @sections = sections
          end

          def link
            placed = place_sections
            places = label_places(placed)
            Linked.new(image: fill(placed, places), places: places, sections: placed.to_h { |one| [one.section.name, one] })
          end

          private

          def place_sections
            total = @sections.sum(&:size)
            refuse_too_big!(total) if total > MOST_BYTES
            address = ORIGIN
            @sections.map do |section|
              Placed.new(section: section, address: address).tap { address += section.size }
            end
          end

          def refuse_too_big!(total)
            if @sections.none?(&:holds)
              raise Error, "the framework's own code needs #{total} bytes, more than the #{MOST_BYTES} a cartridge holds"
            end

            raise TooBig, "#{DOES_NOT_FIT} A cartridge holds #{MOST_BYTES} bytes after its header. Of what goes " \
                          "in it, #{Sections.taken_words(@sections)}. To fix this, #{Sections.biggest(@sections).fix}."
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
            image = "\0".b * (placed.sum { |one| one.section.size })
            placed.each do |one|
              bytes = one.section.bytes.dup
              one.section.fixups.each { |fixup| patch(bytes, fixup, one, places) }
              image[one.address - ORIGIN, bytes.bytesize] = bytes
            end
            image
          end

          def patch(bytes, fixup, placed, places)
            target = places.fetch(fixup.label) do
              raise Error, "#{placed.section.name} names #{fixup.label}, which no section defines"
            end
            target += fixup.plus
            case fixup.kind
            when :abs32 then bytes[fixup.offset, 4] = [target].pack("N")
            when :abs16 then bytes[fixup.offset, 2] = [short_address(target, fixup, placed)].pack("n")
            when :rel16 then bytes[fixup.offset, 2] = [distance(target, fixup, placed)].pack("n")
            when :rel8 then bytes.setbyte(fixup.offset + 1, near_distance(target, fixup, placed))
            else raise Error, "unknown fixup #{fixup.kind}"
            end
          end

          # A near branch's distance is counted from the word after it and is one signed byte, in the
          # low byte of the instruction. Nought there means a long branch, whose distance follows, so
          # a near branch cannot go to the instruction after it.
          def near_distance(target, fixup, placed)
            far = target - (placed.address + fixup.offset + 2)
            unless far.between?(-128, 127) && !far.zero?
              raise Error, "#{placed.section.name}: a near branch to #{fixup.label} is #{far} bytes away, and it reaches " \
                           "-128 to 127 and not 0"
            end

            far & 0xFF
          end

          # A 16-bit address is taken as signed and widened, so it reaches the first 32K of addresses
          # and the last 32K (the top half of work RAM).
          def short_address(target, fixup, placed)
            return target & 0xFFFF if target.between?(0, 0x7FFF) || target.between?(0xFF8000, 0xFFFFFF)

            raise Error, "#{placed.section.name} names #{fixup.label} with a 16-bit address, which does not reach it"
          end

          # A distance is counted from the word the hole is in, as the 68000 counts it, and is one
          # signed word.
          def distance(target, fixup, placed)
            far = target - (placed.address + fixup.offset)
            unless far.between?(-32_768, 32_767)
              raise Error, "#{placed.section.name}: a branch to #{fixup.label} is #{far} bytes away, more than 32767"
            end

            far & 0xFFFF
          end
        end
      end
    end
  end
end
