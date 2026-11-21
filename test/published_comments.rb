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

  private def relative_path(file) = file.delete_prefix("#{VBlank.root}/")
end
