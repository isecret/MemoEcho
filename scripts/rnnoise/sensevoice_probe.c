// Local evaluation helper. Uses the application's bridge and production settings.
// Usage: sensevoice_probe SHERPA_LIBRARY MODEL TOKENS < wav-paths.txt
// Input paths must be newline-free; output is one JSON object per input WAV.
#include "../../app/MemoEcho/Platform/SherpaOnnxBridge.h"

#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static uint16_t le16(const unsigned char *p) {
  return (uint16_t)p[0] | (uint16_t)p[1] << 8;
}

static uint32_t le32(const unsigned char *p) {
  return (uint32_t)p[0] | (uint32_t)p[1] << 8 |
         (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static float *read_wav(const char *path, int32_t *count) {
  FILE *file = fopen(path, "rb");
  if (!file) return NULL;
  unsigned char header[12];
  if (fread(header, 1, sizeof(header), file) != sizeof(header) ||
      memcmp(header, "RIFF", 4) || memcmp(header + 8, "WAVE", 4)) {
    fclose(file);
    return NULL;
  }
  int valid_format = 0;
  float *samples = NULL;
  unsigned char chunk[8];
  while (fread(chunk, 1, sizeof(chunk), file) == sizeof(chunk)) {
    uint32_t size = le32(chunk + 4);
    if (!memcmp(chunk, "fmt ", 4)) {
      unsigned char format[16];
      if (size < sizeof(format) ||
          fread(format, 1, sizeof(format), file) != sizeof(format)) break;
      valid_format = le16(format) == 1 && le16(format + 2) == 1 &&
                     le32(format + 4) == 16000 && le16(format + 14) == 16;
      if (fseek(file, (long)size - sizeof(format) + (size & 1), SEEK_CUR)) break;
    } else if (!memcmp(chunk, "data", 4)) {
      if (!valid_format || size == 0 || (size & 1) || size / 2 > INT_MAX) break;
      *count = (int32_t)(size / 2);
      samples = malloc((size_t)*count * sizeof(float));
      if (!samples) break;
      for (int32_t i = 0; i < *count; ++i) {
        unsigned char value[2];
        if (fread(value, 1, 2, file) != 2) {
          free(samples);
          samples = NULL;
          break;
        }
        samples[i] = (float)(int16_t)le16(value) / 32768.0f;
      }
      break;
    } else if (fseek(file, (long)size + (size & 1), SEEK_CUR)) {
      break;
    }
  }
  fclose(file);
  return samples;
}

static void json_string(const char *text) {
  putchar('"');
  for (const unsigned char *p = (const unsigned char *)text; *p; ++p) {
    if (*p == '"' || *p == '\\') printf("\\%c", *p);
    else if (*p < 32) printf("\\u%04x", *p);
    else putchar(*p);
  }
  putchar('"');
}

static double monotonic_seconds(void) {
  struct timespec timestamp;
  clock_gettime(CLOCK_MONOTONIC, &timestamp);
  return timestamp.tv_sec + timestamp.tv_nsec / 1e9;
}

int main(int argc, char **argv) {
  if (argc != 4) {
    fprintf(stderr, "usage: %s SHERPA_LIBRARY MODEL TOKENS < wav-paths.txt\n", argv[0]);
    return 2;
  }
  char error[1024] = {0};
  if (!MemoEchoSherpaLoadLibrary(argv[1], error, sizeof(error))) {
    fprintf(stderr, "%s\n", error);
    return 1;
  }
  MemoEchoSherpaRecognizer *recognizer = MemoEchoSherpaCreateRecognizer(
      argv[2], argv[3], "zh", 1, 2, error, sizeof(error));
  if (!recognizer) {
    fprintf(stderr, "%s\n", error);
    return 1;
  }
  fprintf(stderr, "SenseVoice: sherpa=%s language=zh itn=1 threads=2\n",
          MemoEchoSherpaVersion());
  char *path = NULL;
  size_t capacity = 0;
  int failed = 0;
  while (getline(&path, &capacity, stdin) != -1) {
    path[strcspn(path, "\r\n")] = '\0';
    if (!path[0]) continue;
    int32_t count = 0;
    float *samples = read_wav(path, &count);
    if (!samples) {
      fprintf(stderr, "Invalid 16 kHz mono PCM16 WAV: %s\n", path);
      failed = 1;
      break;
    }
    double start = monotonic_seconds();
    char *text = MemoEchoSherpaRecognize(recognizer, samples, count, 16000,
                                        error, sizeof(error));
    double elapsed = monotonic_seconds() - start;
    free(samples);
    if (!text) {
      fprintf(stderr, "%s: %s\n", path, error);
      failed = 1;
      break;
    }
    printf("{\"path\":");
    json_string(path);
    printf(",\"text\":");
    json_string(text);
    printf(",\"decode_seconds\":%.6f}\n", elapsed);
    fflush(stdout);
    MemoEchoSherpaFreeString(text);
  }
  free(path);
  MemoEchoSherpaDestroyRecognizer(recognizer);
  return failed;
}
