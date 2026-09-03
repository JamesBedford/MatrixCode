#include "matrixcode/ui/SettingsDialog.h"

#include <algorithm>
#include <chrono>
#include <iterator>
#include <utility>

#include <QAbstractItemView>
#include <QCheckBox>
#include <QColorDialog>
#include <QComboBox>
#include <QDateTime>
#include <QDateTimeEdit>
#include <QDialogButtonBox>
#include <QDoubleSpinBox>
#include <QFileDialog>
#include <QFile>
#include <QFormLayout>
#include <QFrame>
#include <QFontDatabase>
#include <QGridLayout>
#include <QGroupBox>
#include <QHeaderView>
#include <QIcon>
#include <QLabel>
#include <QLineEdit>
#include <QListWidget>
#include <QMessageBox>
#include <QMenu>
#include <QPlainTextEdit>
#include <QPushButton>
#include <QRegularExpression>
#include <QRegularExpressionValidator>
#include <QSaveFile>
#include <QScrollArea>
#include <QTabWidget>
#include <QTableWidget>
#include <QToolButton>
#include <QVBoxLayout>

#include "matrixcode/core/Settings.h"
#include "matrixcode/platform/ImageImportQt.h"
#include "matrixcode/platform/SettingsStoreLinux.h"

namespace matrixcode::ui {
namespace {

constexpr int kMaximumLines = 12;
constexpr int kMaximumMessages = 12;
constexpr int kMaximumImages = 64;
constexpr int kMaximumMoments = 12;
constexpr qint64 kMaximumPortableSettingsBytes = 8 * 1024 * 1024;

QDoubleSpinBox* Number(
    const double minimum, const double maximum, const double step,
    const int decimals = 2, const QString& suffix = {}) {
  auto* spin = new QDoubleSpinBox;
  spin->setRange(minimum, maximum);
  spin->setSingleStep(step);
  spin->setDecimals(decimals);
  spin->setSuffix(suffix);
  spin->setKeyboardTracking(false);
  return spin;
}

QDoubleSpinBox* Seconds(const double maximum = 600.0, const double minimum = 0.0) {
  return Number(minimum, maximum, 0.1, 2, QObject::tr(" s"));
}

QDoubleSpinBox* Percent(const double minimum = 0.0) {
  return Number(minimum, 100.0, 1.0, 0, QObject::tr(" %"));
}

QLabel* Hint(const QString& text) {
  auto* label = new QLabel(text);
  label->setWordWrap(true);
  label->setProperty("kind", "hint");
  return label;
}

QWidget* WithActions(QWidget* content, const QList<QPair<QString, std::function<void()>>>& actions) {
  auto* wrapper = new QWidget;
  auto* layout = new QVBoxLayout(wrapper);
  layout->setContentsMargins(0, 0, 0, 0);
  layout->addWidget(content, 1);
  auto* row = new QHBoxLayout;
  for (const auto& [label, action] : actions) {
    auto* button = new QPushButton(label);
    QObject::connect(button, &QPushButton::clicked, button, action);
    row->addWidget(button);
  }
  row->addStretch();
  layout->addLayout(row);
  return wrapper;
}

QString Utf8(const std::string& value) {
  return QString::fromUtf8(value.data(), static_cast<qsizetype>(value.size()));
}

std::string StdUtf8(const QString& value) {
  const QByteArray bytes = value.toUtf8();
  return std::string(bytes.constData(), static_cast<std::size_t>(bytes.size()));
}

double ToEpochMilliseconds(const QDateTime& value) {
  return static_cast<double>(value.toMSecsSinceEpoch());
}

QDateTime FromEpochMilliseconds(const std::optional<double> value) {
  const qint64 milliseconds = value.has_value()
    ? static_cast<qint64>(*value)
    : QDateTime::currentDateTime().addDays(1).toMSecsSinceEpoch();
  return QDateTime::fromMSecsSinceEpoch(milliseconds);
}

void ConfigureTable(QTableWidget* table) {
  table->setAlternatingRowColors(true);
  table->setSelectionBehavior(QAbstractItemView::SelectRows);
  table->setSelectionMode(QAbstractItemView::SingleSelection);
  table->verticalHeader()->hide();
  table->horizontalHeader()->setStretchLastSection(true);
}

}  // namespace

SettingsDialog::SettingsDialog(
    const SettingsSnapshot& settings, const SettingsPage initialPage, QWidget* parent)
    : QDialog(parent), draft_(settings) {
  setWindowTitle(tr("Matrix Code Settings"));
  setWindowIcon(QIcon(":/matrixcode/icons/matrixcode.svg"));
  setModal(true);
  setMinimumSize(780, 620);
  resize(900, 720);
  setStyleSheet(R"(
    QDialog { background: #0d1110; color: #dfffe4; }
    QTabWidget::pane { border: 1px solid #24482d; background: #111713; border-radius: 6px; }
    QTabBar::tab { background: #151d17; color: #91b99a; padding: 9px 15px; border: 1px solid #24482d; }
    QTabBar::tab:selected { background: #173420; color: #74ff92; }
    QLabel[kind="hint"] { color: #91a897; padding: 2px 0 8px 0; }
    QGroupBox { border: 1px solid #24482d; border-radius: 6px; margin-top: 11px; padding-top: 8px; font-weight: 600; }
    QGroupBox::title { subcontrol-origin: margin; left: 10px; color: #74ff92; }
    QLineEdit, QComboBox, QDoubleSpinBox, QDateTimeEdit, QListWidget, QTableWidget {
      background: #090d0a; color: #e5ffe9; border: 1px solid #315b39; border-radius: 4px; padding: 5px;
      selection-background-color: #206b35;
    }
    QPushButton, QToolButton { background: #18341f; color: #dfffe4; border: 1px solid #397348; border-radius: 4px; padding: 6px 12px; }
    QPushButton:hover, QToolButton:hover { background: #24512f; border-color: #54b669; }
    QPushButton:default { background: #177633; border-color: #58dc76; }
    QCheckBox { spacing: 7px; }
  )");

  auto* root = new QVBoxLayout(this);
  auto* title = new QLabel(tr("MATRIX CODE"));
  QFont titleFont = title->font();
  titleFont.setPointSize(17);
  titleFont.setBold(true);
  titleFont.setLetterSpacing(QFont::AbsoluteSpacing, 3.0);
  title->setFont(titleFont);
  title->setStyleSheet("color:#00ff41");
  root->addWidget(title);
  root->addWidget(Hint(tr("Native Ubuntu renderer · settings are shared by app, fullscreen, multi-monitor and XScreenSaver modes.")));

  tabs_ = new QTabWidget;
  tabs_->setDocumentMode(true);
  tabs_->addTab(BuildRainPage(), tr("Rain"));
  tabs_->addTab(BuildIntroPage(), tr("Intro"));
  tabs_->addTab(BuildMessagesPage(), tr("Messages"));
  tabs_->addTab(BuildImagesPage(), tr("Images"));
  tabs_->addTab(BuildCountdownPage(), tr("Countdowns"));
  tabs_->setCurrentIndex(static_cast<int>(initialPage));
  root->addWidget(tabs_, 1);

  auto* footer = new QHBoxLayout;
  auto* reset = new QPushButton(tr("Reset this page"));
  previewButton_ = new QPushButton(tr("Preview"));
  previewButton_->setEnabled(false);
  previewButton_->setToolTip(tr("Preview is available while the rain window is open."));
  auto* advanced = new QPushButton(tr("Advanced…"));
  auto* advancedMenu = new QMenu(advanced);
  advancedMenu->addAction(tr("Edit portable JSON…"), this, [this] { EditPortableJson(); });
  advancedMenu->addAction(tr("Import settings…"), this, [this] { ImportPortableJson(); });
  advancedMenu->addAction(tr("Export settings…"), this, [this] { ExportPortableJson(); });
  advanced->setMenu(advancedMenu);
  auto* buttons = new QDialogButtonBox(QDialogButtonBox::Save | QDialogButtonBox::Cancel);
  buttons->button(QDialogButtonBox::Save)->setDefault(true);
  footer->addWidget(reset);
  footer->addWidget(previewButton_);
  footer->addWidget(advanced);
  footer->addStretch();
  footer->addWidget(buttons);
  root->addLayout(footer);
  connect(reset, &QPushButton::clicked, this, [this] { ResetCurrentPage(); });
  connect(previewButton_, &QPushButton::clicked, this, [this] { PreviewCurrentPage(); });
  connect(buttons, &QDialogButtonBox::rejected, this, &QDialog::reject);
  connect(buttons, &QDialogButtonBox::accepted, this, [this] {
    ReadDraft();
    accept();
  });

  Populate(settings);
}

void SettingsDialog::SetPreviewCallback(PreviewCallback callback) {
  previewCallback_ = std::move(callback);
  previewButton_->setEnabled(static_cast<bool>(previewCallback_));
}

QWidget* SettingsDialog::BuildRainPage() {
  auto* body = new QWidget;
  auto* layout = new QGridLayout(body);
  auto* motion = new QGroupBox(tr("Motion and density"));
  auto* motionForm = new QFormLayout(motion);
  speed_ = Number(0.1, 3.0, 0.05);
  density_ = Number(0.1, 100.0, 0.5);
  trail_ = Number(0.01, 0.5, 0.005, 3);
  trailVariation_ = Percent();
  ramp_ = Seconds(60.0);
  glyphRate_ = Number(0.0, 5.0, 0.1);
  glyphScale_ = Number(0.5, 10.0, 0.1);
  motionForm->addRow(tr("Speed"), speed_);
  motionForm->addRow(tr("Density"), density_);
  motionForm->addRow(tr("Trail length"), trail_);
  motionForm->addRow(tr("Trail variation"), trailVariation_);
  motionForm->addRow(tr("Ramp-up"), ramp_);
  motionForm->addRow(tr("Glyph change rate"), glyphRate_);
  motionForm->addRow(tr("Glyph scale"), glyphScale_);

  auto* appearance = new QGroupBox(tr("Appearance"));
  auto* appearanceForm = new QFormLayout(appearance);
  preset_ = new QComboBox;
  preset_->addItems({tr("Classic"), tr("Amber"), tr("Orange"), tr("Gold"), tr("Red"), tr("Pink"), tr("Purple"), tr("Blue"), tr("White"), tr("Custom")});
  preset_->setItemData(0, "classic"); preset_->setItemData(1, "amber");
  preset_->setItemData(2, "orange"); preset_->setItemData(3, "gold");
  preset_->setItemData(4, "red"); preset_->setItemData(5, "pink");
  preset_->setItemData(6, "purple"); preset_->setItemData(7, "blue");
  preset_->setItemData(8, "white"); preset_->setItemData(9, "custom");
  customColor_ = new QLineEdit;
  customColor_->setMaxLength(7);
  customColor_->setValidator(new QRegularExpressionValidator(
    QRegularExpression(QStringLiteral("#[0-9A-Fa-f]{6}")), customColor_));
  auto* colorRow = new QWidget;
  auto* colorLayout = new QHBoxLayout(colorRow);
  colorLayout->setContentsMargins(0, 0, 0, 0);
  colorLayout->addWidget(customColor_);
  auto* chooseColor = new QPushButton(tr("Choose…"));
  colorLayout->addWidget(chooseColor);
  connect(chooseColor, &QPushButton::clicked, this, [this] {
    const QColor current(customColor_->text());
    const QColor selected = QColorDialog::getColor(current, this, tr("Custom rain colour"));
    if (selected.isValid()) customColor_->setText(selected.name(QColor::HexRgb).toUpper());
  });
  glyphMode_ = new QComboBox;
  glyphMode_->addItems({tr("Matrix mix"), tr("Katakana"), tr("Binary"), tr("Digits"), tr("Latin"), tr("Symbols")});
  glyphFont_ = new QComboBox;
  glyphFont_->addItems({tr("Matrix"), tr("Gothic"), tr("Mono"), tr("Terminal"), tr("Rounded"), tr("Mincho")});
  quality_ = new QComboBox;
  quality_->addItems({tr("Low"), tr("Medium"), tr("High")});
  glow_ = Number(0.0, 2.5, 0.05);
  leadBrightness_ = Number(0.0, 3.0, 0.05);
  vignette_ = Percent();
  appearanceForm->addRow(tr("Colour theme"), preset_);
  appearanceForm->addRow(tr("Custom colour"), colorRow);
  appearanceForm->addRow(tr("Glyph set"), glyphMode_);
  appearanceForm->addRow(tr("Glyph font"), glyphFont_);
  appearanceForm->addRow(tr("Quality"), quality_);
  appearanceForm->addRow(tr("Glow"), glow_);
  appearanceForm->addRow(tr("Lead brightness"), leadBrightness_);
  appearanceForm->addRow(tr("Vignette"), vignette_);

  auto* options = new QGroupBox(tr("Options"));
  auto* optionLayout = new QVBoxLayout(options);
  mirror_ = new QCheckBox(tr("Mirror rain glyphs"));
  scanlines_ = new QCheckBox(tr("CRT scanlines"));
  overlap_ = new QCheckBox(tr("Interleaved overlap lanes at high density"));
  viewerName_ = new QLineEdit;
  viewerName_->setMaxLength(80);
  viewerName_->setAccessibleName(tr("Viewer name for the name token"));
  optionLayout->addWidget(mirror_);
  optionLayout->addWidget(scanlines_);
  optionLayout->addWidget(overlap_);
  auto* nameForm = new QFormLayout;
  nameForm->addRow(tr("Name used by {name}"), viewerName_);
  optionLayout->addLayout(nameForm);
  optionLayout->addStretch();

  layout->addWidget(motion, 0, 0);
  layout->addWidget(appearance, 0, 1);
  layout->addWidget(options, 1, 0, 1, 2);
  layout->setRowStretch(2, 1);
  auto* scroll = new QScrollArea;
  scroll->setWidget(body);
  scroll->setWidgetResizable(true);
  scroll->setFrameShape(QFrame::NoFrame);
  return scroll;
}

QWidget* SettingsDialog::BuildIntroPage() {
  auto* page = new QWidget;
  auto* layout = new QVBoxLayout(page);
  layout->addWidget(Hint(tr("The intro plays on every launch. Click or Escape skips it. Tokens such as {name}, {time} and {countdown} are resolved live.")));
  introEnabled_ = new QCheckBox(tr("Play intro on launch"));
  layout->addWidget(introEnabled_);
  introLines_ = new QTableWidget(0, 3);
  introLines_->setHorizontalHeaderLabels({tr("Text"), tr("Hold (s)"), tr("Pause after (s)")});
  ConfigureTable(introLines_);
  introLines_->horizontalHeader()->setSectionResizeMode(0, QHeaderView::Stretch);
  introLines_->horizontalHeader()->setSectionResizeMode(1, QHeaderView::ResizeToContents);
  introLines_->horizontalHeader()->setSectionResizeMode(2, QHeaderView::ResizeToContents);
  layout->addWidget(WithActions(introLines_, {
    {tr("Add line"), [this] { AddIntroLine(); }},
    {tr("Remove"), [this] { RemoveCurrentRow(introLines_); }},
    {tr("Move up"), [this] { MoveCurrentRow(introLines_, -1); }},
    {tr("Move down"), [this] { MoveCurrentRow(introLines_, 1); }},
  }), 1);
  auto* timing = new QGroupBox(tr("Timing and rain choreography"));
  auto* form = new QFormLayout(timing);
  charMilliseconds_ = Number(10.0, 500.0, 5.0, 0, tr(" ms / character"));
  startDelay_ = Seconds(10.0);
  fadeOut_ = Seconds(10.0);
  rainDuringIntro_ = new QCheckBox(tr("Let rain fall behind the intro"));
  postIntroDelay_ = Seconds(10.0);
  form->addRow(tr("Typing speed"), charMilliseconds_);
  form->addRow(tr("Start delay"), startDelay_);
  form->addRow(tr("Fade out"), fadeOut_);
  form->addRow(QString(), rainDuringIntro_);
  form->addRow(tr("Rain delay after intro"), postIntroDelay_);
  layout->addWidget(timing);
  return page;
}

QWidget* SettingsDialog::BuildMessagesPage() {
  auto* page = new QWidget;
  auto* layout = new QVBoxLayout(page);
  layout->addWidget(Hint(tr("Messages are revealed by the same falling glyphs as the rain. Double-click a line to edit it; drag or use the buttons to reorder.")));
  messagesEnabled_ = new QCheckBox(tr("Show messages (N or Shift+M)"));
  layout->addWidget(messagesEnabled_);
  messages_ = new QListWidget;
  messages_->setAlternatingRowColors(true);
  messages_->setDragDropMode(QAbstractItemView::InternalMove);
  layout->addWidget(WithActions(messages_, {
    {tr("Add message"), [this] { AddMessage(); }},
    {tr("Remove"), [this] {
      delete messages_->takeItem(messages_->currentRow());
    }},
    {tr("Move up"), [this] {
      const int row = messages_->currentRow();
      if (row > 0) { auto* item = messages_->takeItem(row); messages_->insertItem(row - 1, item); messages_->setCurrentRow(row - 1); }
    }},
    {tr("Move down"), [this] {
      const int row = messages_->currentRow();
      if (row >= 0 && row + 1 < messages_->count()) { auto* item = messages_->takeItem(row); messages_->insertItem(row + 1, item); messages_->setCurrentRow(row + 1); }
    }},
  }), 1);
  auto* behaviour = new QGroupBox(tr("Behaviour"));
  auto* grid = new QGridLayout(behaviour);
  messageFrequency_ = Seconds(600.0, 0.5); messagePersistence_ = Seconds(600.0, 0.5);
  messageAppear_ = Seconds(); messageDisappear_ = Seconds();
  messageFlicker_ = new QCheckBox(tr("Flicker dissolve"));
  messageBrightness_ = new QCheckBox(tr("Brightness fade"));
  messageLayout_ = new QComboBox; messageLayout_->addItems({tr("Row"), tr("Drop")});
  messageDirection_ = new QComboBox; messageDirection_->addItems({tr("Top to bottom"), tr("Bottom to top")});
  messagePosition_ = Percent(); messageJitter_ = Percent();
  messageHorizontalPosition_ = Percent(); messageHorizontalJitter_ = Percent();
  grid->addWidget(new QLabel(tr("Show one every")), 0, 0); grid->addWidget(messageFrequency_, 0, 1);
  grid->addWidget(new QLabel(tr("Each stays for")), 0, 2); grid->addWidget(messagePersistence_, 0, 3);
  grid->addWidget(new QLabel(tr("Appear over")), 1, 0); grid->addWidget(messageAppear_, 1, 1);
  grid->addWidget(new QLabel(tr("Disappear over")), 1, 2); grid->addWidget(messageDisappear_, 1, 3);
  grid->addWidget(new QLabel(tr("Layout")), 2, 0); grid->addWidget(messageLayout_, 2, 1);
  grid->addWidget(new QLabel(tr("Direction")), 2, 2); grid->addWidget(messageDirection_, 2, 3);
  grid->addWidget(new QLabel(tr("Vertical position")), 3, 0); grid->addWidget(messagePosition_, 3, 1);
  grid->addWidget(new QLabel(tr("Vertical randomness")), 3, 2); grid->addWidget(messageJitter_, 3, 3);
  grid->addWidget(new QLabel(tr("Horizontal position")), 4, 0); grid->addWidget(messageHorizontalPosition_, 4, 1);
  grid->addWidget(new QLabel(tr("Horizontal randomness")), 4, 2); grid->addWidget(messageHorizontalJitter_, 4, 3);
  grid->addWidget(messageFlicker_, 5, 0, 1, 2); grid->addWidget(messageBrightness_, 5, 2, 1, 2);
  layout->addWidget(behaviour);
  return page;
}

QWidget* SettingsDialog::BuildImagesPage() {
  auto* page = new QWidget;
  auto* layout = new QVBoxLayout(page);
  layout->addWidget(Hint(tr("Images emerge from the stationary glyph grid. Imports are aspect-fitted into portable 96×96-cell luminance masks and shared across all native modes.")));
  imagesEnabled_ = new QCheckBox(tr("Show images (Shift+X)"));
  layout->addWidget(imagesEnabled_);
  images_ = new QTableWidget(0, 3);
  images_->setHorizontalHeaderLabels({tr("Name"), tr("Dimensions"), tr("Storage")});
  ConfigureTable(images_);
  images_->horizontalHeader()->setSectionResizeMode(0, QHeaderView::Stretch);
  images_->horizontalHeader()->setSectionResizeMode(1, QHeaderView::ResizeToContents);
  images_->horizontalHeader()->setSectionResizeMode(2, QHeaderView::ResizeToContents);
  layout->addWidget(WithActions(images_, {
    {tr("Add images…"), [this] { ImportImages(); }},
    {tr("Remove"), [this] { RemoveCurrentRow(images_); }},
    {tr("Move up"), [this] { MoveCurrentRow(images_, -1); }},
    {tr("Move down"), [this] { MoveCurrentRow(images_, 1); }},
    {tr("Max visibility"), [this] { ApplyMaximumImageVisibility(); }},
  }), 1);
  auto* behaviour = new QGroupBox(tr("Behaviour"));
  auto* grid = new QGridLayout(behaviour);
  imageFrequency_ = Seconds(600.0, 0.5); imagePersistence_ = Seconds(600.0, 0.5);
  imageAppear_ = Seconds(); imageDisappear_ = Seconds();
  imageScale_ = Percent(5.0); imageJitter_ = Percent();
  imageFlicker_ = new QCheckBox(tr("Flicker dissolve"));
  imageBrightness_ = new QCheckBox(tr("Brightness fade"));
  grid->addWidget(new QLabel(tr("Show one every")), 0, 0); grid->addWidget(imageFrequency_, 0, 1);
  grid->addWidget(new QLabel(tr("Each stays for")), 0, 2); grid->addWidget(imagePersistence_, 0, 3);
  grid->addWidget(new QLabel(tr("Appear over")), 1, 0); grid->addWidget(imageAppear_, 1, 1);
  grid->addWidget(new QLabel(tr("Disappear over")), 1, 2); grid->addWidget(imageDisappear_, 1, 3);
  grid->addWidget(new QLabel(tr("Screen width")), 2, 0); grid->addWidget(imageScale_, 2, 1);
  grid->addWidget(new QLabel(tr("Placement randomness")), 2, 2); grid->addWidget(imageJitter_, 2, 3);
  grid->addWidget(imageFlicker_, 3, 0, 1, 2); grid->addWidget(imageBrightness_, 3, 2, 1, 2);
  layout->addWidget(behaviour);
  return page;
}

QWidget* SettingsDialog::BuildCountdownPage() {
  auto* page = new QWidget;
  auto* layout = new QVBoxLayout(page);
  layout->addWidget(Hint(tr("Use {countdown}, {countup}, or named forms such as {countdown:launch} in intros and messages. Targets use your local time zone.")));
  auto* defaultGroup = new QGroupBox(tr("Default moment"));
  auto* defaultLayout = new QHBoxLayout(defaultGroup);
  countdownEnabled_ = new QCheckBox(tr("Set target"));
  countdownTarget_ = new QDateTimeEdit;
  countdownTarget_->setCalendarPopup(true);
  countdownTarget_->setDisplayFormat("yyyy-MM-dd HH:mm:ss t");
  connect(countdownEnabled_, &QCheckBox::toggled, countdownTarget_, &QWidget::setEnabled);
  defaultLayout->addWidget(countdownEnabled_);
  defaultLayout->addWidget(countdownTarget_, 1);
  layout->addWidget(defaultGroup);
  moments_ = new QTableWidget(0, 3);
  moments_->setHorizontalHeaderLabels({tr("Enabled"), tr("Name"), tr("Target")});
  ConfigureTable(moments_);
  moments_->horizontalHeader()->setSectionResizeMode(0, QHeaderView::ResizeToContents);
  moments_->horizontalHeader()->setSectionResizeMode(1, QHeaderView::Stretch);
  moments_->horizontalHeader()->setSectionResizeMode(2, QHeaderView::Stretch);
  layout->addWidget(WithActions(moments_, {
    {tr("Add moment"), [this] { AddMoment(); }},
    {tr("Remove"), [this] { RemoveCurrentRow(moments_); }},
    {tr("Move up"), [this] { MoveCurrentRow(moments_, -1); }},
    {tr("Move down"), [this] { MoveCurrentRow(moments_, 1); }},
  }), 1);
  return page;
}

void SettingsDialog::ReadDraft() {
  auto& controls = draft_.controls;
  controls.speed = speed_->value();
  controls.density = density_->value();
  controls.trailLength = trail_->value();
  controls.trailVariation = trailVariation_->value() / 100.0;
  controls.rampUpMilliseconds = ramp_->value() * 1000.0;
  controls.glyphRate = glyphRate_->value();
  controls.glyphScale = glyphScale_->value();
  controls.glow = glow_->value();
  controls.leadBrightness = leadBrightness_->value();
  controls.vignette = vignette_->value() / 100.0;
  controls.preset = StdUtf8(preset_->currentData().toString());
  controls.customColor = StdUtf8(customColor_->text());
  controls.glyphMode = static_cast<GlyphMode>(glyphMode_->currentIndex());
  controls.glyphFont = static_cast<GlyphFont>(glyphFont_->currentIndex());
  controls.quality = static_cast<QualityTier>(quality_->currentIndex());
  controls.mirror = mirror_->isChecked();
  controls.scanlines = scanlines_->isChecked();
  controls.allowOverlap = overlap_->isChecked();
  draft_.viewerName = StdUtf8(viewerName_->text());

  auto& intro = draft_.intro;
  intro.enabled = introEnabled_->isChecked();
  intro.lines.clear();
  for (int row = 0; row < introLines_->rowCount(); ++row) {
    const auto* textItem = introLines_->item(row, 0);
    const auto* holdItem = introLines_->item(row, 1);
    const auto* pauseItem = introLines_->item(row, 2);
    if (textItem == nullptr) continue;
    intro.lines.push_back({StdUtf8(textItem->text().left(120)),
      holdItem != nullptr ? holdItem->data(Qt::EditRole).toDouble() * 1000.0 : 2800.0,
      pauseItem != nullptr ? pauseItem->data(Qt::EditRole).toDouble() * 1000.0 : 0.0});
  }
  intro.charMilliseconds = charMilliseconds_->value();
  intro.startDelayMilliseconds = startDelay_->value() * 1000.0;
  intro.fadeOutMilliseconds = fadeOut_->value() * 1000.0;
  intro.rainDuringIntro = rainDuringIntro_->isChecked();
  intro.postIntroDelayMilliseconds = postIntroDelay_->value() * 1000.0;

  auto& messages = draft_.messages;
  messages.enabled = messagesEnabled_->isChecked();
  messages.messages.clear();
  for (int row = 0; row < messages_->count(); ++row) {
    const QString text = messages_->item(row)->text().trimmed().left(120);
    if (!text.isEmpty()) messages.messages.push_back(StdUtf8(text));
  }
  messages.frequencyMilliseconds = messageFrequency_->value() * 1000.0;
  messages.persistenceMilliseconds = messagePersistence_->value() * 1000.0;
  messages.appearMilliseconds = messageAppear_->value() * 1000.0;
  messages.disappearMilliseconds = messageDisappear_->value() * 1000.0;
  messages.flickerOut = messageFlicker_->isChecked();
  messages.brightnessFade = messageBrightness_->isChecked();
  messages.layout = messageLayout_->currentIndex() == 0 ? MessageLayout::Row : MessageLayout::Drop;
  messages.direction = messageDirection_->currentIndex() == 0
    ? MessageDirection::TopToBottom : MessageDirection::BottomToTop;
  messages.position = messagePosition_->value() / 100.0;
  messages.jitter = messageJitter_->value() / 100.0;
  messages.horizontalPosition = messageHorizontalPosition_->value() / 100.0;
  messages.horizontalJitter = messageHorizontalJitter_->value() / 100.0;

  auto& images = draft_.images;
  images.enabled = imagesEnabled_->isChecked();
  for (int row = 0; row < images_->rowCount() && row < static_cast<int>(images.images.size()); ++row) {
    if (const auto* item = images_->item(row, 0); item != nullptr) {
      images.images[static_cast<std::size_t>(row)].name = StdUtf8(item->text().left(80));
    }
  }
  images.frequencyMilliseconds = imageFrequency_->value() * 1000.0;
  images.persistenceMilliseconds = imagePersistence_->value() * 1000.0;
  images.appearMilliseconds = imageAppear_->value() * 1000.0;
  images.disappearMilliseconds = imageDisappear_->value() * 1000.0;
  images.flickerOut = imageFlicker_->isChecked();
  images.brightnessFade = imageBrightness_->isChecked();
  images.imageScale = imageScale_->value() / 100.0;
  images.placementJitter = imageJitter_->value() / 100.0;

  auto& countdown = draft_.countdown;
  countdown.targetMilliseconds = countdownEnabled_->isChecked()
    ? std::optional<double>(ToEpochMilliseconds(countdownTarget_->dateTime())) : std::nullopt;
  countdown.moments.clear();
  for (int row = 0; row < moments_->rowCount(); ++row) {
    const auto* enabled = qobject_cast<QCheckBox*>(moments_->cellWidget(row, 0));
    const auto* name = moments_->item(row, 1);
    const auto* target = qobject_cast<QDateTimeEdit*>(moments_->cellWidget(row, 2));
    if (name == nullptr || target == nullptr) continue;
    countdown.moments.push_back({StdUtf8(name->text().left(40)),
      enabled != nullptr && enabled->isChecked()
        ? std::optional<double>(ToEpochMilliseconds(target->dateTime())) : std::nullopt});
  }
  draft_ = SanitizeSettings(EncodeSettings(draft_));
}

void SettingsDialog::Populate(const SettingsSnapshot& settings) {
  draft_ = settings;
  const auto& controls = draft_.controls;
  speed_->setValue(controls.speed); density_->setValue(controls.density);
  trail_->setValue(controls.trailLength); trailVariation_->setValue(controls.trailVariation * 100.0);
  ramp_->setValue(controls.rampUpMilliseconds / 1000.0); glyphRate_->setValue(controls.glyphRate);
  glyphScale_->setValue(controls.glyphScale); glow_->setValue(controls.glow);
  leadBrightness_->setValue(controls.leadBrightness); vignette_->setValue(controls.vignette * 100.0);
  const int presetIndex = preset_->findData(Utf8(controls.preset));
  preset_->setCurrentIndex(presetIndex >= 0 ? presetIndex : 0);
  customColor_->setText(Utf8(controls.customColor));
  glyphMode_->setCurrentIndex(static_cast<int>(controls.glyphMode));
  glyphFont_->setCurrentIndex(static_cast<int>(controls.glyphFont));
  quality_->setCurrentIndex(static_cast<int>(controls.quality));
  mirror_->setChecked(controls.mirror); scanlines_->setChecked(controls.scanlines);
  overlap_->setChecked(controls.allowOverlap); viewerName_->setText(Utf8(draft_.viewerName));

  introEnabled_->setChecked(draft_.intro.enabled);
  introLines_->setRowCount(static_cast<int>(draft_.intro.lines.size()));
  for (int row = 0; row < introLines_->rowCount(); ++row) {
    const auto& line = draft_.intro.lines[static_cast<std::size_t>(row)];
    introLines_->setItem(row, 0, new QTableWidgetItem(Utf8(line.text)));
    auto* hold = new QTableWidgetItem; hold->setData(Qt::EditRole, line.holdMilliseconds / 1000.0);
    auto* pause = new QTableWidgetItem; pause->setData(Qt::EditRole, line.pauseMilliseconds / 1000.0);
    introLines_->setItem(row, 1, hold); introLines_->setItem(row, 2, pause);
  }
  charMilliseconds_->setValue(draft_.intro.charMilliseconds);
  startDelay_->setValue(draft_.intro.startDelayMilliseconds / 1000.0);
  fadeOut_->setValue(draft_.intro.fadeOutMilliseconds / 1000.0);
  rainDuringIntro_->setChecked(draft_.intro.rainDuringIntro);
  postIntroDelay_->setValue(draft_.intro.postIntroDelayMilliseconds / 1000.0);

  messagesEnabled_->setChecked(draft_.messages.enabled);
  messages_->clear();
  for (const auto& message : draft_.messages.messages) {
    auto* item = new QListWidgetItem(Utf8(message), messages_);
    item->setFlags(item->flags() | Qt::ItemIsEditable | Qt::ItemIsDragEnabled);
  }
  messageFrequency_->setValue(draft_.messages.frequencyMilliseconds / 1000.0);
  messagePersistence_->setValue(draft_.messages.persistenceMilliseconds / 1000.0);
  messageAppear_->setValue(draft_.messages.appearMilliseconds / 1000.0);
  messageDisappear_->setValue(draft_.messages.disappearMilliseconds / 1000.0);
  messageFlicker_->setChecked(draft_.messages.flickerOut);
  messageBrightness_->setChecked(draft_.messages.brightnessFade);
  messageLayout_->setCurrentIndex(draft_.messages.layout == MessageLayout::Row ? 0 : 1);
  messageDirection_->setCurrentIndex(draft_.messages.direction == MessageDirection::TopToBottom ? 0 : 1);
  messagePosition_->setValue(draft_.messages.position * 100.0);
  messageJitter_->setValue(draft_.messages.jitter * 100.0);
  messageHorizontalPosition_->setValue(draft_.messages.horizontalPosition * 100.0);
  messageHorizontalJitter_->setValue(draft_.messages.horizontalJitter * 100.0);

  imagesEnabled_->setChecked(draft_.images.enabled);
  imageFrequency_->setValue(draft_.images.frequencyMilliseconds / 1000.0);
  imagePersistence_->setValue(draft_.images.persistenceMilliseconds / 1000.0);
  imageAppear_->setValue(draft_.images.appearMilliseconds / 1000.0);
  imageDisappear_->setValue(draft_.images.disappearMilliseconds / 1000.0);
  imageFlicker_->setChecked(draft_.images.flickerOut);
  imageBrightness_->setChecked(draft_.images.brightnessFade);
  imageScale_->setValue(draft_.images.imageScale * 100.0);
  imageJitter_->setValue(draft_.images.placementJitter * 100.0);
  UpdateImageTable();

  countdownEnabled_->setChecked(draft_.countdown.targetMilliseconds.has_value());
  countdownTarget_->setEnabled(countdownEnabled_->isChecked());
  countdownTarget_->setDateTime(FromEpochMilliseconds(draft_.countdown.targetMilliseconds));
  moments_->setRowCount(static_cast<int>(draft_.countdown.moments.size()));
  for (int row = 0; row < moments_->rowCount(); ++row) {
    const auto& moment = draft_.countdown.moments[static_cast<std::size_t>(row)];
    auto* enabled = new QCheckBox;
    enabled->setChecked(moment.targetMilliseconds.has_value());
    enabled->setAccessibleName(tr("Enable moment %1").arg(row + 1));
    auto* target = new QDateTimeEdit(FromEpochMilliseconds(moment.targetMilliseconds));
    target->setCalendarPopup(true);
    target->setDisplayFormat("yyyy-MM-dd HH:mm:ss t");
    target->setEnabled(enabled->isChecked());
    connect(enabled, &QCheckBox::toggled, target, &QWidget::setEnabled);
    moments_->setCellWidget(row, 0, enabled);
    moments_->setItem(row, 1, new QTableWidgetItem(Utf8(moment.name)));
    moments_->setCellWidget(row, 2, target);
  }
}

void SettingsDialog::ResetCurrentPage() {
  ReadDraft();
  const SettingsSnapshot defaults = DefaultSettings();
  switch (static_cast<SettingsPage>(tabs_->currentIndex())) {
    case SettingsPage::Rain:
      draft_.controls = defaults.controls;
      draft_.viewerName = platform::SettingsStoreLinux::DefaultViewerName();
      break;
    case SettingsPage::Intro: draft_.intro = defaults.intro; break;
    case SettingsPage::Messages: draft_.messages = defaults.messages; break;
    case SettingsPage::Images: draft_.images = defaults.images; break;
    case SettingsPage::Countdown: draft_.countdown = defaults.countdown; break;
  }
  Populate(draft_);
}

void SettingsDialog::PreviewCurrentPage() {
  ReadDraft();
  if (previewCallback_) previewCallback_(draft_, static_cast<SettingsPage>(tabs_->currentIndex()));
}

void SettingsDialog::ImportImages() {
  ReadDraft();
  if (draft_.images.images.size() >= kMaximumImages) return;
  const QStringList files = QFileDialog::getOpenFileNames(
    this, tr("Import image masks"), {},
    tr("Images (*.png *.jpg *.jpeg *.webp *.gif *.bmp *.tif *.tiff *.svg);;All files (*)"));
  if (files.isEmpty()) return;
  std::size_t failed = 0;
  auto imported = platform::ImportImageMasksQt(
    files, static_cast<std::size_t>(kMaximumImages) - draft_.images.images.size(), &failed);
  draft_.images.images.insert(
    draft_.images.images.end(),
    std::make_move_iterator(imported.begin()), std::make_move_iterator(imported.end()));
  UpdateImageTable();
  if (failed != 0) {
    QMessageBox::warning(this, tr("Some images were skipped"),
      tr("%1 image(s) could not be decoded or did not contain a usable mask.").arg(failed));
  }
}

void SettingsDialog::ApplyMaximumImageVisibility() {
  ReadDraft();
  auto& images = draft_.images;
  images.enabled = true;
  images.frequencyMilliseconds = 500.0;
  images.persistenceMilliseconds = 60000.0;
  images.appearMilliseconds = 0.0;
  images.disappearMilliseconds = 0.0;
  images.flickerOut = false;
  images.brightnessFade = false;
  images.imageScale = 1.0;
  images.placementJitter = 0.0;
  auto& controls = draft_.controls;
  controls.density = 90.0;
  controls.rampUpMilliseconds = 0.0;
  controls.trailLength = 0.45;
  controls.trailVariation = 0.2;
  controls.speed = 0.6;
  controls.glyphScale = 0.7;
  controls.glow = 0.6;
  controls.leadBrightness = 1.0;
  controls.vignette = 0.0;
  controls.scanlines = false;
  controls.allowOverlap = false;
  controls.quality = QualityTier::High;
  controls.glyphMode = GlyphMode::Latin;
  controls.glyphFont = GlyphFont::Mono;
  controls.glyphRate = 1.0;
  controls.mirror = false;
  Populate(draft_);
}

void SettingsDialog::UpdateImageTable() {
  images_->setRowCount(static_cast<int>(draft_.images.images.size()));
  for (int row = 0; row < images_->rowCount(); ++row) {
    const auto& image = draft_.images.images[static_cast<std::size_t>(row)];
    images_->setItem(row, 0, new QTableWidgetItem(Utf8(image.name)));
    auto* dimensions = new QTableWidgetItem(
      tr("%1 × %2").arg(image.width).arg(image.height));
    dimensions->setFlags(dimensions->flags() & ~Qt::ItemIsEditable);
    auto* storage = new QTableWidgetItem(
      tr("%1 bytes").arg(static_cast<qulonglong>(image.luminance.size())));
    storage->setFlags(storage->flags() & ~Qt::ItemIsEditable);
    images_->setItem(row, 1, dimensions);
    images_->setItem(row, 2, storage);
  }
}

void SettingsDialog::MoveCurrentRow(QTableWidget* table, const int delta) {
  ReadDraft();
  const int source = table->currentRow();
  const int target = source + delta;
  if (source < 0 || target < 0 || target >= table->rowCount()) return;
  if (table == introLines_) {
    std::swap(draft_.intro.lines[static_cast<std::size_t>(source)], draft_.intro.lines[static_cast<std::size_t>(target)]);
  } else if (table == images_) {
    std::swap(draft_.images.images[static_cast<std::size_t>(source)], draft_.images.images[static_cast<std::size_t>(target)]);
  } else if (table == moments_) {
    std::swap(draft_.countdown.moments[static_cast<std::size_t>(source)], draft_.countdown.moments[static_cast<std::size_t>(target)]);
  }
  Populate(draft_);
  table->selectRow(target);
}

void SettingsDialog::RemoveCurrentRow(QTableWidget* table) {
  ReadDraft();
  const int row = table->currentRow();
  if (row < 0) return;
  if (table == introLines_ && draft_.intro.lines.size() > 1) {
    draft_.intro.lines.erase(draft_.intro.lines.begin() + row);
  } else if (table == images_) {
    draft_.images.images.erase(draft_.images.images.begin() + row);
  } else if (table == moments_) {
    draft_.countdown.moments.erase(draft_.countdown.moments.begin() + row);
  }
  Populate(draft_);
}

void SettingsDialog::AddIntroLine() {
  ReadDraft();
  if (draft_.intro.lines.size() >= kMaximumLines) return;
  draft_.intro.lines.push_back({"New line", 2800.0, 0.0});
  Populate(draft_);
  introLines_->selectRow(introLines_->rowCount() - 1);
  introLines_->editItem(introLines_->item(introLines_->rowCount() - 1, 0));
}

void SettingsDialog::AddMessage() {
  if (messages_->count() >= kMaximumMessages) return;
  auto* item = new QListWidgetItem(tr("New message"), messages_);
  item->setFlags(item->flags() | Qt::ItemIsEditable | Qt::ItemIsDragEnabled);
  messages_->setCurrentItem(item);
  messages_->editItem(item);
}

void SettingsDialog::AddMoment() {
  ReadDraft();
  if (draft_.countdown.moments.size() >= kMaximumMoments) return;
  draft_.countdown.moments.push_back({"moment", ToEpochMilliseconds(QDateTime::currentDateTime().addDays(1))});
  Populate(draft_);
  moments_->selectRow(moments_->rowCount() - 1);
  moments_->editItem(moments_->item(moments_->rowCount() - 1, 1));
}

void SettingsDialog::EditPortableJson() {
  ReadDraft();
  QDialog editor(this);
  editor.setWindowTitle(tr("Edit portable settings JSON"));
  editor.resize(760, 620);
  auto* layout = new QVBoxLayout(&editor);
  layout->addWidget(Hint(tr("This is the same versioned settings document used by the Windows native app. Invalid and out-of-range values are rejected or sanitized when applied.")));
  auto* text = new QPlainTextEdit;
  text->setLineWrapMode(QPlainTextEdit::NoWrap);
  text->setFont(QFontDatabase::systemFont(QFontDatabase::FixedFont));
  text->setPlainText(QString::fromUtf8(EncodeSettingsUtf8(draft_, true)));
  layout->addWidget(text, 1);
  auto* buttons = new QDialogButtonBox(QDialogButtonBox::Apply | QDialogButtonBox::Cancel);
  layout->addWidget(buttons);
  connect(buttons, &QDialogButtonBox::rejected, &editor, &QDialog::reject);
  connect(buttons->button(QDialogButtonBox::Apply), &QPushButton::clicked, &editor, [this, text, &editor] {
    std::string error;
    const QByteArray utf8 = text->toPlainText().toUtf8();
    const auto decoded = DecodeSettings(
      std::string_view(utf8.constData(), static_cast<std::size_t>(utf8.size())), &error);
    if (!decoded.has_value()) {
      QMessageBox::warning(&editor, tr("Invalid settings JSON"), Utf8(error));
      return;
    }
    Populate(*decoded);
    editor.accept();
  });
  editor.exec();
}

void SettingsDialog::ImportPortableJson() {
  const QString path = QFileDialog::getOpenFileName(
    this, tr("Import Matrix Code settings"), {}, tr("JSON files (*.json);;All files (*)"));
  if (path.isEmpty()) return;
  QFile file(path);
  if (!file.open(QIODevice::ReadOnly) || file.size() < 0 ||
      file.size() > kMaximumPortableSettingsBytes) {
    QMessageBox::warning(this, tr("Could not import settings"),
      tr("The file could not be read or is larger than 8 MiB."));
    return;
  }
  const QByteArray contents = file.readAll();
  std::string error;
  const auto decoded = DecodeSettings(
    std::string_view(contents.constData(), static_cast<std::size_t>(contents.size())), &error);
  if (!decoded.has_value()) {
    QMessageBox::warning(this, tr("Invalid settings JSON"), Utf8(error));
    return;
  }
  Populate(*decoded);
}

void SettingsDialog::ExportPortableJson() {
  ReadDraft();
  const QString path = QFileDialog::getSaveFileName(
    this, tr("Export Matrix Code settings"), QStringLiteral("matrixcode-settings.json"),
    tr("JSON files (*.json)"));
  if (path.isEmpty()) return;
  QSaveFile file(path);
  const std::string encoded = EncodeSettingsUtf8(draft_, true);
  if (!file.open(QIODevice::WriteOnly) ||
      file.write(encoded.data(), static_cast<qint64>(encoded.size())) != static_cast<qint64>(encoded.size()) ||
      !file.commit()) {
    QMessageBox::warning(this, tr("Could not export settings"), file.errorString());
  }
}

}  // namespace matrixcode::ui
