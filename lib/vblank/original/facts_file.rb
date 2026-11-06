# frozen_string_literal: true

require "json"
require "yaml"

module VBlank
  module Original
    # ONE FACTS FILE AS TEXT: its values written by a tool, its comments by hand (see Facts).
    #
    #   FactsFile.merge(text, values)   # the file with +values+, every comment kept
    #   FactsFile.parse(text)           # its header, each key's comment, and its measured section
    #   FactsFile.uncommented(text)     # the paths of keys with no comment above them
    #
    # A file is a header (comment lines, then a blank line), then the tool's keys, each with the
    # comment lines written directly above it, then the hand-written `measured:` section to the end.
    # YAML's own reader drops comments, so this keeps them: a merge writes the values out again in one
    # layout and puts each key's comment back above it by the key's path. A key the values no longer
    # have goes with its comment, a new key comes in with none, and the measured section is copied as
    # it is.
    #
    # WHAT A MERGE DOES NOT KEEP, by design: a comment with a blank line between it and its key (a
    # comment belongs to the key right below it), and a comment inside an item of a list of mappings
    # (the list's key names what each item holds, so the items' keys carry no comments of their own).
    # A key with a capital letter in it is a label of the original's (a table keyed by the
    # decompilation's names), which is data, explained by its mapping's comment.
    module FactsFile
      MEASURED = "measured"
      INDENT = 2
      # Measured entries are a value, its source and its test; those keys need no comment.
      ENTRY_KEYS = %w[value source test].freeze
      # A key line: a plain key, or one in double quotes, then a colon.
      KEY_LINE = /\A(?:"((?:[^"\\]|\\.)*)"|([A-Za-z0-9_-]+)):/

      # What a file holds besides its values: the header's lines, each key's comment lines by its path
      # (keys joined with "."), every key's path in order, and the measured section's text.
      Parsed = Data.define(:header, :comments, :keys, :measured)

      # +text+ (the file as it stands, or "" for a new one) with +values+ (a Hash of the tool's
      # facts) written into it.
      def self.merge(text, values)
        parsed = parse(text)
        lines = parsed.header.empty? ? [] : parsed.header + [""]
        lines += format_mapping(JSON.parse(JSON.generate(values)), 0, [], parsed.comments, top: true)
        lines += [""] + parsed.measured.chomp.lines(chomp: true) unless parsed.measured.empty?
        "#{lines.join("\n")}\n"
      end

      def self.parse(text)
        lines = text.lines(chomp: true)
        leading = lines.take_while { it.start_with?("#") }
        header = [nil, ""].include?(lines[leading.size]) ? leading : []
        lines = lines.drop(header.size)
        lines.shift while lines.first == ""
        comments = {}
        keys = []
        index_keys(lines, comments, keys) do |at, pending|
          return Parsed.new(header:, comments:, keys:, measured: (pending + lines[at..]).join("\n"))
        end
        Parsed.new(header:, comments:, keys:, measured: "")
      end

      # The keys of +text+ that have no comment above them, by path: outside lists, and in the
      # measured section all but an entry's value, source and test.
      def self.uncommented(text)
        parsed = parse(text)
        missing = parsed.keys.reject { |path| parsed.comments.key?(path) || label?(path) }
        return missing if parsed.measured.empty?

        comments = {}
        keys = []
        index_keys(parsed.measured.lines(chomp: true), comments, keys, stop_at_measured: false)
        missing + keys.reject { |path| comments.key?(path) || ENTRY_KEYS.include?(path.split(".").last) }
      end

      # Each key line of +lines+ outside a list: its path into +keys+ and the comment lines just above
      # it into +comments+. At the top-level `measured:` key it yields where that is and the comment
      # lines above it, unless +stop_at_measured+ is false.
      def self.index_keys(lines, comments, keys, stop_at_measured: true)
        stack = []
        pending = []
        list_floor = nil
        lines.each_with_index do |line, at|
          stripped = line.lstrip
          indent = line.length - stripped.length
          if stripped.start_with?("#")
            pending << line
          elsif stripped.empty? || stripped.start_with?("- ")
            list_floor ||= indent if stripped.start_with?("- ")
            pending = []
          elsif (match = stripped.match(KEY_LINE))
            if list_floor && indent >= list_floor
              pending = []
              next
            end
            list_floor = nil
            key = match[1] ? JSON.parse(%("#{match[1]}")) : match[2]
            yield at, pending if stop_at_measured && indent.zero? && key == MEASURED
            stack.pop while stack.any? && stack.last[0] >= indent
            path = (stack.map(&:last) + [key]).join(".")
            keys << path
            comments[path] = pending.map(&:lstrip) unless pending.empty?
            stack << [indent, key]
            pending = []
          end
        end
      end

      def self.format_mapping(map, indent, path, comments, top: false)
        map.each_with_index.flat_map do |(key, value), n|
          key_path = path + [key.to_s]
          above = (comments[key_path.join(".")] || []).map { |comment| (" " * indent) + comment }
          (top && n.positive? ? [""] : []) + above + format_value(format_scalar(key.to_s), value, indent, key_path, comments)
        end
      end

      def self.format_value(key, value, indent, path, comments)
        pad = " " * indent
        case value
        when Hash then ["#{pad}#{key}:"] + format_mapping(value, indent + INDENT, path, comments)
        when Array
          return ["#{pad}#{key}: #{format_flow_list(value)}"] if value.none? { it.is_a?(Hash) || it.is_a?(Array) }

          ["#{pad}#{key}:"] + value.flat_map { |item| format_item(item, indent + INDENT) }
        else ["#{pad}#{key}: #{format_scalar(value)}"]
        end
      end

      # A list's item: a list of plain values on one line, a mapping with its first key after the dash.
      def self.format_item(item, indent)
        pad = " " * indent
        case item
        when Hash
          lines = format_mapping(item, indent + INDENT, [], {})
          lines[0] = "#{pad}- #{lines[0].lstrip}"
          lines
        when Array
          return ["#{pad}- #{format_flow_list(item)}"] if item.none? { it.is_a?(Hash) || it.is_a?(Array) }

          ["#{pad}-"] + item.flat_map { |inner| format_item(inner, indent + INDENT) }
        else ["#{pad}- #{format_scalar(item)}"]
        end
      end

      def self.label?(path) = path.split(".").last.match?(/[A-Z]/)

      def self.format_flow_list(values) = "[#{values.map { format_scalar(it) }.join(', ')}]"

      # A plain value as YAML reads it back the same: a string written bare where YAML reads it back
      # as that string, and in double quotes otherwise, which JSON's quoting is valid YAML for; nothing
      # as null.
      def self.format_scalar(value)
        return "null" if value.nil?
        return value.to_s unless value.is_a?(String)
        return value.to_json if value.empty? || value.match?(/[,\[\]{}#:"'\\]/) || value != value.strip

        begin
          YAML.safe_load("- #{value}").first == value ? value : value.to_json
        rescue Psych::Exception
          value.to_json
        end
      end

      private_class_method :index_keys, :format_mapping, :format_value, :format_item, :label?, :format_flow_list, :format_scalar
    end
  end
end
