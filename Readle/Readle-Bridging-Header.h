#include <zlib.h>
#include "Core/MOBIBridge.h"

// eSpeak NG is already linked by sherpa-onnx. Readle uses its UTF-8 to IPA API.
const char *espeak_TextToPhonemes(const void **textptr, int textmode, int phonememode);
int espeak_SetVoiceByName(const char *name);
