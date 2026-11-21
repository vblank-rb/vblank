# frozen_string_literal: true

require "prism"

# EVERY VERB A GAME CAN WRITE, worked out from what is mixed into Builder right now, for the tests
# that hold something to every verb: the DSL reference (test_dsl_reference.rb), each console's
# answer for every verb (test_answers.rb) and the doc comment on every verb
# (test_verb_doc_comments.rb).
#
# A public method of a concern module is a verb unless its `def` line carries RDoc's `# :nodoc:`.
# That is the one mark: RDoc leaves the method out of the reference the website is generated from,
# and this list leaves it out of the verbs. The methods marked are hooks that handles and the build
# call, public only so they can; the comment above each says whose hook it is.
module DslVerbs
  # The DSL verbs are the public methods the concern modules mix into Builder…
  CONCERNS = VBlank::Builder.included_modules.select { |m| m.name&.start_with?("VBlank::Builder::") }.freeze

  # …plus these verbs defined on Builder itself (the rest of its public methods are
  # framework: program, finalize_program, record_*, the Condition bookkeeping).
  BUILDER_VERBS = %i[list entry].freeze

  # Where a verb is written: its file, the line of its `def`, the comment lines directly above it
  # (without their `#`), and whether its `def` line carries `# :nodoc:`.
  Definition = Data.define(:name, :file, :line, :comment, :nodoc)

  # …plus the verbs the loaded effect packs contribute. A pack's verb is an ordinary
  # DSL verb at the call site, so it has to be looked up in the same place.
  def dsl_verbs
    dsl_verb_candidates.reject { |name, owners| owners.any? { |owner| DslVerbs.definition_of(owner, name)&.nodoc } }
                       .keys.sort
  end

  # Each verb with where it is written, or nil for one not written with `def`.
  def dsl_verb_definitions
    owners = dsl_verb_candidates
    dsl_verbs.to_h do |name|
      [name, owners.fetch(name).filter_map { |owner| DslVerbs.definition_of(owner, name) }.first]
    end
  end

  # The `def` of +name+ as +owner+ (a module) has it, or nil where it is not written with `def`
  # (a method made by `define_method` or `attr_reader`).
  def self.definition_of(owner, name)
    file, near_line = owner.instance_method(name).source_location
    return nil unless file

    parsed = parsed_file(file)
    directed = comment_with_method_directive(parsed, name)
    return Definition.new(name: name, file: file, line: directed.first, comment: directed.last, nodoc: false) if directed

    node = parsed.defs.select { |d| d.name == name }.min_by { |d| (d.location.start_line - near_line).abs }
    return nil unless node

    Definition.new(name: name, file: file, line: node.location.start_line,
                   comment: comment_above(parsed, node), nodoc: nodoc_marked?(parsed, node))
  end

  # A verb made from source text or by `alias` has no `def` to carry its comment. RDoc takes a
  # comment that opens with `# :method: name` as that method's documentation, and so does this:
  # [line of the directive, the comment lines after it], or nil where the file has none for +name+.
  def self.comment_with_method_directive(parsed, name)
    opener = parsed.comments.find { |comment| comment.slice.match?(/\A#\s*:method:\s*#{Regexp.escape(name.to_s)}\s*\z/) }
    return nil unless opener

    by_line = parsed.comments.to_h { |comment| [comment.location.start_line, comment] }
    start = opener.location.start_line
    lines = []
    line = start + 1
    while (comment = by_line[line])
      lines << comment.slice.sub(/\A# ?/, "")
      line += 1
    end
    [start, lines]
  end

  ParsedFile = Data.define(:lines, :comments, :defs, :root)

  # One parse of a file per Ractor, since a test asks about hundreds of verbs in a few dozen files.
  def self.parsed_file(file)
    cache = (Ractor.current[:dsl_verbs_parsed_files] ||= {})
    cache[file] ||= begin
      result = Prism.parse_file(file)
      defs = []
      collect_defs(result.value, defs)
      ParsedFile.new(lines: File.readlines(file), comments: result.comments, defs: defs, root: result.value)
    end
  end

  def self.collect_defs(node, defs)
    defs << node if node.is_a?(Prism::DefNode) && node.receiver.nil?
    node.compact_child_nodes.each { |child| collect_defs(child, defs) }
  end

  # The comment on the `def` line, in its signature (up to the `=` of an endless def, the closing
  # parenthesis or the last parameter), which is where RDoc reads `# :nodoc:`.
  def self.nodoc_marked?(parsed, node)
    signature_end = (node.equal_loc || node.rparen_loc || node.parameters&.location || node.name_loc).end_line
    parsed.comments.any? do |comment|
      comment.location.start_line.between?(node.location.start_line, signature_end) &&
        comment.slice.match?(/\A#\s*:nodoc:/)
    end
  end

  # The comment above each `module` and `class` written in +file+, as [name, line of the keyword,
  # comment lines], for the comments that become a group's page introduction.
  def self.container_comments(file)
    parsed = parsed_file(file)
    found = []
    collect_containers(parsed.root, found)
    found.map { |node| [node.constant_path.slice, node.location.start_line, comment_above(parsed, node)] }
  end

  def self.collect_containers(node, found)
    found << node if node.is_a?(Prism::ModuleNode) || node.is_a?(Prism::ClassNode)
    node.compact_child_nodes.each { |child| collect_containers(child, found) }
  end

  # The comment lines directly above the `def`: each a whole line of its own and none blank between.
  def self.comment_above(parsed, node)
    by_line = parsed.comments.to_h { |comment| [comment.location.start_line, comment] }
    lines = []
    line = node.location.start_line - 1
    while (comment = by_line[line]) && parsed.lines[line - 1].lstrip.start_with?("#")
      lines.unshift(comment.slice.sub(/\A# ?/, ""))
      line -= 1
    end
    lines
  end

  # Each candidate name with the modules that define it.
  private def dsl_verb_candidates
    candidates = Hash.new { |hash, name| hash[name] = [] }
    CONCERNS.each { |mod| mod.public_instance_methods(false).each { |name| candidates[name] << mod } }
    BUILDER_VERBS.each { |name| candidates[name] << VBlank::Builder }
    VBlank::Effects.verbs.each do |name, pack|
      candidates[name] << pack if pack.is_a?(Module)
      candidates[name] # an inline verb has no `def` to mark
    end
    candidates
  end
end
