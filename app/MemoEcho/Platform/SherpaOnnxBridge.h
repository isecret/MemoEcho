#ifndef MemoEchoSherpaOnnxBridge_h
#define MemoEchoSherpaOnnxBridge_h

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MemoEchoSherpaRecognizer MemoEchoSherpaRecognizer;

int32_t MemoEchoSherpaLoadLibrary(const char *library_path, char *error, int32_t error_size);

const char *MemoEchoSherpaVersion(void);

MemoEchoSherpaRecognizer *MemoEchoSherpaCreateRecognizer(
    const char *model_path,
    const char *tokens_path,
    const char *language,
    int32_t use_itn,
    int32_t num_threads,
    char *error,
    int32_t error_size);

char *MemoEchoSherpaRecognize(
    MemoEchoSherpaRecognizer *recognizer,
    const float *samples,
    int32_t sample_count,
    int32_t sample_rate,
    char *error,
    int32_t error_size);

void MemoEchoSherpaDestroyRecognizer(MemoEchoSherpaRecognizer *recognizer);

void MemoEchoSherpaFreeString(char *text);

#ifdef __cplusplus
}
#endif

#endif
