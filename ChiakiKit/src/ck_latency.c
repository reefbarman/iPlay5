// Isolated controller-latency build only. No per-event logging or allocation.
#include "ck_bridge.h"
#include "ck_latency_internal.h"
#include <mach/mach_time.h>
#include <math.h>
#include <os/log.h>
#include <pthread.h>
#include <stdlib.h>

#define CAPACITY 512

typedef struct
{
    uint64_t entry, exit, sent;
    double age_ms;
    void *sender;
    uint16_t seq;
    bool pressed, recovery;
} Sample;

typedef struct
{
    Sample samples[CAPACITY];
    unsigned used, invalid, masked, overflow, failed;
} Run;

// The app has one active stream. Only the synchronous physical pad submission
// can bind a sample to a sequence; only that sender's UDP thread can finish it.
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static Run run;
static uint64_t base_id = 1;
static unsigned first_pending;
static _Thread_local uint64_t armed;
static _Thread_local struct
{
    void *sender;
    uint16_t newest;
    uint8_t count;
    bool tail;
} packet;

uint64_t ck_latency_ticks(void) { return mach_absolute_time(); }

double ck_latency_seconds(uint64_t ticks)
{
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    return ticks * ((double)tb.numer / tb.denom / 1e9);
}

static Sample *lookup(uint64_t id)
{
    return id >= base_id && id - base_id < run.used ? &run.samples[id - base_id] : NULL;
}

uint64_t ck_latency_begin(double age_seconds, uint64_t entry, bool pressed)
{
    pthread_mutex_lock(&lock);
    uint64_t id = 0;
    if (!entry || !isfinite(age_seconds) || age_seconds < 0)
        run.invalid++;
    else if (run.used == CAPACITY)
        run.overflow++;
    else
    {
        id = base_id + run.used;
        run.samples[run.used++] = (Sample){.entry = entry, .age_ms = age_seconds * 1000, .pressed = pressed};
    }
    pthread_mutex_unlock(&lock);
    return id;
}

void ck_latency_exit(uint64_t id)
{
    uint64_t now = ck_latency_ticks();
    pthread_mutex_lock(&lock);
    Sample *s = lookup(id);
    if (s)
        s->exit = now;
    pthread_mutex_unlock(&lock);
}

void ck_latency_arm(uint64_t id) { armed = id; }
void ck_latency_disarm(void) { armed = 0; }
void ck_latency_invalid(void)
{
    pthread_mutex_lock(&lock);
    run.invalid++;
    pthread_mutex_unlock(&lock);
}
void ck_latency_masked(void)
{
    pthread_mutex_lock(&lock);
    run.masked++;
    pthread_mutex_unlock(&lock);
}

void ck_latency_history_edge(void *sender, uint16_t seq, bool pressed)
{
    if (!armed)
        return;
    pthread_mutex_lock(&lock);
    Sample *s = lookup(armed);
    if (s && !s->sender && !s->sent && s->pressed == pressed)
    {
        s->sender = sender;
        s->seq = seq;
        unsigned index = (unsigned)(armed - base_id);
        if (index < first_pending)
            first_pending = index;
        armed = 0;
    }
    pthread_mutex_unlock(&lock);
}

void ck_latency_packet_begin(void *sender, uint16_t newest, uint8_t count, bool tail)
{
    packet.sender = sender;
    packet.newest = newest;
    packet.count = count;
    packet.tail = tail;
}
void ck_latency_packet_end(void) { packet.sender = NULL; }

void ck_latency_socket_result(bool full)
{
    if (!packet.sender)
        return;
    uint64_t now = ck_latency_ticks();
    pthread_mutex_lock(&lock);
    if (!full)
        run.failed++;
    for (unsigned i = first_pending; i < run.used; i++)
    {
        Sample *s = &run.samples[i];
        if (s->sender != packet.sender)
            continue;
        uint16_t behind = (uint16_t)(packet.newest - s->seq);
        if (behind < packet.count)
        {
            if (!full)
                continue;
            s->sent = now;
            s->recovery = packet.tail || behind != 0;
            s->sender = NULL;
        }
        else if (behind < 0x8000)
        {
            // Already outside the history window. Never match after a full wrap.
            s->sender = NULL;
        }
    }
    while (first_pending < run.used && !run.samples[first_pending].sender)
        first_pending++;
    pthread_mutex_unlock(&lock);
}

void ck_latency_sender_reset(void *sender)
{
    pthread_mutex_lock(&lock);
    for (unsigned i = first_pending; i < run.used; i++)
        if (!sender || run.samples[i].sender == sender)
            run.samples[i].sender = NULL;
    pthread_mutex_unlock(&lock);
}
void ck_latency_reset(void) { ck_latency_sender_reset(NULL); }

static int by_value(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

// Called once at teardown. Copy under lock; sorting and logging never hold it.
void ck_latency_report(void)
{
    pthread_mutex_lock(&lock);
    Run snapshot = run;
    base_id += run.used + 1;
    run = (Run){0};
    first_pending = 0;
    pthread_mutex_unlock(&lock);
    if (!snapshot.used && !snapshot.invalid && !snapshot.masked && !snapshot.overflow)
        return;
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    double ms = (double)tb.numer / tb.denom / 1e6;
    double metrics[4][CAPACITY];
    unsigned n = 0, down = 0, recovered = 0;
    for (unsigned i = 0; i < snapshot.used; i++)
    {
        Sample *s = &snapshot.samples[i];
        if (s->exit < s->entry || s->sent < s->entry)
            continue;
        down += s->pressed;
        if (s->recovery)
        {
            recovered++;
            continue;
        }
        metrics[0][n] = s->age_ms;
        metrics[1][n] = (s->exit - s->entry) * ms;
        metrics[2][n] = (s->sent - s->entry) * ms;
        metrics[3][n] = s->age_ms + metrics[2][n];
        n++;
    }
    os_log_t log = os_log_create("io.github.reefbarman.iplay5", "input-latency");
    os_log_with_type(log, OS_LOG_TYPE_DEFAULT, "Cross: matched down=%u up=%u primary=%u recovery=%u unmatched=%u invalid=%u masked=%u overflow=%u history_send_failures=%u", down, n + recovered - down, n, recovered, snapshot.used - n - recovered, snapshot.invalid, snapshot.masked, snapshot.overflow, snapshot.failed);
    const char *labels[] = {"event age at entry", "callback duration", "entry to socket", "estimated event to socket"};
    for (unsigned k = 0; n && k < 4; k++)
    {
        qsort(metrics[k], n, sizeof(double), by_value);
        os_log_with_type(log, OS_LOG_TYPE_DEFAULT, "%{public}s (ms, primary only): p50=%.3f p95=%.3f", labels[k], metrics[k][(n - 1) / 2], metrics[k][(95 * n + 99) / 100 - 1]);
    }
    os_release(log);
}
