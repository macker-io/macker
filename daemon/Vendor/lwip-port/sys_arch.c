#include "lwip/sys.h"
#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <time.h>

struct macker_lwip_sem { pthread_mutex_t mutex; pthread_cond_t condition; unsigned count; int valid; };
struct macker_lwip_mutex { pthread_mutex_t mutex; int valid; };
struct macker_lwip_mbox { pthread_mutex_t mutex; pthread_cond_t not_empty; pthread_cond_t not_full; void **messages; unsigned capacity, head, tail, count; int valid; };

static struct timespec realtime_deadline(u32_t timeout) {
  struct timespec value;
  clock_gettime(CLOCK_REALTIME, &value);
  value.tv_sec += timeout / 1000;
  value.tv_nsec += (long)(timeout % 1000) * 1000000L;
  if (value.tv_nsec >= 1000000000L) { value.tv_sec++; value.tv_nsec -= 1000000000L; }
  return value;
}
static u32_t elapsed_ms(struct timespec start) {
  struct timespec end; clock_gettime(CLOCK_MONOTONIC, &end);
  uint64_t a = (uint64_t)start.tv_sec * 1000 + start.tv_nsec / 1000000;
  uint64_t b = (uint64_t)end.tv_sec * 1000 + end.tv_nsec / 1000000;
  uint64_t value = b >= a ? b - a : 1;
  return value > UINT32_MAX ? UINT32_MAX : (u32_t)value;
}

void sys_init(void) {}

err_t sys_mutex_new(sys_mutex_t *mutex) {
  struct macker_lwip_mutex *value = calloc(1, sizeof(*value));
  if (value == NULL || pthread_mutex_init(&value->mutex, NULL) != 0) { free(value); return ERR_MEM; }
  value->valid = 1; *mutex = value; return ERR_OK;
}
void sys_mutex_lock(sys_mutex_t *mutex) { if (mutex && *mutex) pthread_mutex_lock(&(*mutex)->mutex); }
void sys_mutex_unlock(sys_mutex_t *mutex) { if (mutex && *mutex) pthread_mutex_unlock(&(*mutex)->mutex); }
void sys_mutex_free(sys_mutex_t *mutex) { if (!mutex || !*mutex) return; struct macker_lwip_mutex *v=*mutex; v->valid=0; pthread_mutex_destroy(&v->mutex); free(v); *mutex=NULL; }
int sys_mutex_valid(sys_mutex_t *mutex) { return mutex && *mutex && (*mutex)->valid; }
void sys_mutex_set_invalid(sys_mutex_t *mutex) { if (mutex && *mutex) (*mutex)->valid=0; }

err_t sys_sem_new(sys_sem_t *sem, u8_t count) {
  struct macker_lwip_sem *value=calloc(1,sizeof(*value));
  if (!value || pthread_mutex_init(&value->mutex,NULL)!=0 || pthread_cond_init(&value->condition,NULL)!=0) { if(value){pthread_mutex_destroy(&value->mutex);free(value);} return ERR_MEM; }
  value->count=count ? 1 : 0; value->valid=1; *sem=value; return ERR_OK;
}
void sys_sem_signal(sys_sem_t *sem) { if(!sem||!*sem)return; struct macker_lwip_sem*v=*sem; pthread_mutex_lock(&v->mutex); v->count=1; pthread_cond_signal(&v->condition); pthread_mutex_unlock(&v->mutex); }
u32_t sys_arch_sem_wait(sys_sem_t *sem, u32_t timeout) {
  if(!sem||!*sem)return SYS_ARCH_TIMEOUT; struct macker_lwip_sem*v=*sem; struct timespec start; clock_gettime(CLOCK_MONOTONIC,&start); pthread_mutex_lock(&v->mutex);
  while(v->count==0&&v->valid){ int result; if(timeout==0) result=pthread_cond_wait(&v->condition,&v->mutex); else { struct timespec deadline=realtime_deadline(timeout); result=pthread_cond_timedwait(&v->condition,&v->mutex,&deadline); } if(result==ETIMEDOUT){pthread_mutex_unlock(&v->mutex);return SYS_ARCH_TIMEOUT;} }
  if(v->count)v->count=0; pthread_mutex_unlock(&v->mutex); return elapsed_ms(start);
}
void sys_sem_free(sys_sem_t *sem){if(!sem||!*sem)return;struct macker_lwip_sem*v=*sem;v->valid=0;pthread_cond_broadcast(&v->condition);pthread_cond_destroy(&v->condition);pthread_mutex_destroy(&v->mutex);free(v);*sem=NULL;}
int sys_sem_valid(sys_sem_t *sem){return sem&&*sem&&(*sem)->valid;}
void sys_sem_set_invalid(sys_sem_t *sem){if(sem&&*sem)(*sem)->valid=0;}

err_t sys_mbox_new(sys_mbox_t *mbox,int size){
  unsigned capacity=size>0?(unsigned)size:64; struct macker_lwip_mbox*v=calloc(1,sizeof(*v)); if(!v)return ERR_MEM; v->messages=calloc(capacity,sizeof(void*));
  if(!v->messages||pthread_mutex_init(&v->mutex,NULL)!=0||pthread_cond_init(&v->not_empty,NULL)!=0||pthread_cond_init(&v->not_full,NULL)!=0){free(v->messages);free(v);return ERR_MEM;}
  v->capacity=capacity;v->valid=1;*mbox=v;return ERR_OK;
}
static void mbox_push(struct macker_lwip_mbox*v,void*message){v->messages[v->tail]=message;v->tail=(v->tail+1)%v->capacity;v->count++;pthread_cond_signal(&v->not_empty);}
static void*mbox_pop(struct macker_lwip_mbox*v){void*message=v->messages[v->head];v->messages[v->head]=NULL;v->head=(v->head+1)%v->capacity;v->count--;pthread_cond_signal(&v->not_full);return message;}
void sys_mbox_post(sys_mbox_t *mbox,void*message){if(!mbox||!*mbox)return;struct macker_lwip_mbox*v=*mbox;pthread_mutex_lock(&v->mutex);while(v->count==v->capacity&&v->valid)pthread_cond_wait(&v->not_full,&v->mutex);if(v->valid)mbox_push(v,message);pthread_mutex_unlock(&v->mutex);}
err_t sys_mbox_trypost(sys_mbox_t *mbox,void*message){if(!mbox||!*mbox)return ERR_ARG;struct macker_lwip_mbox*v=*mbox;pthread_mutex_lock(&v->mutex);if(!v->valid||v->count==v->capacity){pthread_mutex_unlock(&v->mutex);return ERR_MEM;}mbox_push(v,message);pthread_mutex_unlock(&v->mutex);return ERR_OK;}
err_t sys_mbox_trypost_fromisr(sys_mbox_t *mbox,void*message){return sys_mbox_trypost(mbox,message);}
u32_t sys_arch_mbox_fetch(sys_mbox_t *mbox,void**message,u32_t timeout){
  if(!mbox||!*mbox)return SYS_ARCH_TIMEOUT;struct macker_lwip_mbox*v=*mbox;struct timespec start;clock_gettime(CLOCK_MONOTONIC,&start);pthread_mutex_lock(&v->mutex);
  while(v->count==0&&v->valid){if(timeout==0)pthread_cond_wait(&v->not_empty,&v->mutex);else{struct timespec deadline=realtime_deadline(timeout);if(pthread_cond_timedwait(&v->not_empty,&v->mutex,&deadline)==ETIMEDOUT){pthread_mutex_unlock(&v->mutex);return SYS_ARCH_TIMEOUT;}}}
  if(v->count==0){pthread_mutex_unlock(&v->mutex);return SYS_ARCH_TIMEOUT;}if(message)*message=mbox_pop(v);else(void)mbox_pop(v);pthread_mutex_unlock(&v->mutex);return elapsed_ms(start);
}
u32_t sys_arch_mbox_tryfetch(sys_mbox_t *mbox,void**message){if(!mbox||!*mbox)return SYS_MBOX_EMPTY;struct macker_lwip_mbox*v=*mbox;pthread_mutex_lock(&v->mutex);if(v->count==0){pthread_mutex_unlock(&v->mutex);return SYS_MBOX_EMPTY;}if(message)*message=mbox_pop(v);else(void)mbox_pop(v);pthread_mutex_unlock(&v->mutex);return 0;}
void sys_mbox_free(sys_mbox_t *mbox){if(!mbox||!*mbox)return;struct macker_lwip_mbox*v=*mbox;v->valid=0;pthread_cond_broadcast(&v->not_empty);pthread_cond_broadcast(&v->not_full);pthread_cond_destroy(&v->not_empty);pthread_cond_destroy(&v->not_full);pthread_mutex_destroy(&v->mutex);free(v->messages);free(v);*mbox=NULL;}
int sys_mbox_valid(sys_mbox_t *mbox){return mbox&&*mbox&&(*mbox)->valid;}
void sys_mbox_set_invalid(sys_mbox_t *mbox){if(mbox&&*mbox)(*mbox)->valid=0;}

struct thread_start { lwip_thread_fn function; void *argument; };
static void *thread_entry(void *argument){struct thread_start *start=argument;lwip_thread_fn function=start->function;void *value=start->argument;free(start);function(value);return NULL;}
sys_thread_t sys_thread_new(const char*name,lwip_thread_fn function,void*argument,int stacksize,int prio){(void)name;(void)prio;pthread_t result;pthread_attr_t attributes;pthread_attr_init(&attributes);if(stacksize>0)pthread_attr_setstacksize(&attributes,(size_t)stacksize);struct thread_start*start=malloc(sizeof(*start));if(!start){pthread_attr_destroy(&attributes);return (pthread_t)0;}start->function=function;start->argument=argument;if(pthread_create(&result,&attributes,thread_entry,start)!=0){free(start);result=(pthread_t)0;}else pthread_detach(result);pthread_attr_destroy(&attributes);return result;}
void sys_msleep(u32_t milliseconds){struct timespec value={.tv_sec=milliseconds/1000,.tv_nsec=(long)(milliseconds%1000)*1000000L};nanosleep(&value,NULL);}
u32_t sys_now(void) {
  static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
  static uint64_t start;
  struct timespec value;
  clock_gettime(CLOCK_MONOTONIC, &value);
  uint64_t current = (uint64_t)value.tv_sec * 1000 + value.tv_nsec / 1000000;
  pthread_mutex_lock(&lock);
  if (!start) start = current;
  uint64_t base = start;
  pthread_mutex_unlock(&lock);
  return (u32_t)(current - base);
}
u32_t sys_jiffies(void) { return sys_now(); }

static pthread_mutex_t protect_mutex;
static pthread_once_t protect_once = PTHREAD_ONCE_INIT;
static void init_protect(void) {
  pthread_mutexattr_t attr;
  pthread_mutexattr_init(&attr);
  pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
  pthread_mutex_init(&protect_mutex, &attr);
  pthread_mutexattr_destroy(&attr);
}
sys_prot_t sys_arch_protect(void) {
  pthread_once(&protect_once, init_protect);
  pthread_mutex_lock(&protect_mutex);
  return 1;
}
void sys_arch_unprotect(sys_prot_t protection) {
  (void)protection;
  pthread_mutex_unlock(&protect_mutex);
}
