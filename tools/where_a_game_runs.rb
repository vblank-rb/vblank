#!/usr/bin/env ruby
# frozen_string_literal: true

# Draws the README's chart of the hardware VBlank drives on each target, from the lists in
# Console::HardwareFeatures: one bar a target, the features driven out of the target's whole list.
# It writes two pictures, light and dark, which the README shows through a <picture> so GitHub
# picks the one for the reader's theme. (One picture with a prefers-color-scheme rule inside would
# follow the computer's setting instead, which can disagree with GitHub's.)
#
#   ruby tools/where_a_game_runs.rb
#
# Run it after changing a list; a test fails until the pictures match.
require_relative "../lib/vblank"

module WhereAGameRuns
  FONT = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif"
  TITLE = "The hardware VBlank drives on each target"
  FOOTER = "Features supported out of the target's whole list. Rare add-ons are left out."

  # Layout, in pixels.
  WIDTH = 640
  PAD = 24
  TITLE_Y = 38
  FIRST_ROW_Y = 72
  ROW_STEP = 34
  NAME_WIDTH = 150
  COUNT_WIDTH = 60
  BAR_HEIGHT = 12
  FOOTER_GAP = 30
  BOTTOM_PAD = 22

  Theme = Data.define(:background, :border, :text, :muted, :track, :fill)

  # GitHub's own colours for each theme.
  THEMES = {
    "light" => Theme.new("#ffffff", "#d0d7de", "#1f2328", "#59636e", "#eaeef2", "#2f81f7"),
    "dark" => Theme.new("#0d1117", "#30363d", "#e6edf3", "#9198a1", "#21262d", "#4493f8")
  }.freeze

  module_function

  # Where the picture for +theme+ is kept.
  def path(theme) = VBlank.root.join("assets", "where-a-game-runs-#{theme}.svg")

  # The picture for +theme+ ("light" or "dark"), drawn from +targets+.
  def svg(theme, targets = VBlank::Console::HardwareFeatures::TARGETS)
    colors = THEMES.fetch(theme)
    footer_y = FIRST_ROW_Y + ((targets.size - 1) * ROW_STEP) + FOOTER_GAP
    height = footer_y + BOTTOM_PAD
    bars = targets.each_with_index.map { |target, i| bar_row(target, FIRST_ROW_Y + (i * ROW_STEP), colors) }.join
    <<~SVG
      <svg xmlns="http://www.w3.org/2000/svg" width="#{WIDTH}" height="#{height}" viewBox="0 0 #{WIDTH} #{height}" font-family="#{FONT}">
      <rect x="0.5" y="0.5" width="#{WIDTH - 1}" height="#{height - 1}" rx="12" fill="#{colors.background}" stroke="#{colors.border}"/>
      <text x="#{PAD}" y="#{TITLE_Y}" fill="#{colors.text}" font-size="15" font-weight="600">#{TITLE}</text>
      #{bars}<text x="#{PAD}" y="#{footer_y}" fill="#{colors.muted}" font-size="12">#{escape(FOOTER)}</text>
      </svg>
    SVG
  end

  def bar_row(target, y, colors)
    bar_x = PAD + NAME_WIDTH
    bar_width = WIDTH - bar_x - COUNT_WIDTH - PAD
    fill_width = (bar_width * target.driven_count.fdiv(target.feature_count)).round(1)
    bar_y = y - (BAR_HEIGHT / 2) - 4
    <<~SVG
      <text x="#{PAD}" y="#{y}" fill="#{colors.text}" font-size="14">#{escape(target.title)}</text>
      <rect x="#{bar_x}" y="#{bar_y}" width="#{bar_width}" height="#{BAR_HEIGHT}" rx="6" fill="#{colors.track}"/>
      <rect x="#{bar_x}" y="#{bar_y}" width="#{fill_width}" height="#{BAR_HEIGHT}" rx="6" fill="#{colors.fill}"/>
      <text x="#{WIDTH - PAD}" y="#{y}" fill="#{colors.muted}" font-size="14" text-anchor="end">#{target.driven_count} / #{target.feature_count}</text>
    SVG
  end

  def escape(text) = text.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")

  def readme_path = VBlank.root.join("README.md")

  # The README's words for a reader who cannot see the chart: its alt attribute, whole.
  def alt_attribute(targets = VBlank::Console::HardwareFeatures::TARGETS)
    counts = targets.map { |target| "#{target.title} #{target.driven_count} of #{target.feature_count}" }
    %(alt="How much of each target's hardware VBlank drives: #{escape(counts.join(', '))}")
  end

  # Matches the alt attribute alt_attribute writes, whatever its counts.
  ALT_ATTRIBUTE = /alt="How much of each target's hardware VBlank drives: [^"]*"/

  # +text+ (the README) with its chart's alt attribute written from the lists.
  def readme_with_alt(text)
    raise "README.md has no chart alt text to replace" unless text.match?(ALT_ATTRIBUTE)

    text.sub(ALT_ATTRIBUTE, alt_attribute)
  end

  def write_all
    THEMES.each_key do |theme|
      File.write(path(theme), svg(theme))
      puts "Wrote #{path(theme).relative_path_from(VBlank.root)}"
    end
    File.write(readme_path, readme_with_alt(File.read(readme_path)))
    puts "Wrote the chart's alt text in README.md"
    VBlank::Console::HardwareFeatures::TARGETS.each do |target|
      puts format("%-18s %3d / %-3d", target.title, target.driven_count, target.feature_count)
    end
  end
end

WhereAGameRuns.write_all if $PROGRAM_NAME == __FILE__
