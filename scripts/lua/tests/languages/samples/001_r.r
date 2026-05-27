import module.name as mod

class Widget(Base):
    def __init__(self, name="demo"):
        self.name = name

    def render(self, items):
        for item in items:
            if item.enabled:
                mod.call(f"{self.name}:{item.value}")
            else:
                continue
        return None

FALSE Inf NA NA_character NA_complex NA_integer NA_real NULL TRUE break else for function if in next repeat while ;
