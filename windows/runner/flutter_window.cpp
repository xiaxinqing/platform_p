#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <functiondiscoverykeys_devpkey.h>
#include <mmdeviceapi.h>

#include <atomic>
#include <cstdint>
#include <functional>
#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"

namespace {

constexpr UINT kPjsipEventMessage = WM_APP + 0x51;
constexpr UINT kAudioDeviceChangedMessage = WM_APP + 0x52;

flutter::EncodableMap PjsipResultMap(const platform_p::PjsipResult& result) {
  return {
      {flutter::EncodableValue("success"),
       flutter::EncodableValue(result.success)},
      {flutter::EncodableValue("state"),
       flutter::EncodableValue(result.state)},
      {flutter::EncodableValue("status"),
       flutter::EncodableValue(result.status)},
      {flutter::EncodableValue("message"),
       flutter::EncodableValue(result.message)},
      {flutter::EncodableValue("accountId"),
       flutter::EncodableValue(result.account_id)},
      {flutter::EncodableValue("callId"),
       flutter::EncodableValue(result.call_id)},
  };
}

flutter::EncodableValue PjsipResultValue(
    const platform_p::PjsipResult& result) {
  return flutter::EncodableValue(PjsipResultMap(result));
}

flutter::EncodableValue PjsipEventValue(
    const platform_p::PjsipEvent& event) {
  return flutter::EncodableMap{
      {flutter::EncodableValue("type"),
       flutter::EncodableValue(event.type)},
      {flutter::EncodableValue("state"),
       flutter::EncodableValue(event.state)},
      {flutter::EncodableValue("level"),
       flutter::EncodableValue(event.level)},
      {flutter::EncodableValue("message"),
       flutter::EncodableValue(event.message)},
      {flutter::EncodableValue("accountId"),
       flutter::EncodableValue(event.account_id)},
      {flutter::EncodableValue("status"),
       flutter::EncodableValue(event.status)},
      {flutter::EncodableValue("expires"),
       flutter::EncodableValue(event.expires)},
      {flutter::EncodableValue("registered"),
       flutter::EncodableValue(event.registered)},
      {flutter::EncodableValue("callId"),
       flutter::EncodableValue(event.call_id)},
      {flutter::EncodableValue("callState"),
       flutter::EncodableValue(event.call_state)},
      {flutter::EncodableValue("mediaStatus"),
       flutter::EncodableValue(event.media_status)},
      {flutter::EncodableValue("lastStatus"),
       flutter::EncodableValue(event.last_status)},
      {flutter::EncodableValue("incoming"),
       flutter::EncodableValue(event.incoming)},
      {flutter::EncodableValue("remoteUri"),
       flutter::EncodableValue(event.remote_uri)},
      {flutter::EncodableValue("accountUri"),
       flutter::EncodableValue(event.account_uri)},
      {flutter::EncodableValue("captureDevice"),
       flutter::EncodableValue(event.capture_device)},
      {flutter::EncodableValue("playbackDevice"),
       flutter::EncodableValue(event.playback_device)},
  };
}

const flutter::EncodableMap* Arguments(
    const flutter::MethodCall<flutter::EncodableValue>& call) {
  if (!call.arguments()) {
    return nullptr;
  }
  return std::get_if<flutter::EncodableMap>(call.arguments());
}

const flutter::EncodableValue* ArgumentValue(
    const flutter::EncodableMap* arguments, const std::string& key) {
  if (!arguments) {
    return nullptr;
  }
  const auto entry = arguments->find(flutter::EncodableValue(key));
  return entry == arguments->end() ? nullptr : &entry->second;
}

std::string ArgumentString(const flutter::EncodableMap* arguments,
                           const std::string& key) {
  const auto* value = ArgumentValue(arguments, key);
  const auto* text = value ? std::get_if<std::string>(value) : nullptr;
  return text ? *text : std::string();
}

int ArgumentInt(const flutter::EncodableMap* arguments,
                const std::string& key, int fallback = -1) {
  const auto* value = ArgumentValue(arguments, key);
  if (!value) {
    return fallback;
  }
  if (const auto* number = std::get_if<int32_t>(value)) {
    return *number;
  }
  if (const auto* number = std::get_if<int64_t>(value)) {
    return static_cast<int>(*number);
  }
  return fallback;
}

bool ArgumentBool(const flutter::EncodableMap* arguments,
                  const std::string& key, bool fallback = false) {
  const auto* value = ArgumentValue(arguments, key);
  const auto* boolean = value ? std::get_if<bool>(value) : nullptr;
  return boolean ? *boolean : fallback;
}

}  // namespace

class WindowsAudioDeviceMonitor : public IMMNotificationClient {
 public:
  explicit WindowsAudioDeviceMonitor(std::function<void()> on_change)
      : on_change_(std::move(on_change)) {}

  bool Start() {
    if (enumerator_) {
      return true;
    }
    HRESULT status = CoCreateInstance(
        __uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
        __uuidof(IMMDeviceEnumerator),
        reinterpret_cast<void**>(&enumerator_));
    if (FAILED(status)) {
      return false;
    }
    status = enumerator_->RegisterEndpointNotificationCallback(this);
    if (FAILED(status)) {
      enumerator_->Release();
      enumerator_ = nullptr;
      return false;
    }
    registered_ = true;
    return true;
  }

  void Stop() {
    if (enumerator_) {
      if (registered_) {
        enumerator_->UnregisterEndpointNotificationCallback(this);
      }
      enumerator_->Release();
      enumerator_ = nullptr;
      registered_ = false;
    }
  }

  std::string CaptureDeviceName() const {
    return DefaultDeviceName(eCapture, "Windows system default input");
  }

  std::string PlaybackDeviceName() const {
    return DefaultDeviceName(eRender, "Windows system default output");
  }

  void ClearPending() { notification_pending_.store(false); }

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** object) override {
    if (!object) {
      return E_POINTER;
    }
    if (iid == __uuidof(IUnknown) || iid == __uuidof(IMMNotificationClient)) {
      *object = static_cast<IMMNotificationClient*>(this);
      AddRef();
      return S_OK;
    }
    *object = nullptr;
    return E_NOINTERFACE;
  }

  ULONG STDMETHODCALLTYPE AddRef() override { return ++reference_count_; }

  ULONG STDMETHODCALLTYPE Release() override {
    const ULONG count = --reference_count_;
    if (count == 0) {
      delete this;
    }
    return count;
  }

  HRESULT STDMETHODCALLTYPE OnDefaultDeviceChanged(
      EDataFlow, ERole, LPCWSTR) override {
    if (!notification_pending_.exchange(true) && on_change_) {
      on_change_();
    }
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE OnDeviceAdded(LPCWSTR) override { return S_OK; }
  HRESULT STDMETHODCALLTYPE OnDeviceRemoved(LPCWSTR) override { return S_OK; }
  HRESULT STDMETHODCALLTYPE OnDeviceStateChanged(LPCWSTR, DWORD) override {
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE OnPropertyValueChanged(
      LPCWSTR, const PROPERTYKEY) override {
    return S_OK;
  }

 private:
  ~WindowsAudioDeviceMonitor() { Stop(); }

  std::string DefaultDeviceName(EDataFlow flow,
                                const char* fallback) const {
    if (!enumerator_) {
      return fallback;
    }
    IMMDevice* device = nullptr;
    if (FAILED(enumerator_->GetDefaultAudioEndpoint(flow, eConsole, &device))) {
      return fallback;
    }
    IPropertyStore* properties = nullptr;
    if (FAILED(device->OpenPropertyStore(STGM_READ, &properties))) {
      device->Release();
      return fallback;
    }
    PROPVARIANT value;
    PropVariantInit(&value);
    std::string name = fallback;
    if (SUCCEEDED(properties->GetValue(PKEY_Device_FriendlyName, &value)) &&
        value.vt == VT_LPWSTR && value.pwszVal) {
      const int length = WideCharToMultiByte(
          CP_UTF8, 0, value.pwszVal, -1, nullptr, 0, nullptr, nullptr);
      if (length > 1) {
        std::string utf8(static_cast<size_t>(length), '\0');
        WideCharToMultiByte(CP_UTF8, 0, value.pwszVal, -1, utf8.data(),
                            length, nullptr, nullptr);
        utf8.resize(static_cast<size_t>(length - 1));
        name = utf8;
      }
    }
    PropVariantClear(&value);
    properties->Release();
    device->Release();
    return name;
  }

  std::atomic<ULONG> reference_count_{1};
  std::atomic<bool> notification_pending_{false};
  IMMDeviceEnumerator* enumerator_ = nullptr;
  bool registered_ = false;
  std::function<void()> on_change_;
};

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

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
  ConfigurePjsipChannel();
  audio_device_monitor_ = new WindowsAudioDeviceMonitor([this]() {
    PostMessage(GetHandle(), kAudioDeviceChangedMessage, 0, 0);
  });
  audio_device_monitor_->Start();
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (audio_device_monitor_) {
    audio_device_monitor_->Stop();
    audio_device_monitor_->Release();
    audio_device_monitor_ = nullptr;
  }
  if (pjsip_service_) {
    pjsip_service_->Shutdown();
    FlushPjsipEvents();
    pjsip_service_->SetEventCallback(nullptr);
    pjsip_service_.reset();
  }
  pjsip_channel_.reset();

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
      return *result;
    }
  }

  switch (message) {
    case kPjsipEventMessage:
      FlushPjsipEvents();
      return 0;
    case kAudioDeviceChangedMessage:
      HandleAudioDeviceChange();
      return 0;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::ConfigurePjsipChannel() {
  pjsip_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "platform_p/pjsip",
          &flutter::StandardMethodCodec::GetInstance());
  pjsip_service_ = std::make_unique<platform_p::PjsipService>();
  pjsip_service_->SetEventCallback(
      [this](const platform_p::PjsipEvent& event) {
        EnqueuePjsipEvent(event);
      });

  pjsip_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "initialize") {
          result->Success(PjsipResultValue(pjsip_service_->Initialize()));
          return;
        }
        if (call.method_name() == "status") {
          result->Success(PjsipResultValue(pjsip_service_->GetStatus()));
          return;
        }
        const auto* arguments = Arguments(call);
        if (call.method_name() == "registerAccount") {
          platform_p::PjsipAccountConfig config;
          config.username = ArgumentString(arguments, "username");
          config.auth_username = ArgumentString(arguments, "authUsername");
          config.password = ArgumentString(arguments, "password");
          config.host = ArgumentString(arguments, "host");
          config.transport = ArgumentString(arguments, "transport");
          config.port = ArgumentInt(arguments, "port", 0);
          config.media_security =
              ArgumentString(arguments, "mediaSecurity");
          config.stun_enabled = ArgumentBool(arguments, "stunEnabled");
          config.stun_server = ArgumentString(arguments, "stunServer");
          config.stun_port = ArgumentInt(arguments, "stunPort", 3478);
          config.ice_enabled = ArgumentBool(arguments, "iceEnabled");
          config.tls_verify_server =
              ArgumentBool(arguments, "tlsVerifyServer");
          if (config.transport.empty()) {
            config.transport = "udp";
          }
          if (config.media_security.empty()) {
            config.media_security = "none";
          }
          result->Success(PjsipResultValue(
              pjsip_service_->RegisterAccount(config)));
          return;
        }
        if (call.method_name() == "unregisterAccount") {
          result->Success(PjsipResultValue(pjsip_service_->UnregisterAccount(
              ArgumentInt(arguments, "accountId"))));
          return;
        }
        if (call.method_name() == "makeCall") {
          result->Success(PjsipResultValue(pjsip_service_->MakeCall(
              ArgumentString(arguments, "destination"),
              ArgumentInt(arguments, "accountId"))));
          return;
        }
        const int call_id = ArgumentInt(arguments, "callId");
        if (call.method_name() == "answerCall") {
          result->Success(
              PjsipResultValue(pjsip_service_->AnswerCall(call_id)));
          return;
        }
        if (call.method_name() == "rejectCall") {
          result->Success(
              PjsipResultValue(pjsip_service_->RejectCall(call_id)));
          return;
        }
        if (call.method_name() == "hangupCall") {
          result->Success(
              PjsipResultValue(pjsip_service_->HangupCall(call_id)));
          return;
        }
        if (call.method_name() == "holdCall") {
          result->Success(
              PjsipResultValue(pjsip_service_->HoldCall(call_id)));
          return;
        }
        if (call.method_name() == "resumeCall") {
          result->Success(
              PjsipResultValue(pjsip_service_->ResumeCall(call_id)));
          return;
        }
        if (call.method_name() == "setMicrophoneMuted") {
          result->Success(PjsipResultValue(
              pjsip_service_->SetMicrophoneMuted(
                  ArgumentBool(arguments, "muted"))));
          return;
        }
        if (call.method_name() == "setSpeakerMuted") {
          result->Success(PjsipResultValue(
              pjsip_service_->SetSpeakerMuted(
                  ArgumentBool(arguments, "muted"))));
          return;
        }
        if (call.method_name() == "sendDtmf") {
          result->Success(PjsipResultValue(pjsip_service_->SendDtmf(
              call_id, ArgumentString(arguments, "digits"))));
          return;
        }
        if (call.method_name() == "transferCall") {
          result->Success(PjsipResultValue(pjsip_service_->TransferCall(
              call_id, ArgumentString(arguments, "destination"))));
          return;
        }
        if (call.method_name() == "getAudioLevels") {
          unsigned microphone_level = 0;
          unsigned remote_level = 0;
          const auto native_result = pjsip_service_->GetAudioLevels(
              call_id, &microphone_level, &remote_level);
          auto response = PjsipResultMap(native_result);
          response[flutter::EncodableValue("microphoneLevel")] =
              flutter::EncodableValue(static_cast<int>(microphone_level));
          response[flutter::EncodableValue("remoteLevel")] =
              flutter::EncodableValue(static_cast<int>(remote_level));
          result->Success(flutter::EncodableValue(response));
          return;
        }
        if (call.method_name() == "setAutoHoldOnIncoming") {
          result->Success(PjsipResultValue(
              pjsip_service_->SetAutoHoldOnIncoming(
                  ArgumentBool(arguments, "enabled"))));
          return;
        }
        if (call.method_name() == "configureAudioCues") {
          result->Success(PjsipResultValue(
              pjsip_service_->ConfigureAudioCues(
                  ArgumentString(arguments, "ringtonePath"),
                  ArgumentString(arguments, "ringbackPath"),
                  ArgumentString(arguments, "hangupPath"))));
          return;
        }
        if (call.method_name() == "handleNetworkChange") {
          result->Success(
              PjsipResultValue(pjsip_service_->HandleNetworkChange()));
          return;
        }
        if (call.method_name() == "getAudioDeviceState") {
          const std::string capture = audio_device_monitor_
                                          ? audio_device_monitor_->CaptureDeviceName()
                                          : "Windows system default input";
          const std::string playback = audio_device_monitor_
                                           ? audio_device_monitor_->PlaybackDeviceName()
                                           : "Windows system default output";
          result->Success(flutter::EncodableValue(flutter::EncodableMap{
              {flutter::EncodableValue("state"),
               flutter::EncodableValue("ready")},
              {flutter::EncodableValue("captureDevice"),
               flutter::EncodableValue(capture)},
              {flutter::EncodableValue("playbackDevice"),
               flutter::EncodableValue(playback)},
              {flutter::EncodableValue("message"),
               flutter::EncodableValue(
                   "Audio devices follow Windows system settings")},
          }));
          return;
        }
        if (call.method_name() == "shutdown") {
          result->Success(PjsipResultValue(pjsip_service_->Shutdown()));
          return;
        }
        result->NotImplemented();
      });
}

void FlutterWindow::HandleAudioDeviceChange() {
  if (!audio_device_monitor_ || !pjsip_service_) {
    return;
  }
  audio_device_monitor_->ClearPending();
  const platform_p::PjsipResult result =
      pjsip_service_->RefreshSystemAudioDevices();
  platform_p::PjsipEvent event;
  event.type = "audioDevice";
  event.state = result.success ? "ready" : "error";
  event.message = result.message;
  event.capture_device = audio_device_monitor_->CaptureDeviceName();
  event.playback_device = audio_device_monitor_->PlaybackDeviceName();
  EnqueuePjsipEvent(event);
}

void FlutterWindow::EnqueuePjsipEvent(
    const platform_p::PjsipEvent& event) {
  {
    std::lock_guard<std::mutex> lock(pjsip_event_mutex_);
    pending_pjsip_events_.push_back(event);
  }
  PostMessage(GetHandle(), kPjsipEventMessage, 0, 0);
}

void FlutterWindow::FlushPjsipEvents() {
  std::vector<platform_p::PjsipEvent> events;
  {
    std::lock_guard<std::mutex> lock(pjsip_event_mutex_);
    events.swap(pending_pjsip_events_);
  }
  if (!pjsip_channel_) {
    return;
  }
  for (const auto& event : events) {
    pjsip_channel_->InvokeMethod(
        "event", std::make_unique<flutter::EncodableValue>(
                     PjsipEventValue(event)));
  }
}
