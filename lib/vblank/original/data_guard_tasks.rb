# frozen_string_literal: true

require "fileutils"
require "open3"
require "rake"
require "rake/tasklib"
require_relative "../console"
require_relative "data_guard"

module VBlank
  module Original
    # A PORT'S RAKE TASKS FOR ITS PRE-COMMIT DATA GUARD (DataGuard). In the game's Rakefile:
    #
    #   require "vblank/original/data_guard_tasks"
    #
    #   VBlank::Original::DataGuardTasks.new do |t|
    #     t.consoles = %i[gbc]                       # the consoles the game is for
    #     t.folders = %w[dumps/ /cache/ *.levels/]   # folders that hold the original's data
    #     t.suffixes = %w[chr]                       # kinds of file its tools write
    #     t.generated_mark = "# rocket: written from the original"  # what its tools stamp on line one
    #   end
    #
    # That defines two tasks:
    #
    #   rake data_guard:check     refuse the staged files the guard refuses; the hook runs this
    #   rake data_guard:install   point git at the repository's hooks folder (.githooks) and make its
    #                             pre-commit hook run the check
    #
    # Install keeps a pre-commit hook the game already has, with its own checks, and puts the one
    # line that runs this check after its first line (#!/bin/sh). A hook that runs it already is left
    # alone. A game moving from a data check of its own takes that check out of the hook by hand,
    # since install cannot tell which lines it was. Each clone runs install once, since git does not
    # take its hooks from the repository by itself. A repository whose hooks are in another folder
    # already (core.hooksPath) is refused, rather than having those hooks stop without a word.
    #
    # SKIP_GAME_DATA_CHECK=1 git commit ... goes past the guard, for a refusal that is wrong.
    class DataGuardTasks < Rake::TaskLib
      HOOKS_FOLDER = ".githooks"
      # The line install puts in the pre-commit hook.
      HOOK_LINE = "bundle exec rake data_guard:check || exit 1"
      NEW_HOOK = "#!/bin/sh\n# Refuse a commit that stages the original game's data (VBlank::Original::DataGuard).\n#{HOOK_LINE}\n".freeze

      attr_accessor :consoles, :folders, :suffixes, :generated_mark, :most_bytes

      def initialize
        super
        @consoles = nil
        @folders = []
        @suffixes = []
        @generated_mark = nil
        @most_bytes = DataGuard::MOST_BYTES
        yield self if block_given?
        define_tasks
      end

      # The guard's refusals of what is staged in the repository at +folder+, each a message: none
      # when SKIP_GAME_DATA_CHECK is set in +env+.
      def staged_refusals(folder = Dir.pwd, env: ENV)
        return [] unless env[DataGuard::SKIP_SETTING].to_s.empty?

        configured_guard.refusals(DataGuard.staged_files(folder))
      end

      # Point the repository at +folder+ at its hooks folder, and make that folder's pre-commit hook
      # run the check. The path of the hook.
      def install(folder = Dir.pwd)
        refuse_other_hooks_folder!(folder)
        hooks = File.join(folder, HOOKS_FOLDER)
        FileUtils.mkdir_p(hooks)
        hook = File.join(hooks, "pre-commit")
        File.write(hook, hook_with_check(File.exist?(hook) ? File.read(hook) : ""))
        File.chmod(0o755, hook)
        system("git", "-C", folder.to_s, "config", "core.hooksPath", HOOKS_FOLDER, exception: true)
        hook
      end

      private

      def configured_guard
        raise ArgumentError, "The data guard names no consoles. Set t.consoles in the Rakefile, as the game names them." if consoles.nil?

        DataGuard.new(consoles: consoles, folders: folders, suffixes: suffixes, generated_mark: generated_mark,
                      most_bytes: most_bytes)
      end

      def refuse_other_hooks_folder!(folder)
        named, = Open3.capture2("git", "-C", folder.to_s, "config", "--local", "core.hooksPath")
        named = named.strip
        return if named.empty? || named == HOOKS_FOLDER

        raise ArgumentError, "This repository runs its hooks from #{named}. If install points git at #{HOOKS_FOLDER}, " \
                             "those hooks stop. Add the line \"#{HOOK_LINE}\" to #{named}/pre-commit instead."
      end

      # The pre-commit hook +text+ with the check's line in it: after the #! line of a hook there
      # already, at its top when it has none, or a hook of its own when there is no hook.
      def hook_with_check(text)
        return NEW_HOOK if text.strip.empty?
        return text if text.include?(HOOK_LINE)
        return "#!/bin/sh\n#{HOOK_LINE}\n#{text}" unless text.start_with?("#!")

        first, rest = text.split("\n", 2)
        "#{first}\n#{HOOK_LINE}\n#{rest}"
      end

      def define_tasks
        namespace :data_guard do
          desc "Refuse a commit that stages the original game's data"
          task(:check) do
            refusals = staged_refusals
            refusals.each { |refusal| warn("pre-commit: #{refusal}") }
            exit(1) unless refusals.empty?
          end

          desc "Make this clone's pre-commit hook refuse the original game's data"
          task(:install) { puts "The pre-commit hook #{install} now runs rake data_guard:check." }
        end
      end
    end
  end
end
