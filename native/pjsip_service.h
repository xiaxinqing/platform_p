#ifndef PLATFORM_P_NATIVE_PJSIP_SERVICE_H_
#define PLATFORM_P_NATIVE_PJSIP_SERVICE_H_

#include <atomic>
#include <functional>
#include <mutex>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

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
  std::string account_uri;
  std::string capture_device;
  std::string playback_device;
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
  int port = 0;
  std::string media_security = "none";
  bool stun_enabled = false;
  std::string stun_server;
  int stun_port = 3478;
  bool ice_enabled = false;
  bool tls_verify_server = false;
};

struct PjsipAccountRuntime {
  std::string username;
  std::string host;
  std::string transport;
  int port = 0;
  std::string media_security;
  bool stun_enabled = false;
  std::string stun_server;
  int stun_port = 3478;
  bool ice_enabled = false;
  bool tls_verify_server = false;
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
  PjsipResult UnregisterAccount(int account_id);
  PjsipResult MakeCall(const std::string& destination, int account_id);
  PjsipResult AnswerCall(int call_id);
  PjsipResult RejectCall(int call_id);
  PjsipResult HangupCall(int call_id);
  PjsipResult HoldCall(int call_id);
  PjsipResult ResumeCall(int call_id);
  PjsipResult TransferCall(int call_id, const std::string& destination);
  PjsipResult SetMicrophoneMuted(bool muted);
  PjsipResult SetSpeakerMuted(bool muted);
  PjsipResult SendDtmf(int call_id, const std::string& digits);
  PjsipResult GetAudioLevels(int call_id,
                              unsigned* microphone_level,
                              unsigned* remote_level);
  PjsipResult SetAutoHoldOnIncoming(bool enabled);
  PjsipResult ConfigureAudioCues(const std::string& ringtone_path,
                                 const std::string& ringback_path,
                                 const std::string& hangup_path);
  PjsipResult RefreshSystemAudioDevices();
  PjsipResult HandleNetworkChange();
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
  void HoldOtherConfirmedCalls(int except_call_id);
  void ConnectCallAudio(int call_id, bool connect);
  void RefreshAudioCues();
  void HandleCallAudioCueState(int call_id, int call_state);
  void StartAudioCueLocked(const std::string& path,
                           bool loop,
                           int* player_id);
  void StopAudioCueLocked(int* player_id);
  void StopAllAudioCues();
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
  mutable std::mutex audio_cue_mutex_;
  EventCallback event_callback_;
  bool created_ = false;
  bool initialized_ = false;
  int udp_transport_id_ = -1;
  int tcp_transport_id_ = -1;
  int tls_transport_id_ = -1;
  int tls_verified_transport_id_ = -1;
  std::atomic<int> active_audio_call_id_{-1};
  std::atomic<bool> auto_hold_on_incoming_{true};
  std::string ringtone_path_;
  std::string ringback_path_;
  std::string hangup_path_;
  int ringtone_player_id_ = -1;
  int ringback_player_id_ = -1;
  int hangup_player_id_ = -1;
  std::unordered_set<int> connected_call_ids_;
  std::unordered_set<int> hangup_played_call_ids_;
  std::unordered_map<int, PjsipAccountRuntime> accounts_;
  std::vector<std::string> stun_servers_;
};

}  // namespace platform_p

#endif  // PLATFORM_P_NATIVE_PJSIP_SERVICE_H_
