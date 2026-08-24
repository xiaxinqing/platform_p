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
      if (config.transport.empty()) {
        config.transport = "udp";
      }
      result(ResultDictionary(g_service->RegisterAccount(config)));
      return;
    }
    if ([call.method isEqualToString:@"unregisterAccount"]) {
      result(ResultDictionary(g_service->UnregisterAccount()));
      return;
    }
    if ([call.method isEqualToString:@"makeCall"]) {
      NSDictionary* arguments =
          [call.arguments isKindOfClass:[NSDictionary class]]
              ? static_cast<NSDictionary*>(call.arguments)
              : @{};
      result(ResultDictionary(
          g_service->MakeCall(ArgumentString(arguments, @"destination"))));
      return;
    }
    if ([call.method isEqualToString:@"answerCall"] ||
        [call.method isEqualToString:@"rejectCall"] ||
        [call.method isEqualToString:@"hangupCall"]) {
      NSDictionary* arguments =
          [call.arguments isKindOfClass:[NSDictionary class]]
              ? static_cast<NSDictionary*>(call.arguments)
              : @{};
      const int call_id = ArgumentInt(arguments, @"callId");
      if ([call.method isEqualToString:@"answerCall"]) {
        result(ResultDictionary(g_service->AnswerCall(call_id)));
      } else if ([call.method isEqualToString:@"rejectCall"]) {
        result(ResultDictionary(g_service->RejectCall(call_id)));
      } else {
        result(ResultDictionary(g_service->HangupCall(call_id)));
      }
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
