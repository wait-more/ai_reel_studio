#include "flutter_window.h"

#include <optional>

#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"
#include "ime_context.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

HWND FlutterWindow::FlutterViewHwnd() const {
  if (!flutter_controller_ || !flutter_controller_->view()) {
    return nullptr;
  }
  return flutter_controller_->view()->GetNativeWindow();
}

void FlutterWindow::RefreshFlutterViewIme() {
  RefreshWindowImeContext(FlutterViewHwnd());
}

void FlutterWindow::RegisterImeChannel() {
  if (!flutter_controller_ || !flutter_controller_->engine()) {
    return;
  }
  ime_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "ai_reel_studio/windows_ime",
          &flutter::StandardMethodCodec::GetInstance());
  ime_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "refresh") {
          RefreshFlutterViewIme();
          result->Success();
          return;
        }
        result->NotImplemented();
      });
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  RegisterImeChannel();
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Do not call Show() on the first frame. Win32Window::Show uses
  // SW_SHOWNORMAL, which restores a maximized window back to a normal size.
  // Visibility is controlled by windowManager.show() on the Dart side.
  // ForceRedraw still paints the first frame while the window stays hidden.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  ime_channel_.reset();
  DestroyOwnedImeContext();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      // Flutter may consume WM_ACTIVATE; still refresh IME on reactivation.
      if (message == WM_ACTIVATE && LOWORD(wparam) != WA_INACTIVE) {
        RefreshFlutterViewIme();
      }
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_ACTIVATE: {
      // Focus child first (base handler), then rotate HIMC.
      const LRESULT base =
          Win32Window::MessageHandler(hwnd, message, wparam, lparam);
      if (LOWORD(wparam) != WA_INACTIVE) {
        RefreshFlutterViewIme();
      }
      return base;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
