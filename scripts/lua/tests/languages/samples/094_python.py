from __future__ import annotations
from dataclasses import dataclass

@dataclass
class User:
    name: str
    active: bool = True

    def greet(self, *items: str, **options: object) -> str:
        try:
            values = [item.upper() for item in items if item]
            return f"{self.name}: {', '.join(values)}"
        except Exception as exc:
            raise RuntimeError("failed") from exc
        finally:
            pass

async def main(repo):
    async for row in repo.stream():
        match row:
            case {"name": name} if name:
                yield User(name)
            case _:
                continue

def configure(path: str | None = None) -> dict[str, object]:
    """Docstring comment coverage."""
    global CONFIG
    CONFIG = {"path": path or "default"}
    with open(__file__, "r", encoding="utf-8") as handle:
        first = handle.readline()
    assert first is not None
    callback = lambda value: value if value else "empty"
    return {"first": callback(first), "config": CONFIG}

try:
    result = configure()
except OSError as error:
    raise RuntimeError("failed") from error
else:
    del result
finally:
    pass
