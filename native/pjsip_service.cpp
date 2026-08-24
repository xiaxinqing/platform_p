#include "pjsip_service.h"

#include <pjsua-lib/pjsua.h>

#include <cstdio>
#include <utility>

#ifdef _WIN32
#include <Windows.h>
#endif

namespace platform_p {

std::atomic<PjsipService*> PjsipService::active_service_(nullptr);

namespace {

constexpr int kRuntimeLogLevel = 4;

std::string StatusDescription(int status) {
  char buffer[PJ_ERR_MSG_SIZE] = {};
  const pj_str_t description =
      pj_strerror(static_cast<pj_status_t>(status), buffer, sizeof(buffer));
  return std::string(description.ptr, static_cast<size_t>(description.slen));
}

void PrintNativeLog(int level, const std::string& message) {
  std::fprintf(stderr, "[PJSIP][L%d] %s\n", level, message.c_str());
  std::fflush(stderr);
#ifdef _WIN32
  const std::string line =
      "[PJSIP][L" + std::to_string(level) + "] " + message + "\n";
  OutputDebugStringA(line.c_str());
#endif
}

pj_str_t StringRef(std::string& value) {
  pj_str_t result;
  result.ptr = const_cast<char*>(value.c_str());
  result.slen = static_cast<pj_ssize_t>(value.size());
  return result;
}

}  // namespace

PjsipService::PjsipService() = default;

PjsipService::~PjsipService() {
  SetEventCallback(nullptr);
  Shutdown();
}

void PjsipService::SetEventCallback(EventCallback callback) {
  std::lock_guard<std::mutex> lock(callback_mutex_);
  event_callback_ = std::move(callback);
}

PjsipResult PjsipService::Initialize() {
  std::lock_guard<std::mutex> lock(lifecycle_mutex_);
  if (initialized_) {
    return {true, "started", PJ_SUCCESS, "PJSIP is already initialized"};
  }

  EmitStatus("initializing", "Starting native PJSIP initialization");
  EmitLog(kRuntimeLogLevel,
          "Configuration: log=4, media=8000Hz/mono, maxCalls=4");

  pj_status_t status = pjsua_create();
  if (status != PJ_SUCCESS) {
    return Fail("pjsua_create", status);
  }
  created_ = true;
  active_service_.store(this);
  EmitLog(4, "pjsua_create succeeded");

  pjsua_config ua_config;
  pjsua_logging_config log_config;
  pjsua_media_config media_config;
  pjsua_config_default(&ua_config);
  pjsua_logging_config_default(&log_config);
  pjsua_media_config_default(&media_config);

  ua_config.max_calls = 4;
  ua_config.cb.on_reg_state = &PjsipService::RegistrationStateCallback;
  ua_config.cb.on_incoming_call = &PjsipService::IncomingCallCallback;
  ua_config.cb.on_call_state = &PjsipService::CallStateCallback;
  ua_config.cb.on_call_media_state = &PjsipService::CallMediaStateCallback;
  ua_config.use_timer = PJSUA_SIP_TIMER_INACTIVE;
  ua_config.stun_srv_cnt = 0;
  ua_config.stun_try_ipv6 = PJ_FALSE;
  ua_config.nat_type_in_sdp = 0;
  media_config.clock_rate = 8000;
  media_config.channel_count = 1;
  media_config.ec_tail_len = 20;
  log_config.msg_logging = PJ_TRUE;
  log_config.level = kRuntimeLogLevel;
  log_config.console_level = kRuntimeLogLevel;
  log_config.cb = &PjsipService::NativeLogCallback;

  status = pjsua_init(&ua_config, &log_config, &media_config);
  if (status != PJ_SUCCESS) {
    return Fail("pjsua_init", status);
  }
  EmitLog(4, "pjsua_init succeeded");

  pjsua_transport_config transport_config;
  pjsua_transport_config_default(&transport_config);
  transport_config.port = 0;
  status = pjsua_transport_create(PJSIP_TRANSPORT_UDP, &transport_config,
                                  &udp_transport_id_);
  if (status != PJ_SUCCESS) {
    return Fail("pjsua_transport_create(UDP)", status);
  }
  EmitLog(4, "UDP transport created with a system-assigned port");

  pjsua_transport_config_default(&transport_config);
  transport_config.port = 0;
  status = pjsua_transport_create(PJSIP_TRANSPORT_TCP, &transport_config,
                                  &tcp_transport_id_);
  if (status != PJ_SUCCESS) {
    return Fail("pjsua_transport_create(TCP)", status);
  }
  EmitLog(4, "TCP transport created with a system-assigned port");

  status = pjsua_start();
  if (status != PJ_SUCCESS) {
    return Fail("pjsua_start", status);
  }

  initialized_ = true;
  ConfigureCodecs();
  EmitLog(3, "PJSIP native engine started successfully");
  EmitStatus("started", "PJSIP initialization completed");
  return {true, "started", PJ_SUCCESS,
          "PJSIP native engine started successfully"};
}

PjsipResult PjsipService::GetStatus() const {
  std::lock_guard<std::mutex> lock(lifecycle_mutex_);
  if (initialized_) {
    return {true, "started", PJ_SUCCESS, "PJSIP is running"};
  }
  if (created_) {
    return {false, "created", PJ_SUCCESS, "PJSIP is not fully initialized"};
  }
  return {true, "idle", PJ_SUCCESS, "PJSIP is not initialized"};
}

PjsipResult PjsipService::RegisterAccount(
    const PjsipAccountConfig& config) {
  std::lock_guard<std::mutex> lock(lifecycle_mutex_);
  if (!initialized_) {
    return {false, "error", PJ_EINVALIDOP,
            "PJSIP must be initialized before registering an account"};
  }
  if (config.username.empty() || config.password.empty() ||
      config.host.empty()) {
    return {false, "started", PJ_EINVAL,
            "Username, password and host are required"};
  }
  if (account_id_ != PJSUA_INVALID_ID && pjsua_acc_is_valid(account_id_)) {
    return {false, "started", PJ_EINVALIDOP,
            "An account is already configured", account_id_};
  }

  const bool use_tcp = config.transport == "tcp";
  const int transport_id = use_tcp ? tcp_transport_id_ : udp_transport_id_;
  if (transport_id == PJSUA_INVALID_ID) {
    return {false, "started", PJ_EINVALIDOP,
            "Requested SIP transport is unavailable"};
  }

  std::string id_uri = "sip:" + config.username + "@" + config.host;
  std::string registrar_uri =
      "sip:" + config.host + ";transport=" + (use_tcp ? "tcp" : "udp");
  std::string realm = "*";
  std::string scheme = "digest";
  std::string auth_username =
      config.auth_username.empty() ? config.username : config.auth_username;
  std::string password = config.password;

  pjsua_acc_config account_config;
  pjsua_acc_config_default(&account_config);
  account_config.id = StringRef(id_uri);
  account_config.reg_uri = StringRef(registrar_uri);
  account_config.transport_id = transport_id;
  account_config.register_on_acc_add = PJ_TRUE;
  account_config.ka_interval = 15;
  account_config.allow_via_rewrite = PJ_TRUE;
  account_config.allow_contact_rewrite = 2;
  account_config.allow_sdp_nat_rewrite = PJ_TRUE;
  account_config.cred_count = 1;
  account_config.cred_info[0].realm = StringRef(realm);
  account_config.cred_info[0].scheme = StringRef(scheme);
  account_config.cred_info[0].username = StringRef(auth_username);
  account_config.cred_info[0].data_type = 0;
  account_config.cred_info[0].data = StringRef(password);

  pjsua_acc_id new_account_id = PJSUA_INVALID_ID;
  const pj_status_t status =
      pjsua_acc_add(&account_config, PJ_TRUE, &new_account_id);
  if (status != PJ_SUCCESS) {
    const std::string message =
        "pjsua_acc_add failed: " + StatusDescription(status);
    EmitLog(1, message);
    return {false, "started", status, message};
  }

  account_id_ = new_account_id;
  account_host_ = config.host;
  account_transport_ = use_tcp ? "tcp" : "udp";
  EmitLog(3, "SIP registration request sent for account " +
                 std::to_string(account_id_));
  EmitRegistration(account_id_, 0, 0, false, "Registration request sent");
  return {true, "started", PJ_SUCCESS, "Registration request sent",
          account_id_};
}

PjsipResult PjsipService::UnregisterAccount() {
  std::lock_guard<std::mutex> lock(lifecycle_mutex_);
  if (account_id_ == PJSUA_INVALID_ID || !pjsua_acc_is_valid(account_id_)) {
    account_id_ = PJSUA_INVALID_ID;
    return {true, initialized_ ? "started" : "idle", PJ_SUCCESS,
            "No SIP account is configured"};
  }

  const int removed_account_id = account_id_;
  const pj_status_t status = pjsua_acc_del(account_id_);
  if (status != PJ_SUCCESS) {
    const std::string message =
        "pjsua_acc_del failed: " + StatusDescription(status);
    EmitLog(1, message);
    return {false, initialized_ ? "started" : "idle", status, message,
            account_id_};
  }

  account_id_ = PJSUA_INVALID_ID;
  account_host_.clear();
  EmitLog(3, "SIP account unregistered: " +
                 std::to_string(removed_account_id));
  EmitRegistration(removed_account_id, 0, 0, false,
                   "SIP account unregistered");
  return {true, initialized_ ? "started" : "idle", PJ_SUCCESS,
          "SIP account unregistered", removed_account_id};
}

PjsipResult PjsipService::MakeCall(const std::string& destination) {
  std::lock_guard<std::mutex> lock(lifecycle_mutex_);
  if (!initialized_ || account_id_ == PJSUA_INVALID_ID ||
      !pjsua_acc_is_valid(account_id_)) {
    return {false, "started", PJ_EINVALIDOP,
            "A registered SIP account is required"};
  }
  if (destination.empty()) {
    return {false, "started", PJ_EINVAL, "Destination is required"};
  }
  const int existing_call = active_call_id_.load();
  if (existing_call != PJSUA_INVALID_ID &&
      pjsua_call_is_active(existing_call)) {
    return {false, "started", PJ_EINVALIDOP,
            "Another call is already active", account_id_, existing_call};
  }

  std::string uri = destination;
  if (uri.rfind("sip:", 0) != 0 && uri.rfind("sips:", 0) != 0) {
    uri = "sip:" + destination + "@" + account_host_ + ";transport=" +
          account_transport_;
  }
  pj_str_t destination_uri = StringRef(uri);
  pjsua_call_setting setting;
  pjsua_call_setting_default(&setting);
  setting.aud_cnt = 1;
  setting.vid_cnt = 0;
  setting.txt_cnt = 0;

  pjsua_call_id call_id = PJSUA_INVALID_ID;
  const pj_status_t status = pjsua_call_make_call(
      account_id_, &destination_uri, &setting, nullptr, nullptr, &call_id);
  if (status != PJ_SUCCESS) {
    const std::string message =
        "pjsua_call_make_call failed: " + StatusDescription(status);
    EmitLog(1, message);
    return {false, "started", status, message, account_id_};
  }
  active_call_id_.store(call_id);
  EmitLog(3, "Outgoing call created: call=" + std::to_string(call_id) +
                 ", destination=" + uri);
  EmitCall(call_id, false, "Outgoing call created");
  return {true, "started", PJ_SUCCESS, "Outgoing call created", account_id_,
          call_id};
}

PjsipResult PjsipService::AnswerCall(int call_id) {
  std::lock_guard<std::mutex> lock(lifecycle_mutex_);
  if (!initialized_ || !pjsua_call_is_active(call_id)) {
    return {false, "started", PJ_EINVAL, "Call is no longer active",
            account_id_, call_id};
  }
  const pj_status_t status =
      pjsua_call_answer(call_id, PJSIP_SC_OK, nullptr, nullptr);
  if (status != PJ_SUCCESS) {
    return {false, "started", status,
            "pjsua_call_answer failed: " + StatusDescription(status),
            account_id_, call_id};
  }
  active_call_id_.store(call_id);
  EmitLog(3, "Incoming call answered: call=" + std::to_string(call_id));
  return {true, "started", PJ_SUCCESS, "Incoming call answered", account_id_,
          call_id};
}

PjsipResult PjsipService::RejectCall(int call_id) {
  std::lock_guard<std::mutex> lock(lifecycle_mutex_);
  if (!initialized_ || !pjsua_call_is_active(call_id)) {
    return {false, "started", PJ_EINVAL, "Call is no longer active",
            account_id_, call_id};
  }
  const pj_status_t status =
      pjsua_call_answer(call_id, PJSIP_SC_BUSY_HERE, nullptr, nullptr);
  if (status != PJ_SUCCESS) {
    return {false, "started", status,
            "pjsua_call_answer(486) failed: " + StatusDescription(status),
            account_id_, call_id};
  }
  EmitLog(3, "Incoming call rejected: call=" + std::to_string(call_id));
  return {true, "started", PJ_SUCCESS, "Incoming call rejected", account_id_,
          call_id};
}

PjsipResult PjsipService::HangupCall(int call_id) {
  std::lock_guard<std::mutex> lock(lifecycle_mutex_);
  if (!initialized_ || !pjsua_call_is_active(call_id)) {
    active_call_id_.compare_exchange_strong(call_id, PJSUA_INVALID_ID);
    return {true, "started", PJ_SUCCESS, "Call is already disconnected",
            account_id_, call_id};
  }
  const pj_status_t status =
      pjsua_call_hangup(call_id, 0, nullptr, nullptr);
  if (status != PJ_SUCCESS) {
    return {false, "started", status,
            "pjsua_call_hangup failed: " + StatusDescription(status),
            account_id_, call_id};
  }
  EmitLog(3, "Call hangup requested: call=" + std::to_string(call_id));
  return {true, "started", PJ_SUCCESS, "Call hangup requested", account_id_,
          call_id};
}

PjsipResult PjsipService::Shutdown() {
  std::lock_guard<std::mutex> lock(lifecycle_mutex_);
  if (!created_) {
    return {true, "idle", PJ_SUCCESS, "PJSIP is already stopped"};
  }
  EmitStatus("stopping", "Stopping native PJSIP engine");
  const pj_status_t status = pjsua_destroy();
  initialized_ = false;
  created_ = false;
  account_id_ = PJSUA_INVALID_ID;
  active_call_id_.store(PJSUA_INVALID_ID);
  account_host_.clear();
  udp_transport_id_ = PJSUA_INVALID_ID;
  tcp_transport_id_ = PJSUA_INVALID_ID;
  active_service_.store(nullptr);
  if (status != PJ_SUCCESS) {
    const std::string message =
        "pjsua_destroy failed: " + StatusDescription(status);
    EmitLog(1, message);
    EmitStatus("error", message);
    return {false, "error", status, message};
  }
  EmitLog(3, "PJSIP native engine stopped");
  EmitStatus("idle", "PJSIP shutdown completed");
  return {true, "idle", PJ_SUCCESS, "PJSIP shutdown completed"};
}

void PjsipService::NativeLogCallback(int level,
                                     const char* data,
                                     int length) {
  if (data == nullptr || length <= 0) {
    return;
  }
  std::string message(data, static_cast<size_t>(length));
  while (!message.empty() &&
         (message.back() == '\n' || message.back() == '\r')) {
    message.pop_back();
  }
  PrintNativeLog(level, message);
  PjsipService* service = active_service_.load();
  if (service != nullptr) {
    service->Emit({"log", "", level, message});
  }
}

void PjsipService::RegistrationStateCallback(int account_id) {
  PjsipService* service = active_service_.load();
  if (service == nullptr) {
    return;
  }

  pjsua_acc_info info;
  const pj_status_t status = pjsua_acc_get_info(account_id, &info);
  if (status != PJ_SUCCESS) {
    service->EmitRegistration(account_id, status, 0, false,
                              "Unable to read registration state");
    return;
  }

  std::string status_text;
  if (info.status_text.ptr != nullptr && info.status_text.slen > 0) {
    status_text.assign(info.status_text.ptr,
                       static_cast<size_t>(info.status_text.slen));
  }
  const bool registered = info.status == PJSIP_SC_OK && info.expires > 0;
  service->EmitLog(
      registered ? 3 : 4,
      "SIP registration state: account=" + std::to_string(account_id) +
          ", status=" + std::to_string(info.status) +
          ", expires=" + std::to_string(info.expires));
  service->EmitRegistration(account_id, info.status, info.expires, registered,
                            status_text);
}

void PjsipService::IncomingCallCallback(int account_id,
                                        int call_id,
                                        pjsip_rx_data*) {
  PjsipService* service = active_service_.load();
  if (service == nullptr) {
    return;
  }
  service->active_call_id_.store(call_id);
  service->EmitLog(3, "Incoming call received: call=" +
                          std::to_string(call_id) + ", account=" +
                          std::to_string(account_id));
  service->EmitCall(call_id, true, "Incoming call received");
  const pj_status_t status =
      pjsua_call_answer(call_id, PJSIP_SC_RINGING, nullptr, nullptr);
  if (status != PJ_SUCCESS) {
    service->EmitLog(2, "Unable to send 180 Ringing: " +
                            StatusDescription(status));
  }
}

void PjsipService::CallStateCallback(int call_id, pjsip_event*) {
  PjsipService* service = active_service_.load();
  if (service == nullptr) {
    return;
  }
  pjsua_call_info info;
  const pj_status_t status = pjsua_call_get_info(call_id, &info);
  if (status != PJ_SUCCESS) {
    service->EmitLog(4, "Call state released: call=" +
                            std::to_string(call_id));
    int expected = call_id;
    service->active_call_id_.compare_exchange_strong(expected,
                                                      PJSUA_INVALID_ID);
    return;
  }
  const bool incoming = info.role == PJSIP_ROLE_UAS;
  service->EmitCall(call_id, incoming, "Call state changed");
  if (info.state == PJSIP_INV_STATE_DISCONNECTED) {
    int expected = call_id;
    service->active_call_id_.compare_exchange_strong(expected,
                                                      PJSUA_INVALID_ID);
  }
}

void PjsipService::CallMediaStateCallback(int call_id) {
  PjsipService* service = active_service_.load();
  if (service == nullptr) {
    return;
  }
  pjsua_call_info info;
  if (pjsua_call_get_info(call_id, &info) != PJ_SUCCESS) {
    return;
  }
  if (info.media_status == PJSUA_CALL_MEDIA_ACTIVE) {
    const pjsua_conf_port_id slot = pjsua_call_get_conf_port(call_id);
    if (slot != PJSUA_INVALID_ID) {
      const pj_status_t playback = pjsua_conf_connect(slot, 0);
      const pj_status_t capture = pjsua_conf_connect(0, slot);
      if (playback != PJ_SUCCESS || capture != PJ_SUCCESS) {
        service->EmitLog(2, "Unable to connect call audio: call=" +
                                std::to_string(call_id));
      } else {
        service->EmitLog(3, "Call audio connected: call=" +
                                std::to_string(call_id));
      }
    }
  }
  service->EmitCall(call_id, info.role == PJSIP_ROLE_UAS,
                    "Call media state changed");
}

PjsipResult PjsipService::Fail(const std::string& step, int status) {
  const std::string message =
      step + " failed (" + std::to_string(status) + "): " +
      StatusDescription(status);
  EmitLog(1, message);
  if (created_) {
    pjsua_destroy();
  }
  initialized_ = false;
  created_ = false;
  account_id_ = PJSUA_INVALID_ID;
  active_call_id_.store(PJSUA_INVALID_ID);
  account_host_.clear();
  udp_transport_id_ = PJSUA_INVALID_ID;
  tcp_transport_id_ = PJSUA_INVALID_ID;
  active_service_.store(nullptr);
  EmitStatus("error", message);
  return {false, "error", status, message};
}

void PjsipService::ConfigureCodecs() {
  pjsua_codec_info codecs[64];
  unsigned count = 64;
  const pj_status_t status = pjsua_enum_codecs(codecs, &count);
  if (status != PJ_SUCCESS) {
    EmitLog(2, "Unable to enumerate codecs: " + StatusDescription(status));
    return;
  }
  unsigned kept = 0;
  for (unsigned index = 0; index < count; ++index) {
    const pj_str_t& codec_id = codecs[index].codec_id;
    const std::string id(codec_id.ptr, static_cast<size_t>(codec_id.slen));
    const bool keep = id.compare(0, 5, "PCMU/") == 0 ||
                      id.compare(0, 5, "PCMA/") == 0;
    pjsua_codec_set_priority(&codec_id,
                             static_cast<pj_uint8_t>(keep ? 128 : 0));
    if (keep) {
      ++kept;
    }
  }
  EmitLog(4, "Codec configuration completed: kept " +
                 std::to_string(kept) + " PCMU/PCMA entries");
}

void PjsipService::Emit(const PjsipEvent& event) const {
  EventCallback callback;
  {
    std::lock_guard<std::mutex> lock(callback_mutex_);
    callback = event_callback_;
  }
  if (callback) {
    callback(event);
  }
}

void PjsipService::EmitLog(int level, const std::string& message) const {
  PrintNativeLog(level, message);
  Emit({"log", "", level, message});
}

void PjsipService::EmitStatus(const std::string& state,
                              const std::string& message) const {
  Emit({"status", state, 0, message});
}

void PjsipService::EmitRegistration(int account_id,
                                    int status,
                                    int expires,
                                    bool registered,
                                    const std::string& message) const {
  PjsipEvent event;
  event.type = "registration";
  event.message = message;
  event.account_id = account_id;
  event.status = status;
  event.expires = expires;
  event.registered = registered;
  Emit(event);
}

void PjsipService::EmitCall(int call_id,
                            bool incoming,
                            const std::string& message) const {
  pjsua_call_info info;
  if (pjsua_call_get_info(call_id, &info) != PJ_SUCCESS) {
    return;
  }
  PjsipEvent event;
  event.type = "call";
  event.message = message;
  event.account_id = info.acc_id;
  event.call_id = call_id;
  event.call_state = static_cast<int>(info.state);
  event.media_status = static_cast<int>(info.media_status);
  event.last_status = info.last_status;
  event.incoming = incoming;
  if (info.remote_info.ptr != nullptr && info.remote_info.slen > 0) {
    event.remote_uri.assign(info.remote_info.ptr,
                            static_cast<size_t>(info.remote_info.slen));
  }
  if (info.state_text.ptr != nullptr && info.state_text.slen > 0) {
    event.state.assign(info.state_text.ptr,
                       static_cast<size_t>(info.state_text.slen));
  }
  if (info.last_status_text.ptr != nullptr && info.last_status_text.slen > 0) {
    event.message.assign(info.last_status_text.ptr,
                         static_cast<size_t>(info.last_status_text.slen));
  }
  Emit(event);
}

}  // namespace platform_p
