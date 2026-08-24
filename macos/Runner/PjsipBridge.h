#import <FlutterMacOS/FlutterMacOS.h>

#ifdef __cplusplus
extern "C" {
#endif

void RegisterPjsipBridge(id<FlutterBinaryMessenger> messenger);
void ShutdownPjsipBridge(void);

#ifdef __cplusplus
}
#endif
