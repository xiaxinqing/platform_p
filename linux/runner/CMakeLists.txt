cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME}
  "main.cc"
  "my_application.cc"
  "../../native/pjsip_service.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the application ID.
add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")
target_compile_definitions(${BINARY_NAME} PRIVATE PJ_AUTOCONF=1)

# PJSIP native SDK.
set(PJSIP_SDK_ROOT "${CMAKE_SOURCE_DIR}/Frameworks/PJSIP")
set(PJSIP_LIB_DIR "${PJSIP_SDK_ROOT}/pjsip/lib")
set(PJSIP_OPENSSL_LIB_DIR "${PJSIP_SDK_ROOT}/openssl/lib")

target_include_directories(${BINARY_NAME} PRIVATE
  "${PJSIP_SDK_ROOT}/pjsip/include"
  "${PJSIP_SDK_ROOT}/openssl/include"
)

# Add dependency libraries. Add any application-specific dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK)
target_link_libraries(${BINARY_NAME} PRIVATE
  "-Wl,--start-group"
  "${PJSIP_LIB_DIR}/libpjsua2.a"
  "${PJSIP_LIB_DIR}/libpjsua-lib.a"
  "${PJSIP_LIB_DIR}/libpjsip-ua.a"
  "${PJSIP_LIB_DIR}/libpjsip-simple.a"
  "${PJSIP_LIB_DIR}/libpjsip.a"
  "${PJSIP_LIB_DIR}/libpjmedia-codec.a"
  "${PJSIP_LIB_DIR}/libpjmedia-audiodev.a"
  "${PJSIP_LIB_DIR}/libpjmedia-videodev.a"
  "${PJSIP_LIB_DIR}/libpjmedia.a"
  "${PJSIP_LIB_DIR}/libpjnath.a"
  "${PJSIP_LIB_DIR}/libpjlib-util.a"
  "${PJSIP_LIB_DIR}/libpjlib.a"
  "${PJSIP_LIB_DIR}/libg7221.a"
  "${PJSIP_LIB_DIR}/libgsm.a"
  "${PJSIP_LIB_DIR}/libilbc.a"
  "${PJSIP_LIB_DIR}/libresample.a"
  "${PJSIP_LIB_DIR}/libspeex.a"
  "${PJSIP_LIB_DIR}/libsrtp.a"
  "${PJSIP_LIB_DIR}/libwebrtc_aec3.a"
  "-Wl,--end-group"
  "${PJSIP_OPENSSL_LIB_DIR}/libssl.a"
  "${PJSIP_OPENSSL_LIB_DIR}/libcrypto.a"
  asound
  uuid
  pthread
  dl
  rt
  m
)

target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")
