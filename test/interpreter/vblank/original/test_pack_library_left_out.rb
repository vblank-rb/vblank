# frozen_string_literal: true

require "test_helper"
require "made_up_original"
require "prism"
require "set"
require "tmpdir"

# The paths of every file read through File's or IO's own readers while reading is switched on for
# this Ractor, on any of its threads (a routine may be played on a thread of its own). Prepended
# once, for the process; in any other Ractor it only passes the call on. Written out as source, not
# made from a block: a method made from a block cannot be called from another Ractor, and every
# test's File.read goes through this one.
module ReadPathsRecorded
  RECORDED_METHODS = %i[read binread readlines foreach open new].freeze

  def self.recording
    Ractor.current[:read_paths_recorded] = Set.new
    yield
    Ractor.current[:read_paths_recorded]
  ensure
    Ractor.current[:read_paths_recorded] = nil
  end

  RECORDED_METHODS.each do |name|
    module_eval <<~READER, __FILE__, __LINE__ + 1
      def #{name}(path = nil, *rest, **options, &block)
        recorded = Ractor.current[:read_paths_recorded]
        recorded << File.expand_path(path.to_s) if recorded && (path.is_a?(String) || path.is_a?(Pathname))
        super(path, *rest, **options, &block)
      end
    READER
  end
end

# THE CONSTANTS A FILE NAMES, each with the scopes it is named in, and whether it is named inside a
# method or block that ran (one starting on a line of +ran_lines+; with nil, every one counts). The
# full name of a scope is worked out from the modules loaded, so `module Backends` inside
# `module IR` is "VBlank::IR::Backends".
#
# Looking a name up (::resolve) follows Ruby's order closely enough to over-reach rather than miss:
# the scopes it is written in, innermost first, then the ancestors of the innermost, then the top.
class ConstantsNamed < Prism::Visitor
  # +called+ is the method called on it where the constant is a call's receiver (`SPUTables.rules`).
  Named = Data.define(:nesting, :parts, :ran, :called)

  attr_reader :named

  def initialize(ran_lines)
    super()
    @ran_lines = ran_lines
    @nesting = []
    @inside_ran = 0
    @named = []
    @receivers = {}.compare_by_identity
  end

  def self.module_named(name)
    Object.const_get(name)
  rescue NameError
    nil
  end

  # [the module holding it, its name] for the constant +parts+ named in +nesting+, or nil.
  def self.resolve(nesting, parts)
    first, *rest = parts
    owner = first.nil? ? Object : lexical_owner(nesting, first)
    first, *rest = rest if first.nil?
    return unless owner

    rest.each do |part|
      value = owner.const_get(first, false)
      return unless value.is_a?(Module) && value.const_defined?(part, false)

      owner = value
      first = part
    end
    [owner, first]
  rescue NameError
    nil
  end

  def self.lexical_owner(nesting, name)
    scopes = nesting.reverse.filter_map { |scope| module_named(scope) }.grep(Module)
    scopes.find { |scope| scope.const_defined?(name, false) } ||
      scopes.first&.ancestors&.find { |ancestor| ancestor.const_defined?(name, false) } ||
      (Object if Object.const_defined?(name, false))
  end

  def self.path_parts(node)
    case node
    when Prism::ConstantReadNode then [node.name]
    when Prism::ConstantPathNode
      return [nil, node.name] if node.parent.nil?

      head = path_parts(node.parent)
      head && [*head, node.name]
    end
  end

  # The full name of the class or module +path+ opens inside +nesting+.
  def self.scope_name(nesting, path)
    parts = path_parts(path)
    return parts.drop(1).join("::") if parts.first.nil?

    found = parts.size > 1 && resolve(nesting, parts[0..-2])
    return [nesting.last, *parts].compact.join("::") unless found

    owner, name = found
    [owner == Object ? name : "#{owner.name}::#{name}", parts.last].join("::")
  end

  def visit_module_node(node) = within(node) { visit(node.body) if node.body }

  def visit_class_node(node)
    visit(node.superclass) if node.superclass
    within(node) { visit(node.body) if node.body }
  end

  def visit_def_node(node) = ran_body(node) { super }
  def visit_block_node(node) = ran_body(node) { super }
  def visit_lambda_node(node) = ran_body(node) { super }
  def visit_constant_write_node(node) = ran_body(node) { super }

  def visit_call_node(node)
    @receivers[node.receiver] = node.name if node.receiver
    super
  end

  def visit_constant_read_node(node)
    @named << Named.new(nesting: @nesting.dup, parts: [node.name], ran: ran?, called: @receivers[node])
  end

  def visit_constant_path_node(node)
    parts = ConstantsNamed.path_parts(node)
    return super unless parts

    @named << Named.new(nesting: @nesting.dup, parts: parts, ran: ran?, called: @receivers[node])
  end

  private

  def ran? = @ran_lines.nil? || @inside_ran.positive?

  def ran_body(node)
    ran = @ran_lines&.include?(node.location.start_line)
    @inside_ran += 1 if ran
    yield
  ensure
    @inside_ran -= 1 if ran
  end

  def within(node)
    @nesting.push(ConstantsNamed.scope_name(@nesting, node.constant_path))
    yield
  ensure
    @nesting.pop
  end
end

# WHAT A FILE PUTS IN EACH CLASS AND MODULE IT OPENS, as it loads: the methods it defines there
# ("name", or "self.name" for the module's own), and every other statement (an include, a prepend,
# a registration), which changes the module whatever calls it. A class, module or constant inside
# one is a thing of its own, not something put in it. Statements at the top of the file are
# under "".
class PutInModules < Prism::Visitor
  NAMESPACE_ONLY = [Prism::ModuleNode, Prism::ClassNode, Prism::ConstantWriteNode].freeze
  Statement = Data.define(:line, :node)

  # By the full name of the module: each method name defined there, with its line.
  attr_reader :methods

  # By the full name of the module ("" for the top of the file): every other statement.
  attr_reader :statements

  # The full name of every class and module it opens, a namespace or not.
  attr_reader :opened

  def initialize
    super()
    @nesting = []
    @methods = Hash.new { |names, scope| names[scope] = {} }
    @statements = Hash.new { |list, scope| list[scope] = [] }
    @opened = Set.new
  end

  # The full names of the modules it puts anything in.
  def filled = [*@methods.keys, *@statements.keys].reject(&:empty?)

  def visit_program_node(node)
    note(node.statements.body)
    super
  end

  def visit_module_node(node) = within(node) { visit(node.body) if node.body }
  def visit_class_node(node) = within(node) { visit(node.body) if node.body }

  private

  def within(node)
    @nesting.push(ConstantsNamed.scope_name(@nesting, node.constant_path))
    @opened << @nesting.last
    note(node.body.is_a?(Prism::StatementsNode) ? node.body.body : [])
    yield
  ensure
    @nesting.pop
  end

  def note(statements, singleton: false)
    scope = @nesting.last.to_s
    statements.each do |statement|
      case statement
      when *NAMESPACE_ONLY then next
      when Prism::DefNode
        own = singleton || statement.receiver.is_a?(Prism::SelfNode)
        @methods[scope][own ? "self.#{statement.name}" : statement.name.to_s] = statement.location.start_line
      when Prism::SingletonClassNode
        note(statement.body.is_a?(Prism::StatementsNode) ? statement.body.body : [], singleton: true) if statement.expression.is_a?(Prism::SelfNode)
      when Prism::CallNode
        next if statement.receiver.nil? && %i[require require_relative].include?(statement.name)
        next note_visibility(statement, singleton) if statement.receiver.nil? && VISIBILITY.include?(statement.name)

        @statements[scope] << Statement.new(line: statement.location.start_line, node: statement)
      else
        @statements[scope] << Statement.new(line: statement.location.start_line, node: statement)
      end
    end
  end

  # `private`, alone or around a method (`private def x`), which changes only this file's methods.
  VISIBILITY = %i[private public protected module_function].freeze

  def note_visibility(call, singleton)
    note(call.arguments&.arguments&.grep(Prism::DefNode) || [], singleton: singleton)
  end
end

# WHAT THE PACK CACHE'S KEY LEAVES OUT IS NEVER WHAT A PACK IS MADE WITH. The key digests VBlank's
# library but the files PackLibrary::LEFT_OUT names, so a commit to those leaves a port's kept pack
# hitting. That is right only if no unpacking is built or played with them, and this is the check.
# Made-up routines are built and played every way a build plays one (the interpreter, the game as C,
# the game as Ruby, the pack cache a part at a time), and no left-out file may have:
#
# - run (TracePoint), or been read as a file (a runtime's source is read, not loaded);
# - defined a value a file that ran names anywhere in it, or a value that value is made from: Ruby
#   says which methods ran but not which constants they read, and a table read from a file whose
#   code never runs is still what the pack is made of;
# - put code in a class or module that a method or block that ran names (PS1::SPUTables named in
#   the computer's sound tables, say), though that code did not run for these routines.
#
# And no left-out file may replace a method of, or put a statement in, a class or module the rest of
# the library opens, since that runs as theirs whoever calls it.
#
# What this cannot see is a method called on an object whose class nothing that ran names, in code
# no made-up routine reaches. A new kind of routine (a format, a slot kind) belongs in
# #play_every_way.
class TestPackLibraryLeftOut < Minitest::Test
  include MadeUpOriginal

  # It prepends File's and IO's readers for the whole process, and traces every thread of the
  # Ractor it plays in.
  runs_on_the_main_ractor!

  PackCache = VBlank::Original::PackCache
  PackLibrary = VBlank::Original::PackLibrary
  LIB = VBlank.root.join("lib").to_s

  # The made-up port's routine of two packed blocks, as one routine and as three parts, the last
  # reading what the first wrote.
  private def routines(folder)
    whole = unpacked_pack(VBlank::Builder.new, folder).unpacking
    parted = VBlank::Builder.new.data_pack(from: original(folder), version: "1") do |slots|
      slots.tiles :walls, count: 2
      slots.numbers :heights, count: HEIGHTS.length, width: :byte, signed: false
      slots.numbers :sums, count: 8, width: :byte, signed: false
      slots.fill_from_copy(:walls) { |copy, into| copy.unpack_lz77 at: LZ77_AT, into: into[:walls] }
      slots.fill_from_copy(:heights) { |copy, into| copy.unpack_rle at: RLE_AT, into: into[:heights] }
      slots.fill_from_copy(:sums) { |_copy, into| repeat(8) { |i| into[:sums][i] = into[:walls][i] + 1 } }
    end
    [whole, parted]
  end

  # Builds and plays the routines every way, each step handed to +watched+ as a lambda it calls,
  # which records what the step reads. The pack cache's own reading (the library, to digest it) is
  # not a step: that is the key, not what the pack is made with.
  private def play_every_way(folder, watched)
    whole, parted = watched.call(-> { routines(folder) })
    frames = whole.most_frames
    watched.call(-> { whole.run_on(Reference.new, frames: frames, max_steps: whole.most_steps_a_frame) })
    watched.call(-> { whole.run_as_ruby(frames: frames) })
    watched.call(-> { whole.run_as_c(frames: frames) })
    watched.call(-> { whole.write_pack_fastest(File.join(folder, "whole.pack"), sha1: SHA1, build_version: "1") })
    cache = PackCache.new(File.join(folder, "packs"))
    cache.pack(parted.unpacking, sha1: SHA1, build_version: "1", parts: parted.unpacking_parts) do |path, playing, _names|
      watched.call(-> { playing.write_pack_fastest(path, sha1: SHA1, build_version: "1") })
    end
    cache.slot_bytes(parted.unpacking) { |playing, _names| watched.call(-> { playing.slot_bytes_in(playing.run_fastest) }) }
  end

  # The lines each method and block of the library that ran starts on, by file, and the files read.
  private def ran_and_read
    ran = Hash.new { |lines, path| lines[path] = Set.new }
    read = Set.new
    File.singleton_class.prepend(ReadPathsRecorded) unless File.singleton_class.include?(ReadPathsRecorded)
    IO.singleton_class.prepend(ReadPathsRecorded) unless IO.singleton_class.include?(ReadPathsRecorded)
    trace = TracePoint.new(:call, :b_call) { |point| ran[point.path] << point.lineno if point.path.start_with?(LIB) }
    watched = lambda do |step|
      made = nil
      read.merge(ReadPathsRecorded.recording { made = step.call })
      made
    end
    # Enabled without a block, which would trace this thread alone: a routine may play on another.
    trace.enable
    begin
      Dir.mktmpdir { |folder| play_every_way(folder, watched) }
    ensure
      trace.disable
    end
    [ran, read.select { |path| path.start_with?(LIB) }]
  end

  # What every file of the library puts in the modules it opens, by path.
  private def put_in_modules
    Dir.glob(File.join(LIB, "**", "*.rb")).to_h do |path|
      visitor = PutInModules.new
      Prism.parse_file(path).value.accept(visitor)
      [path, visitor]
    end
  end

  # What the left-out files put in each module, by its full name: the method names, and whether
  # anything else; and every module a kept file opens.
  LeftOutCode = Data.define(:methods, :statements, :opened_by_kept)

  private def left_out_code
    methods = Hash.new { |names, scope| names[scope] = Set.new }
    statements = Set.new
    opened_by_kept = Set.new
    put_in_modules.each do |path, visitor|
      next opened_by_kept.merge(visitor.opened) unless left_out?(path)

      visitor.methods.each { |scope, names| methods[scope].merge(names.keys) }
      statements.merge(visitor.statements.keys)
    end
    LeftOutCode.new(methods: methods, statements: statements, opened_by_kept: opened_by_kept)
  end

  # Whether +named+, naming the module +value+ defined at +defined_at+, can reach left-out code:
  # the module is defined in a left-out file and no kept file opens it, or a left-out file put a
  # statement in it, or put in it the method called on it (`SPUTables.rules`), or any method where
  # it is not called on but handed on (made, included, passed).
  private def reaches_left_out_code?(named, value, defined_at, code)
    return true if defined_at && left_out?(defined_at) && !code.opened_by_kept.include?(value.name)
    return true if code.statements.include?(value.name)

    methods = code.methods.fetch(value.name, Set.new)
    named.called ? methods.include?("self.#{named.called}") : methods.any?
  end

  # Code that walks every module under the one it names, left-out ones too, by file. Each is here
  # because what it finds lands in the program a routine is built as, which the key holds whole:
  # the method names of every VBlank module decide which calls in a game's block may run game code
  # (DSL::PlainRuby::CallChanges.known_method_names), and so how the block is read into the program.
  READS_EVERY_MODULE = { "vblank/dsl/plain_ruby_call_changes.rb" => "VBlank" }.freeze

  # Files that ran whose classes and modules count only where named in a method or block that ran.
  # Everywhere else a class or module a file that ran names anywhere, defined only in left-out
  # files, is refused, though the code naming it did not run for these routines: that is how
  # Diagnostics::DrawnSprite, named by the interpreter where a sprite is drawn, is held KEPT. These
  # files name left-out classes for work that is no unpacking's, or whose result lands in the
  # program the key holds whole.
  READ_BY_METHOD = {
    "vblank/console/kit.rb" => "the parts that serve each console, named and never run",
    "vblank/builder.rb" => "raw instructions (`entry`), assembled into the program",
    "vblank/builder/scenes.rb" => "a tape's presses, read into the program",
    "vblank/testing.rb" => "a game's tests asking whether the emulator is there"
  }.freeze

  # Whether +path+ is inside a LEFT_OUT entry, KEPT or not.
  private def inside_left_out_entry?(path) = PackLibrary.new(kept: []).left_out?(path)

  # Where the code that ran names something left out, each as "what: why it is reached". Every
  # value a file that ran names anywhere in it is followed to where it is set, and what that names in
  # turn. A class or module named in a method or block that ran is checked for left-out code. One
  # defined in a file KEPT inside a left-out folder that never ran is then read as a file that ran,
  # since the routine reaches it by name, so what it reaches from its folder must be KEPT too.
  private def left_out_named(ran)
    code = left_out_code
    found = []
    seen = Set.new
    waiting = ran.map { |path, lines| [path, lines, true] }
    until waiting.empty?
      path, lines, whole_file = waiting.shift
      named = ConstantsNamed.new(lines)
      Prism.parse_file(path).value.accept(named)
      named.named.each do |each|
        owner, name = ConstantsNamed.resolve(each.nesting, each.parts)
        next unless owner && (each.ran || whole_file)

        value = owner.const_get(name, false)
        defined_at, line = owner.const_source_location(name.to_s)
        why = "#{each.parts.compact.join('::')}, named by #{place(path)}"
        if value.is_a?(Module)
          next unless value.name

          if each.ran
            next if READS_EVERY_MODULE[place(path)] == value.name

            found << "#{value.name}: #{why}" if reaches_left_out_code?(each, value, defined_at, code)
          else
            next if READ_BY_METHOD.key?(place(path))

            found << "#{value.name}: #{why}, defined only in a left-out file" if defined_at && left_out?(defined_at) && !code.opened_by_kept.include?(value.name)
          end
          next unless defined_at && inside_left_out_entry?(defined_at) && !ran.key?(defined_at) && seen.add?(defined_at)

          waiting << [defined_at, nil, true]
        elsif defined_at&.start_with?(LIB) && seen.add?([defined_at, line])
          found << "#{place(defined_at)}:#{line}: #{why}" if left_out?(defined_at)
          waiting << [defined_at, Set[line], false]
        end
      end
    end
    found.uniq
  end

  private def place(path) = path.delete_prefix("#{LIB}/")

  private def left_out?(path) = PackLibrary.new.left_out?(path)

  def test_nothing_left_out_runs_is_read_or_is_named_while_a_pack_is_made
    skip_on_this_machine "zig is not installed, so a routine cannot be played as C" unless VBlank::IR::Backends::Native::Zig.installed?

    ran, read = ran_and_read

    assert_empty ran.keys.select { |path| left_out?(path) }.map { |path| place(path) }, "left out of the key, and ran"
    assert_empty read.select { |path| left_out?(path) }.map { |path| place(path) }, "left out of the key, and read"
    assert_empty left_out_named(ran), "left out of the key, and named by code that ran"
  end

  # The full names of the VBlank classes and modules +node+ names, looked up from the top.
  private def vblank_modules_named(node)
    named = ConstantsNamed.new(nil)
    node.accept(named)
    named.named.filter_map do |each|
      owner, name = ConstantsNamed.resolve(each.nesting, each.parts)
      value = owner&.const_get(name, false)
      value.name if value.is_a?(Module) && value.name&.start_with?("VBlank")
    end
  end

  # A left-out file loads all the same, so what it puts into a class or module the rest of the
  # library opens runs as theirs: a method of the same name replaces theirs, and a statement in its
  # body (an include, a prepend) changes it. A method of its own is a name nothing kept calls, which
  # the test above would see run. At the top of a file, a statement is refused where it names a kept
  # VBlank class or module (`VBlank::Builder.prepend(...)`); one that changes only minitest or Ruby's
  # warnings is left alone.
  def test_a_left_out_file_changes_nothing_the_rest_of_the_library_opens
    kept, left = put_in_modules.partition { |path, _| !left_out?(path) }
    kept_methods = Hash.new { |names, scope| names[scope] = Set.new }
    kept.each { |_, visitor| visitor.methods.each { |scope, names| kept_methods[scope].merge(names.keys) } }
    kept_modules = kept.flat_map { |_, visitor| visitor.filled }.to_set
    changes = left.flat_map do |path, visitor|
      replaced = visitor.methods.flat_map do |scope, names|
        names.filter_map { |name, line| "#{place(path)}:#{line} replaces #{scope}##{name}" if kept_methods[scope].include?(name) }
      end
      statements = visitor.statements.flat_map do |scope, list|
        list.filter_map do |statement|
          changed = scope.empty? ? (vblank_modules_named(statement.node) & kept_modules.to_a).first : (scope if kept_modules.include?(scope))
          "#{place(path)}:#{statement.line} changes #{changed} as it loads" if changed
        end
      end
      replaced + statements
    end

    assert_empty changes, "a left-out file changes what the key covers"
  end
end
