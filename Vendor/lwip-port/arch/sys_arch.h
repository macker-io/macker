#ifndef MACKER_LWIP_SYS_ARCH_H
#define MACKER_LWIP_SYS_ARCH_H

#include <pthread.h>
#include <stdint.h>

struct macker_lwip_sem;
struct macker_lwip_mutex;
struct macker_lwip_mbox;

typedef struct macker_lwip_sem *sys_sem_t;
typedef struct macker_lwip_mutex *sys_mutex_t;
typedef struct macker_lwip_mbox *sys_mbox_t;
typedef pthread_t sys_thread_t;
typedef uintptr_t sys_prot_t;

#endif
