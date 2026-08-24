#import "PjsipBridge.h"

#include "../../native/pjsip_service.h"

#include <memory>

namespace {

FlutterMethodChannel* g_channel = nil;
std::unique_ptr<platform_p::PjsipService> g_service;

NSString* NativeString(const std::string& value) {
  NSString* string = [[NSString alloc] initWithBytes:value.data()
                                              length:value.size()
                                            encoding:NSUTF8StringEncoding];
  return string ?: @"";
}

NSDictionary* ResultDictionary(const platform_p::PjsipResult& result) {
  return @{
    @"success" : @(result.success),
    @"state" : NativeString(result.state),
    @"status" : @(result.status),
    @"message" : NativeString(result.message),
    @"accountId" : @(result.account_id),
    @"callId" : @(result.call_id),
  };
}

NSDictionary* EventDictionary(const platform_p::PjsipEvent& event) {
  return @{
    @"type" : NativeString(event.type),
    @"state" : NativeString(event.state),
    @"level" : @(event.level),
    @"message" : NativeString(event.message),
    @"accountId" : @(event.account_id),
    @"status" : @(event.status),
    @"expires" : @(event.expires),
    @"registered" : @(event.registered),
    @"callId" : @(event.call_id),
    @"callState" : @(event.call_state),
    @"mediaStatus" : @(event.media_status),
    @"lastStatus" : @(event.last_status),
    @"incoming" : @(event.incoming),
    @"remoteUri" : NativeString(event.remote_uri),
    @"accountUri" : NativeString(event.account_uri),
  };
}

std::string ArgumentString(NSDictionary* arguments, NSString* key) {
  id value = arguments[key];
  if (![value isKindOfClass:[NSString class]]) {
    return "";
  }
  const char* utf8 = [static_cast<NSString*>(value) UTF8String];
  return utf8 == nullptr ? "" : std::string(utf8);
}

int ArgumentInt(NSDictionary* arguments, NSString* key, int fallback = -1) {
  id value = arguments[key];
  return [value isKindOfClass:[NSNumber class]]
             ? [static_cast<NSNumber*>(value) intValue]
             : fallback;
}

bool ArgumentBool(NSDictionary* arguments, NSString* key) {
  id value = arguments[key];
  return [value isKindOfClass:[NSNumber class]]
             ? [static_cast<NSNumber*>(value) boolValue]
             : false;
}

}  // namespace

void RegisterPjsipBridge(id<FlutterBinaryMessenger> messenger) {
  if (g_channel != nil) {
    return;
  }

  g_channel = [FlutterMethodChannel methodChannelWithName:@"platform_p/pjsip"
                                         binaryMessenger:messenger];
  g_service = std::make_unique<platform_p::PjsipService>();
  g_service->SetEventCallback([](const platform_p::PjsipEvent& event) {
    NSDictionary* payload = EventDictionary(event);
    dispatch_async(dispatch_get_main_queue(), ^{
      [g_channel invokeMethod:@"event" arguments:payload];
    });
  });

  [g_channel setMethodCallHandler:^(FlutterMethodCall* call,
                                    FlutterResult result) {
    if ([call.method isEqualToString:@"initialize"]) {
      result(ResultDictionary(g_service->Initialize()));
      return;
    }
    if ([call.method isEqualToString:@"status"]) {
      result(ResultDictionary(g_service->GetStatus()));
      return;
    }
    if ([call.method isEqualToString:@"registerAccount"]) {
      NSDictionary* arguments =
          [call.arguments isKindOfClass:[NSDictionary class]]
              ? static_cast<NSDictionary*>(call.arguments)
              : @{};
      platform_p::PjsipAccountConfig config;
      config.username = ArgumentString(arguments, @"username");
      config.auth_username = ArgumentString(arguments, @"authUsername");
      config.password = ArgumentString(arguments, @"password");
      config.host = ArgumentString(arguments, @"host");
      config.transport = ArgumentString(arguments, @"transport");
      config.port = ArgumentInt(arguments, @"port", 0);
      config.media_security = ArgumentString(arguments, @"mediaSecurity");
      config.stun_enabled = ArgumentBool(arguments, @"stunEnabled");
      config.stun_server = ArgumentString(arguments, @"stunServer");
      config.stun_port = ArgumentInt(arguments, @"stunPort", 3478);
      config.ice_enabled = ArgumentBool(arguments, @"iceEnabled");
      config.tls_verify_server =
          ArgumentBool(arguments, @"tlsVerifyServer");
      if (config.transport.empty()) {
        config.transport = "udp";
      }
      if (config.media_security.empty()) {
        config.media_security = "none";
      }
      result(ResultDictionary(g_service->RegisterAccount(config)));
      return;
    }
    if ([call.method isEqualToString:@"unregisterAccount"]) {
      NSDictionary* arguments =
          [call.arguments isKindOfClass:[NSDictionary class]]
              ? static_cast<NSDictionary*>(call.arguments)
              : @{};
      result(ResultDictionary(
          g_service->UnregisterAccount(ArgumentInt(arguments, @"accountId"))));
      return;
    }
    if ([call.method isEqualToString:@"makeCall"]) {
      NSDictionary* arguments =
          [call.arguments isKindOfClass:[NSDictionary class]]
              ? static_cast<NSDictionary*>(call.arguments)
              : @{};
      result(ResultDictionary(
          g_service->MakeCall(ArgumentString(arguments, @"destination"),
                              ArgumentInt(arguments, @"accountId"))));
      return;
    }
    if ([call.method isEqualToString:@"answerCall"] ||
        [call.method isEqualToString:@"rejectCall"] ||
        [call.method isEqualToString:@"hangupCall"] ||
        [call.method isEqualToString:@"holdCall"] ||
        [call.method isEqualToString:@"resumeCall"]) {
      NSDictionary* arguments =
          [call.arguments isKindOfClass:[NSDictionary class]]
              ? static_cast<NSDictionary*>(call.arguments)
              : @{};
      const int call_id = ArgumentInt(arguments, @"callId");
      if ([call.method isEqualToString:@"answerCall"]) {
        result(ResultDictionary(g_service->AnswerCall(call_id)));
      } else if ([call.method isEqualToString:@"rejectCall"]) {
        result(ResultDictionary(g_service->RejectCall(call_id)));
      } else if ([call.method isEqualToString:@"holdCall"]) {
        result(ResultDictionary(g_service->HoldCall(call_id)));
      } else if ([call.method isEqualToString:@"resumeCall"]) {
        result(ResultDictionary(g_service->ResumeCall(call_id)));
      } else {
        result(ResultDictionary(g_service->HangupCall(call_id)));
      }
      return;
    }
    if ([call.method isEqualToString:@"setMicrophoneMuted"] ||
        [call.method isEqualToString:@"setSpeakerMuted"]) {
      NSDictionary* arguments =
          [call.arguments isKindOfClass:[NSDictionary class]]
              ? static_cast<NSDictionary*>(call.arguments)
              : @{};
      const bool muted = [arguments[@"muted"] boolValue];
      result(ResultDictionary(
          [call.method isEqualToString:@"setMicrophoneMuted"]
              ? g_service->SetMicrophoneMuted(muted)
              : g_service->SetSpeakerMuted(muted)));
      return;
    }
    if ([call.method isEqualToString:@"sendDtmf"]) {
      NSDictionary* arguments =
          [call.arguments isKindOfClass:[NSDictionary class]]
              ? static_cast<NSDictionary*>(call.arguments)
              : @{};
      result(ResultDictionary(g_service->SendDtmf(
          ArgumentInt(arguments, @"callId"),
          ArgumentString(arguments, @"digits"))));
      return;
    }
    if ([call.method isEqualToString:@"getAudioLevels"]) {
      NSDictionary* arguments =
          [call.arguments isKindOfClass:[NSDictionary class]]
              ? static_cast<NSDictionary*>(call.arguments)
              : @{};
      unsigned microphone_level = 0;
      unsigned remote_level = 0;
      const platform_p::PjsipResult native_result = g_service->GetAudioLevels(
          ArgumentInt(arguments, @"callId"), &microphone_level,
          &remote_level);
      NSMutableDictionary* response =
          [ResultDictionary(native_result) mutableCopy];
      response[@"microphoneLevel"] = @(microphone_level);
      response[@"remoteLevel"] = @(remote_level);
      result(response);
      return;
    }
    if ([call.method isEqualToString:@"setAutoHoldOnIncoming"]) {
      NSDictionary* arguments =
          [call.arguments isKindOfClass:[NSDictionary class]]
              ? static_cast<NSDictionary*>(call.arguments)
              : @{};
      result(ResultDictionary(g_service->SetAutoHoldOnIncoming(
          [arguments[@"enabled"] boolValue])));
      return;
    }
    if ([call.method isEqualToString:@"configureAudioCues"]) {
      NSDictionary* arguments =
          [call.arguments isKindOfClass:[NSDictionary class]]
              ? static_cast<NSDictionary*>(call.arguments)
              : @{};
      result(ResultDictionary(g_service->ConfigureAudioCues(
          ArgumentString(arguments, @"ringtonePath"),
          ArgumentString(arguments, @"ringbackPath"),
          ArgumentString(arguments, @"hangupPath"))));
      return;
    }
    if ([call.method isEqualToString:@"shutdown"]) {
      result(ResultDictionary(g_service->Shutdown()));
      return;
    }
    result(FlutterMethodNotImplemented);
  }];
}

void ShutdownPjsipBridge(void) {
  if (g_service) {
    g_service->Shutdown();
    g_service->SetEventCallback(nullptr);
    g_service.reset();
  }
  [g_channel setMethodCallHandler:nil];
  g_channel = nil;
}
