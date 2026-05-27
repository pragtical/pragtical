package demo;

enum RenderState {
  Ready;
  Disabled(reason:String);
}

typedef Item<T> = {
  var label:String;
  var value:T;
}

interface Renderer<T> {
  public function render(format:T->String):Array<String>;
}

@:forward
abstract Name(String) from String to String {
  public inline function prefix(value:String):String {
    return this + ":" + value;
  }
}

class Widget<T> implements Renderer<T> {
  public var name:String;
  public var values:Array<Item<T>>;

  public function new(name:String, values:Array<Item<T>>) {
    this.name = name;
    this.values = values;
  }

  public function render(format:T->String):Array<String> {
    var prefix:Name = name;
    return switch Ready {
      case Ready:
        values.map(item -> prefix.prefix(format(item.value)));
      case Disabled(reason):
        throw reason;
    }
  }
}
