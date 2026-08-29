cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "../../native/pjsip_service.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")
target_compile_definitions(${BINARY_NAME} PRIVATE "PJ_AUTOCONF=1")

# PJSIP native SDK.
set(PJSIP_SDK_ROOT "${CMAKE_SOURCE_DIR}/Frameworks/PJSIP")
set(PJSIP_LIB_DIR "${PJSIP_SDK_ROOT}/pjsip/lib")
set(PJSIP_OPENSSL_LIB_DIR "${PJSIP_SDK_ROOT}/openssl/lib")

target_include_directories(${BINARY_NAME} PRIVATE
  "${PJSIP_SDK_ROOT}/pjsip/include"
  "${PJSIP_SDK_ROOT}/openssl/include"
)

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_link_libraries(${BINARY_NAME} PRIVATE
  "${PJSIP_LIB_DIR}/pjsua2.lib"
  "${PJSIP_LIB_DIR}/pjsua-lib.lib"
  "${PJSIP_LIB_DIR}/pjsip-ua.lib"
  "${PJSIP_LIB_DIR}/pjsip-simple.lib"
  "${PJSIP_LIB_DIR}/pjsip.lib"
  "${PJSIP_LIB_DIR}/pjmedia-codec.lib"
  "${PJSIP_LIB_DIR}/pjmedia-audiodev.lib"
  "${PJSIP_LIB_DIR}/pjmedia-videodev.lib"
  "${PJSIP_LIB_DIR}/pjmedia.lib"
  "${PJSIP_LIB_DIR}/pjnath.lib"
  "${PJSIP_LIB_DIR}/pjlib-util.lib"
  "${PJSIP_LIB_DIR}/pjlib.lib"
  "${PJSIP_LIB_DIR}/g7221.lib"
  "${PJSIP_LIB_DIR}/gsm.lib"
  "${PJSIP_LIB_DIR}/ilbc.lib"
  "${PJSIP_LIB_DIR}/resample.lib"
  "${PJSIP_LIB_DIR}/speex.lib"
  "${PJSIP_LIB_DIR}/srtp.lib"
  "${PJSIP_LIB_DIR}/webrtc_aec3.lib"
  "${PJSIP_OPENSSL_LIB_DIR}/libssl.lib"
  "${PJSIP_OPENSSL_LIB_DIR}/libcrypto.lib"
  ws2_32.lib
  winmm.lib
  ole32.lib
  oleaut32.lib
  uuid.lib
  secur32.lib
  crypt32.lib
  iphlpapi.lib
)
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Bundle the OpenSSL runtime beside the Flutter executable.
file(GLOB PJSIP_OPENSSL_DLLS "${PJSIP_SDK_ROOT}/openssl/bin/*.dll")
set(PLUGIN_BUNDLED_LIBRARIES
  ${PLUGIN_BUNDLED_LIBRARIES}
  ${PJSIP_OPENSSL_DLLS}
  PARENT_SCOPE
)

# flutter run launches directly from the runner build directory instead of the
# installed bundle, so keep the OpenSSL runtime beside the executable there too.
foreach(PJSIP_OPENSSL_DLL ${PJSIP_OPENSSL_DLLS})
  add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      "${PJSIP_OPENSSL_DLL}"
      "$<TARGET_FILE_DIR:${BINARY_NAME}>"
  )
endforeach()

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
