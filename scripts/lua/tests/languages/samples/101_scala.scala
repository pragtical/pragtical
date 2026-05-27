package demo

final case class Item(label: String, enabled: Boolean = true)

trait Renderer:
  def render(items: List[Item]): String

final class Widget(name: String = "demo") extends Renderer:
  override def render(items: List[Item]): String =
    items.filter(_.enabled).map(item => s"$name:${item.label}").mkString(", ")
