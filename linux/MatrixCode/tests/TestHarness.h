#pragma once

#include <cstddef>
#include <sstream>
#include <stdexcept>
#include <string>

namespace matrixcode::test {

inline std::size_t assertions = 0;

inline void Expect(const bool condition, const char* expression, const char* file, const int line) {
  ++assertions;
  if (condition) return;
  std::ostringstream message;
  message << file << ':' << line << ": expectation failed: " << expression;
  throw std::runtime_error(message.str());
}

template <typename Actual, typename Expected>
void ExpectEqual(
    const Actual& actual,
    const Expected& expected,
    const char* actualExpression,
    const char* expectedExpression,
    const char* file,
    const int line) {
  ++assertions;
  if (actual == expected) return;
  std::ostringstream message;
  message << file << ':' << line << ": expected " << actualExpression << " == " << expectedExpression;
  throw std::runtime_error(message.str());
}

}  // namespace matrixcode::test

#define MX_EXPECT(expression) \
  ::matrixcode::test::Expect(static_cast<bool>(expression), #expression, __FILE__, __LINE__)
#define MX_EXPECT_EQ(actual, expected) \
  ::matrixcode::test::ExpectEqual((actual), (expected), #actual, #expected, __FILE__, __LINE__)
