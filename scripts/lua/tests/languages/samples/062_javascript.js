import { readFileSync as read } from "node:fs";

export class Widget extends HTMLElement {
  #secret = Symbol("secret");
  static defaults = { enabled: true, count: 0 };

  static {
    this.registry = new Map();
  }

  constructor(name = "demo") {
    super();
    this.name = name;
  }

  get label() { return this.name; }
  set label(value) { this.name = value?.trim() || "demo"; }

  async render(items = []) {
    const escaped = items.map((item) => `${item.id}:${item.label ?? "none"}`);
    const matcher = /item-(\d+)[a-z]*/gi;
    for (const value of escaped) {
      if (matcher.test(value)) console.log(value);
    }
    return <section class="card">{escaped.join(", ")}</section>;
  }
}

try {
  await new Widget("main").render([{ id: 1, label: "alpha" }]);
} catch (error) {
  throw error;
} finally {
  void undefined;
}

switch (typeof Widget) {
  case "function":
    debugger;
    break;
  default:
    delete Widget.registry;
}

function* ids(items) {
  yield* items.map(({ id }) => id);
}

Infinity NaN arguments async await break case catch class const continue debugger default delete do else export extends false finally for from function get if import in instanceof let new null of return set static super switch this throw true try typeof undefined var void while with yield ;
