# frozen_string_literal: true

require "test_helper"
require "net/http"
require "stringio"
require "tmpdir"

# `vblank preview`: the game as a page served on this computer, built again from its file each
# time the page is asked for, so an edit shows on the next reload — and a build that stops says
# why in the page instead.
class TestJSPreview < Minitest::Test
  Preview = VBlank::IR::Backends::JS::Preview

  private def game_source(title, color)
    <<~RUBY
      VBlank.game #{title.inspect}, consoles: %i[gba] do
        screen :bitmap
        game_loop { clear_screen #{color.inspect} }
      end
    RUBY
  end

  # Serves +file+ for the length of the block, which is handed a way to fetch the page.
  private def serving(file, settings: [], template: nil, console: nil, out: StringIO.new)
    preview = Preview.new(file, settings: settings, template: template, console: console, port: 0, out: out)
    server = Thread.new { preview.serve }
    yield -> { Net::HTTP.get_response(URI(preview.url)) }
  ensure
    preview&.stop
    server&.join(5)
  end

  # `vblank run --browser` is the page, and `vblank preview` the same thing by its older name.
  def test_run_with_browser_serves_the_page_that_preview_does
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "game.rb"), game_source("BROWSER", :blue))
      [%w[run game.rb --browser --port 8765], %w[preview game.rb --port 8765]].each do |command|
        said, waiting = spawn_and_read_first_line(command, dir)
        assert_match(%r{Playing game\.rb at http://127\.0\.0\.1:8765/}, said)
        assert_match(/<title>BROWSER<\/title>/, Net::HTTP.get(URI("http://127.0.0.1:8765/")).force_encoding(Encoding::UTF_8))
      ensure
        stop_process(waiting)
      end
    end
  end

  # Started in a process group of its own, so what it starts is stopped with it.
  private def spawn_and_read_first_line(command, dir)
    reader, writer = IO.pipe
    pid = spawn(RbConfig.ruby, VBlank.root.join("bin", "vblank").to_s, *command, chdir: dir, out: writer, err: writer, pgroup: true)
    writer.close
    [reader.gets.to_s, pid]
  end

  private def stop_process(pid)
    return unless pid

    Process.kill("KILL", -pid)
    Process.wait(pid)
  end

  def test_a_reload_plays_the_game_as_its_file_says_now
    Dir.mktmpdir do |dir|
      file = File.join(dir, "game.rb")
      File.write(file, game_source("FIRST", :blue))
      serving(file) do |fetch|
        first = fetch.call
        assert_equal "200", first.code
        assert_match(/<title>FIRST<\/title>/, first.body.force_encoding(Encoding::UTF_8))

        File.write(file, game_source("SECOND", :red))
        assert_match(/<title>SECOND<\/title>/, fetch.call.body.force_encoding(Encoding::UTF_8))
      end
    end
  end

  # A game for two consoles is previewed as the one asked for: here the Color, whose screen the
  # page's canvas is the size of.
  def test_the_page_plays_the_game_as_the_console_asked_for
    Dir.mktmpdir do |dir|
      file = File.join(dir, "game.rb")
      File.write(file, game_source("BOTH", :blue).sub("%i[gba]", "%i[gba gbc]"))
      serving(file, console: "gbc") do |fetch|
        assert_match(/<canvas id="screen" width="160" height="144"/, fetch.call.body.force_encoding(Encoding::UTF_8))
      end
    end
  end

  # Every setting reaches the build, not only the last: the game below has no default for either,
  # so a build missing one stops.
  def test_every_setting_reaches_the_build
    Dir.mktmpdir do |dir|
      file = File.join(dir, "game.rb")
      File.write(file, <<~RUBY)
        VBlank.game "SETTINGS", consoles: %i[gba] do
          screen :bitmap
          setting :first
          setting :second
          game_loop { clear_screen :black }
        end
      RUBY
      serving(file, settings: %w[first=1 second=2]) do |fetch|
        page = fetch.call.body.force_encoding(Encoding::UTF_8)

        refute_match(/did not build/, page)
        assert_match(/<title>SETTINGS<\/title>/, page)
      end
    end
  end

  # A page template given to the preview is the one every reload is written from.
  def test_the_template_given_writes_every_page
    Dir.mktmpdir do |dir|
      file = File.join(dir, "game.rb")
      File.write(file, game_source("TEMPLATED", :blue))
      template = File.join(dir, "mine.html.erb")
      File.write(template, "<!doctype html>\n<h1>Mine: <%= title %></h1>\n<%= game %>\n")
      serving(file, template: template) do |fetch|
        assert_match(/<h1>Mine: TEMPLATED<\/h1>/, fetch.call.body.force_encoding(Encoding::UTF_8))
      end
    end
  end

  def test_a_build_that_stops_says_why_in_the_page
    Dir.mktmpdir do |dir|
      file = File.join(dir, "game.rb")
      File.write(file, "VBlank.game \"BROKEN\", consoles: %i[gba] do\n  screen :bitmap\n  game_loop { clear_screen :no_such_color }\nend\n")
      said = StringIO.new
      serving(file, out: said) do |fetch|
        page = fetch.call.body.force_encoding(Encoding::UTF_8)

        assert_match(/The game did not build/, page)
        assert_match(/no_such_color/, page)
        refute_match(/\r|\e/, page, "a line redrawn in place would be noise in the page")
        assert_match(/no_such_color/, said.string, "the terminal is told as well")
      end
    end
  end

  # A page takes as long as the game takes to build, and a browser tab spinning over a silent
  # terminal looks like a hang. This game cannot finish building until the test lets it, so the
  # words can only have reached the terminal while the build was going.
  def test_the_terminal_is_told_a_build_has_begun_while_it_runs
    Dir.mktmpdir do |dir|
      file = File.join(dir, "game.rb")
      go_on = File.join(dir, "go_on")
      File.write(file, "sleep 0.01 until File.exist?(#{go_on.inspect})\n#{game_source('SLOW', :blue)}")
      said = StringIO.new
      serving(file, out: said) do |fetch|
        page = Thread.new { fetch.call }
        begin
          wait_until { said.string.include?("Building game.rb") }
          refute_includes said.string, "Built game.rb"
        ensure
          File.write(go_on, "") # whatever happened, the build it started must not wait for ever
        end
        assert_match(/<title>SLOW<\/title>/, page.value.body.force_encoding(Encoding::UTF_8))
      end
      assert_match(/Building game\.rb\n.*the guardrails.*\nBuilt game\.rb\n/m, said.string, "the build's progress comes between the two")
      refute_includes said.string, "vblank-preview", "the folder a page is built in is nobody's business"
    end
  end

  private def wait_until
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
    sleep 0.01 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    assert yield, "it did not happen in time"
  end
end
