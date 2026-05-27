package demo

import groovy.transform.CompileStatic

trait Renderer {
  abstract String render(List<Map> items)
}

@CompileStatic
class Widget implements Renderer {
  String name = 'demo'

  String render(List<Map> items) {
    try {
      switch (items.size()) {
        case 0: return ''
        default:
          return items.findAll { it.enabled }
                      .collect { "${name}:${it.label}" }
                      .join(', ')
      }
    } finally {
      println "rendered ${name}"
    }
  }
}

def widget = new Widget(name: 'main')
assert widget.render([[enabled: true, label: 'alpha']]) == 'main:alpha'
