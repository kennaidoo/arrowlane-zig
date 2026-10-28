#ifndef ARROWLAND_ZIG_H
#define ARROWLAND_ZIG_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define AL_OK 0
#define AL_ERR_INVALID -1
#define AL_ERR_FRAME -2
#define AL_ERR_PANIC -3
#define AL_ERR_BUFFER -4

typedef struct AlBuffer {
    uint8_t *data;
    size_t len;
    size_t cap;
} AlBuffer;

typedef struct AlDecision {
    uint8_t lane_id;
    double predicted_ms;
    uint64_t predicted_bytes;
    const char *reason;
} AlDecision;

const char *al_version(void);
int al_select(uint64_t rows, uint64_t arrow_bytes, uint8_t topology,
              uint8_t policy, bool shm_ready, AlDecision *out);
AlBuffer al_inspect(const uint8_t *data, size_t len);
AlBuffer al_repack(const uint8_t *data, size_t len, uint8_t lane_id);
void al_free(AlBuffer buffer);
void al_free_reason(const char *reason);

#ifdef __cplusplus
}
#endif

#endif
