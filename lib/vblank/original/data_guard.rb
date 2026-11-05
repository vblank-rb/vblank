# frozen_string_literal: true

require "open3"

module VBlank
  module Original
    # ONE STAGED FILE AS THE GUARD SEES IT: its path, how many bytes git holds for it, and its first
    # line. The bytes and the line are what is staged, not what is on disk.
    StagedFile = Data.define(:path, :size, :first_line)

    # THE CHECK THAT KEEPS THE ORIGINAL'S DATA OUT OF A PORT'S HISTORY, run by its pre-commit hook.
    #
    # None of the original's cartridge, art, maps, text or sound is the port's to give away. The
    # build reads the player's own copy and writes what it pulls out of it somewhere git ignores. But
    # a `git add -f`, a path the ignore rules do not cover yet, or a new tool writing somewhere
    # unexpected can stage one anyway, and a blob is in history for good once it is committed. This
    # is the backstop. It looks only at the staged files (added, copied, changed or renamed), and
    # refuses:
    #
    # - a file of the kinds a console's original cartridges, discs and saves are kept in, for each
    #   console the game names (ORIGINAL_FILE_KINDS: a .gbc and a .sav for the Color), whatever its
    #   case;
    # - a file of a kind the game names (its decompilation's own formats);
    # - anything inside a folder the game names. A folder is a pattern for one or more folder names:
    #   "dumps/" is a folder of that name at any depth, "/cache/" one at the top of the repository
    #   only, and "*.levels/" any folder whose name ends .levels. Case is not looked at;
    # - a file whose first line starts with the mark the game's tools stamp on what they write from
    #   the original (generated_mark:). Only the first line, so the tool that writes the mark, and
    #   its test, can name it;
    # - a file over most_bytes (512 KB unless said), which is almost always art pulled from the
    #   original. The message says how to commit it anyway, rather than guessing where it came from.
    #
    # WHAT THE GAME SUPPLIES: its consoles, and any folders, kinds and mark of its own. It names them
    # in its Rakefile (DataGuardTasks), whose task the hook runs.
    class DataGuard
      # THE KINDS OF FILE A CONSOLE'S ORIGINALS ARE KEPT IN, by the suffixes the dumping tools give
      # them: the cartridge or disc, and the save the emulator keeps beside it. Players' copies come
      # from many tools, each with its own habits, so each console has several.
      ORIGINAL_FILE_KINDS = {
        gba: %w[gba agb sav],
        gbc: %w[gb gbc cgb sgb sav],
        snes: %w[sfc smc swc fig srm],
        genesis: %w[gen md smd bin srm],
        ps1: %w[bin cue iso img mcr]
      }.freeze

      # KINDS THAT ARE ALSO EVERYDAY TEXT: a Genesis dump is often .md, and so is every Markdown file
      # a repository keeps. Such a file is a cartridge only at a cartridge's size: no Genesis cartridge
      # was smaller than 128 KB, and no README is that big.
      TEXT_KINDS_LEAST_CARTRIDGE_BYTES = { "md" => 128 * 1024 }.freeze

      # The staged size past which a file is refused.
      MOST_BYTES = 512 * 1024
      # The setting that lets one commit past the guard, for a refusal that is wrong.
      SKIP_SETTING = "SKIP_GAME_DATA_CHECK"
      # How much of a file is read for its first line.
      FIRST_LINE_BYTES = 1024
      # How git marks a submodule in its index: a commit of another repository, not a file.
      SUBMODULE_MODE = "160000"

      def initialize(consoles:, folders: [], suffixes: [], generated_mark: nil, most_bytes: MOST_BYTES)
        kinds = consoles.flat_map { |console| ORIGINAL_FILE_KINDS.fetch(Console.for(console).name) }
        @suffixes = (kinds + suffixes.map { it.delete_prefix(".") }).map(&:downcase).uniq
        @folders = folders
        @generated_mark = generated_mark
        @most_bytes = most_bytes
      end

      # What is wrong with +staged+ (StagedFile values), a message for each kind of refusal, or none.
      def refusals(staged)
        [data_files_message(staged), generated_files_message(staged), big_files_message(staged)].compact
      end

      # The files staged in the repository at +folder+, added, copied, changed or renamed, as
      # StagedFile values. A submodule is no file, and is left out.
      def self.staged_files(folder = Dir.pwd)
        raw = git(folder, "diff", "--cached", "--raw", "-z", "--no-renames", "--diff-filter=ACMRT").split("\0")
        entries = raw.each_slice(2).filter_map do |status, path|
          _old_mode, mode, _old_blob, blob, = status.delete_prefix(":").split
          [path.dup.force_encoding(Encoding::UTF_8), blob] unless mode == SUBMODULE_MODE
        end
        blob_heads(folder, entries.map(&:last)).zip(entries).map do |(size, head), (path, _blob)|
          StagedFile.new(path: path, size: size, first_line: head.lines.first.to_s.chomp)
        end
      end

      # The size and the first FIRST_LINE_BYTES of each of +blobs+, read in one git process, a blob
      # at a time, so a big file is never held whole.
      def self.blob_heads(folder, blobs)
        return [] if blobs.empty?

        Open3.popen2("git", "-C", folder.to_s, "cat-file", "--batch") do |input, output, _waiter|
          output.binmode
          input.write(blobs.map { "#{it}\n" }.join)
          input.close
          blobs.map do
            size = Integer(output.gets.split[2])
            head = output.read([size, FIRST_LINE_BYTES].min)
            IO.copy_stream(output, File::NULL, size - head.bytesize + 1) # the rest, and the newline after it
            [size, head.force_encoding(Encoding::UTF_8).scrub]
          end
        end
      end

      def self.git(folder, *arguments)
        out, error, status = Open3.capture3("git", "-C", folder.to_s, *arguments, binmode: true)
        raise ArgumentError, "git #{arguments.first} failed in #{folder}: #{error.strip}" unless status.success?

        out
      end
      private_class_method :git, :blob_heads

      private

      def data_files_message(staged)
        found = staged.select { |file| original_kind?(file) || inside_named_folder?(file.path) }
        return if found.empty?

        "These staged files look like the original game's data:\n#{file_list(found)}\n" \
          "The original's data must not go in the repository. The build reads the player's own copy. " \
          "Unstage them (git restore --staged FILE) and add their paths to .gitignore.#{skip_sentence}"
      end

      def generated_files_message(staged)
        return unless @generated_mark

        found = staged.select { |file| file.first_line.start_with?(@generated_mark) }
        return if found.empty?

        "These staged files were written from the original game by a tool:\n#{file_list(found)}\n" \
          "They hold the original's content, so they must not go in the repository. Anybody with a copy " \
          "gets them back by running the tool. Unstage them. To keep a file you changed by hand, remove the " \
          "mark from its first line."
      end

      def big_files_message(staged)
        found = staged.select { |file| file.size > @most_bytes }
        return if found.empty?

        "These staged files are more than #{@most_bytes / 1024} KB:\n#{file_list(found) { " (#{it.size} bytes)" }}\n" \
          "A file this big is usually art pulled from the original game. If it is, unstage it.#{skip_sentence}"
      end

      # Whether +file+ is of a kind an original is kept in; one of the TEXT_KINDS only at a cartridge's size.
      def original_kind?(file)
        kind = File.extname(file.path).delete_prefix(".").downcase
        return false unless @suffixes.include?(kind)

        file.size >= TEXT_KINDS_LEAST_CARTRIDGE_BYTES.fetch(kind, 0)
      end

      # Whether a folder +path+ is in matches a folder pattern the game names: anchored at the top
      # with a leading slash, at any depth without one.
      def inside_named_folder?(path)
        parts = File.dirname(path).split("/").reject { it == "." }
        @folders.any? do |folder|
          anchored = folder.start_with?("/")
          pattern = folder.delete_prefix("/").delete_suffix("/")
          length = pattern.count("/") + 1
          starts = anchored ? [0] : (0..(parts.size - length))
          starts.any? { |start| parts.size >= start + length && File.fnmatch(pattern, parts[start, length].join("/"), File::FNM_CASEFOLD) }
        end
      end

      def file_list(files) = files.map { |file| "  #{file.path}#{yield(file) if block_given?}" }.join("\n")

      def skip_sentence = " If a file must go in the repository, commit with #{SKIP_SETTING}=1."
    end
  end
end
