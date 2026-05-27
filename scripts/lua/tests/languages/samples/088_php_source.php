<?php
namespace Demo;

final class Widget {
  public function __construct(private string $name = "demo") {}

  public function render(array $items): string {
    $out = [];
    foreach ($items as $item) {
      if (($item["enabled"] ?? false) === true) {
        $out[] = "{$this->name}:{$item['label']}";
      }
    }
    return implode(", ", $out);
  }
}

echo (new Widget())->render([["enabled" => true, "label" => "alpha"]]);
?>

<?php
trait Timestamped {
  public function touch(): void { $this->updatedAt = new DateTimeImmutable(); }
}

enum Status: string {
  case Draft = 'draft';
  case Published = 'published';
}

try {
  match (Status::Draft) {
    Status::Draft => print "draft",
    default => throw new RuntimeException("unknown"),
  };
} catch (Throwable $error) {
  echo $error->getMessage();
} finally {
  unset($error);
}
?>
