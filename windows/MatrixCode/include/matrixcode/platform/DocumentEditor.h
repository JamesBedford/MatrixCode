#pragma once

#include <windows.h>

#include "matrixcode/core/Types.h"

namespace matrixcode::platform {

enum class DocumentPage { Intro = 0, Messages = 1, Images = 2, Countdown = 3 };

class DocumentEditor final {
 public:
  [[nodiscard]] static INT_PTR ShowModal(
    HWND owner,
    SettingsSnapshot& settings,
    DocumentPage initialPage = DocumentPage::Intro);
};

}  // namespace matrixcode::platform
