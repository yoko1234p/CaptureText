#include "CaptureONNX.h"
#include "vendor/onnxruntime_c_api.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct CTOCRSession {
    void *library;
    const OrtApi *api;
    OrtEnv *env;
    OrtSession *session;
    OrtSessionOptions *options;
    OrtAllocator *allocator;
    char *input_name;
    char *output_name;
};

static int check(CTOCRSession *s, OrtStatus *status, char *error, size_t capacity) {
    if (!status) return 1;
    if (capacity) snprintf(error, capacity, "%s", s->api->GetErrorMessage(status));
    s->api->ReleaseStatus(status);
    return 0;
}

void ctocr_close(CTOCRSession *s) {
    if (!s) return;
    if (s->allocator) {
        if (s->input_name) s->allocator->Free(s->allocator, s->input_name);
        if (s->output_name) s->allocator->Free(s->allocator, s->output_name);
    }
    if (s->api) {
        if (s->session) s->api->ReleaseSession(s->session);
        if (s->options) s->api->ReleaseSessionOptions(s->options);
        if (s->env) s->api->ReleaseEnv(s->env);
    }
    if (s->library) dlclose(s->library);
    free(s);
}

CTOCRSession *ctocr_open(const char *runtime, const char *model, char *error, size_t cap) {
    CTOCRSession *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    s->library = dlopen(runtime, RTLD_NOW | RTLD_LOCAL);
    if (!s->library) { if (cap) snprintf(error, cap, "Cannot load OCR runtime"); goto failure; }
    const OrtApiBase *(*base)(void) = dlsym(s->library, "OrtGetApiBase");
    if (!base || !(s->api = base()->GetApi(ORT_API_VERSION))) {
        if (cap) snprintf(error, cap, "Incompatible OCR runtime"); goto failure;
    }
    if (!check(s, s->api->CreateEnv(ORT_LOGGING_LEVEL_ERROR, "CaptureText", &s->env), error, cap) ||
        !check(s, s->api->CreateSessionOptions(&s->options), error, cap) ||
        !check(s, s->api->SetIntraOpNumThreads(s->options, 2), error, cap) ||
        !check(s, s->api->SetInterOpNumThreads(s->options, 1), error, cap) ||
        !check(s, s->api->CreateSession(s->env, model, s->options, &s->session), error, cap) ||
        !check(s, s->api->GetAllocatorWithDefaultOptions(&s->allocator), error, cap) ||
        !check(s, s->api->SessionGetInputName(s->session, 0, s->allocator, &s->input_name), error, cap) ||
        !check(s, s->api->SessionGetOutputName(s->session, 0, s->allocator, &s->output_name), error, cap)) goto failure;
    return s;
failure:
    ctocr_close(s);
    return NULL;
}

int ctocr_recognize(CTOCRSession *s, float *pixels, int width, int32_t *indices,
                    size_t capacity, size_t *count, char *error, size_t cap) {
    if (!s || !pixels || width < 1 || width > 3200 || !indices || !count) return 0;
    *count = 0;
    OrtMemoryInfo *memory = NULL;
    OrtValue *input = NULL, *output = NULL;
    OrtTensorTypeAndShapeInfo *shape = NULL;
    float *data = NULL;
    int64_t dimensions[3] = {0};
    size_t rank = 0, elements = 0;
    int ok = 0;
    const int64_t input_shape[] = {1, 3, 48, width};
    if (!check(s, s->api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memory), error, cap) ||
        !check(s, s->api->CreateTensorWithDataAsOrtValue(memory, pixels, (size_t)width * 48 * 3 * sizeof(float),
            input_shape, 4, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &input), error, cap) ||
        !check(s, s->api->Run(s->session, NULL, (const char *const *)&s->input_name,
            (const OrtValue *const *)&input, 1, (const char *const *)&s->output_name, 1, &output), error, cap) ||
        !check(s, s->api->GetTensorTypeAndShape(output, &shape), error, cap) ||
        !check(s, s->api->GetDimensionsCount(shape, &rank), error, cap) || rank != 3 ||
        !check(s, s->api->GetDimensions(shape, dimensions, 3), error, cap) ||
        !check(s, s->api->GetTensorShapeElementCount(shape, &elements), error, cap)) goto done;
    if (dimensions[0] != 1 || dimensions[1] < 1 || (size_t)dimensions[1] > capacity ||
        dimensions[2] < 2 || dimensions[2] > 30000 || elements != (size_t)dimensions[1] * dimensions[2]) goto done;
    if (!check(s, s->api->GetTensorMutableData(output, (void **)&data), error, cap)) goto done;
    for (size_t t = 0; t < (size_t)dimensions[1]; t++) {
        const float *row = data + t * dimensions[2];
        int32_t best = 0;
        for (int32_t k = 1; k < dimensions[2]; k++) if (row[k] > row[best]) best = k;
        indices[t] = best;
    }
    *count = (size_t)dimensions[1];
    ok = 1;
done:
    if (shape) s->api->ReleaseTensorTypeAndShapeInfo(shape);
    if (output) s->api->ReleaseValue(output);
    if (input) s->api->ReleaseValue(input);
    if (memory) s->api->ReleaseMemoryInfo(memory);
    return ok;
}
