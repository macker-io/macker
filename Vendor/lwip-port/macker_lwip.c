#include "macker_lwip.h"

#include "lwip/def.h"
#include "lwip/init.h"
#include "lwip/ip4.h"
#include "lwip/ip4_addr.h"
#include "lwip/netif.h"
#include "lwip/pbuf.h"
#include "lwip/tcp.h"
#include "lwip/tcpip.h"
#include "lwip/udp.h"

#include <pthread.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#define MACKER_GATEWAY_IP 0xC0A8FF01u
#define MACKER_FIRST_PORT 40000u
#define MACKER_LAST_PORT 49999u
#define MACKER_MAX_PACKET 65535u
#define MACKER_MAX_PENDING (256u * 1024u)

typedef struct macker_tcp_flow macker_tcp_flow_t;
typedef struct macker_udp_flow macker_udp_flow_t;

struct macker_tcp_flow {
  struct macker_lwip *stack;
  uint32_t id;
  uint32_t remote_ip;
  uint16_t remote_port;
  uint32_t guest_ip;
  uint16_t guest_port;
  uint16_t local_port;
  bool outbound;
  struct tcp_pcb *listener;
  struct tcp_pcb *pcb;
  uint8_t *pending;
  size_t pending_length;
  size_t pending_offset;
  macker_tcp_flow_t *next;
};

struct macker_udp_flow {
  struct macker_lwip *stack;
  uint32_t id;
  uint32_t remote_ip;
  uint16_t remote_port;
  uint32_t guest_ip;
  uint16_t guest_port;
  uint16_t local_port;
  bool outbound;
  struct udp_pcb *pcb;
  macker_udp_flow_t *next;
};

struct macker_lwip {
  struct netif netif;
  macker_lwip_output_fn output;
  macker_lwip_event_fn event;
  void *context;
  uint16_t next_port;
  macker_tcp_flow_t *tcp;
  macker_udp_flow_t *udp;
};

static pthread_once_t tcpip_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t tcpip_init_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t tcpip_init_condition = PTHREAD_COND_INITIALIZER;
static bool tcpip_ready;

static void tcpip_ready_callback(void *arg) {
  (void)arg;
  pthread_mutex_lock(&tcpip_init_mutex);
  tcpip_ready = true;
  pthread_cond_signal(&tcpip_init_condition);
  pthread_mutex_unlock(&tcpip_init_mutex);
}

static void start_tcpip(void) {
  pthread_mutex_lock(&tcpip_init_mutex);
  tcpip_init(tcpip_ready_callback, NULL);
  while (!tcpip_ready) pthread_cond_wait(&tcpip_init_condition, &tcpip_init_mutex);
  pthread_mutex_unlock(&tcpip_init_mutex);
}

static void ensure_tcpip(void) {
  pthread_once(&tcpip_once, start_tcpip);
}

static void set_ip(ip4_addr_t *address, uint32_t value) {
  IP4_ADDR(address, (uint8_t)(value >> 24), (uint8_t)(value >> 16),
           (uint8_t)(value >> 8), (uint8_t)value);
}

static uint16_t read16(const uint8_t *data) {
  return (uint16_t)(((uint16_t)data[0] << 8) | data[1]);
}

static uint32_t read32(const uint8_t *data) {
  return ((uint32_t)data[0] << 24) | ((uint32_t)data[1] << 16) |
         ((uint32_t)data[2] << 8) | data[3];
}

static void write16(uint8_t *data, uint16_t value) {
  data[0] = (uint8_t)(value >> 8);
  data[1] = (uint8_t)value;
}

static void write32(uint8_t *data, uint32_t value) {
  data[0] = (uint8_t)(value >> 24);
  data[1] = (uint8_t)(value >> 16);
  data[2] = (uint8_t)(value >> 8);
  data[3] = (uint8_t)value;
}

static uint16_t checksum(const uint8_t *data, size_t length, uint32_t sum) {
  while (length >= 2) {
    sum += ((uint32_t)data[0] << 8) | data[1];
    data += 2;
    length -= 2;
  }
  if (length != 0) sum += (uint32_t)data[0] << 8;
  while (sum >> 16) sum = (sum & 0xffffu) + (sum >> 16);
  return (uint16_t)~sum;
}

static void fix_checksums(uint8_t *packet, size_t length) {
  if (length < 20 || (packet[0] >> 4) != 4) return;
  size_t header_length = (size_t)(packet[0] & 0x0f) * 4;
  size_t total_length = read16(packet + 2);
  if (header_length < 20 || total_length < header_length || total_length > length) return;
  packet[10] = 0;
  packet[11] = 0;
  write16(packet + 10, checksum(packet, header_length, 0));
  if (packet[9] != IP_PROTO_TCP && packet[9] != IP_PROTO_UDP) return;
  size_t transport_length = total_length - header_length;
  size_t checksum_offset = packet[9] == IP_PROTO_TCP ? 16 : 6;
  if (transport_length < checksum_offset + 2) return;
  uint32_t sum = 0;
  sum += (uint32_t)read16(packet + 12);
  sum += (uint32_t)read16(packet + 14);
  sum += (uint32_t)read16(packet + 16);
  sum += (uint32_t)read16(packet + 18);
  sum += packet[9];
  sum += (uint32_t)transport_length;
  packet[header_length + checksum_offset] = 0;
  packet[header_length + checksum_offset + 1] = 0;
  uint16_t value = checksum(packet + header_length, transport_length, sum);
  if (packet[9] == IP_PROTO_UDP && value == 0) value = 0xffff;
  write16(packet + header_length + checksum_offset, value);
}

static bool rewrite_input(uint8_t *packet, size_t length, uint16_t local_port) {
  if (length < 20 || (packet[0] >> 4) != 4) return false;
  size_t header_length = (size_t)(packet[0] & 0x0f) * 4;
  if (header_length < 20 || length < header_length + 8) return false;
  if (packet[9] != IP_PROTO_TCP && packet[9] != IP_PROTO_UDP) return false;
  write32(packet + 16, MACKER_GATEWAY_IP);
  write16(packet + header_length + 2, local_port);
  fix_checksums(packet, length);
  return true;
}

static bool rewrite_output(macker_tcp_flow_t *tcp, macker_udp_flow_t *udp,
                           uint8_t *packet, size_t length) {
  if (tcp == NULL && udp == NULL) return false;
  if (tcp != NULL && !tcp->outbound) return true;
  if (udp != NULL && !udp->outbound) return true;
  if (length < 20 || (packet[0] >> 4) != 4) return false;
  size_t header_length = (size_t)(packet[0] & 0x0f) * 4;
  if (header_length < 20 || length < header_length + 8) return false;
  uint32_t remote_ip = tcp != NULL ? tcp->remote_ip : udp->remote_ip;
  uint16_t remote_port = tcp != NULL ? tcp->remote_port : udp->remote_port;
  write32(packet + 12, remote_ip);
  write16(packet + header_length, remote_port);
  if (tcp != NULL) {
    write32(packet + 16, tcp->guest_ip);
    write16(packet + header_length + 2, tcp->guest_port);
  } else {
    write32(packet + 16, udp->guest_ip);
    write16(packet + header_length + 2, udp->guest_port);
  }
  fix_checksums(packet, length);
  return true;
}

static macker_tcp_flow_t *find_tcp(struct macker_lwip *stack, uint32_t id) {
  for (macker_tcp_flow_t *flow = stack->tcp; flow != NULL; flow = flow->next) {
    if (flow->id == id) return flow;
  }
  return NULL;
}

static macker_udp_flow_t *find_udp(struct macker_lwip *stack, uint32_t id) {
  for (macker_udp_flow_t *flow = stack->udp; flow != NULL; flow = flow->next) {
    if (flow->id == id) return flow;
  }
  return NULL;
}

static macker_tcp_flow_t *find_tcp_output(struct macker_lwip *stack,
                                          const uint8_t *packet, size_t length) {
  if (length < 28 || packet[9] != IP_PROTO_TCP) return NULL;
  size_t header_length = (size_t)(packet[0] & 0x0f) * 4;
  if (header_length < 20 || length < header_length + 4) return NULL;
  uint32_t destination = read32(packet + 16);
  uint16_t source_port = read16(packet + header_length);
  uint16_t destination_port = read16(packet + header_length + 2);
  for (macker_tcp_flow_t *flow = stack->tcp; flow != NULL; flow = flow->next) {
    if (flow->local_port == source_port &&
        ((flow->guest_ip == destination && flow->guest_port == destination_port) || flow->outbound)) return flow;
  }
  return NULL;
}

static macker_udp_flow_t *find_udp_output(struct macker_lwip *stack,
                                          const uint8_t *packet, size_t length) {
  if (length < 28 || packet[9] != IP_PROTO_UDP) return NULL;
  size_t header_length = (size_t)(packet[0] & 0x0f) * 4;
  if (header_length < 20 || length < header_length + 4) return NULL;
  uint32_t destination = read32(packet + 16);
  uint16_t source_port = read16(packet + header_length);
  uint16_t destination_port = read16(packet + header_length + 2);
  for (macker_udp_flow_t *flow = stack->udp; flow != NULL; flow = flow->next) {
    if (flow->local_port == source_port &&
        ((flow->guest_ip == destination && flow->guest_port == destination_port) || flow->outbound)) return flow;
  }
  return NULL;
}

static err_t macker_netif_output(struct netif *netif, struct pbuf *p,
                                 const ip4_addr_t *destination) {
  (void)destination;
  struct macker_lwip *stack = (struct macker_lwip *)netif->state;
  if (p == NULL || p->tot_len > MACKER_MAX_PACKET) return ERR_BUF;
  uint8_t *packet = malloc(p->tot_len);
  if (packet == NULL) return ERR_MEM;
  pbuf_copy_partial(p, packet, p->tot_len, 0);
  macker_tcp_flow_t *tcp = find_tcp_output(stack, packet, p->tot_len);
  macker_udp_flow_t *udp = tcp == NULL ? find_udp_output(stack, packet, p->tot_len) : NULL;
  if (tcp == NULL && udp == NULL) {
    free(packet);
    return ERR_OK;
  }
  rewrite_output(tcp, udp, packet, p->tot_len);
  if (stack->output != NULL) {
    stack->output(stack->context, tcp != NULL ? tcp->id : udp->id, packet, p->tot_len);
  }
  free(packet);
  return ERR_OK;
}

static err_t macker_netif_init(struct netif *netif) {
  struct macker_lwip *stack = (struct macker_lwip *)netif->state;
  netif->name[0] = 'm';
  netif->name[1] = 'k';
  netif->mtu = 1500;
  netif->flags = 0;
  netif->output = macker_netif_output;
  netif->linkoutput = NULL;
  (void)stack;
  return ERR_OK;
}

static void emit_event(struct macker_lwip *stack, uint32_t id, int event,
                       const void *data, size_t length) {
  if (stack->event != NULL) {
    stack->event(stack->context, id, event, data, length);
  }
}

static void tcp_pump(macker_tcp_flow_t *flow);
static void clear_tcp_callbacks(struct tcp_pcb *pcb);

static err_t tcp_connected(void *arg, struct tcp_pcb *pcb, err_t error) {
  macker_tcp_flow_t *flow = (macker_tcp_flow_t *)arg;
  if (error != ERR_OK) {
    emit_event(flow->stack, flow->id, MACKER_LWIP_EVENT_ERROR, NULL, 0);
    return error;
  }
  flow->pcb = pcb;
  emit_event(flow->stack, flow->id, MACKER_LWIP_EVENT_CONNECTED, NULL, 0);
  tcp_pump(flow);
  return ERR_OK;
}

static void attach_tcp_callbacks(struct tcp_pcb *pcb, macker_tcp_flow_t *flow);

static void close_tcp_listener(macker_tcp_flow_t *flow) {
  if (flow->listener == NULL || flow->pcb == NULL || flow->pcb->state == SYN_RCVD) return;
  struct tcp_pcb *listener = flow->listener;
  flow->listener = NULL;
  if (tcp_close(listener) != ERR_OK) tcp_abort(listener);
}

static err_t on_tcp_accept(void *arg, struct tcp_pcb *newpcb, err_t error) {
  macker_tcp_flow_t *flow = (macker_tcp_flow_t *)arg;
  if (error != ERR_OK || newpcb == NULL) return ERR_ABRT;
  flow->pcb = newpcb;
  attach_tcp_callbacks(newpcb, flow);
  emit_event(flow->stack, flow->id, MACKER_LWIP_EVENT_CONNECTED, NULL, 0);
  tcp_pump(flow);
  return ERR_OK;
}

static err_t tcp_receive(void *arg, struct tcp_pcb *pcb, struct pbuf *p,
                         err_t error) {
  (void)error;
  macker_tcp_flow_t *flow = (macker_tcp_flow_t *)arg;
  if (p == NULL) {
    clear_tcp_callbacks(pcb);
    flow->pcb = NULL;
    emit_event(flow->stack, flow->id, MACKER_LWIP_EVENT_CLOSED, NULL, 0);
    tcp_close(pcb);
    return ERR_OK;
  }
  if (p->tot_len != 0) {
    uint8_t *data = malloc(p->tot_len);
    if (data == NULL) {
      pbuf_free(p);
      return ERR_MEM;
    }
    pbuf_copy_partial(p, data, p->tot_len, 0);
    emit_event(flow->stack, flow->id, MACKER_LWIP_EVENT_DATA, data, p->tot_len);
    free(data);
  }
  tcp_recved(pcb, p->tot_len);
  pbuf_free(p);
  return ERR_OK;
}

static void tcp_error(void *arg, err_t error) {
  (void)error;
  macker_tcp_flow_t *flow = (macker_tcp_flow_t *)arg;
  flow->pcb = NULL;
  emit_event(flow->stack, flow->id, MACKER_LWIP_EVENT_ERROR, NULL, 0);
}

static err_t on_tcp_sent(void *arg, struct tcp_pcb *pcb, u16_t length) {
  (void)length;
  macker_tcp_flow_t *flow = (macker_tcp_flow_t *)arg;
  flow->pcb = pcb;
  tcp_pump(flow);
  return ERR_OK;
}

static void attach_tcp_callbacks(struct tcp_pcb *pcb, macker_tcp_flow_t *flow) {
  tcp_arg(pcb, flow);
  tcp_recv(pcb, tcp_receive);
  tcp_sent(pcb, on_tcp_sent);
  tcp_err(pcb, tcp_error);
}

static void tcp_pump(macker_tcp_flow_t *flow) {
  if (flow->pcb == NULL || flow->pcb->state != ESTABLISHED) return;
  while (flow->pending_offset < flow->pending_length && tcp_sndbuf(flow->pcb) > 0) {
    size_t remaining = flow->pending_length - flow->pending_offset;
    size_t amount = remaining < tcp_sndbuf(flow->pcb) ? remaining : tcp_sndbuf(flow->pcb);
    if (amount > 0xffffu) amount = 0xffffu;
    err_t result = tcp_write(flow->pcb, flow->pending + flow->pending_offset,
                             (u16_t)amount, TCP_WRITE_FLAG_COPY);
    if (result == ERR_MEM) break;
    if (result != ERR_OK) {
      emit_event(flow->stack, flow->id, MACKER_LWIP_EVENT_ERROR, NULL, 0);
      break;
    }
    flow->pending_offset += amount;
  }
  if (flow->pending_offset == flow->pending_length) {
    free(flow->pending);
    flow->pending = NULL;
    flow->pending_length = 0;
    flow->pending_offset = 0;
  } else if (flow->pending_offset != 0) {
    memmove(flow->pending, flow->pending + flow->pending_offset,
            flow->pending_length - flow->pending_offset);
    flow->pending_length -= flow->pending_offset;
    flow->pending_offset = 0;
  }
  tcp_output(flow->pcb);
}

static err_t input_packet(struct macker_lwip *stack, uint16_t local_port,
                          const uint8_t *packet, size_t length, bool rewrite) {
  if (packet == NULL || length == 0 || length > MACKER_MAX_PACKET) return ERR_ARG;
  uint8_t *copy = malloc(length);
  if (copy == NULL) return ERR_MEM;
  memcpy(copy, packet, length);
  if (rewrite && !rewrite_input(copy, length, local_port)) {
    free(copy);
    return ERR_VAL;
  }
  struct pbuf *p = pbuf_alloc(PBUF_RAW, (u16_t)length, PBUF_RAM);
  if (p == NULL) {
    free(copy);
    return ERR_MEM;
  }
  pbuf_take(p, copy, (u16_t)length);
  free(copy);
  err_t result = ip4_input(p, &stack->netif);
  return result;
}

static uint16_t next_port(struct macker_lwip *stack) {
  for (unsigned i = 0; i <= MACKER_LAST_PORT - MACKER_FIRST_PORT; i++) {
    uint16_t candidate = stack->next_port;
    stack->next_port = candidate >= MACKER_LAST_PORT ? MACKER_FIRST_PORT : candidate + 1;
    bool used = false;
    for (macker_tcp_flow_t *tcp = stack->tcp; tcp != NULL; tcp = tcp->next)
      used |= tcp->local_port == candidate;
    for (macker_udp_flow_t *udp = stack->udp; udp != NULL; udp = udp->next)
      used |= udp->local_port == candidate;
    if (!used) return candidate;
  }
  return 0;
}

struct init_netif_action { struct macker_lwip *stack; int result; };
static void init_netif_action(void *arg) {
  struct init_netif_action *action = arg;
  ip4_addr_t address, mask, gateway;
  set_ip(&address, MACKER_GATEWAY_IP);
  set_ip(&mask, 0u);
  set_ip(&gateway, 0u);
  action->result = netif_add(&action->stack->netif, &address, &mask, &gateway,
                             action->stack, macker_netif_init, ip4_input) != NULL ? 0 : -1;
  if (action->result == 0) {
    netif_set_default(&action->stack->netif);
    netif_set_up(&action->stack->netif);
    netif_set_link_up(&action->stack->netif);
  }
}

static int wait_action(void (*function)(void *), void *argument) {
  return tcpip_callback_wait(function, argument) == ERR_OK ? 0 : -1;
}

macker_lwip_t *macker_lwip_create(macker_lwip_output_fn output,
                                  macker_lwip_event_fn event,
                                  void *context) {
  ensure_tcpip();
  struct macker_lwip *stack = calloc(1, sizeof(*stack));
  if (stack == NULL) return NULL;
  stack->output = output;
  stack->event = event;
  stack->context = context;
  stack->next_port = MACKER_FIRST_PORT;
  struct init_netif_action action = { .stack = stack, .result = -1 };
  if (wait_action(init_netif_action, &action) != 0 || action.result != 0) {
    free(stack);
    return NULL;
  }
  return stack;
}

struct tcp_start_action {
  struct macker_lwip *stack;
  uint32_t id, remote_ip, guest_ip;
  uint16_t remote_port, guest_port, host_port;
  const uint8_t *packet;
  size_t length;
  int result;
};

static void tcp_outbound_start_action(void *arg) {
  struct tcp_start_action *action = arg;
  struct macker_lwip *stack = action->stack;
  macker_tcp_flow_t *flow = calloc(1, sizeof(*flow));
  if (flow == NULL) { action->result = -1; return; }
  uint16_t port = next_port(stack);
  if (port == 0) { free(flow); action->result = -1; return; }
  flow->stack = stack;
  flow->id = action->id;
  flow->remote_ip = action->remote_ip;
  flow->remote_port = action->remote_port;
  flow->guest_ip = action->guest_ip;
  flow->guest_port = action->guest_port;
  flow->outbound = true;
  flow->local_port = port;
  struct tcp_pcb *listener = tcp_new();
  if (listener == NULL) { free(flow); action->result = -1; return; }
  ip4_addr_t local;
  set_ip(&local, MACKER_GATEWAY_IP);
  if (tcp_bind(listener, &local, flow->local_port) != ERR_OK) {
    tcp_abort(listener); free(flow); action->result = -1; return;
  }
  flow->listener = tcp_listen_with_backlog(listener, 1);
  if (flow->listener == NULL) {
    tcp_abort(listener);
    free(flow);
    action->result = -1;
    return;
  }
  tcp_arg(flow->listener, flow);
  tcp_accept(flow->listener, on_tcp_accept);
  flow->next = stack->tcp;
  stack->tcp = flow;
  action->result = input_packet(stack, flow->local_port, action->packet, action->length, true) == ERR_OK ? 0 : -1;
  close_tcp_listener(flow);
}

static void tcp_inbound_start_action(void *arg) {
  struct tcp_start_action *action = arg;
  struct macker_lwip *stack = action->stack;
  macker_tcp_flow_t *flow = calloc(1, sizeof(*flow));
  if (flow == NULL) { action->result = -1; return; }
  flow->stack = stack;
  flow->id = action->id;
  flow->guest_ip = action->guest_ip;
  flow->guest_port = action->guest_port;
  flow->local_port = action->host_port;
  flow->outbound = false;
  flow->pcb = tcp_new();
  if (flow->pcb == NULL) { free(flow); action->result = -1; return; }
  ip4_addr_t local, guest;
  set_ip(&local, MACKER_GATEWAY_IP);
  set_ip(&guest, flow->guest_ip);
  if (tcp_bind(flow->pcb, &local, flow->local_port) != ERR_OK) {
    tcp_abort(flow->pcb); free(flow); action->result = -1; return;
  }
  attach_tcp_callbacks(flow->pcb, flow);
  flow->next = stack->tcp;
  stack->tcp = flow;
  if (tcp_connect(flow->pcb, &guest, flow->guest_port, tcp_connected) != ERR_OK) {
    stack->tcp = flow->next; tcp_abort(flow->pcb); free(flow); action->result = -1; return;
  }
  action->result = 0;
}

struct packet_action {
  struct macker_lwip *stack;
  uint32_t id;
  const uint8_t *packet;
  size_t length;
  int result;
};

static void tcp_input_action(void *arg) {
  struct packet_action *action = arg;
  macker_tcp_flow_t *flow = find_tcp(action->stack, action->id);
  if (flow == NULL) { action->result = -1; return; }
  action->result =
    input_packet(action->stack, flow->local_port, action->packet, action->length, flow->outbound) == ERR_OK ? 0 : -1;
  close_tcp_listener(flow);
  if (action->result == 0) tcp_pump(flow);
}

int macker_lwip_tcp_outbound_start(macker_lwip_t *stack, uint32_t flow_id,
                                   uint32_t remote_ip, uint16_t remote_port,
                                   uint32_t guest_ip, uint16_t guest_port,
                                   const uint8_t *packet, size_t length) {
  if (stack == NULL || packet == NULL) return -1;
  struct tcp_start_action action = { stack, flow_id, remote_ip, guest_ip, remote_port,
                                     guest_port, 0, packet, length, -1 };
  return wait_action(tcp_outbound_start_action, &action) == 0 ? action.result : -1;
}

int macker_lwip_tcp_inbound_start(macker_lwip_t *stack, uint32_t flow_id,
                                  uint32_t guest_ip, uint16_t guest_port,
                                  uint16_t host_port) {
  if (stack == NULL) return -1;
  struct tcp_start_action action = { stack, flow_id, 0, guest_ip, 0, guest_port,
                                     host_port, NULL, 0, -1 };
  return wait_action(tcp_inbound_start_action, &action) == 0 ? action.result : -1;
}

int macker_lwip_tcp_input(macker_lwip_t *stack, uint32_t flow_id,
                          const uint8_t *packet, size_t length) {
  if (stack == NULL || packet == NULL) return -1;
  struct packet_action action = { stack, flow_id, packet, length, -1 };
  return wait_action(tcp_input_action, &action) == 0 ? action.result : -1;
}

struct write_action { struct macker_lwip *stack; uint32_t id; const uint8_t *data; size_t length; int result; };
static void tcp_write_action(void *arg) {
  struct write_action *action = arg;
  macker_tcp_flow_t *flow = find_tcp(action->stack, action->id);
  if (flow == NULL || action->length > MACKER_MAX_PACKET) { action->result = -1; return; }
  if (action->length != 0) {
    if (flow->pending_length + action->length > MACKER_MAX_PENDING) { action->result = -1; return; }
    uint8_t *pending = realloc(flow->pending, flow->pending_length + action->length);
    if (pending == NULL) { action->result = -1; return; }
    memcpy(pending + flow->pending_length, action->data, action->length);
    flow->pending = pending;
    flow->pending_length += action->length;
  }
  tcp_pump(flow);
  action->result = 0;
}

int macker_lwip_tcp_write(macker_lwip_t *stack, uint32_t flow_id,
                          const uint8_t *data, size_t length) {
  if (stack == NULL || (length != 0 && data == NULL)) return -1;
  struct write_action action = { stack, flow_id, data, length, -1 };
  return wait_action(tcp_write_action, &action) == 0 ? action.result : -1;
}

static void tcp_fin_action(void *arg) {
  struct write_action *action = arg;
  macker_tcp_flow_t *flow = find_tcp(action->stack, action->id);
  action->result = flow == NULL || flow->pcb == NULL ? -1 : tcp_shutdown(flow->pcb, 0, 1);
}

int macker_lwip_tcp_fin(macker_lwip_t *stack, uint32_t flow_id) {
  if (stack == NULL) return -1;
  struct write_action action = { stack, flow_id, NULL, 0, -1 };
  return wait_action(tcp_fin_action, &action) == 0 ? action.result : -1;
}

static void clear_tcp_callbacks(struct tcp_pcb *pcb) {
  if (pcb == NULL) return;
  tcp_arg(pcb, NULL);
  tcp_recv(pcb, NULL);
  tcp_sent(pcb, NULL);
  tcp_err(pcb, NULL);
}

static void abort_tcp_pcb(struct tcp_pcb *pcb, bool listener) {
  if (pcb == NULL) return;
  clear_tcp_callbacks(pcb);
  if (listener) tcp_accept(pcb, NULL);
  tcp_abort(pcb);
}

static void tcp_close_action(void *arg) {
  struct write_action *action = arg;
  macker_tcp_flow_t **cursor = &action->stack->tcp;
  while (*cursor != NULL && (*cursor)->id != action->id) cursor = &(*cursor)->next;
  if (*cursor == NULL) { action->result = -1; return; }
  macker_tcp_flow_t *flow = *cursor;
  *cursor = flow->next;
  abort_tcp_pcb(flow->listener, true);
  abort_tcp_pcb(flow->pcb, false);
  free(flow->pending);
  free(flow);
  action->result = 0;
}

void macker_lwip_tcp_close(macker_lwip_t *stack, uint32_t flow_id) {
  if (stack == NULL) return;
  struct write_action action = { stack, flow_id, NULL, 0, -1 };
  (void)wait_action(tcp_close_action, &action);
}

static void udp_receive(void *arg, struct udp_pcb *pcb, struct pbuf *p,
                       const ip_addr_t *address, u16_t port) {
  (void)pcb;
  (void)address;
  (void)port;
  macker_udp_flow_t *flow = (macker_udp_flow_t *)arg;
  if (p == NULL) return;
  uint8_t *data = malloc(p->tot_len);
  if (data != NULL) {
    pbuf_copy_partial(p, data, p->tot_len, 0);
    emit_event(flow->stack, flow->id, MACKER_LWIP_EVENT_DATA, data, p->tot_len);
    free(data);
  }
  pbuf_free(p);
}

struct udp_start_action { struct macker_lwip *stack; uint32_t id, remote_ip, guest_ip; uint16_t remote_port, guest_port, host_port; int result; };
static void udp_input_action(void *arg);

static void udp_start_action(void *arg) {
  struct udp_start_action *action = arg;
  macker_udp_flow_t *flow = calloc(1, sizeof(*flow));
  if (flow == NULL) { action->result = -1; return; }
  flow->stack = action->stack;
  flow->id = action->id;
  flow->remote_ip = action->remote_ip;
  flow->remote_port = action->remote_port;
  flow->guest_ip = action->guest_ip;
  flow->guest_port = action->guest_port;
  flow->outbound = action->host_port == 0;
  flow->local_port = flow->outbound ? next_port(action->stack) : action->host_port;
  if (flow->local_port == 0) { free(flow); action->result = -1; return; }
  flow->pcb = udp_new();
  if (flow->pcb == NULL) { free(flow); action->result = -1; return; }
  ip4_addr_t local, guest;
  set_ip(&local, MACKER_GATEWAY_IP);
  set_ip(&guest, flow->guest_ip);
  if (udp_bind(flow->pcb, &local, flow->local_port) != ERR_OK ||
      udp_connect(flow->pcb, &guest, flow->guest_port) != ERR_OK) {
    udp_remove(flow->pcb); free(flow); action->result = -1; return;
  }
  udp_recv(flow->pcb, udp_receive, flow);
  flow->next = action->stack->udp;
  action->stack->udp = flow;
  action->result = 0;
}

int macker_lwip_udp_outbound_start(macker_lwip_t *stack, uint32_t flow_id,
                                   uint32_t remote_ip, uint16_t remote_port,
                                   uint32_t guest_ip, uint16_t guest_port,
                                   const uint8_t *packet, size_t length) {
  if (stack == NULL || packet == NULL) return -1;
  struct udp_start_action action = { stack, flow_id, remote_ip, guest_ip, remote_port, guest_port, 0, -1 };
  if (wait_action(udp_start_action, &action) != 0 || action.result != 0) return -1;
  struct packet_action input = { stack, flow_id, packet, length, -1 };
  return wait_action(udp_input_action, &input) == 0 ? input.result : -1;
}

int macker_lwip_udp_inbound_start(macker_lwip_t *stack, uint32_t flow_id,
                                  uint32_t guest_ip, uint16_t guest_port,
                                  uint16_t host_port) {
  if (stack == NULL) return -1;
  struct udp_start_action action = { stack, flow_id, 0, guest_ip, 0, guest_port, host_port, -1 };
  return wait_action(udp_start_action, &action) == 0 ? action.result : -1;
}

static void udp_input_action(void *arg) {
  struct packet_action *action = arg;
  macker_udp_flow_t *flow = find_udp(action->stack, action->id);
  if (flow == NULL) { action->result = -1; return; }
  action->result = input_packet(action->stack, flow->local_port,
                                action->packet, action->length, flow->outbound) == ERR_OK ? 0 : -1;
}

int macker_lwip_udp_input(macker_lwip_t *stack, uint32_t flow_id,
                          const uint8_t *packet, size_t length) {
  if (stack == NULL || packet == NULL) return -1;
  struct packet_action action = { stack, flow_id, packet, length, -1 };
  return wait_action(udp_input_action, &action) == 0 ? action.result : -1;
}

static void udp_write_action(void *arg) {
  struct write_action *action = arg;
  macker_udp_flow_t *flow = find_udp(action->stack, action->id);
  if (flow == NULL || flow->pcb == NULL || action->length > 0xffffu) { action->result = -1; return; }
  struct pbuf *p = pbuf_alloc(PBUF_TRANSPORT, (u16_t)action->length, PBUF_RAM);
  if (p == NULL) { action->result = -1; return; }
  pbuf_take(p, action->data, (u16_t)action->length);
  err_t result = udp_send(flow->pcb, p);
  pbuf_free(p);
  action->result = result == ERR_OK ? 0 : -1;
}

int macker_lwip_udp_write(macker_lwip_t *stack, uint32_t flow_id,
                          const uint8_t *data, size_t length) {
  if (stack == NULL || (length != 0 && data == NULL)) return -1;
  struct write_action action = { stack, flow_id, data, length, -1 };
  return wait_action(udp_write_action, &action) == 0 ? action.result : -1;
}

static void udp_close_action(void *arg) {
  struct write_action *action = arg;
  macker_udp_flow_t **cursor = &action->stack->udp;
  while (*cursor != NULL && (*cursor)->id != action->id) cursor = &(*cursor)->next;
  if (*cursor == NULL) return;
  macker_udp_flow_t *flow = *cursor;
  *cursor = flow->next;
  if (flow->pcb != NULL) udp_remove(flow->pcb);
  free(flow);
}

void macker_lwip_udp_close(macker_lwip_t *stack, uint32_t flow_id) {
  if (stack == NULL) return;
  struct write_action action = { stack, flow_id, NULL, 0, -1 };
  (void)wait_action(udp_close_action, &action);
}

static void destroy_action(void *arg) {
  struct macker_lwip *stack = arg;
  while (stack->tcp != NULL) {
    macker_tcp_flow_t *flow = stack->tcp;
    stack->tcp = flow->next;
    abort_tcp_pcb(flow->listener, true);
    abort_tcp_pcb(flow->pcb, false);
    free(flow->pending);
    free(flow);
  }
  while (stack->udp != NULL) {
    macker_udp_flow_t *flow = stack->udp;
    stack->udp = flow->next;
    if (flow->pcb != NULL) udp_remove(flow->pcb);
    free(flow);
  }
  netif_remove(&stack->netif);
}

void macker_lwip_destroy(macker_lwip_t *stack) {
  if (stack == NULL) return;
  (void)wait_action(destroy_action, stack);
  free(stack);
}
