sealed class RenderState {
  const RenderState();
}
class Ready extends RenderState {
  const Ready();
}
class Disabled extends RenderState {
  final String reason;
  const Disabled(this.reason);
}

mixin Timestamped {
  DateTime get createdAt => DateTime.now();
}

class Widget<T> {
  final String name;
  final List<T> values;
  final RenderState state;

  const Widget(this.name, this.values, {this.state = const Ready()});

  Iterable<String> render(String Function(T value) format) sync* {
    switch (state) {
      case Disabled(reason: final reason):
        throw StateError(reason);
      case Ready():
        break;
    }
    for (final value in values) {
      yield '$name:${format(value)}';
    }
  }
}

Future<void> main() async {
  final widget = Widget<int>('demo', [1, 2, 3]);
  await Future<void>.delayed(Duration.zero);
  print(widget.render((value) => value.toString()).join(','));
}
