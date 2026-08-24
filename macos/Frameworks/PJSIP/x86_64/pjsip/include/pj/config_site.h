#define PJSUA_MAX_CALLS          32
#define PJSUA_MAX_ACC            64
#define PJMEDIA_SOUND_CLOCK_RATE 44100
#define PJMEDIA_HAS_VIDEO        0
#define PJ_LOG_MAX_LEVEL         6
#define PJ_IOQUEUE_MAX_HANDLERS  256
#ifdef PJ_HAS_SSL_SOCK
#  undef PJ_HAS_SSL_SOCK
#endif
#define PJ_HAS_SSL_SOCK          1
#define PJMEDIA_HAS_SRTP         1
#define PJMEDIA_SRTP_HAS_DTLS    1
