#include <iostream>
#include <memory>
#define TRACE(name) std::cout << name << "\n"

namespace demo {
template <typename T>
class Box final {
public:
  explicit Box(T value) : value_(std::move(value)) {}
  constexpr const T& value() const noexcept { return value_; }
private:
  T value_;
};
}

int main() {
  auto box = demo::Box<std::string>{"value"};
  TRACE(box.value());
  switch (box.value().size()) {
    case 0: return 1;
    default: break;
  }
  try { return box.value().empty() ? 1 : 0; }
  catch (const std::exception& ex) { return -1; }
}

enum class Mode : unsigned { Read, Write };
union Number { int i; float f; };
static_assert(sizeof(Number) >= sizeof(int));

template <typename T>
concept Printable = requires(T value) { std::cout << value; };

consteval int build_value() { return 42; }

#define #elif #else #elseif #endif #error #if #ifdef #ifndef #include #pragma #warning NULL alignas alignof and and_eq asm auto bitand bitor bool break case catch char char16_t char32_t char8_t class co_await co_return co_yield compl concept const const_cast consteval constexpr constinit continue decltype default delete do double dynamic_cast else elseif enum explicit export extern false float for friend goto if inline int long mutable namespace new noexcept not not_eq nullptr operator or or_eq override private protected public register reinterpret_cast requires return short static static_assert static_cast struct switch template then this thread_local throw true try typedef typeid typename union unsigned using virtual void volatile wchar_t while xor xor_eq ;
