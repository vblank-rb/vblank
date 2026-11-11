# frozen_string_literal: true

require "fileutils"
require "json"
require "yaml"

module VBlank
  module Original
    # WHAT A PORT KNOWS ABOUT ITS ORIGINAL, each fact written once in a YAML file and read from there:
    # a file for each part of the game, in the folders the game names.
    #
    #   FACTS = VBlank::Original::Facts.new("data/facts", "data/stages")
    #   FACTS.of(:ball, :gravity)                        # => 11
    #   FACTS.measured(:screens, :title, :white_frames)  # => 6
    #   FACTS.write(:ball, extracted)                    # a tool's new values, every comment kept
    #
    # In each file:
    #
    # - the values outside `measured:` are what the original's code and tables hold, written by the
    #   game's own tool from the player's copy (an extractor), never by hand;
    # - `measured:` is what was worked out by playing the original, written by hand: each entry a
    #   value, its source and the test that holds it to the original, nested as deep as the game likes;
    # - every key has a comment written by hand directly above it, saying what it is and where it
    #   comes from.
    #
    # WHAT THE GAME SUPPLIES: the folders, and the tool that reads its values off the copy. Every .yml
    # file in a folder is a facts file, named by its name without .yml; a name in two folders is
    # refused, since a fact must be written once. Testing#assert_facts_kept holds every file to the
    # three rules above.
    #
    # FACTS A PERSON WRITES. A port made from a decompilation has no tool: a person reads each number
    # in the original's source and writes it down. Such a game sets that:
    #
    #   FACTS = VBlank::Original::Facts.new("data/facts", written_by: :hand)
    #
    # They read the same, and Testing#assert_facts_kept holds them to the rules that fit:
    #
    # - no layout: a number stays in the base it was written in (`cue: 0x7f`, which a person checks
    #   against the source's own hex) and a list stays down the page;
    # - every top-level key but `measured:` has a comment directly above it, with no blank line
    #   between, saying what it is and where in the original it was read. A mapping's comment covers
    #   every key under it, so those need none of their own. A top-level key that is a label of the
    #   original's needs one like any other: nothing above it explains it;
    # - `measured:` is as above, a value, a source and a test for each entry. An entry's source says
    #   where it was read, so nothing in the section needs a comment, and nor does `measured:`.
    #
    # Whether a comment names where the number was read is for the person to keep: the check can
    # tell only that a comment is there. #write refuses these files, since it would write the
    # tool's layout over the person's.
    #
    # Every file is read when this is made, and what is read is frozen all the way down, so a Facts
    # in a constant is shared by every Ractor as it is. Reading is of what was read then; #write
    # changes the file, and a Facts made after it reads the new values.
    class Facts
      MEASURED = FactsFile::MEASURED.to_sym

      # Who writes the values outside `measured:`, the game's tool or a person.
      WRITERS = %i[tool hand].freeze

      # The names of the files, as symbols.
      attr_reader :files

      def initialize(*folders, written_by: :tool)
        refuse_unknown_writer!(written_by)
        @written_by = written_by
        @folders = folders.map { |folder| File.expand_path(folder) }.freeze
        found = @folders.flat_map { |folder| Dir[File.join(folder, "*.yml")] }.group_by { |path| File.basename(path, ".yml").to_sym }
        refuse_doubled_names!(found)
        @paths = found.transform_values(&:first).freeze
        @files = @paths.keys.freeze
        @loaded = @paths.transform_values { |path| YAML.safe_load_file(path, symbolize_names: true) || {} }
        Ractor.make_shareable(self)
      end

      # Whether a person writes these files' values (`written_by: :hand`), not the game's tool.
      def written_by_hand? = @written_by == :hand

      # The path of +file+.
      def path(file) = @paths.fetch(file.to_sym) { raise KeyError, "There is no facts file #{file}.yml. The files are #{files.join(', ')}." }

      # The tool's fact or facts of +file+ at +path+ (all of them for none): everything but its
      # measured section. A key in +path+ is a Symbol or String for a mapping, an Integer for a list.
      def of(file, *path) = path.empty? ? extracted(file) : fact_at(extracted(file), file, path)

      # The record of +file+ at +path+ as a +type+ (a Data class whose fields are the record's keys):
      # a key the record lacks, or one the type does not know, is an error where it is read.
      def record(type, file, *path) = type.new(**of(file, *path))

      # The list of records of +file+ at +path+, each a +type+.
      def records(type, file, *path) = of(file, *path).map { |found| type.new(**found) }

      # The value of the measured fact at +path+ in +file+'s measured section.
      def measured(file, *path)
        entry = fact_at(measured_section(file), file, [MEASURED, *path])
        raise KeyError, "#{file}.yml's measured #{path.join('.')} has no value. Give it a value, a source and a test." unless entry.is_a?(Hash) && entry.key?(:value)

        entry.fetch(:value)
      end

      # The entries of +file+'s measured section by their path ("title.white_frames"), each what the
      # file holds there: a Hash of its value, source and test, string keys, when it is written right.
      def measured_entries(file) = measured_entries_under(JSON.parse(JSON.generate(measured_section(file)[MEASURED]))).to_h

      # Write +values+ (a Hash, as the game's tool read them off the copy) into +file+, keeping every
      # comment and the measured section. A file there is not yet is made in +folder+, the first folder
      # unless set.
      def write(file, values, folder: @folders.first)
        refuse_write_over_hand_written!(file)
        target = @paths.fetch(file.to_sym) { File.join(File.expand_path(folder), "#{file}.yml") }
        FileUtils.mkdir_p(File.dirname(target))
        File.write(target, FactsFile.merge(File.exist?(target) ? File.read(target) : "", values))
      end

      # Whether +file+, as it is on disk now, is laid out as #write would write its own values: a file
      # edited by hand is not.
      def kept?(file)
        text = File.read(path(file))
        values = (YAML.safe_load(text) || {}).except(FactsFile::MEASURED)
        FactsFile.merge(text, values) == text
      end

      # The paths of +file+'s keys that have no comment above them and need one: every key of a
      # tool's file, the top-level keys of a person's.
      def uncommented(file)
        text = File.read(path(file))
        written_by_hand? ? FactsFile.uncommented_top_level(text) : FactsFile.uncommented(text)
      end

      private

      def refuse_unknown_writer!(written_by)
        return if WRITERS.include?(written_by)

        raise ArgumentError, "written_by: #{written_by.inspect} is not known. Write written_by: :hand for facts a person writes, " \
                             "or leave it out for facts a tool writes."
      end

      def refuse_write_over_hand_written!(file)
        return unless written_by_hand?

        raise ArgumentError, "#{file}.yml is written by hand (written_by: :hand), and a write would put the tool's layout over it. " \
                             "Change the file in an editor."
      end

      def refuse_doubled_names!(found)
        doubled = found.values.select { |paths| paths.size > 1 }
        return if doubled.empty?

        raise ArgumentError, "Two facts files have one name: #{doubled.map { it.join(' and ') }.join('; ')}. " \
                             "A file is read by its name, so give each a name of its own."
      end

      def loaded(file) = @loaded.fetch(file.to_sym) { path(file) }

      def extracted(file) = loaded(file).except(MEASURED)

      # The measured section of +file+, under its key, empty when it has none.
      def measured_section(file) = { MEASURED => loaded(file)[MEASURED] || {} }

      def fact_at(facts, file, path)
        found = path.reduce(facts) do |inner, key|
          case inner
          when Hash then inner[key.is_a?(String) ? key.to_sym : key]
          when Array then key.is_a?(Integer) ? inner[key] : nil
          end
        end
        raise KeyError, "#{file}.yml has nothing at #{path.join('.')}. Check the name of each key." if found.nil?

        found
      end

      # Each entry of a measured section, by its path of keys: a Hash with a value, a source or a test
      # is an entry, any other Hash holds more.
      def measured_entries_under(facts, path = [])
        return [[path.join("."), facts]] if facts.keys.intersect?(FactsFile::ENTRY_KEYS)

        facts.flat_map { |key, inner| inner.is_a?(Hash) ? measured_entries_under(inner, path + [key]) : [[(path + [key]).join("."), inner]] }
      end
    end
  end
end
