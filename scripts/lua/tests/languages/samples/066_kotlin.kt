package demo

import kotlinx.coroutines.flow.Flow

sealed interface RenderState {
  data object Ready : RenderState
  data class Failed(val reason: String) : RenderState
}

data class Item(val label: String, val enabled: Boolean = true)

class Widget<T : Item>(private val name: String = "demo") {
  companion object {
    const val DefaultName = "demo"
  }

  operator fun invoke(item: T): String = "$name:${item.label}"

  fun render(items: List<T>): String {
    var state: RenderState = RenderState.Ready
    return when (state) {
      RenderState.Ready -> items.asSequence()
        .filter { it.enabled }
        .map(::invoke)
        .joinToString(", ")
      is RenderState.Failed -> error((state as RenderState.Failed).reason)
    }
  }
}

suspend fun main() {
  val widget = Widget<Item>("main")
  println(widget.render(listOf(Item("alpha"))))
}
