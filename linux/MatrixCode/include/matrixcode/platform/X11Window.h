#pragma once

#include <optional>

#include <QSize>
#include <QtGlobal>

namespace matrixcode::platform {

[[nodiscard]] std::optional<QSize> QueryX11WindowSize(quint64 windowId);

}  // namespace matrixcode::platform
