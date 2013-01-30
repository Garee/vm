#ifdef KERNEL_TEST_ENABLED
#include "../tests/kerneltypes.h"
#endif

#include "SharedMacros.h"
#include "SharedTypes.h"

/* Used to create, manipulate and access packet information. */
#define PKT_TYPE_SHIFT 0
#define PKT_DEST_SHIFT 2
#define PKT_ARG_SHIFT  10
#define PKT_SUB_SHIFT  14
#define PKT_TYPE_MASK  0x3      // 00000000000000000000000000000011
#define PKT_DEST_MASK  0x3FC    // 00000000000000000000001111111100
#define PKT_ARG_MASK   0x3C00   // 00000000000000000011110000000000
#define PKT_SUB_MASK   0xFFC000 // 00000000111111111100000000000000

/* Used to access symbol information. */
#define SYMBOL_KIND_SHIFT 63
#define SYMBOL_QUOTED_SHIFT 54
#define SYMBOL_KIND_MASK 0xF000000000000000
#define SYMBOL_QUOTED_MASK 0x00
#define SYMBOL_OPCODE_MASK 0xFFFFFFFF
#define SYMBOL_NAME_MASK 0xFFFFFFFF

/* Definition of symbol kinds. */
#define K_S 1
#define K_R 4
#define K_B 6

/* Used to access the information stored within a subtask record. */
#define NARGS_ABSENT_SHIFT   0
#define SUBTREC_STATUS_SHIFT 4
#define NARGS_ABSENT_MASK    0xF
#define SUBTREC_STATUS_MASK  0xF0

/* Packet Types. */
#define ERROR     0
#define REFERENCE 1
#define DATA      2

/* Subtask record status. */
#define NEW        0
#define PROCESSING 1
#define PENDING    2

/* Arg status. */
#define ABSENT     0
#define REQUESTING 1
#define PRESENT    2

/***********************************/
/******* Function Prototypes *******/
/***********************************/
void parse_pkt(packet p, __global uint2 *q, __global subt *table);

bool cunit_q_is_empty(size_t gid, __global uint2 *q, int n);
bool cunit_q_is_full(size_t gid, __global uint2 *q, int n);
uint cunit_q_size(size_t gid, __global uint2 *q, int n);
void transferRQ(__global uint2 *rq,  __global uint2 *q, int n);

void subt_store_payload(uint payload, uint arg_pos, ushort i, __global subt *subt);
bool subt_is_ready(ushort i, __global subt *subt);
__global subt_rec *subt_get_rec(ushort i, __global subt *subt);
bool subt_push(ushort i, __global subt *subt);
bool subt_pop(ushort *result, __global subt *subt);
bool subt_is_full(__global subt *subt);
bool subt_is_empty(__global subt *subt);
ushort subt_top(__global subt *subt);
void subt_set_top(__global subt *subt, ushort i);

uint subt_rec_get_service_id(__global subt_rec *r);
uint subt_rec_get_arg(__global subt_rec *r, uint arg_pos);
uint subt_rec_get_arg_status(__global subt_rec *r, uint arg_pos);
uint subt_rec_get_subt_status(__global subt_rec *r);
uint subt_rec_get_nargs_absent(__global subt_rec *r);
uint subt_rec_get_return_to(__global subt_rec *r);
uint subt_rec_get_return_as(__global subt_rec *r);
void subt_rec_set_service_id(__global subt_rec *r, uint service_id);
void subt_rec_set_arg(__global subt_rec *r, uint arg_pos, uint arg);
void subt_rec_set_arg_status(__global subt_rec *r, uint arg_pos, uint status);
void subt_rec_set_subt_status(__global subt_rec *r, uint status);
void subt_rec_set_nargs_absent(__global subt_rec *r, uint n);
void subt_rec_set_return_to(__global subt_rec *r, uint return_to);
void subt_rec_set_return_as(__global subt_rec *r, uint return_as);

uint pkt_get_type(packet p);
uint pkt_get_dest(packet p);
uint pkt_get_arg_pos(packet p);
uint pkt_get_sub(packet p);
uint pkt_get_payload(packet p);
void pkt_set_type(packet *p, uint type);
void pkt_set_dest(packet *p, uint dest);
void pkt_set_arg_pos(packet *p, uint arg);
void pkt_set_sub(packet *p, uint sub);
void pkt_set_payload(packet *p, uint payload);
packet pkt_create(uint type, uint dest, uint arg, uint sub, uint payload);

uint q_get_head_index(size_t id, size_t gid, __global uint2 *q, int n);
uint q_get_tail_index(size_t id, size_t gid, __global uint2 *q, int n);
void q_set_head_index(uint index, size_t id, size_t gid, __global uint2 *q, int n);
void q_set_tail_index(uint index, size_t id, size_t gid, __global uint2 *q, int n);
void q_set_last_op(uint type, size_t id, size_t gid,__global uint2 *q, int n);
bool q_last_op_is_read(size_t id, size_t gid, __global uint2 *q, int n);
bool q_last_op_is_write(size_t id, size_t gid, __global uint2 *q, int n);
bool q_is_empty(size_t id, size_t gid, __global uint2 *q, int n);
bool q_is_full(size_t id, size_t gid,__global uint2 *q, int n);
uint q_size(size_t id, size_t gid, __global uint2 *q, int n);
bool q_read(uint2 *result, size_t id, __global uint2 *q, int n);
bool q_write(uint2 value, size_t id, __global uint2 *q, int n);

/**************************/
/******* The Kernel *******/
/**************************/
__kernel void vm(__global packet *q,            /* Compute unit queues. */
                   __global packet *rq,           /* Transfer queues for READ state. */
                   int n,                         /* The number of compute units. */
                   __global int *state,           /* Are we in the READ or WRITE state? */
                   __global bytecode *cStore,     /* The code store. */
                   __global subt *subt,           /* The subtask table. */
                   __global char *in,             /* Input data from the host. */
                   __global char *result,         /* Memory to store the final results. */
                   __global char *scratch         /* Scratch memory for temporary results. */
                 ) {
  size_t gid = get_global_id(0);

  if (*state == WRITE) {
    transferRQ(rq, q, n);
  } else {
    for (int i = 0; i < n; i++) {
      packet p;
      while (q_read(&p, i, q, n)) {
        parse_pkt(p, rq, subt);
      }
    }
  }
}

uint symbol_get_kind(ulong s) {
  return (s & SYMBOL_KIND_MASK) >> SYMBOL_KIND_SHIFT;
}

bool symbol_is_quoted(ulong s) {
  return (s & SYMBOL_QUOTED_MASK) >> SYMBOL_QUOTED_SHIFT;
}

uint symbol_get_opcode(ulong s) {
  return s & SYMBOL_OPCODE_MASK;
}

uint symbol_get_name(ulong s) {
  return s & SYMBOL_NAME_MASK;
}

void parse_pkt(packet p, __global uint2 *q, __global subt *subt) {
  uint type = pkt_get_type(p);
  uint subtask = pkt_get_sub(p);
  uint arg_pos = pkt_get_arg_pos(p);
  uint payload = pkt_get_payload(p);

  switch (type) {
  case ERROR:
    break;
  case REFERENCE: // Create new subtask record.
    switch (symbol_get_kind(payload)) {
    case K_S:
      break;
    case K_R:
      if (!symbol_is_quoted(payload)) {
	uint dest = symbol_get_name(payload);
        packet p = pkt_create(REFERENCE, dest, arg_pos, subtask, payload);
      } else {

      }
      break;
    case K_B:
      break;
    }
    break;
  case DATA: // Store packet payload in associated subtask record.
    subt_store_payload(payload, arg_pos, subtask, subt);
    if (subt_is_ready(subtask, subt)) {
      // Perform computation
    }
    break;
  }
}



/**************************************/
/**** Compute Unit Queue Functions ****/
/**************************************/

/* Returns true if all queues owned by the specified compute unit are empty, false otherwise. */
bool cunit_q_is_empty(size_t gid, __global uint2 *q, int n) {
  for (int i = 0; i < n; i++) {
    if (!q_is_empty(gid, i, q, n)) {
      return false;
    }
  }

  return true;
}

/* Returns true if all queues owned by the specified compute unit are full, false otherwise. */
bool cunit_q_is_full(size_t gid, __global uint2 *q, int n) {
  for (int i = 0; i < n; i++) {
    if (!q_is_full(gid, i, q, n)) {
      return false;
    }
  }

  return true;
}

/* Return the total size of all compute unit owned queues. */
uint cunit_q_size(size_t gid, __global uint2 *q, int n) {
  uint size = 0;
  for (int i = 0; i < n; i++) {
    size += q_size(gid, i, q, n);
  }

  return size;
}

/* Copy all compute unit owned queue values from the readQueue into the real queues. */
void transferRQ(__global uint2 *rq, __global uint2 *q, int n) {
  uint2 packet;
  for (int i = 0; i < n; i++) {
    while (q_read(&packet, i, rq, n)) {
      q_write(packet, i, q, n);
    }
  }
}

/*********************************/
/**** Subtask Table Functions ****/
/*********************************/

void subt_store_payload(uint payload, uint arg_pos, ushort i, __global subt *subt) {
  __global subt_rec *rec = subt_get_rec(i, subt);
  uint nargs_absent = subt_rec_get_nargs_absent(rec) - 1;
  subt_rec_set_arg(rec, arg_pos, payload);
  subt_rec_set_arg_status(rec, arg_pos, PRESENT);
  subt_rec_set_nargs_absent(rec, nargs_absent);
}

bool subt_is_ready(ushort i, __global subt *subt) {
  __global subt_rec *rec = subt_get_rec(i, subt);
  return subt_rec_get_nargs_absent(rec) == 0;
}

__global subt_rec *subt_get_rec(ushort i, __global subt *subt) {
  return &(subt->recs[i]);
}

bool subt_push(ushort i, __global subt *subt) {
  if (subt_is_empty(subt)) {
    return false;
  }

  ushort top = subt_top(subt);
  subt->av_recs[top - 1] = i;
  subt_set_top(subt, top - 1);
  return true;
}

bool subt_pop(ushort *av_index, __global subt *subt) {
  if (subt_is_full(subt)) {
    return false;
  }

  ushort top = subt_top(subt);
  *av_index = subt->av_recs[top];
  subt_set_top(subt, top + 1);
  return true;
}

bool subt_is_full(__global subt *subt) {
  return subt_top(subt) == SUBT_SIZE + 1;
}

bool subt_is_empty(__global subt *subt) {
  return subt_top(subt) == 1;
}

ushort subt_top(__global subt *subt) {
  return subt->av_recs[0];
}

void subt_set_top(__global subt *subt, ushort i) {
  subt->av_recs[0] = i;
}

/**********************************/
/**** Subtask Record Functions ****/
/**********************************/
uint subt_rec_get_service_id(__global subt_rec *r) {
  return r->service_id;
}

uint subt_rec_get_arg(__global subt_rec *r, uint arg_pos) {
  return r->args[arg_pos];
}

uint subt_rec_get_arg_status(__global subt_rec *r, uint arg_pos) {
  return r->arg_status[arg_pos];
}

uint subt_rec_get_subt_status(__global subt_rec *r) {
  return (r->subt_status & SUBTREC_STATUS_MASK) >> SUBTREC_STATUS_SHIFT;
}

uint subt_rec_get_nargs_absent(__global subt_rec *r) {
  return (r->subt_status & NARGS_ABSENT_MASK);
}

uint subt_rec_get_return_to(__global subt_rec *r) {
  return r->return_to;
}

uint subt_rec_get_return_as(__global subt_rec *r) {
  return r->return_as;
}

void subt_rec_set_service_id(__global subt_rec *r, uint service_id) {
  r->service_id = service_id;
}

void subt_rec_set_arg(__global subt_rec *r, uint arg_pos, uint arg) {
  r->args[arg_pos] = arg;
}

void subt_rec_set_arg_status(__global subt_rec *r, uint arg_pos, uint status) {
  r->arg_status[arg_pos] = status;
}

void subt_rec_set_subt_status(__global subt_rec *r, uint status) {
  r->subt_status = (r->subt_status & ~SUBTREC_STATUS_MASK)
    | ((status << SUBTREC_STATUS_SHIFT) & SUBTREC_STATUS_MASK);
}

void subt_rec_set_nargs_absent(__global subt_rec *r, uint n) {
  r->subt_status = (r->subt_status & ~NARGS_ABSENT_MASK)
    | ((n << NARGS_ABSENT_SHIFT) & NARGS_ABSENT_MASK);
}

void subt_rec_set_return_to(__global subt_rec *r, uint return_to) {
  r->return_to = return_to;
}

void subt_rec_set_return_as(__global subt_rec *r, uint return_as) {
  r->return_as = return_as;
}

/**************************/
/**** Packet Functions ****/
/**************************/

/* Return the packet type. */
uint pkt_get_type(packet p) {
  return (p.x & PKT_TYPE_MASK) >> PKT_TYPE_SHIFT;
}

/* Return the packet destination address. */
uint pkt_get_dest(packet p) {
  return (p.x & PKT_DEST_MASK) >> PKT_DEST_SHIFT;
}

/* Return the packet argument position. */
uint pkt_get_arg_pos(packet p) {
  return (p.x & PKT_ARG_MASK) >> PKT_ARG_SHIFT;
}

/* Return the packet subtask. */
uint pkt_get_sub(packet p) {
  return (p.x & PKT_SUB_MASK) >> PKT_SUB_SHIFT;
}

/* Return the packet payload. */
uint pkt_get_payload(packet p) {
  return p.y;
}

/* Set the packet type. */
void pkt_set_type(packet *p, uint type) {
  (*p).x = ((*p).x & ~PKT_TYPE_MASK) | ((type << PKT_TYPE_SHIFT) & PKT_TYPE_MASK);
}

/* Set the packet destination address. */
void pkt_set_dest(packet *p, uint dest) {
  (*p).x = ((*p).x & ~PKT_DEST_MASK) | ((dest << PKT_DEST_SHIFT) & PKT_DEST_MASK);
}

/* Set the packet argument position. */
void pkt_set_arg_pos(packet *p, uint arg) {
  (*p).x = ((*p).x & ~PKT_ARG_MASK) | ((arg << PKT_ARG_SHIFT) & PKT_ARG_MASK);
}

/* Set the packet subtask. */
void pkt_set_sub(packet *p, uint sub) {
  (*p).x = ((*p).x & ~PKT_SUB_MASK) | ((sub << PKT_SUB_SHIFT) & PKT_SUB_MASK);
}

/* Set the packet payload. */
void pkt_set_payload(packet *p, uint payload) {
  (*p).y = payload;
}

/* Return a newly created packet. */
packet pkt_create(uint type, uint dest, uint arg, uint sub, uint payload) {
  packet p;
  pkt_set_type(&p, type);
  pkt_set_dest(&p, dest);
  pkt_set_arg_pos(&p, arg);
  pkt_set_sub(&p, sub);
  pkt_set_payload(&p, payload);
  return p;
}


/*************************/
/**** Queue Functions ****/
/*************************/

/* Returns the array index of the head element of the queue. */
uint q_get_head_index(size_t id, size_t gid, __global uint2 *q, int n) {
  ushort2 indices = as_ushort2(q[id * n + gid].x);
  return indices.x;
}

/* Returns the array index of the tail element of the queue. */
uint q_get_tail_index(size_t id, size_t gid,__global uint2 *q, int n) {
  ushort2 indices = as_ushort2(q[id * n + gid].x);
  return indices.y;
}

/* Set the array index of the head element of the queue. */
void q_set_head_index(uint index, size_t id, size_t gid, __global uint2 *q, int n) {
  ushort2 indices = as_ushort2(q[id * n + gid].x);
  indices.x = index;
  q[id * n + gid].x = as_uint(indices);
}

/* Set the array index of the tail element of the queue. */
void q_set_tail_index(uint index, size_t id, size_t gid,__global uint2 *q, int n) {
  ushort2 indices = as_ushort2(q[id * n + gid].x);
  indices.y = index;
  q[id * n + gid].x = as_uint(indices);
}

/* Set the type of the operation last performed on the queue. */
void q_set_last_op(uint type, size_t id, size_t gid, __global uint2 *q, int n) {
  q[id * n + gid].y = type;
}

/* Returns true if the last operation performed on the queue is a read, false otherwise. */
bool q_last_op_is_read(size_t id, size_t gid,__global uint2 *q, int n) {
  return q[id * n + gid].y == READ;
}

/* Returns true if the last operation performed on the queue is a write, false otherwise. */
bool q_last_op_is_write(size_t id, size_t gid,__global uint2 *q, int n) {
  return q[id * n + gid].y == WRITE;
}

/* Returns true if the queue is empty, false otherwise. */
bool q_is_empty(size_t id, size_t gid,  __global uint2 *q, int n) {
  return (q_get_head_index(id, gid, q, n) == q_get_tail_index(id, gid, q, n))
    && q_last_op_is_read(id, gid, q, n);
}

/* Returns true if the queue is full, false otherwise. */
bool q_is_full(size_t id, size_t gid, __global uint2 *q, int n) {
  return (q_get_head_index(id, gid, q, n) == q_get_tail_index(id, gid, q, n))
    && q_last_op_is_write(id, gid, q, n);
}

/* Return the size of the queue. */
uint q_size(size_t id, size_t gid, __global uint2 *q, int n) {
  if (q_is_full(id, gid, q, n)) return QUEUE_SIZE;
  if (q_is_empty(id, gid, q, n)) return 0;
  uint head = q_get_head_index(id, gid, q, n);
  uint tail = q_get_tail_index(id, gid, q, n);
  return (tail > head) ? (tail - head) : QUEUE_SIZE - head;
}

/* Read the value located at the head index of the queue into 'result'.
 * Returns true if succcessful (queue is not empty), false otherwise. */
bool q_read(uint2 *result, size_t id, __global uint2 *q, int n) {
  size_t gid = get_global_id(0);
  if (q_is_empty(gid, id, q, n)) {
    return false;
  }

  int index = q_get_head_index(gid, id, q, n);
  *result = q[(n*n) + (gid * n * QUEUE_SIZE) + (id * QUEUE_SIZE) + index];
  q_set_head_index((index + 1) % QUEUE_SIZE, gid, id, q, n);
  q_set_last_op(READ, gid, id, q, n);
  return true;
}

/* Write a value into the tail index of the queue.
 * Returns true if successful (queue is not full), false otherwise. */
bool q_write(uint2 value, size_t id, __global uint2 *q, int n) {
  size_t gid = get_global_id(0);
  if (q_is_full(id, gid, q, n)) {
    return false;
  }

  int index = q_get_tail_index(id, gid, q, n);
  q[(n*n) + (id * n * QUEUE_SIZE) + (gid * QUEUE_SIZE) + index] = value;
  q_set_tail_index((index + 1) % QUEUE_SIZE, id, gid, q, n);
  q_set_last_op(WRITE, id, gid, q, n);
  return true;
}
