# frozen_string_literal: true

require "json"
require_relative "near_names"

module VBlank
  module Original
    # A name the labels do not hold. The message names the labels nearest it.
    class UnknownLabel < KeyError; end

    # THE ORIGINAL'S LABELS: where each routine, table and variable sits, by the name its decompilation
    # gives it, read from a file of VBlank's own.
    #
    #   labels = VBlank::Original::Labels.read("data/labels.json")
    #   labels.offset("Music_Title")      # where its bytes are in the player's copy
    #   labels.address("wScore+1")        # where a running console has the second byte of wScore
    #   labels.span("Music_Title")        # how many bytes it runs, up to the next label
    #   labels.names_at(offset: 0x4000)   # every name for the bytes there
    #
    # The file is written once, by the port's harvest, from the symbol file the assembler wrote
    # (SymbolFile reads one of each format); it is committed, so nothing else needs the decompilation.
    #
    # TWO NUMBERS FOR ONE PLACE. A cartridge is mapped into the console's memory, so a byte of it has
    # its place in the file (the offset, which reading the copy wants) and the address the processor
    # sees it at (which a probe of a running console wants). On a console that switches banks of the
    # cartridge into one window, many offsets share an address. A cartridge label keeps both; a
    # variable in the console's RAM has only an address. Which is wanted is always asked for by name.
    #
    # The file is JSON with a label to a line, so a harvest run again shows as the lines that moved:
    #
    #   {"labels":1,"rom_bank_bytes":"0x4000", "list": [
    #   {"name":"Music_Title","space":"rom","address":"0x4000","offset":"0x4000"},
    #   {"name":"wScore","space":"ram","address":"0xc000","width":2,"size":2}
    #   ]}
    #
    # Required on its own (`require "vblank/original/labels"`), by a port's harvest and its tests: a
    # game that reads no original never loads it.
    class Labels
      include Enumerable

      # One label: its name, :rom (in the cartridge) or :ram, the address the console sees it at, its
      # offset in the copy (a cartridge label's alone), and for a variable the bytes the code reads it
      # by (width) and the bytes it takes (size), where the assembler says.
      Label = Data.define(:name, :space, :address, :offset, :width, :size) do
        def initialize(name:, space:, address:, offset: nil, width: nil, size: nil)
          super
        end
      end

      SPACES = %i[rom ram].freeze
      # The first line of a saved file, which says what it is and in which version of the format.
      FORMAT_VERSION = 1
      # A name and a number of bytes into it: `wBallStates+1`.
      NAME_AND_BYTES = /\A(.+?)\+(\d+|0x\h+)\z/

      # The labels saved at +path+: one file, or a folder of them read as one.
      def self.read(path)
        files = File.directory?(path) ? Dir.glob(File.join(path, "*.json")).sort : [path].select { File.file?(it) }
        raise ArgumentError, "There are no saved labels at #{path}. Run the port's harvest to write them." if files.empty?

        saved = files.map { read_file(it) }
        banks = saved.map(&:first).uniq
        raise ArgumentError, "The files in #{path} give different bank sizes. Run the port's harvest again." if banks.size > 1

        new(saved.flat_map(&:last), rom_bank_bytes: banks.first)
      end

      def self.read_file(path)
        saved = JSON.parse(File.read(path))
        unless saved.is_a?(Hash) && saved["labels"] == FORMAT_VERSION && saved["list"].is_a?(Array)
          raise ArgumentError, "#{path} is not a file of saved labels. Run the port's harvest again to write it."
        end

        bank = saved["rom_bank_bytes"]&.then { Integer(it) }
        [bank, saved["list"].map { label_from(it) }]
      end

      def self.label_from(row)
        Label.new(name: row.fetch("name"), space: row.fetch("space").to_sym, address: Integer(row.fetch("address")),
                  offset: row["offset"]&.then { Integer(it) }, width: row["width"], size: row["size"])
      end
      private_class_method :read_file, :label_from

      # +labels+ are Label records. +rom_bank_bytes+ is the size of the cartridge's banks on a console
      # that switches them, where a label's bytes never run past its bank's end.
      def initialize(labels, rom_bank_bytes: nil)
        @rom_bank_bytes = rom_bank_bytes
        @by_name = {}
        labels.each do |label|
          raise ArgumentError, "#{label.name} is in #{label.space.inspect}, which is not :rom or :ram." unless SPACES.include?(label.space)
          raise ArgumentError, "#{label.name} is in the cartridge and has no offset." if label.space == :rom && label.offset.nil?

          @by_name[label.name] = label
        end
        @rom = @by_name.values.select { it.space == :rom }.sort_by { [it.offset, it.name] }
        @ram = @by_name.values.select { it.space == :ram }.sort_by { [it.address, it.name] }
      end

      attr_reader :rom_bank_bytes

      def each(&) = (@rom + @ram).each(&)

      # The label named +name+, or UnknownLabel naming those nearest it.
      def fetch(name)
        @by_name.fetch(name.to_s) { raise UnknownLabel, unknown_label_message(name.to_s) }
      end

      def include?(name) = @by_name.key?(name.to_s)

      # Where +name+ is in the copy, or a number of bytes further for `name+n`.
      def offset(name)
        label, bytes = split_name(name)
        found = fetch(label)
        raise ArgumentError, "#{label} is in the console's RAM, not in the copy. Ask for its address." unless found.offset

        found.offset + bytes
      end

      # Where a running console sees +name+, or a number of bytes further for `name+n`.
      def address(name)
        label, bytes = split_name(name)
        fetch(label).address + bytes
      end

      # Every name for the place at +offset+ in the copy, or at +address+ on the console, in order of
      # name; none where nothing is named there.
      def names_at(offset: nil, address: nil)
        raise ArgumentError, "Give offset: or address:, one of them." unless offset.nil? ^ address.nil?

        found = offset ? @rom.select { it.offset == offset } : each.select { it.address == address }
        found.map(&:name).sort
      end

      # How many bytes +name+ runs: its size where the assembler gave one; otherwise up to the next
      # label of its space, and in the cartridge never past the end of its bank.
      def span(name)
        label = fetch(name)
        return label.size if label.size

        label.space == :rom ? rom_span(label) : ram_span(label)
      end

      # The labels as the saved file's text: a label to a line, in order of place.
      def saved_text
        head = { "labels" => FORMAT_VERSION }
        head["rom_bank_bytes"] = hex(@rom_bank_bytes) if @rom_bank_bytes
        rows = map { JSON.generate(saved_row(it)) }
        "#{JSON.generate(head).delete_suffix('}')}, \"list\": [\n#{rows.join(",\n")}\n]}\n"
      end

      def write(path) = File.write(path, saved_text)

      # True when the file at +path+ is not these labels as #write writes them: a harvest's check that
      # what is committed is what the symbol file says.
      def stale?(path) = !File.file?(path) || File.read(path) != saved_text

      private

      def split_name(name)
        match = name.to_s.match(NAME_AND_BYTES)
        match ? [match[1], Integer(match[2])] : [name.to_s, 0]
      end

      def rom_span(label)
        following = @rom.bsearch { it.offset > label.offset }&.offset
        bank_end = @rom_bank_bytes && (((label.offset / @rom_bank_bytes) + 1) * @rom_bank_bytes)
        ends = [following, bank_end].compact
        refuse_open_span!(label) if ends.empty?
        ends.min - label.offset
      end

      def ram_span(label)
        following = @ram.bsearch { it.address > label.address }&.address
        refuse_open_span!(label) unless following
        following - label.address
      end

      def refuse_open_span!(label)
        raise ArgumentError, "#{label.name} is the last label, so nothing tells where it ends. Give its length yourself."
      end

      def unknown_label_message(name)
        near = NearNames.among(@by_name.keys, name)
        hint = near.empty? ? "" : " Near names are: #{near.join(', ')}."
        "There is no label #{name}.#{hint} Write the name as the decompilation writes it."
      end

      def saved_row(label)
        row = { "name" => label.name, "space" => label.space.to_s, "address" => hex(label.address) }
        row["offset"] = hex(label.offset) if label.offset
        row["width"] = label.width if label.width
        row["size"] = label.size if label.size
        row
      end

      def hex(number) = format("0x%x", number)
    end
  end
end
