# frozen_string_literal: true

require "json"

# THE EXAMPLE EXCHANGES (docs/network/exchanges.json) PLAYED AGAINST ANYTHING THAT TAKES AND GIVES
# TEXT, as a relay does. Each implementation has its own copy of this player in its own language and
# reads the same file, so a relay in Ruby, one in JavaScript and the real one are held to one thing.
#
# The relay is given as +connect+, which makes one machine's link: something that answers
# send_text(text), receive_text (the next text for the machine, or nil) and close.
module NetworkExchanges
  PATH = VBlank.root.join("docs/network/exchanges.json").to_s

  def self.all = JSON.parse(File.read(PATH)).fetch("exchanges")

  # Plays +exchange+ on a relay and returns a list of what went wrong, empty when all was as written.
  def self.play(exchange, &connect)
    links = Hash.new { |hash, name| hash[name] = yield }
    learned = {}
    problems = []
    exchange.fetch("steps").each_with_index do |step, index|
      act(step, links, learned)
      problems.concat(compare(step, links, learned).map { |problem| "#{exchange['name']}, step #{index + 1}: #{problem}" })
    end
    problems
  end

  def self.act(step, links, learned)
    link = links[step.fetch("client")]
    return link.close if step["closes"]

    text = step.key?("sends_text") ? step["sends_text"] : JSON.generate(fill(step.fetch("sends"), learned))
    link.send_text(text)
  end

  # What every client was handed, against what the step says each should have got.
  def self.compare(step, links, learned)
    got = links.flat_map do |name, link|
      texts = []
      texts << link.receive_text while link.pending?
      texts.map { |text| [name, JSON.parse(text)] }
    end
    expected = step.fetch("gets")
    problems = []
    problems << "got #{got.size} messages, expected #{expected.size}: #{got.inspect}" if got.size != expected.size
    expected.zip(got).each do |want, have|
      next unless have

      problems << "#{want['client']} was to get #{want['message'].inspect} and #{have.first} got #{have.last.inspect}" unless matches?(want, have, learned)
    end
    problems
  end

  def self.matches?(want, have, learned)
    name, message = have
    return false unless name == want.fetch("client")

    want.fetch("message").all? { |field, value| same?(value, message[field], learned) }
  end

  # A $name is learned the first time it is met, and has to be the same after. What is inside an object or a list is
  # held to the same rule: an object matches when every field it names does, a list when it is as long and each entry does.
  def self.same?(wanted, found, learned)
    case wanted
    when Hash then found.is_a?(Hash) && wanted.all? { |field, value| same?(value, found[field], learned) }
    when Array then found.is_a?(Array) && found.size == wanted.size && wanted.zip(found).all? { |want, have| same?(want, have, learned) }
    when String then wanted.start_with?("$") ? learn(wanted, found, learned) : wanted == found
    else wanted == found
    end
  end

  def self.learn(name, found, learned)
    return learned[name] == found if learned.key?(name)

    learned[name] = found
    true
  end

  def self.fill(value, learned)
    case value
    when String then value.start_with?("$") ? learned.fetch(value) : value
    when Array then value.map { |each| fill(each, learned) }
    when Hash then value.transform_values { |each| fill(each, learned) }
    else value
    end
  end
end
