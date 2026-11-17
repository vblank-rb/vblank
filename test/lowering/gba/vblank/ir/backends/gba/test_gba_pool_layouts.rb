# frozen_string_literal: true

require "test_helper"

# A POOL KEPT EACH WAY THE ADVANCE CAN KEEP ONE (Backends::PoolLayout): as lists, as tables side by
# side, as a record for each thing, its walks stepped with a register on the thing
# (GBA::Statements#emit_stepped_walk). The Advance's run plays games on the interpreter, so this reads
# the cartridge in the emulator: the game does its work in its first twenty passes and then idles, so
# the cartridge and the interpreter hold the same numbers however their frames line up, and every
# field of every pool and the game's own numbers are compared.
class TestGBAPoolLayouts < Minitest::Test
  # Things of mixed widths that move, meet, are removed and spawned again, walked both ways, with a
  # routine checking each against the others and finding itself among them; a pool removed from only
  # between walks, one removed inside its own walk, and one spawned into during its own walk; fields
  # moved on by numbers that cross a byte and the sign.
  def self.game(layout)
    VBlank.build("LAYOUT #{layout}", console: :gba, out: nil, err: nil) do
      screen :tiled
      image(:dot, "#" => :white) { (["#" * 8] * 8).join("\n") }
      sprite :dot, at: [8, 8]
      things = pool :thing, x: 0, y: 0, dx: 0, hits: 0, drift: 0, rise: 0, capacity: 6,
                            widths: { y: :half, dx: :byte, hits: :byte, rise: :half }, layout: layout
      sparks = pool :spark, x: 0, age: 0, capacity: 5, widths: { age: :byte }, layout: layout
      seeds = pool :seed, x: 0, age: 0, capacity: 6, widths: { age: :byte }, layout: layout
      fired = var :fired, 0
      total = var :total, 0
      oldest = var :oldest, 0
      step = var :step, 0
      things.func(:step) do |e|
        e.x += e.dx
        things.each do |other|
          e.hits += 1 if other.index != e.index && (other.x - e.x).abs < 12 && (other.y - e.y).abs < 40
        end
        things.each do |other|
          other.dx = 0 - other.dx if other.index == e.index && other.hits > 20 && other.hits < 23
        end
      end
      game_loop do
        step += 1
        if step <= 20
          fired += 1
          things.spawn(x: (fired * 53) % 180, y: (fired * 7) % 60, dx: (fired % 5) - 2)
          sparks.spawn(x: fired, age: 0)
          seeds.spawn(x: fired, age: 0) if fired % 3 == 0
          things.each do |t|
            call :step
            t.drift -= 3
            t.rise += 200
            t.remove if t.x > 200 || t.x < -20 || t.hits > 30
          end
          things.each(newest_first: true) { |t| oldest = t.index }
          things.remove_at(oldest) if things.count > 4
          total = 0
          sparks.each do |s|
            s.age += 1
            sparks.each { |other| other.remove if other.age > 2 && other.index != s.index }
            total += s.x
          end
          seeds.each do |s|
            s.age += 1
            seeds.spawn(x: s.x + 1, age: 0) if s.age == 2
            seeds.each { |other| total += other.x }
          end
          seeds.each { |s| s.remove if s.age > 4 }
        end
      end
    end
  end

  FIELDS = { thing: %i[x y dx hits drift rise], spark: %i[x age], seed: %i[x age] }.freeze

  def test_a_pool_kept_as_lists_holds_what_the_interpreter_holds = assert_cartridge_holds_interpreters(:lists)
  def test_a_pool_kept_as_tables_holds_what_the_interpreter_holds = assert_cartridge_holds_interpreters(:tables)
  def test_a_pool_kept_as_records_holds_what_the_interpreter_holds = assert_cartridge_holds_interpreters(:records)

  private def assert_cartridge_holds_interpreters(layout)
    built = self.class.game(layout)
    want = VBlank::IR::Backends::Reference.new.run(built.source_program, frames: 60)
    got = VBlank::Diagnostics::Verifier.new(built, frames: 60, vars: built.var_addresses)

    %i[fired total oldest].each { |name| assert_equal want[name], got.var(name), name }
    FIELDS.each do |pool, fields|
      fields.each { |field| assert_equal want.pool(pool, field), got.pool(pool, field), "#{pool}.#{field}" }
    end
  end
end
