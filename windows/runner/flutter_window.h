#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>
#include <mutex>
#include <vector>

#include "../../native/pjsip_service.h"
#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void ConfigurePjsipChannel();
  void EnqueuePjsipEvent(const platform_p::PjsipEvent& event);
  void FlushPjsipEvents();

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      pjsip_channel_;
  std::unique_ptr<platform_p::PjsipService> pjsip_service_;
  std::mutex pjsip_event_mutex_;
  std::vector<platform_p::PjsipEvent> pending_pjsip_events_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
