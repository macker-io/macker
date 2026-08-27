#ifndef MACKER_LWIPOPTS_H
#define MACKER_LWIPOPTS_H

#define NO_SYS 0
#define LWIP_SOCKET 0
#define LWIP_NETCONN 0
#define LWIP_RAW 1
#define LWIP_IPV4 1
#define LWIP_IPV6 0
#define LWIP_ETHERNET 0
#define LWIP_ARP 0
#define LWIP_DHCP 0
#define LWIP_AUTOIP 0
#define LWIP_IGMP 0
#define LWIP_SINGLE_NETIF 1
#define LWIP_NETIF_API 0
#define LWIP_TIMERS 1
#define LWIP_TCP 1
#define LWIP_UDP 1
#define LWIP_ICMP 0
#define LWIP_ICMP6 0
#define LWIP_DNS 0
#define LWIP_SNMP 0
#define LWIP_MDNS_RESPONDER 0
#define LWIP_STATS 0
#define LWIP_DEBUG 0
#define LWIP_PROVIDE_ERRNO 0
#define LWIP_NETIF_HOSTNAME 0
#define LWIP_CHECKSUM_ON_COPY 0

/*
 * Core locking is the low-overhead path lwIP recommends: wait_action becomes
 * lock + call instead of a per-packet semaphore. Checksums on the virtio path
 * are rewritten by the glue, so inbound verification is skipped (gvisor-style
 * offload). Window scale lets TCP_WND / TCP_SND_BUF exceed 64 KiB, matching
 * netstack's "large BDP buffers" tuning. Outbound checksums are filled once
 * in the glue after NAT rewrite, so lwIP generation is disabled.
 */
#define LWIP_TCPIP_CORE_LOCKING 1
#define LWIP_TCPIP_THREAD_STACKSIZE 0
#define LWIP_TCPIP_THREAD_PRIO 0
#define TCPIP_MBOX_SIZE 256
#define MEMP_NUM_TCPIP_MSG_API 64
#define MEMP_NUM_TCPIP_MSG_INPKT 64
#define MEMP_NUM_SYS_TIMEOUT 16

#define CHECKSUM_CHECK_IP 0
#define CHECKSUM_CHECK_TCP 0
#define CHECKSUM_CHECK_UDP 0
#define CHECKSUM_GEN_IP 0
#define CHECKSUM_GEN_TCP 0
#define CHECKSUM_GEN_UDP 0

#define LWIP_WND_SCALE 1
#define TCP_RCV_SCALE 7
#define MEM_SIZE (8 * 1024 * 1024)
#define MEMP_NUM_TCP_PCB 256
#define MEMP_NUM_TCP_PCB_LISTEN 256
#define MEMP_NUM_TCP_SEG 2048
#define MEMP_NUM_UDP_PCB 256
#define MEMP_NUM_PBUF 2048
#define PBUF_POOL_SIZE 1024
/* 4096 stays under lwIP's u16 SNDLOWAT check (8*MSS < 0xFFFF-4*MSS) while
 * cutting virtio TCP pps ~3× versus 1460. Guest eth0 MTU is 65535. */
#define PBUF_POOL_BUFSIZE 4160
#define TCP_MSS 4096
#define TCP_WND (1024 * 1024)
#define TCP_SND_BUF (1024 * 1024)
#define TCP_SND_QUEUELEN 2048
#define TCP_SNDLOWAT (8 * TCP_MSS)
#define TCP_SNDQUEUELOWAT (TCP_SND_QUEUELEN / 4)
#define TCP_QUEUE_OOSEQ 1
#define TCP_OVERSIZE TCP_MSS
#define LWIP_NETIF_TX_SINGLE_PBUF 1
#define IP_REASSEMBLY 1
#define IP_FRAG 0
#define IP_OPTIONS_ALLOWED 1

#endif
