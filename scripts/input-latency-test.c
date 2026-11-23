// macOS host smoke test. Build from the repository root:
// xcrun --sdk macosx clang -std=c11 -Wall -Wextra -Werror -DCK_INPUT_LATENCY_PROBE \
//   -IChiakiKit/include scripts/input-latency-test.c -o /tmp/input-latency-test
// /tmp/input-latency-test
#include <assert.h>
#include <stdio.h>

// Inspect the actual probe's samples and counters without exporting a test API.
#include "../ChiakiKit/src/ck_latency.c"

static char sender_a, sender_b;

static uint64_t event(bool pressed)
{
    uint64_t id = ck_latency_begin(0.125, ck_latency_ticks(), pressed);
    assert(id && lookup(id)->age_ms == 125.0);
    return id;
}

static uint64_t edge(void *sender, uint16_t seq, bool pressed)
{
    uint64_t id = event(pressed);
    ck_latency_arm(id);
    ck_latency_history_edge(sender, seq, pressed);
    ck_latency_disarm();
    assert(lookup(id)->sender == sender && lookup(id)->seq == seq);
    return id;
}

static void send_history(void *sender, uint16_t newest, uint8_t count, bool tail, bool full)
{
    ck_latency_packet_begin(sender, newest, count, tail);
    ck_latency_socket_result(full);
    ck_latency_packet_end();
}

static void test_wrap_overlap_and_old_queue(void)
{
    uint64_t down = edge(&sender_a, UINT16_MAX, true);
    uint64_t up = edge(&sender_a, 0, false);
    ck_latency_exit(down);
    send_history(&sender_a, UINT16_MAX - 1, 8, false, true);
    assert(!lookup(down)->sent && lookup(down)->sender == &sender_a);
    assert(!lookup(up)->sent && lookup(up)->sender == &sender_a);

    // The newer history packet includes both edges; only the newest is primary.
    send_history(&sender_a, 0, 2, false, true);
    assert(lookup(down)->sent >= lookup(down)->exit && lookup(down)->recovery);
    uint64_t sent = lookup(up)->sent;
    assert(sent >= lookup(up)->entry && !lookup(up)->recovery && !lookup(up)->exit);
    ck_latency_exit(up);
    assert(lookup(up)->exit >= sent);

    // A duplicate must not overwrite a primary result or its timestamp.
    send_history(&sender_a, 0, 2, true, true);
    assert(lookup(up)->sent == sent && !lookup(up)->recovery);
}

static void test_failed_send_and_expiry(void)
{
    uint64_t retry = edge(&sender_a, 12, true);
    ck_latency_exit(retry);
    send_history(&sender_a, 12, 1, false, false);
    assert(run.failed == 1 && !lookup(retry)->sent && lookup(retry)->sender == &sender_a);
    send_history(&sender_a, 12, 1, true, true);
    assert(run.failed == 1 && lookup(retry)->sent >= lookup(retry)->exit && lookup(retry)->recovery);

    uint64_t expired = edge(&sender_a, 13, false);
    send_history(&sender_a, 21, 8, false, true); // Exactly outside the history window.
    assert(!lookup(expired)->sender && !lookup(expired)->sent);
    send_history(&sender_a, 13, 1, false, true); // Sequence reused after wrap.
    assert(!lookup(expired)->sent);
}

static void test_unarmed_normal_and_missing_edges(void)
{
    uint64_t no_edge = event(true);
    ck_latency_arm(no_edge);
    ck_latency_history_edge(&sender_a, 48, false); // Opposite transition is not the original edge.
    ck_latency_disarm();
    ck_latency_exit(no_edge);
    ck_latency_history_edge(&sender_a, 49, true); // Later virtual edge is unarmed.
    send_history(&sender_a, 49, 2, false, true);
    assert(!lookup(no_edge)->sender && !lookup(no_edge)->sent);

    uint64_t pending = edge(&sender_a, 50, false);
    send_history(&sender_b, 50, 1, false, true);
    ck_latency_packet_begin(&sender_a, 50, 1, false);
    ck_latency_packet_end();
    ck_latency_socket_result(false); // Ordinary traffic cannot count or finish the sample.
    ck_latency_socket_result(true);
    assert(run.failed == 0 && !lookup(pending)->sent && lookup(pending)->sender == &sender_a);
    send_history(&sender_a, 50, 1, false, true);
    assert(lookup(pending)->sent >= lookup(pending)->entry && !lookup(pending)->recovery);
}

static void test_session_resets(void)
{
    uint64_t old = edge(&sender_a, 8, true);
    uint64_t other = edge(&sender_b, 8, true);
    ck_latency_sender_reset(&sender_a);
    send_history(&sender_a, 8, 1, false, true);
    assert(!lookup(old)->sent && lookup(other)->sender == &sender_b);
    send_history(&sender_b, 8, 1, false, true);
    assert(lookup(other)->sent >= lookup(other)->entry);

    uint64_t pending = edge(&sender_b, 9, false);
    ck_latency_reset();
    send_history(&sender_b, 9, 1, false, true);
    assert(!lookup(pending)->sender && !lookup(pending)->sent);
    ck_latency_masked();
    ck_latency_invalid();
    assert(run.masked == 1 && run.invalid == 1);
    ck_latency_report();
    assert(!run.used && !run.failed && !run.masked && !run.invalid && !lookup(pending));

    uint64_t fresh = edge(&sender_b, 9, false);
    ck_latency_exit(pending); // An old callback ID cannot update the next run.
    assert(fresh > pending && !lookup(fresh)->exit);
    ck_latency_exit(fresh);
    send_history(&sender_b, 9, 1, false, true);
    assert(lookup(fresh)->sent >= lookup(fresh)->exit && !lookup(fresh)->recovery);
}

int main(void)
{
    test_wrap_overlap_and_old_queue();
    ck_latency_report();
    test_failed_send_and_expiry();
    ck_latency_report();
    test_unarmed_normal_and_missing_edges();
    ck_latency_report();
    test_session_resets();
    ck_latency_report();
    puts("input latency smoke test passed");
    return 0;
}
