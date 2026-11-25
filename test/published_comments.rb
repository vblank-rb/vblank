# frozen_string_literal: true

require "dsl_verbs"

# The comments the website publishes, found where a build finds what they describe: each verb's doc
# comment, the comment on each group of verbs, and each check's class comment. Each comes as
# ["Name (file:line", comment lines], the label a failing test prints.
#
# `include PublishedComments` beside `include DslVerbs` in a test of doc comments.
module PublishedComments
  # Every check a build can run: every class in Guardrails::Checks (the always-on ones, the build
  # checks run after lowering, and those the builder or a backend runs itself) and every check an
  # effect pack brings.
  def self.check_classes
    checks = VBlank::IR::Guardrails::Checks
    in_module = checks.constants.map { |name| checks.const_get(name) }
                      .select { |value| value.is_a?(Class) && value.method_defined?(:detect) }
    from_packs = VBlank::Effects::DEFAULT_PACKS.flat_map { |pack| pack.respond_to?(:checks) ? Array(pack.checks) : [] }
    (in_module + (VBlank::IR::Guardrails.default_checks + from_packs).map(&:class)).uniq.sort_by(&:name)
  end

  # The files whose class and module comments introduce a group of verbs.
  GROUP_FILES = Ractor.make_shareable(
    (Dir.glob(VBlank.root.join("lib/vblank/builder/*.rb").to_s) + [VBlank.root.join("lib/vblank/builder.rb").to_s] +
     Dir.glob(VBlank.root.join("lib/vblank/effects/packs/*.rb").to_s)).sort
  )

  # The class comment of +klass+, empty when it has none.
  private def check_comment(klass)
    file, line = Object.const_source_location(klass.name)
    found = DslVerbs.container_comments(file).find { |_, at, _| at == line }
    ["#{klass.name.split('::').last} (#{relative_path(file)}:#{line}", found ? found.last : []]
  end

  private def verb_comments
    dsl_verb_definitions.filter_map do |verb, definition|
      ["#{verb} (#{relative_path(definition.file)}", definition.comment] if definition
    end
  end

  private def group_comments
    GROUP_FILES.flat_map do |file|
      DslVerbs.container_comments(file).map { |name, line, lines| ["#{name} (#{relative_path(file)}:#{line}", lines] }
    end
  end

  # The files whose classes are the handles a game holds: what a verb hands back, and what those
  # are made of.
  HANDLE_FILES = Ractor.make_shareable(Dir.glob(VBlank.root.join("lib/vblank/dsl/*.rb").to_s).sort)

  # One class, module or `Data.define` constant written in a handle file: its whole name, where it
  # is written, the comment above it and whether its line carries `# :nodoc:`.
  HandleDefinition = Data.define(:name, :file, :line, :comment, :nodoc)

  # A handle: a class or module in lib/vblank/dsl that RDoc publishes, so not marked `# :nodoc:`
  # and not inside something that is. One written in several places (reopened, or a `Data.define`
  # given methods by a `class` below it) is one handle, its page the first comment found.
  Handle = Data.define(:name, :file, :line, :comment)

  # Every handle, by name.
  def self.handles
    definitions = HANDLE_FILES.flat_map { |file| handle_definitions(file) }
    hidden = definitions.select(&:nodoc).map(&:name)
    shown = definitions.reject { |found| hidden.any? { |name| found.name == name || found.name.start_with?("#{name}::") } }
    shown.group_by(&:name).map do |name, places|
      page = places.find { |place| !place.comment.empty? } || places.first
      Handle.new(name: name, file: page.file, line: page.line, comment: page.comment)
    end.sort_by(&:name)
  end

  # The classes, modules and `Data.define` constants written in +file+, inside VBlank::DSL.
  def self.handle_definitions(file)
    parsed = DslVerbs.parsed_file(file)
    found = []
    collect_handle_definitions(parsed, file, parsed.root, [], found)
    found.select { |definition| definition.name.start_with?("VBlank::DSL::") }
  end

  def self.collect_handle_definitions(parsed, file, node, nesting, found)
    name = handle_name(node)
    if name
      full = (nesting + [name]).join("::")
      found << HandleDefinition.new(name: full, file: file, line: node.location.start_line,
                                    comment: DslVerbs.comment_above(parsed, node), nodoc: line_nodoc?(parsed, node))
      nesting += [name] unless node.is_a?(Prism::ConstantWriteNode)
    end
    node.compact_child_nodes.each { |child| collect_handle_definitions(parsed, file, child, nesting, found) }
  end

  # The name a `class`, a `module` or a `Name = Data.define(...)` gives, or nil for any other node.
  def self.handle_name(node)
    case node
    when Prism::ClassNode, Prism::ModuleNode then node.constant_path.slice
    when Prism::ConstantWriteNode then node.name.to_s if data_define?(node.value)
    end
  end

  def self.data_define?(node)
    node.is_a?(Prism::CallNode) && node.name == :define && node.receiver.is_a?(Prism::ConstantReadNode) &&
      node.receiver.name == :Data
  end

  # Whether the first line of +node+ (its `class` or `def` line) carries RDoc's `# :nodoc:`.
  def self.line_nodoc?(parsed, node)
    parsed.comments.any? do |comment|
      comment.location.start_line == node.location.start_line && comment.slice.match?(/\A#\s*:nodoc:/)
    end
  end

  # The public methods a game can call on +handle+, as [label, comment lines] for those RDoc
  # publishes: written with `def` (or `def self.`), or by `attr_reader` and its siblings, and not
  # marked `# :nodoc:`. A method with no `def` to carry a comment (made by `define_method`) comes
  # with nil for its comment, so a test can say so.
  def self.handle_methods(handle)
    klass = Object.const_get(handle.name)
    instance = klass.public_instance_methods(false).map { |name| [name, klass.instance_method(name), false] }
    singleton = klass.singleton_methods(false).map { |name| [name, klass.method(name), true] }
    (instance + singleton).filter_map do |name, method, on_class|
      file, = method.source_location
      next unless file&.start_with?(VBlank.root.join("lib/vblank/dsl/").to_s)

      found = method_comment(file, name, on_class, method.source_location.last)
      next if %i[nodoc alias].include?(found)

      label = "#{handle.name.delete_prefix('VBlank::DSL::')}#{on_class ? '.' : '#'}#{name}"
      ["#{label} (#{file.delete_prefix("#{VBlank.root}/")}:#{method.source_location.last}", found]
    end.sort_by(&:first)
  end

  # The comment lines above the method +name+ in +file+, :nodoc: where it is marked, or nil where
  # no `def` or `attr_*` line writes it.
  def self.method_comment(file, name, on_class, near_line)
    parsed = DslVerbs.parsed_file(file)
    directed = DslVerbs.comment_with_method_directive(parsed, name)
    return directed.last if directed

    # A module's method made with `module_function` is written as a plain `def`.
    candidates = method_nodes(parsed, on_class).select { |candidate| writes_method?(candidate, name) }
    candidates = method_nodes(parsed, false).select { |candidate| writes_method?(candidate, name) } if candidates.empty? && on_class
    node = candidates.min_by { |candidate| (candidate.location.start_line - near_line).abs }
    # RDoc publishes an `alias` as the method it names, so the comment to read is that one's.
    return :alias if !node && alias_written?(parsed.root, name)
    return nil unless node
    return :nodoc if node.is_a?(Prism::DefNode) ? DslVerbs.nodoc_marked?(parsed, node) : line_nodoc?(parsed, node)

    DslVerbs.comment_above(parsed, node)
  end

  ATTRIBUTE_CALLS = %i[attr_reader attr_accessor attr_writer].freeze

  # The `def` nodes (on the class itself when +on_class+) and `attr_*` calls in +parsed+.
  def self.method_nodes(parsed, on_class)
    cache = (Ractor.current[:published_comments_method_nodes] ||= {})
    cache[[parsed.root.object_id, on_class]] ||= begin
      found = []
      collect_method_nodes(parsed.root, on_class, found)
      found
    end
  end

  def self.collect_method_nodes(node, on_class, found)
    case node
    when Prism::DefNode
      found << node if node.receiver.is_a?(Prism::SelfNode) == on_class
    when Prism::CallNode
      found << node if !on_class && node.receiver.nil? && ATTRIBUTE_CALLS.include?(node.name)
    end
    node.compact_child_nodes.each { |child| collect_method_nodes(child, on_class, found) }
  end

  def self.alias_written?(node, name)
    return true if node.is_a?(Prism::AliasMethodNode) && node.new_name.slice.delete_prefix(":").to_sym == name

    node.compact_child_nodes.any? { |child| alias_written?(child, name) }
  end

  def self.writes_method?(node, name)
    return node.name == name if node.is_a?(Prism::DefNode)

    attribute = name.to_s.delete_suffix("=").to_sym
    Array(node.arguments&.arguments).any? { |argument| argument.is_a?(Prism::SymbolNode) && argument.unescaped.to_sym == attribute }
  end

  # Each handle's page and each of its methods, as [label, comment lines], for the checks every
  # published comment is held to. A method with no comment to read is left out here.
  private def handle_comments
    PublishedComments.handles.flat_map do |handle|
      page = ["#{handle.name.delete_prefix('VBlank::DSL::')} (#{relative_path(handle.file)}:#{handle.line}", handle.comment]
      [page] + PublishedComments.handle_methods(handle).select(&:last)
    end
  end

  private def relative_path(file) = file.delete_prefix("#{VBlank.root}/")
end
