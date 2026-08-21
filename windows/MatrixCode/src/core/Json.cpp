#include "matrixcode/core/Json.h"

#include <charconv>
#include <cstdlib>
#include <cmath>
#include <cstdint>
#include <iomanip>
#include <limits>
#include <sstream>
#include <system_error>

namespace matrixcode::json {

bool Value::IsNull() const noexcept { return std::holds_alternative<std::nullptr_t>(storage_); }
const bool* Value::AsBool() const noexcept { return std::get_if<bool>(&storage_); }
const double* Value::AsNumber() const noexcept { return std::get_if<double>(&storage_); }
const std::string* Value::AsString() const noexcept { return std::get_if<std::string>(&storage_); }
const Array* Value::AsArray() const noexcept { return std::get_if<Array>(&storage_); }
const Object* Value::AsObject() const noexcept { return std::get_if<Object>(&storage_); }
Array* Value::AsArray() noexcept { return std::get_if<Array>(&storage_); }
Object* Value::AsObject() noexcept { return std::get_if<Object>(&storage_); }

const Value* Value::Find(const std::string_view key) const noexcept {
  const auto* object = AsObject();
  if (object == nullptr) return nullptr;
  const auto iterator = object->find(key);
  return iterator == object->end() ? nullptr : &iterator->second;
}

Value* Value::Find(const std::string_view key) noexcept {
  auto* object = AsObject();
  if (object == nullptr) return nullptr;
  const auto iterator = object->find(key);
  return iterator == object->end() ? nullptr : &iterator->second;
}

namespace {

void AppendUtf8(std::string& output, const std::uint32_t codePoint) {
  if (codePoint <= 0x7f) {
    output.push_back(static_cast<char>(codePoint));
  } else if (codePoint <= 0x7ff) {
    output.push_back(static_cast<char>(0xc0u | (codePoint >> 6u)));
    output.push_back(static_cast<char>(0x80u | (codePoint & 0x3fu)));
  } else if (codePoint <= 0xffff) {
    output.push_back(static_cast<char>(0xe0u | (codePoint >> 12u)));
    output.push_back(static_cast<char>(0x80u | ((codePoint >> 6u) & 0x3fu)));
    output.push_back(static_cast<char>(0x80u | (codePoint & 0x3fu)));
  } else {
    output.push_back(static_cast<char>(0xf0u | (codePoint >> 18u)));
    output.push_back(static_cast<char>(0x80u | ((codePoint >> 12u) & 0x3fu)));
    output.push_back(static_cast<char>(0x80u | ((codePoint >> 6u) & 0x3fu)));
    output.push_back(static_cast<char>(0x80u | (codePoint & 0x3fu)));
  }
}

class Parser final {
 public:
  Parser(const std::string_view input, const std::size_t maximumDepth)
      : input_(input), maximumDepth_(maximumDepth) {}

  ParseResult Run() {
    SkipSpace();
    auto result = ParseValue(0);
    if (!result.has_value()) return {std::nullopt, error_, offset_};
    SkipSpace();
    if (offset_ != input_.size()) return FailResult("unexpected trailing input");
    return {std::move(result), {}, 0};
  }

 private:
  std::optional<Value> ParseValue(const std::size_t depth) {
    if (depth > maximumDepth_) return Fail("maximum nesting depth exceeded");
    if (offset_ >= input_.size()) return Fail("unexpected end of input");
    switch (input_[offset_]) {
      case 'n': return ParseLiteral("null", Value(nullptr));
      case 't': return ParseLiteral("true", Value(true));
      case 'f': return ParseLiteral("false", Value(false));
      case '"': {
        auto string = ParseString();
        return string.has_value() ? std::optional<Value>(Value(std::move(*string))) : std::nullopt;
      }
      case '[': return ParseArray(depth + 1);
      case '{': return ParseObject(depth + 1);
      default: return ParseNumber();
    }
  }

  std::optional<Value> ParseLiteral(const std::string_view literal, Value result) {
    if (input_.substr(offset_, literal.size()) != literal) return Fail("invalid literal");
    offset_ += literal.size();
    return result;
  }

  std::optional<Value> ParseNumber() {
    const std::size_t start = offset_;
    if (Peek('-')) ++offset_;
    if (Peek('0')) {
      ++offset_;
    } else {
      if (!Digit(Peek())) return Fail("invalid number");
      while (Digit(Peek())) ++offset_;
    }
    if (Peek('.')) {
      ++offset_;
      if (!Digit(Peek())) return Fail("invalid number fraction");
      while (Digit(Peek())) ++offset_;
    }
    if (Peek('e') || Peek('E')) {
      ++offset_;
      if (Peek('+') || Peek('-')) ++offset_;
      if (!Digit(Peek())) return Fail("invalid number exponent");
      while (Digit(Peek())) ++offset_;
    }
    const auto token = input_.substr(start, offset_ - start);
    double number = 0.0;
    const auto [end, error] = std::from_chars(
      token.data(), token.data() + token.size(), number, std::chars_format::general);
    if (error == std::errc::result_out_of_range) {
      const std::string storage(token);
      char* parsedEnd = nullptr;
      number = std::strtod(storage.c_str(), &parsedEnd);
      if (parsedEnd != storage.c_str() + storage.size()) return Fail("number is invalid");
    } else if (error != std::errc{} || end != token.data() + token.size()) {
      return Fail("number is not finite");
    }
    return Value(number);
  }

  std::optional<std::string> ParseString() {
    if (!Consume('"')) return FailString("expected string");
    std::string output;
    while (offset_ < input_.size()) {
      const unsigned char value = static_cast<unsigned char>(input_[offset_++]);
      if (value == '"') return output;
      if (value < 0x20u) return FailString("unescaped control character");
      if (value != '\\') {
        output.push_back(static_cast<char>(value));
        continue;
      }
      if (offset_ >= input_.size()) return FailString("unterminated escape");
      const char escape = input_[offset_++];
      switch (escape) {
        case '"': output.push_back('"'); break;
        case '\\': output.push_back('\\'); break;
        case '/': output.push_back('/'); break;
        case 'b': output.push_back('\b'); break;
        case 'f': output.push_back('\f'); break;
        case 'n': output.push_back('\n'); break;
        case 'r': output.push_back('\r'); break;
        case 't': output.push_back('\t'); break;
        case 'u': {
          auto first = ParseHex4();
          if (!first.has_value()) return std::nullopt;
          std::uint32_t codePoint = *first;
          if (codePoint >= 0xd800u && codePoint <= 0xdbffu) {
            const auto second = offset_ + 6 <= input_.size() && input_[offset_] == '\\' &&
                input_[offset_ + 1] == 'u'
              ? Hex4At(offset_ + 2)
              : std::nullopt;
            if (second.has_value() && *second >= 0xdc00u && *second <= 0xdfffu) {
              offset_ += 6;
              codePoint = 0x10000u + ((codePoint - 0xd800u) << 10u) + (*second - 0xdc00u);
            } else {
              codePoint = 0xfffdu;
            }
          } else if (codePoint >= 0xdc00u && codePoint <= 0xdfffu) {
            codePoint = 0xfffdu;
          }
          AppendUtf8(output, codePoint);
          break;
        }
        default: return FailString("invalid escape");
      }
    }
    return FailString("unterminated string");
  }

  std::optional<std::uint32_t> ParseHex4() {
    if (input_.size() - offset_ < 4) {
      FailString("short unicode escape");
      return std::nullopt;
    }
    std::uint32_t result = 0;
    for (int index = 0; index < 4; ++index) {
      const char value = input_[offset_++];
      result <<= 4u;
      if (value >= '0' && value <= '9') result |= static_cast<std::uint32_t>(value - '0');
      else if (value >= 'a' && value <= 'f') result |= static_cast<std::uint32_t>(value - 'a' + 10);
      else if (value >= 'A' && value <= 'F') result |= static_cast<std::uint32_t>(value - 'A' + 10);
      else {
        FailString("invalid unicode escape");
        return std::nullopt;
      }
    }
    return result;
  }

  [[nodiscard]] std::optional<std::uint32_t> Hex4At(const std::size_t offset) const noexcept {
    if (input_.size() - offset < 4) return std::nullopt;
    std::uint32_t result = 0;
    for (std::size_t index = 0; index < 4; ++index) {
      const char value = input_[offset + index];
      result <<= 4u;
      if (value >= '0' && value <= '9') result |= static_cast<std::uint32_t>(value - '0');
      else if (value >= 'a' && value <= 'f') result |= static_cast<std::uint32_t>(value - 'a' + 10);
      else if (value >= 'A' && value <= 'F') result |= static_cast<std::uint32_t>(value - 'A' + 10);
      else return std::nullopt;
    }
    return result;
  }

  std::optional<Value> ParseArray(const std::size_t depth) {
    Consume('[');
    SkipSpace();
    Array values;
    if (Consume(']')) return Value(std::move(values));
    while (true) {
      SkipSpace();
      auto value = ParseValue(depth);
      if (!value.has_value()) return std::nullopt;
      values.push_back(std::move(*value));
      SkipSpace();
      if (Consume(']')) return Value(std::move(values));
      if (!Consume(',')) return Fail("expected ',' or ']'");
    }
  }

  std::optional<Value> ParseObject(const std::size_t depth) {
    Consume('{');
    SkipSpace();
    Object values;
    if (Consume('}')) return Value(std::move(values));
    while (true) {
      SkipSpace();
      auto key = ParseString();
      if (!key.has_value()) return std::nullopt;
      SkipSpace();
      if (!Consume(':')) return Fail("expected ':'");
      SkipSpace();
      auto value = ParseValue(depth);
      if (!value.has_value()) return std::nullopt;
      values.insert_or_assign(std::move(*key), std::move(*value));
      SkipSpace();
      if (Consume('}')) return Value(std::move(values));
      if (!Consume(',')) return Fail("expected ',' or '}'");
    }
  }

  [[nodiscard]] bool Peek(const char value) const noexcept {
    return offset_ < input_.size() && input_[offset_] == value;
  }
  [[nodiscard]] char Peek() const noexcept { return offset_ < input_.size() ? input_[offset_] : '\0'; }
  [[nodiscard]] static bool Digit(const char value) noexcept { return value >= '0' && value <= '9'; }
  bool Consume(const char value) noexcept {
    if (!Peek(value)) return false;
    ++offset_;
    return true;
  }
  void SkipSpace() noexcept {
    while (offset_ < input_.size()) {
      const char value = input_[offset_];
      if (value != ' ' && value != '\t' && value != '\r' && value != '\n') break;
      ++offset_;
    }
  }
  std::optional<Value> Fail(std::string error) {
    if (error_.empty()) error_ = std::move(error);
    return std::nullopt;
  }
  std::optional<std::string> FailString(std::string error) {
    if (error_.empty()) error_ = std::move(error);
    return std::nullopt;
  }
  ParseResult FailResult(std::string error) {
    return {std::nullopt, std::move(error), offset_};
  }

  std::string_view input_;
  std::size_t maximumDepth_;
  std::size_t offset_ = 0;
  std::string error_;
};

void Indent(std::string& output, const std::size_t depth) {
  output.append(depth * 2, ' ');
}

void SerializeString(std::string& output, const std::string_view value) {
  output.push_back('"');
  constexpr char hex[] = "0123456789abcdef";
  for (const unsigned char character : value) {
    switch (character) {
      case '"': output += "\\\""; break;
      case '\\': output += "\\\\"; break;
      case '\b': output += "\\b"; break;
      case '\f': output += "\\f"; break;
      case '\n': output += "\\n"; break;
      case '\r': output += "\\r"; break;
      case '\t': output += "\\t"; break;
      default:
        if (character < 0x20u) {
          output += "\\u00";
          output.push_back(hex[character >> 4u]);
          output.push_back(hex[character & 0x0fu]);
        } else {
          output.push_back(static_cast<char>(character));
        }
        break;
    }
  }
  output.push_back('"');
}

void SerializeValue(std::string& output, const Value& value, const bool pretty, const std::size_t depth) {
  if (value.IsNull()) {
    output += "null";
  } else if (const auto* boolean = value.AsBool()) {
    output += *boolean ? "true" : "false";
  } else if (const auto* number = value.AsNumber()) {
    std::ostringstream stream;
    stream << std::setprecision(std::numeric_limits<double>::max_digits10) << *number;
    output += stream.str();
  } else if (const auto* string = value.AsString()) {
    SerializeString(output, *string);
  } else if (const auto* array = value.AsArray()) {
    output.push_back('[');
    for (std::size_t index = 0; index < array->size(); ++index) {
      if (index != 0) output.push_back(',');
      if (pretty) { output.push_back('\n'); Indent(output, depth + 1); }
      SerializeValue(output, (*array)[index], pretty, depth + 1);
    }
    if (pretty && !array->empty()) { output.push_back('\n'); Indent(output, depth); }
    output.push_back(']');
  } else if (const auto* object = value.AsObject()) {
    output.push_back('{');
    std::size_t index = 0;
    for (const auto& [key, child] : *object) {
      if (index++ != 0) output.push_back(',');
      if (pretty) { output.push_back('\n'); Indent(output, depth + 1); }
      SerializeString(output, key);
      output += pretty ? ": " : ":";
      SerializeValue(output, child, pretty, depth + 1);
    }
    if (pretty && !object->empty()) { output.push_back('\n'); Indent(output, depth); }
    output.push_back('}');
  }
}

}  // namespace

ParseResult Parse(const std::string_view input, const std::size_t maximumDepth) {
  return Parser(input, maximumDepth).Run();
}

std::string Serialize(const Value& value, const bool pretty) {
  std::string output;
  SerializeValue(output, value, pretty, 0);
  if (pretty) output.push_back('\n');
  return output;
}

}  // namespace matrixcode::json
