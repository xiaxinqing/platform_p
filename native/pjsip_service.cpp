#include "pjsip_service.h"

#include <pjsua-lib/pjsua.h>

#include <cstdio>
#include <algorithm>
#include <utility>
#include <vector>

#ifdef _WIN32
#include <Windows.h>
#endif

namespace platform_p {

std::atomic<PjsipService*> PjsipService::active_service_(nullptr);

namespace {

constexpr int kRuntimeLogLevel = 4;

#if defined(__APPLE__)
char kDefaultCaBundlePath[] = "/etc/ssl/cert.pem";
#elif defined(__linux__)
char kDefaultCaBundlePath[] = "/etc/ssl/certs/ca-certificates.crt";
#endif

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

  pjsua_transport_config_default(&transport_config);
  transport_config.port = 0;
  transport_config.tls_setting.verify_server = PJ_FALSE;
  status = pjsua_transport_create(PJSIP_TRANSPORT_TLS, &transport_config,
                                  &tls_transport_id_);
  if (status != PJ_SUCCESS) {
    tls_transport_id_ = PJSUA_INVALID_ID;
    EmitLog(2, "TLS transport is unavailable: " +
                   StatusDescription(status));
  } else {
    EmitLog(4, "TLS transport created with a system-assigned port");
  }

  pjsua_transport_config_default(&transport_config);
  transport_config.port = 0;
  transport_config.tls_setting.verify_server = PJ_TRUE;
#if defined(__APPLE__) || defined(__linux__)
  transport_config.tls_setting.ca_list_file = pj_str(kDefaultCaBundlePath);
#endif
  status = pjsua_transport_create(PJSIP_TRANSPORT_TLS, &transport_config,
                                  &tls_verified_transport_id_);
  if (status != PJ_SUCCESS) {
    tls_verified_transport_id_ = PJSUA_INVALID_ID;
    EmitLog(2, "Verified TLS transport is unavailable: " +
                   StatusDescription(status));
  } else {
    EmitLog(4, "Verified TLS transport created with system CA bundle");
  }

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
  if (config.stun_enabled && config.stun_server.empty()) {
    return {false, "started", PJ_EINVAL,
            "STUN server is required when STUN is enabled"};
  }
  for (const auto& entry : accounts_) {
    const PjsipAccountRuntime& account = entry.second;
    if (account.username == config.username && account.host == config.host &&
        account.transport == config.transport &&
        account.port == config.port) {
      return {false, "started", PJ_EEXISTS,
              "This SIP account is already configured", entry.first};
    }
  }

  const bool use_tls = config.transport == "tls";
  const bool use_tcp = config.transport == "tcp";
  const int transport_id = use_tls
                               ? config.tls_verify_server
                                     ? tls_verified_transport_id_
                                     : tls_transport_id_
                                   : use_tcp ? tcp_transport_id_
                                             : udp_transport_id_;
  if (transport_id == PJSUA_INVALID_ID) {
    return {false, "started", PJ_EINVALIDOP,
            "Requested SIP transport is unavailable"};
  }

  const int port = config.port > 0 ? config.port : use_tls ? 5061 : 5060;
  const std::string transport = use_tls ? "tls" : use_tcp ? "tcp" : "udp";
  const std::string host_and_port =
      config.host + ":" + std::to_string(port);
  std::string id_uri = "sip:" + config.username + "@" + config.host;
  std::string registrar_uri =
      "sip:" + host_and_port + ";transport=" + transport;
  std::string realm = "*";
  std::string scheme = "digest";
  std::string auth_username =
      config.auth_username.empty() ? config.username : config.auth_username;
  std::string password = config.password;

  pjsua_acc_config account_config;
  pjsua_acc_config_default(&account_config);

  std::string stun_address;
  if (config.stun_enabled) {
    const int stun_port = config.stun_port > 0 ? config.stun_port : 3478;
    stun_address = config.stun_server + ":" + std::to_string(stun_port);
    if (std::find(stun_servers_.begin(), stun_servers_.end(), stun_address) ==
        stun_servers_.end()) {
      stun_servers_.push_back(stun_address);
    }
    std::vector<pj_str_t> stun_refs;
    stun_refs.reserve(stun_servers_.size());
    for (std::string& server : stun_servers_) {
      stun_refs.push_back(StringRef(server));
    }
    const pj_status_t stun_status = pjsua_update_stun_servers(
        static_cast<unsigned>(stun_refs.size()), stun_refs.data(), PJ_FALSE);
    if (stun_status != PJ_SUCCESS) {
      const std::string message =
          "pjsua_update_stun_servers failed: " +
          StatusDescription(stun_status);
      EmitLog(1, message);
      return {false, "started", stun_status, message};
    }
    EmitLog(3, "STUN server applied: " + stun_address);
    account_config.sip_stun_use = PJSUA_STUN_USE_DEFAULT;
    account_config.media_stun_use = PJSUA_STUN_RETRY_ON_FAILURE;
  } else {
    account_config.sip_stun_use = PJSUA_STUN_USE_DISABLED;
    account_config.media_stun_use = PJSUA_STUN_USE_DISABLED;
  }
  if (config.ice_enabled) {
    account_config.ice_cfg_use = PJSUA_ICE_CONFIG_USE_CUSTOM;
    account_config.ice_cfg.enable_ice = PJ_TRUE;
    EmitLog(3, "ICE candidate gathering enabled for " + config.username);
  }
  account_config.id = StringRef(id_uri);
  account_config.reg_uri = StringRef(registrar_uri);
  account_config.transport_id = transport_id;
  account_config.register_on_acc_add = PJ_TRUE;
  account_config.ka_interval = 15;
  account_config.allow_via_rewrite = PJ_TRUE;
  account_config.allow_contact_rewrite = 2;
  account_config.allow_sdp_nat_rewrite = PJ_TRUE;
  account_config.srtp_opt.crypto_count = 0;
  account_config.srtp_opt.keying_count = 0;
  if (config.media_security == "dtls_srtp" ||
      config.media_security == "sdes_srtp" ||
      config.media_security == "optional_dtls_first" ||
      config.media_security == "optional_sdes_first") {
    const bool optional =
        config.media_security == "optional_dtls_first" ||
        config.media_security == "optional_sdes_first";
    account_config.use_srtp = optional ? PJMEDIA_SRTP_OPTIONAL
                                       : PJMEDIA_SRTP_MANDATORY;
    account_config.srtp_secure_signaling = use_tls ? 1 : 0;
    const bool dtls_first = config.media_security == "dtls_srtp" ||
                            config.media_security == "optional_dtls_first";
    const bool include_dtls = config.media_security != "sdes_srtp";
    const bool include_sdes = config.media_security != "dtls_srtp";
    if (include_dtls && dtls_first) {
      account_config.srtp_opt.keying[account_config.srtp_opt.keying_count++] =
          PJMEDIA_SRTP_KEYING_DTLS_SRTP;
    }
    if (include_sdes) {
      account_config.srtp_opt.keying[account_config.srtp_opt.keying_count++] =
          PJMEDIA_SRTP_KEYING_SDES;
    }
    if (include_dtls && !dtls_first) {
      account_config.srtp_opt.keying[account_config.srtp_opt.keying_count++] =
          PJMEDIA_SRTP_KEYING_DTLS_SRTP;
    }
  } else {
    account_config.use_srtp = PJMEDIA_SRTP_DISABLED;
  }
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

  accounts_[new_account_id] = {
      config.username,      config.host,        transport,
      port,                 config.media_security,
      config.stun_enabled,  config.stun_server,
      config.stun_port,     config.ice_enabled};
  accounts_[new_account_id].tls_verify_server = config.tls_verify_server;
  EmitLog(3, "SIP registration request sent for account " +
                 std::to_string(new_account_id));
  EmitRegistration(new_account_id, 0, 0, false,
                   "Registration request sent");
  return {true, "started", PJ_SUCCESS, "Registration request sent",
          new_account_id};
}

PjsipResult PjsipService::UnregisterAccount(int account_id) {
  std::lock_guard<std::mutex> lock(lifecycle_mutex_);
  if (account_id == PJSUA_INVALID_ID || !pjsua_acc_is_valid(account_id)) {
    accounts_.erase(account_id);
    return {true, initialized_ ? "started" : "idle", PJ_SUCCESS,
            "No SIP account is configured"};
  }

  const int removed_account_id = account_id;
  const pj_status_t status = pjsua_acc_del(account_id);
  if (status != PJ_SUCCESS) {
    const std::string message =
        "pjsua_acc_del failed: " + StatusDescription(status);
    EmitLog(1, message);
    return {false, initialized_ ? "started" : "idle", status, message,
            account_id};
  }

  accounts_.erase(removed_account_id);
  EmitLog(3, "SIP account unregistered: " +
                 std::to_string(removed_account_id));
  EmitRegistration(removed_account_id, 0, 0, false,
                   "SIP account unregistered");
  return {true, initialized_ ? "started" : "idle", PJ_SUCCESS,
          "SIP account unregistered", removed_account_id};
}

PjsipResult PjsipService::MakeCall(const std::string& destination,
                                   int account_id) {
  std::lock_guard<std::mutex> lock(lifecycle_mutex_);
  const auto account_entry = accounts_.find(account_id);
  if (!initialized_ || account_entry == accounts_.end() ||
      !pjsua_acc_is_valid(account_id)) {
    return {false, "started", PJ_EINVALIDOP,
            "A registered SIP account is required"};
  }
  if (destination.empty()) {
    return {false, "started", PJ_EINVAL, "Destination is required"};
  }
  if (pjsua_call_get_count() >= 4) {
    return {false, "started", PJ_EINVALIDOP,
            "The maximum of four simultaneous calls has been reached",
            account_id};
  }

  HoldOtherConfirmedCalls(PJSUA_INVALID_ID);

  std::string uri = destination;
  if (uri.rfind("sip:", 0) != 0 && uri.rfind("sips:", 0) != 0) {
    uri = "sip:" + destination + "@" + account_entry->second.host + ":" +
          std::to_string(account_entry->second.port) + ";transport=" +
          account_entry->second.transport;
  }
  pj_str_t destination_uri = StringRef(uri);
  pjsua_call_setting setting;
  pjsua_call_setting_default(&setting);
  setting.aud_cnt = 1;
  setting.vid_cnt = 0;
  setting.txt_cnt = 0;

  pjsua_call_id call_id = PJSUA_INVALID_ID;
  const pj_status_t status = pjsua_call_make_call(
      account_id, &destination_uri, &setting, nullptr, nullptr, &call_id);
  if (status != PJ_SUCCESS) {
    const std::string message =
        "pjsua_call_make_call failed: " + StatusDescription(status);
    EmitLog(1, message);
    return {false, "started", status, message, account_id};
  }
  active_audio_call_id_.store(call_id);
  EmitLog(3, "Outgoing call created: call=" + std::to_string(call_id) +
                 ", destination=" + uri);
  EmitCall(call_id, false, "Outgoing call created");
  return {true, "started", PJ_SUCCESS, "Outgoing call created", account_id,
          call_id};
}

PjsipResult PjsipService::AnswerCall(int call_id) {
  std::lock_guard<std::mutex> lock(lifecycle_mutex_);
  if (!initialized_ || !pjsua_call_is_active(call_id)) {
    return {false, "started", PJ_EINVAL, "Call is no longer active", -1,
            call_id};
  }
  if (auto_hold_on_incoming_.load()) {
    HoldOtherConfirmedCalls(call_id);
  }
  // pjsua_call_answer() may synchronously create media and invoke the media
  // callback. Select this call first so its conference port is connected to
  // the sound device instead of being treated as a background call.
  const int previous_audio_call_id = active_audio_call_id_.load();
  active_audio_call_id_.store(call_id);
  const pj_status_t status =
      pjsua_call_answer(call_id, PJSIP_SC_OK, nullptr, nullptr);
  if (status != PJ_SUCCESS) {
    active_audio_call_id_.store(previous_audio_call_id);
    return {false, "started", status,
            "pjsua_call_answer failed: " + StatusDescription(status),
            -1, call_id};
  }
  EmitLog(3, "Incoming call answered: call=" + std::to_string(call_id));
  return {true, "started", PJ_SUCCESS, "Incoming call answered", -1,
          call_id};
}

PjsipResult PjsipService::RejectCall(int call_id) {
  std::lock_guard<std::mutex> lock(lifecycle_mutex_);
  if (!initialized_ || !pjsua_call_is_active(call_id)) {
    return {false, "started", PJ_EINVAL, "Call is no longer active", -1,
            call_id};
  }
  const pj_status_t status =
      pjsua_call_answer(call_id, PJSIP_SC_BUSY_HERE, nullptr, nullptr);
  if (status != PJ_SUCCESS) {
    return {false, "started", status,
            "pjsua_call_answer(486) failed: " + StatusDescription(status),
            -1, call_id};
  }
  EmitLog(3, "Incoming call rejected: call=" + std::to_string(call_id));
  return {true, "started", PJ_SUCCESS, "Incoming call rejected", -1,
          call_id};
}

PjsipResult PjsipService::HangupCall(int call_id) {
  std::lock_guard<std::mutex> lock(lifecycle_mutex_);
  if (!initialized_ || !pjsua_call_is_active(call_id)) {
    int expected = call_id;
    active_audio_call_id_.compare_exchange_strong(expected,
                                                   PJSUA_INVALID_ID);
    return {true, "started", PJ_SUCCESS, "Call is already disconnected", -1,
            call_id};
  }
  const pj_status_t status =
      pjsua_call_hangup(call_id, 0, nullptr, nullptr);
  if (status != PJ_SUCCESS) {
    return {false, "started", status,
            "pjsua_call_hangup failed: " + StatusDescription(status),
            -1, call_id};
  }
  EmitLog(3, "Call hangup requested: call=" + std::to_string(call_id));
  return {true, "started", PJ_SUCCESS, "Call hangup requested", -1,
          call_id};
}

PjsipResult PjsipService::HoldCall(int call_id) {
  std::lock_guard<std::mutex> lock(lifecycle_mutex_);
  if (!initialized_ || !pjsua_call_is_active(call_id)) {
    return {false, "started", PJ_EINVAL, "Call is no longer active", -1,
            call_id};
  }
  ConnectCallAudio(call_id, false);
  const pj_status_t status = pjsua_call_set_hold(call_id, nullptr);
  if (status != PJ_SUCCESS) {
    return {false, "started", status,
            "pjsua_call_set_hold failed: " + StatusDescription(status), -1,
            call_id};
  }
  int expected = call_id;
  active_audio_call_id_.compare_exchange_strong(expected, PJSUA_INVALID_ID);
  EmitLog(3, "Call hold requested: call=" + std::to_string(call_id));
  return {true, "started", PJ_SUCCESS, "Call hold requested", -1, call_id};
}

PjsipResult PjsipService::ResumeCall(int call_id) {
  std::lock_guard<std::mutex> lock(lifecycle_mutex_);
  if (!initialized_ || !pjsua_call_is_active(call_id)) {
    return {false, "started", PJ_EINVAL, "Call is no longer active", -1,
            call_id};
  }
  HoldOtherConfirmedCalls(call_id);
  active_audio_call_id_.store(call_id);
  const pj_status_t status = pjsua_call_reinvite(call_id, PJ_TRUE, nullptr);
  if (status != PJ_SUCCESS) {
    return {false, "started", status,
            "pjsua_call_reinvite failed: " + StatusDescription(status), -1,
            call_id};
  }
  EmitLog(3, "Call resume requested: call=" + std::to_string(call_id));
  return {true, "started", PJ_SUCCESS, "Call resume requested", -1,
          call_id};
}

PjsipResult PjsipService::SetMicrophoneMuted(bool muted) {
  std::lock_guard<std::mutex> lock(lifecycle_mutex_);
  if (!initialized_) {
    return {false, "idle", PJ_EINVALIDOP, "PJSIP engine is not started"};
  }
  // Port 0 is the sound device. Its RX side carries microphone frames into
  // the conference bridge.
  const pj_status_t status =
      pjsua_conf_adjust_rx_level(0, muted ? 0.0f : 1.0f);
  if (status != PJ_SUCCESS) {
    return {false, "started", status,
            "Microphone mute failed: " + StatusDescription(status)};
  }
  EmitLog(3, muted ? "Microphone muted" : "Microphone unmuted");
  return {true, "started", PJ_SUCCESS,
          muted ? "Microphone muted" : "Microphone unmuted"};
}

PjsipResult PjsipService::SetSpeakerMuted(bool muted) {
  std::lock_guard<std::mutex> lock(lifecycle_mutex_);
  if (!initialized_) {
    return {false, "idle", PJ_EINVALIDOP, "PJSIP engine is not started"};
  }
  // Port 0 TX carries mixed remote audio from the bridge to the speaker.
  const pj_status_t status =
      pjsua_conf_adjust_tx_level(0, muted ? 0.0f : 1.0f);
  if (status != PJ_SUCCESS) {
    return {false, "started", status,
            "Speaker mute failed: " + StatusDescription(status)};
  }
  EmitLog(3, muted ? "Speaker muted" : "Speaker unmuted");
  return {true, "started", PJ_SUCCESS,
          muted ? "Speaker muted" : "Speaker unmuted"};
}

PjsipResult PjsipService::SendDtmf(int call_id,
                                    const std::string& digits) {
  std::lock_guard<std::mutex> lock(lifecycle_mutex_);
  if (!initialized_ || !pjsua_call_is_active(call_id) || digits.empty()) {
    return {false, "started", PJ_EINVAL,
            "Active call and DTMF digit required", -1, call_id};
  }
  for (const char digit : digits) {
    if (std::string("0123456789*#ABCDabcd").find(digit) ==
        std::string::npos) {
      return {false, "started", PJ_EINVAL, "Invalid DTMF digit", -1,
              call_id};
    }
  }

  pj_str_t value = pj_str(const_cast<char*>(digits.c_str()));
  const pj_status_t status = pjsua_call_dial_dtmf(call_id, &value);
  if (status != PJ_SUCCESS) {
    return {false, "started", status,
            "DTMF send failed: " + StatusDescription(status), -1, call_id};
  }
  EmitLog(4, "DTMF sent: call=" + std::to_string(call_id) +
                 ", digits=" + digits);
  return {true, "started", PJ_SUCCESS, "DTMF sent", -1, call_id};
}

PjsipResult PjsipService::GetAudioLevels(int call_id,
                                         unsigned* microphone_level,
                                         unsigned* remote_level) {
  std::lock_guard<std::mutex> lock(lifecycle_mutex_);
  if (!initialized_ || microphone_level == nullptr ||
      remote_level == nullptr || !pjsua_call_is_active(call_id)) {
    return {false, "started", PJ_EINVAL, "Active call required", -1,
            call_id};
  }

  const pjsua_conf_port_id call_slot = pjsua_call_get_conf_port(call_id);
  if (call_slot == PJSUA_INVALID_ID) {
    return {false, "started", PJ_EINVALIDOP, "Call media is not active", -1,
            call_id};
  }

  unsigned speaker_output = 0;
  unsigned call_output = 0;
  const pj_status_t microphone_status = pjsua_conf_get_signal_level(
      0, &speaker_output, microphone_level);
  const pj_status_t remote_status = pjsua_conf_get_signal_level(
      call_slot, &call_output, remote_level);
  if (microphone_status != PJ_SUCCESS || remote_status != PJ_SUCCESS) {
    const pj_status_t status = microphone_status != PJ_SUCCESS
                                   ? microphone_status
                                   : remote_status;
    return {false, "started", status,
            "Audio level read failed: " + StatusDescription(status), -1,
            call_id};
  }
  return {true, "started", PJ_SUCCESS, "Audio levels read", -1, call_id};
}

PjsipResult PjsipService::SetAutoHoldOnIncoming(bool enabled) {
  std::lock_guard<std::mutex> lock(lifecycle_mutex_);
  auto_hold_on_incoming_.store(enabled);
  EmitLog(3, enabled ? "Incoming call auto-hold enabled"
                     : "Incoming call auto-hold disabled");
  return {true, initialized_ ? "started" : "idle", PJ_SUCCESS,
          enabled ? "接听新来电时将自动保持当前通话"
                  : "接听新来电时不会自动保持当前通话"};
}

PjsipResult PjsipService::ConfigureAudioCues(
    const std::string& ringtone_path,
    const std::string& ringback_path,
    const std::string& hangup_path) {
  {
    std::lock_guard<std::mutex> lock(audio_cue_mutex_);
    ringtone_path_ = ringtone_path;
    ringback_path_ = ringback_path;
    hangup_path_ = hangup_path;
  }
  RefreshAudioCues();
  return {true, initialized_ ? "started" : "idle", PJ_SUCCESS,
          "PJSIP call sounds configured"};
}

PjsipResult PjsipService::Shutdown() {
  std::lock_guard<std::mutex> lock(lifecycle_mutex_);
  if (!created_) {
    return {true, "idle", PJ_SUCCESS, "PJSIP is already stopped"};
  }
  EmitStatus("stopping", "Stopping native PJSIP engine");
  StopAllAudioCues();
  const pj_status_t status = pjsua_destroy();
  initialized_ = false;
  created_ = false;
  accounts_.clear();
  stun_servers_.clear();
  active_audio_call_id_.store(PJSUA_INVALID_ID);
  udp_transport_id_ = PJSUA_INVALID_ID;
  tcp_transport_id_ = PJSUA_INVALID_ID;
  tls_transport_id_ = PJSUA_INVALID_ID;
  tls_verified_transport_id_ = PJSUA_INVALID_ID;
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
  service->RefreshAudioCues();
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
    service->active_audio_call_id_.compare_exchange_strong(
        expected, PJSUA_INVALID_ID);
    service->HandleCallAudioCueState(call_id,
                                     PJSIP_INV_STATE_DISCONNECTED);
    return;
  }
  const bool incoming = info.role == PJSIP_ROLE_UAS;
  service->EmitCall(call_id, incoming, "Call state changed");
  service->HandleCallAudioCueState(call_id, info.state);
  if (info.state == PJSIP_INV_STATE_DISCONNECTED) {
    int expected = call_id;
    service->active_audio_call_id_.compare_exchange_strong(
        expected, PJSUA_INVALID_ID);
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
    int selected = service->active_audio_call_id_.load();
    if (selected == PJSUA_INVALID_ID) {
      service->active_audio_call_id_.compare_exchange_strong(selected,
                                                              call_id);
    }
    service->ConnectCallAudio(
        call_id, !service->auto_hold_on_incoming_.load() ||
                     service->active_audio_call_id_.load() == call_id);
  } else {
    service->ConnectCallAudio(call_id, false);
  }
  service->RefreshAudioCues();
  service->EmitCall(call_id, info.role == PJSIP_ROLE_UAS,
                    "Call media state changed");
}

PjsipResult PjsipService::Fail(const std::string& step, int status) {
  const std::string message =
      step + " failed (" + std::to_string(status) + "): " +
      StatusDescription(status);
  EmitLog(1, message);
  if (created_) {
    StopAllAudioCues();
    pjsua_destroy();
  }
  initialized_ = false;
  created_ = false;
  accounts_.clear();
  stun_servers_.clear();
  active_audio_call_id_.store(PJSUA_INVALID_ID);
  udp_transport_id_ = PJSUA_INVALID_ID;
  tcp_transport_id_ = PJSUA_INVALID_ID;
  tls_transport_id_ = PJSUA_INVALID_ID;
  tls_verified_transport_id_ = PJSUA_INVALID_ID;
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

void PjsipService::HoldOtherConfirmedCalls(int except_call_id) {
  pjsua_call_id call_ids[PJSUA_MAX_CALLS];
  unsigned count = PJSUA_MAX_CALLS;
  if (pjsua_enum_calls(call_ids, &count) != PJ_SUCCESS) {
    return;
  }
  for (unsigned index = 0; index < count; ++index) {
    const int call_id = call_ids[index];
    if (call_id == except_call_id) {
      continue;
    }
    pjsua_call_info info;
    if (pjsua_call_get_info(call_id, &info) != PJ_SUCCESS ||
        info.state != PJSIP_INV_STATE_CONFIRMED ||
        info.media_status == PJSUA_CALL_MEDIA_LOCAL_HOLD) {
      continue;
    }
    ConnectCallAudio(call_id, false);
    const pj_status_t status = pjsua_call_set_hold(call_id, nullptr);
    if (status == PJ_SUCCESS) {
      EmitLog(3, "Automatically holding call=" + std::to_string(call_id));
    } else {
      EmitLog(2, "Unable to auto-hold call=" + std::to_string(call_id) +
                     ": " + StatusDescription(status));
    }
  }
}

void PjsipService::ConnectCallAudio(int call_id, bool connect) {
  const pjsua_conf_port_id slot = pjsua_call_get_conf_port(call_id);
  if (slot == PJSUA_INVALID_ID) {
    return;
  }
  if (!connect) {
    pjsua_conf_disconnect(slot, 0);
    pjsua_conf_disconnect(0, slot);
    return;
  }
  const pj_status_t playback = pjsua_conf_connect(slot, 0);
  const pj_status_t capture = pjsua_conf_connect(0, slot);
  if (playback != PJ_SUCCESS || capture != PJ_SUCCESS) {
    EmitLog(2, "Unable to connect call audio: call=" +
                   std::to_string(call_id));
  } else {
    EmitLog(3, "Call audio connected: call=" + std::to_string(call_id));
  }
}

void PjsipService::RefreshAudioCues() {
  bool has_incoming = false;
  bool has_outgoing_ringback = false;
  pjsua_call_id call_ids[PJSUA_MAX_CALLS];
  unsigned count = PJSUA_MAX_CALLS;
  if (initialized_ && pjsua_enum_calls(call_ids, &count) == PJ_SUCCESS) {
    for (unsigned index = 0; index < count; ++index) {
      pjsua_call_info info;
      if (pjsua_call_get_info(call_ids[index], &info) != PJ_SUCCESS) {
        continue;
      }
      const bool waiting = info.state == PJSIP_INV_STATE_INCOMING ||
                           info.state == PJSIP_INV_STATE_EARLY;
      if (info.role == PJSIP_ROLE_UAS && waiting) {
        has_incoming = true;
      }
      if (info.role == PJSIP_ROLE_UAC &&
          info.state == PJSIP_INV_STATE_EARLY &&
          info.media_status != PJSUA_CALL_MEDIA_ACTIVE) {
        has_outgoing_ringback = true;
      }
    }
  }

  std::lock_guard<std::mutex> lock(audio_cue_mutex_);
  if (has_incoming) {
    StopAudioCueLocked(&ringback_player_id_);
    StopAudioCueLocked(&hangup_player_id_);
    StartAudioCueLocked(ringtone_path_, true, &ringtone_player_id_);
    return;
  }
  StopAudioCueLocked(&ringtone_player_id_);
  if (has_outgoing_ringback) {
    StopAudioCueLocked(&hangup_player_id_);
    StartAudioCueLocked(ringback_path_, true, &ringback_player_id_);
  } else {
    StopAudioCueLocked(&ringback_player_id_);
  }
}

void PjsipService::HandleCallAudioCueState(
    int call_id,
    int call_state) {
  bool play_hangup = false;
  {
    std::lock_guard<std::mutex> lock(audio_cue_mutex_);
    if (call_state == PJSIP_INV_STATE_CONFIRMED) {
      connected_call_ids_.insert(call_id);
    } else if (call_state != PJSIP_INV_STATE_DISCONNECTED) {
      hangup_played_call_ids_.erase(call_id);
    }
    if (call_state == PJSIP_INV_STATE_DISCONNECTED) {
      const bool was_connected = connected_call_ids_.erase(call_id) > 0;
      play_hangup =
          was_connected && hangup_played_call_ids_.insert(call_id).second;
      if (play_hangup) {
        StopAudioCueLocked(&hangup_player_id_);
        StartAudioCueLocked(hangup_path_, false, &hangup_player_id_);
      }
    }
  }
  RefreshAudioCues();
}

void PjsipService::StartAudioCueLocked(const std::string& path,
                                       bool loop,
                                       int* player_id) {
  if (!initialized_ || path.empty() || player_id == nullptr ||
      *player_id != PJSUA_INVALID_ID) {
    return;
  }
  pj_str_t file_path = pj_str(const_cast<char*>(path.c_str()));
  const unsigned options = loop ? 0 : PJMEDIA_FILE_NO_LOOP;
  pj_status_t status = pjsua_player_create(&file_path, options, player_id);
  if (status != PJ_SUCCESS) {
    *player_id = PJSUA_INVALID_ID;
    EmitLog(2, "Unable to create PJSIP sound player: " +
                   StatusDescription(status));
    return;
  }
  const pjsua_conf_port_id port = pjsua_player_get_conf_port(*player_id);
  status = pjsua_conf_connect(port, 0);
  if (status != PJ_SUCCESS) {
    pjsua_player_destroy(*player_id);
    *player_id = PJSUA_INVALID_ID;
    EmitLog(2, "Unable to connect PJSIP sound player: " +
                   StatusDescription(status));
  }
}

void PjsipService::StopAudioCueLocked(int* player_id) {
  if (player_id == nullptr || *player_id == PJSUA_INVALID_ID) {
    return;
  }
  pjsua_player_destroy(*player_id);
  *player_id = PJSUA_INVALID_ID;
}

void PjsipService::StopAllAudioCues() {
  std::lock_guard<std::mutex> lock(audio_cue_mutex_);
  StopAudioCueLocked(&ringtone_player_id_);
  StopAudioCueLocked(&ringback_player_id_);
  StopAudioCueLocked(&hangup_player_id_);
  connected_call_ids_.clear();
  hangup_played_call_ids_.clear();
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
  pjsua_acc_info info;
  if (pjsua_acc_get_info(account_id, &info) == PJ_SUCCESS &&
      info.acc_uri.ptr != nullptr && info.acc_uri.slen > 0) {
    event.account_uri.assign(info.acc_uri.ptr,
                             static_cast<size_t>(info.acc_uri.slen));
  }
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
