module Demo
  module Renderable
    def renderable? = true
  end

  class Widget
    include Renderable
    attr_reader :name

    def initialize(name = "demo")
      @name = name
    end

    def render(items)
      items.filter_map do |item|
        next unless item[:enabled]
        "#{name}:#{item.fetch(:label)}"
      end
    rescue KeyError => error
      warn error.message
    ensure
      @done = true
    end
  end
end

case Demo::Widget.new.render([{ enabled: true, label: "alpha" }])
in [String => first, *rest]
  puts first
else
  warn "empty"
end

BEGIN END __ENCODING__ __FILE__ __LINE__ alias and begin break case class def defined? do else elsif end ensure extend false for if in include module next nil not or private redo require require_dependency rescue retry return self super then true undef unless until when while yield ;
