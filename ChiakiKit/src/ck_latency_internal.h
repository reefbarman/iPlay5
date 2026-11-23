// Local-only measurements for the isolated device build. Nothing is serialized.
#pragma once
#include <stdbool.h>
#include <stdint.h>

void ck_latency_history_edge(void *sender, uint16_t seq, bool pressed);
void ck_latency_packet_begin(void *sender, uint16_t newest, uint8_t count, bool tail);
void ck_latency_packet_end(void);
void ck_latency_socket_result(bool full);
void ck_latency_sender_reset(void *sender);
