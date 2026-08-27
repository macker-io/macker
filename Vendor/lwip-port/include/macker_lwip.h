#ifndef MACKER_LWIP_H
#define MACKER_LWIP_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct macker_lwip macker_lwip_t;

typedef void (*macker_lwip_output_fn)(void *context, uint32_t flow_id,
                                      const uint8_t *packet, size_t length);
typedef void (*macker_lwip_event_fn)(void *context, uint32_t flow_id, int event,
                                     const uint8_t *data, size_t length);

enum {
  MACKER_LWIP_EVENT_CONNECTED = 1,
  MACKER_LWIP_EVENT_DATA = 2,
  MACKER_LWIP_EVENT_CLOSED = 3,
  MACKER_LWIP_EVENT_ERROR = 4,
  /* Host→guest sndbuf/pending has drained; Swift may resume socket reads. */
  MACKER_LWIP_EVENT_WRITABLE = 5
};

macker_lwip_t *macker_lwip_create(macker_lwip_output_fn output,
                                  macker_lwip_event_fn event,
                                  void *context);
void macker_lwip_destroy(macker_lwip_t *stack);

int macker_lwip_tcp_outbound_start(macker_lwip_t *stack, uint32_t flow_id,
                                   uint32_t remote_ip, uint16_t remote_port,
                                   uint32_t guest_ip, uint16_t guest_port,
                                   const uint8_t *packet, size_t length);
int macker_lwip_tcp_inbound_start(macker_lwip_t *stack, uint32_t flow_id,
                                  uint32_t guest_ip, uint16_t guest_port,
                                  uint16_t host_port);
int macker_lwip_tcp_input(macker_lwip_t *stack, uint32_t flow_id,
                          const uint8_t *packet, size_t length);
int macker_lwip_tcp_input_many(macker_lwip_t *stack, const uint32_t *flow_ids,
                               const uint8_t *const *packets, const size_t *lengths,
                               size_t count);
int macker_lwip_tcp_write(macker_lwip_t *stack, uint32_t flow_id,
                          const uint8_t *data, size_t length);
int macker_lwip_tcp_fin(macker_lwip_t *stack, uint32_t flow_id);
void macker_lwip_tcp_close(macker_lwip_t *stack, uint32_t flow_id);

int macker_lwip_udp_outbound_start(macker_lwip_t *stack, uint32_t flow_id,
                                   uint32_t remote_ip, uint16_t remote_port,
                                   uint32_t guest_ip, uint16_t guest_port,
                                   const uint8_t *packet, size_t length);
int macker_lwip_udp_inbound_start(macker_lwip_t *stack, uint32_t flow_id,
                                  uint32_t guest_ip, uint16_t guest_port,
                                  uint16_t host_port);
int macker_lwip_udp_input(macker_lwip_t *stack, uint32_t flow_id,
                          const uint8_t *packet, size_t length);
int macker_lwip_udp_write(macker_lwip_t *stack, uint32_t flow_id,
                          const uint8_t *data, size_t length);
void macker_lwip_udp_close(macker_lwip_t *stack, uint32_t flow_id);

#ifdef __cplusplus
}
#endif

#endif
