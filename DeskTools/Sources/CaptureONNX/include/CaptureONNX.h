#pragma once
#include <stddef.h>
#include <stdint.h>
// Runtime and sessions live only in the short-lived OCR worker.
typedef struct CTOCRSession CTOCRSession;
CTOCRSession *ctocr_open(const char *runtime_path, const char *model_path, char *error, size_t error_capacity);
int ctocr_recognize(CTOCRSession *session, float *pixels, int width, int32_t *indices,
                    size_t capacity, size_t *count, char *error, size_t error_capacity);
void ctocr_close(CTOCRSession *session);
