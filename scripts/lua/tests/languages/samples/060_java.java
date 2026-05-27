package demo;

import java.util.List;

public final class Widget implements AutoCloseable {
  private final String name;

  public Widget(String name) { this.name = name; }

  public static Widget create(String name) {
    return new Widget(name == null ? "default" : name);
  }

  public void render(List<String> items) {
    for (String item : items) {
      if (!item.isBlank()) System.out.println(name + ":" + item);
    }
  }

  @Override public void close() throws Exception {}
}

sealed interface Result permits Success, Failure {}
record Success(String value) implements Result {}
record Failure(Throwable error) implements Result {}

enum Mode { READ, WRITE }

@interface Route {
  String value();
}

class Controller<T extends Widget> {
  @Route("/widgets")
  public Result handle(T widget) {
    try (widget) {
      return switch (Mode.READ) {
        case READ -> new Success("read");
        case WRITE -> new Success("write");
      };
    } catch (Exception error) {
      return new Failure(error);
    }
  }
}

abstract assert boolean break byte case catch char class const continue default do double else enum extends false final finally float for goto if implements import instanceof int interface long native new null package permits private protected public record return sealed short static strictfp super switch synchronized this throw throws transient true try var void volatile while yield ;
