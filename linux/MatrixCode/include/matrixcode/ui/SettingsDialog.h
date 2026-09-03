#pragma once

#include <functional>

#include <QDialog>

#include "matrixcode/core/Types.h"

class QCheckBox;
class QComboBox;
class QDateTimeEdit;
class QDoubleSpinBox;
class QLineEdit;
class QListWidget;
class QPushButton;
class QSpinBox;
class QTableWidget;
class QTabWidget;

namespace matrixcode::ui {

enum class SettingsPage { Rain = 0, Intro = 1, Messages = 2, Images = 3, Countdown = 4 };

/**
 * Native editor for the complete portable settings document. The dialog edits a
 * private draft and only mutates the caller's snapshot after Save is pressed.
 */
class SettingsDialog final : public QDialog {
 public:
  using PreviewCallback = std::function<void(const SettingsSnapshot&, SettingsPage)>;

  explicit SettingsDialog(
    const SettingsSnapshot& settings,
    SettingsPage initialPage = SettingsPage::Rain,
    QWidget* parent = nullptr);

  [[nodiscard]] const SettingsSnapshot& Result() const noexcept { return draft_; }
  void SetPreviewCallback(PreviewCallback callback);

 private:
  QWidget* BuildRainPage();
  QWidget* BuildIntroPage();
  QWidget* BuildMessagesPage();
  QWidget* BuildImagesPage();
  QWidget* BuildCountdownPage();
  void ReadDraft();
  void Populate(const SettingsSnapshot& settings);
  void ResetCurrentPage();
  void PreviewCurrentPage();
  void ImportImages();
  void ApplyMaximumImageVisibility();
  void UpdateImageTable();
  void MoveCurrentRow(QTableWidget* table, int delta);
  void RemoveCurrentRow(QTableWidget* table);
  void AddIntroLine();
  void AddMessage();
  void AddMoment();
  void EditPortableJson();
  void ImportPortableJson();
  void ExportPortableJson();

  SettingsSnapshot draft_;
  PreviewCallback previewCallback_;
  QTabWidget* tabs_ = nullptr;
  QPushButton* previewButton_ = nullptr;

  QDoubleSpinBox* speed_ = nullptr;
  QDoubleSpinBox* density_ = nullptr;
  QDoubleSpinBox* trail_ = nullptr;
  QDoubleSpinBox* trailVariation_ = nullptr;
  QDoubleSpinBox* ramp_ = nullptr;
  QDoubleSpinBox* glyphRate_ = nullptr;
  QDoubleSpinBox* glyphScale_ = nullptr;
  QDoubleSpinBox* glow_ = nullptr;
  QDoubleSpinBox* leadBrightness_ = nullptr;
  QDoubleSpinBox* vignette_ = nullptr;
  QComboBox* preset_ = nullptr;
  QLineEdit* customColor_ = nullptr;
  QComboBox* glyphMode_ = nullptr;
  QComboBox* glyphFont_ = nullptr;
  QComboBox* quality_ = nullptr;
  QLineEdit* viewerName_ = nullptr;
  QCheckBox* mirror_ = nullptr;
  QCheckBox* scanlines_ = nullptr;
  QCheckBox* overlap_ = nullptr;

  QCheckBox* introEnabled_ = nullptr;
  QTableWidget* introLines_ = nullptr;
  QDoubleSpinBox* charMilliseconds_ = nullptr;
  QDoubleSpinBox* startDelay_ = nullptr;
  QDoubleSpinBox* fadeOut_ = nullptr;
  QCheckBox* rainDuringIntro_ = nullptr;
  QDoubleSpinBox* postIntroDelay_ = nullptr;

  QCheckBox* messagesEnabled_ = nullptr;
  QListWidget* messages_ = nullptr;
  QDoubleSpinBox* messageFrequency_ = nullptr;
  QDoubleSpinBox* messagePersistence_ = nullptr;
  QDoubleSpinBox* messageAppear_ = nullptr;
  QDoubleSpinBox* messageDisappear_ = nullptr;
  QCheckBox* messageFlicker_ = nullptr;
  QCheckBox* messageBrightness_ = nullptr;
  QComboBox* messageLayout_ = nullptr;
  QComboBox* messageDirection_ = nullptr;
  QDoubleSpinBox* messagePosition_ = nullptr;
  QDoubleSpinBox* messageJitter_ = nullptr;
  QDoubleSpinBox* messageHorizontalPosition_ = nullptr;
  QDoubleSpinBox* messageHorizontalJitter_ = nullptr;

  QCheckBox* imagesEnabled_ = nullptr;
  QTableWidget* images_ = nullptr;
  QDoubleSpinBox* imageFrequency_ = nullptr;
  QDoubleSpinBox* imagePersistence_ = nullptr;
  QDoubleSpinBox* imageAppear_ = nullptr;
  QDoubleSpinBox* imageDisappear_ = nullptr;
  QCheckBox* imageFlicker_ = nullptr;
  QCheckBox* imageBrightness_ = nullptr;
  QDoubleSpinBox* imageScale_ = nullptr;
  QDoubleSpinBox* imageJitter_ = nullptr;

  QCheckBox* countdownEnabled_ = nullptr;
  QDateTimeEdit* countdownTarget_ = nullptr;
  QTableWidget* moments_ = nullptr;
};

}  // namespace matrixcode::ui
