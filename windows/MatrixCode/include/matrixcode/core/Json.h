#pragma once

#include <cstddef>
#include <map>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <variant>
#include <vector>

namespace matrixcode::json {

class Value;
using Array = std::vector<Value>;
using Object = std::map<std::string, Value, std::less<>>;

class Value final {
 public:
  using Storage = std::variant<std::nullptr_t, bool, double, std::string, Array, Object>;

  Value() noexcept : storage_(nullptr) {}
  Value(std::nullptr_t) noexcept : storage_(nullptr) {}
  Value(bool value) : storage_(value) {}
  Value(double value) : storage_(value) {}
  Value(int value) : storage_(static_cast<double>(value)) {}
  Value(std::string value) : storage_(std::move(value)) {}
  Value(const char* value) : storage_(std::string(value)) {}
  Value(Array value) : storage_(std::move(value)) {}
  Value(Object value) : storage_(std::move(value)) {}

  [[nodiscard]] bool IsNull() const noexcept;
  [[nodiscard]] const bool* AsBool() const noexcept;
  [[nodiscard]] const double* AsNumber() const noexcept;
  [[nodiscard]] const std::string* AsString() const noexcept;
  [[nodiscard]] const Array* AsArray() const noexcept;
  [[nodiscard]] const Object* AsObject() const noexcept;
  [[nodiscard]] Array* AsArray() noexcept;
  [[nodiscard]] Object* AsObject() noexcept;
  [[nodiscard]] const Value* Find(std::string_view key) const noexcept;
  [[nodiscard]] Value* Find(std::string_view key) noexcept;
  [[nodiscard]] const Storage& Data() const noexcept { return storage_; }

 private:
  Storage storage_;
};

struct ParseResult {
  std::optional<Value> value;
  std::string error;
  std::size_t errorOffset = 0;
};

[[nodiscard]] ParseResult Parse(std::string_view input, std::size_t maximumDepth = 64);
[[nodiscard]] std::string Serialize(const Value& value, bool pretty = false);

}  // namespace matrixcode::json
