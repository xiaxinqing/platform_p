#ifndef PLATFORM_P_NATIVE_PJSIP_SERVICE_H_
#define PLATFORM_P_NATIVE_PJSIP_SERVICE_H_

#include <atomic>
#include <functional>
#include <mutex>
#include <string>

struct pjsip_event;
struct pjsip_rx_data;

namespace platform_p {

struct PjsipEvent {
  std::string type;
  std::string state;
  int level = 0;
  std::string message;
  int account_id = -1;
  int status = 0;
  int expires = 0;
  bool registered = false;
  int call_id = -1;
  int call_state = 0;
  int media_status = 0;
  int last_status = 0;
  bool incoming = false;
  std::string remote_uri;
};

struct PjsipResult {
  bool success = false;
  std::string state;
  int status = 0;
  std::string message;
  int account_id = -1;
  int call_id = -1;
};

struct PjsipAccountConfig {
  std::string username;
  std::string auth_username;
  std::string password;
  std::string host;
  std::string transport = "udp";
};

class PjsipService {
 public:
  using EventCallback = std::function<void(const PjsipEvent&)>;

  PjsipService();
  ~PjsipService();
  PjsipService(const PjsipService&) = delete;
  PjsipService& operator=(const PjsipService&) = delete;

  void SetEventCallback(EventCallback callback);
  PjsipResult Initialize();
  PjsipResult GetStatus() const;
  PjsipResult RegisterAccount(const PjsipAccountConfig& config);
  PjsipResult UnregisterAccount();
  PjsipResult MakeCall(const std::string& destination);
  PjsipResult AnswerCall(int call_id);
  PjsipResult RejectCall(int call_id);
  PjsipResult HangupCall(int call_id);
  PjsipResult Shutdown();

 private:
  static void NativeLogCallback(int level, const char* data, int length);
  static void RegistrationStateCallback(int account_id);
  static void IncomingCallCallback(int account_id,
                                   int call_id,
                                   ::pjsip_rx_data* data);
  static void CallStateCallback(int call_id, ::pjsip_event* event);
  static void CallMediaStateCallback(int call_id);
  PjsipResult Fail(const std::string& step, int status);
  void ConfigureCodecs();
  void Emit(const PjsipEvent& event) const;
  void EmitLog(int level, const std::string& message) const;
  void EmitStatus(const std::string& state, const std::string& message) const;
  void EmitRegistration(int account_id,
                        int status,
                        int expires,
                        bool registered,
                        const std::string& message) const;
  void EmitCall(int call_id, bool incoming, const std::string& message) const;

  static std::atomic<PjsipService*> active_service_;
  mutable std::mutex lifecycle_mutex_;
  mutable std::mutex callback_mutex_;
  EventCallback event_callback_;
  bool created_ = false;
  bool initialized_ = false;
  int udp_transport_id_ = -1;
  int tcp_transport_id_ = -1;
  int account_id_ = -1;
  std::atomic<int> active_call_id_{-1};
  std::string account_host_;
  std::string account_transport_ = "udp";
};

}  // namespace platform_p

#endif  // PLATFORM_P_NATIVE_PJSIP_SERVICE_H_
