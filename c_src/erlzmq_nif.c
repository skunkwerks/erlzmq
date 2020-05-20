// -*- coding:utf-8;Mode:C;tab-width:2;c-basic-offset:2;indent-tabs-mode:nil -*-
// ex: set softtabstop=2 tabstop=2 shiftwidth=2 expandtab fileencoding=utf-8:
//
// Copyright (c) 2020 Łukasz Samson
// Copyright (c) 2019 erlang solutions ltd
// Copyright (c) 2011 Yurii Rashkovskii, Evax Software and Michael Truog
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#include "zmq.h"
#if ZMQ_VERSION_MAJOR < 4 || ZMQ_VERSION_MAJOR == 4 && ZMQ_VERSION_MINOR < 1
#include "zmq_utils.h"
#endif
#include "erl_nif.h"
#include "erl_driver.h"
#include <string.h>
#include <stdio.h>
#include <assert.h>
#include <sys/types.h>
#include <inttypes.h>
#include <sys/resource.h>
#include <time.h>

#ifndef ZMQ_ROUTING_ID
#define ZMQ_ROUTING_ID ZMQ_IDENTITY
#endif

#ifndef ZMQ_CONNECT_ROUTING_ID
#define ZMQ_CONNECT_ROUTING_ID ZMQ_CONNECT_RID
#endif

#ifndef ZMQ_IMMEDIATE
#define ZMQ_IMMEDIATE ZMQ_DELAY_ATTACH_ON_CONNECT
#endif

static ErlNifResourceType* erlzmq_nif_resource_context;
static ErlNifResourceType* erlzmq_nif_resource_socket;

typedef struct erlzmq_context {
  void * context_zmq;
  uint64_t socket_index;
  ErlNifMutex * mutex;
  int status;
} erlzmq_context_t;

typedef struct erlzmq_socket {
  erlzmq_context_t * context;
  uint64_t socket_index;
  void * socket_zmq;
  ErlNifMutex * mutex;
  int status;
} erlzmq_socket_t;

#define ERLZMQ_SOCKET_STATUS_READY   0
#define ERLZMQ_SOCKET_STATUS_CLOSED  1

#define ERLZMQ_CONTEXT_STATUS_READY       0
#define ERLZMQ_CONTEXT_STATUS_TERMINATING 1
#define ERLZMQ_CONTEXT_STATUS_TERMINATED  2

// Prototypes
#define NIF(name) \
  ERL_NIF_TERM name(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[])

NIF(erlzmq_nif_context);
NIF(erlzmq_nif_socket);
NIF(erlzmq_nif_bind);
NIF(erlzmq_nif_unbind);
NIF(erlzmq_nif_connect);
NIF(erlzmq_nif_disconnect);
NIF(erlzmq_nif_setsockopt);
NIF(erlzmq_nif_getsockopt);
NIF(erlzmq_nif_send);
NIF(erlzmq_nif_recv);
NIF(erlzmq_nif_close);
NIF(erlzmq_nif_term);
NIF(erlzmq_nif_ctx_get);
NIF(erlzmq_nif_ctx_set);
NIF(erlzmq_nif_curve_keypair);
NIF(erlzmq_nif_z85_decode);
NIF(erlzmq_nif_z85_encode);
NIF(erlzmq_nif_has);
NIF(erlzmq_nif_version);

static ERL_NIF_TERM return_zmq_errno(ErlNifEnv* env, int const value);

static ErlNifFunc nif_funcs[] =
{
  // non blocking
  {"context", 1, erlzmq_nif_context, 0},
  // can block on context mutex
  {"socket", 2, erlzmq_nif_socket, ERL_NIF_DIRTY_JOB_IO_BOUND},
  // can block on socket mutex
  {"bind", 2, erlzmq_nif_bind, ERL_NIF_DIRTY_JOB_IO_BOUND},
  // can block on socket mutex
  {"unbind", 2, erlzmq_nif_unbind, ERL_NIF_DIRTY_JOB_IO_BOUND},
  // can block on socket mutex
  {"connect", 2, erlzmq_nif_connect, ERL_NIF_DIRTY_JOB_IO_BOUND},
  // can block on socket mutex
  {"disconnect", 2, erlzmq_nif_disconnect, ERL_NIF_DIRTY_JOB_IO_BOUND},
  // can block on socket mutex
  {"setsockopt", 3, erlzmq_nif_setsockopt, ERL_NIF_DIRTY_JOB_IO_BOUND},
  // can block on socket mutex
  {"getsockopt", 2, erlzmq_nif_getsockopt, ERL_NIF_DIRTY_JOB_IO_BOUND},
  // can block on zmq_send or socket mutex
  {"send", 3, erlzmq_nif_send, ERL_NIF_DIRTY_JOB_IO_BOUND},
  // can block on zmq_recv or socket mutex
  {"recv", 2, erlzmq_nif_recv, ERL_NIF_DIRTY_JOB_IO_BOUND},
  // can block on socket mutex
  {"close", 1, erlzmq_nif_close, ERL_NIF_DIRTY_JOB_IO_BOUND},
  // can block on zmq_term or context mutex
  {"term", 1, erlzmq_nif_term, ERL_NIF_DIRTY_JOB_IO_BOUND},
  // can block on context mutex
  {"ctx_get", 2, erlzmq_nif_ctx_get, ERL_NIF_DIRTY_JOB_IO_BOUND},
  // can block on context mutex
  {"ctx_set", 3, erlzmq_nif_ctx_set, ERL_NIF_DIRTY_JOB_IO_BOUND},
  // non blocking
  {"curve_keypair", 0, erlzmq_nif_curve_keypair, 0},
  // non blocking
  {"z85_decode", 1, erlzmq_nif_z85_decode, 0},
  // non blocking
  {"z85_encode", 1, erlzmq_nif_z85_encode, 0},
  // non blocking
  {"has", 1, erlzmq_nif_has, 0},
  // non blocking
  {"version", 0, erlzmq_nif_version, 0}
};

NIF(erlzmq_nif_context)
{
  int thread_count;

  if (! enif_get_int(env, argv[0], &thread_count)) {
    return enif_make_badarg(env);
  }

  erlzmq_context_t * context = enif_alloc_resource(erlzmq_nif_resource_context,
                                                   sizeof(erlzmq_context_t));
  assert(context);
  context->status = ERLZMQ_CONTEXT_STATUS_TERMINATED;
  context->mutex = 0;
  context->context_zmq = zmq_init(thread_count);
  if (! context->context_zmq) {
    enif_release_resource(context);
    return return_zmq_errno(env, zmq_errno());
  }

  context->mutex = enif_mutex_create("erlzmq_context_t_mutex");
  assert(context->mutex);

  context->socket_index = 0;

  context->status = ERLZMQ_CONTEXT_STATUS_READY;

  return enif_make_tuple2(env, enif_make_atom(env, "ok"),
                          enif_make_resource(env, context));
}

NIF(erlzmq_nif_socket)
{
  erlzmq_context_t * context;
  int socket_type;

  if (! enif_get_resource(env, argv[0], erlzmq_nif_resource_context,
                          (void **) &context)) {
    return enif_make_badarg(env);
  }

  if (context->status != ERLZMQ_CONTEXT_STATUS_READY) {
    return return_zmq_errno(env, ETERM);
  }

  if (! enif_get_int(env, argv[1], &socket_type)) {
    return enif_make_badarg(env);
  }

  erlzmq_socket_t * socket = enif_alloc_resource(erlzmq_nif_resource_socket,
                                                 sizeof(erlzmq_socket_t));
  assert(socket);
  socket->context = context;
  socket->mutex = 0;
  socket->status = ERLZMQ_SOCKET_STATUS_CLOSED;
  socket->socket_zmq = 0;

  assert(context->mutex);
  enif_mutex_lock(context->mutex);
  if (context->status != ERLZMQ_CONTEXT_STATUS_READY) {
    enif_mutex_unlock(context->mutex);
    enif_release_resource(socket);
    return return_zmq_errno(env, ETERM);
  }

  socket->socket_index = context->socket_index++;
  assert(context->status == ERLZMQ_CONTEXT_STATUS_READY);
  assert(context->context_zmq);
  socket->socket_zmq = zmq_socket(context->context_zmq, socket_type);
  enif_mutex_unlock(context->mutex);
  if (! socket->socket_zmq) {
    enif_release_resource(socket);
    return return_zmq_errno(env, zmq_errno());
  }

  socket->status = ERLZMQ_SOCKET_STATUS_READY;
  char mutex_name[64];
  sprintf(mutex_name, "erlzmq_socket_t_mutex_%" PRIu64, socket->socket_index);
  socket->mutex = enif_mutex_create(mutex_name);
  assert(socket->mutex);
  enif_keep_resource(socket->context);

  return enif_make_tuple2(env, enif_make_atom(env, "ok"), enif_make_tuple2(env,
                          enif_make_uint64(env, socket->socket_index),
                          enif_make_resource(env, socket)));
}

NIF(erlzmq_nif_bind)
{
  erlzmq_socket_t * socket;
  unsigned endpoint_length;

  if (! enif_get_resource(env, argv[0], erlzmq_nif_resource_socket,
                          (void **) &socket)) {
    return enif_make_badarg(env);
  }

  if (! enif_get_list_length(env, argv[1], &endpoint_length)) {
    return enif_make_badarg(env);
  }

  if (socket->context->status != ERLZMQ_CONTEXT_STATUS_READY) {
    return return_zmq_errno(env, ETERM);
  }

  if (socket->status != ERLZMQ_SOCKET_STATUS_READY) {
    return return_zmq_errno(env, ENOTSOCK);
  }

  char * endpoint = (char *) malloc(endpoint_length + 1);
  assert(endpoint);
  if (! enif_get_string(env, argv[1], endpoint, endpoint_length + 1,
                        ERL_NIF_LATIN1)) {
    free(endpoint);
    return enif_make_badarg(env);
  }

  assert(socket->mutex);
  enif_mutex_lock(socket->mutex);

  if (socket->status != ERLZMQ_SOCKET_STATUS_READY) {
    enif_mutex_unlock(socket->mutex);
    free(endpoint);
    return return_zmq_errno(env, ENOTSOCK);
  }

  ERL_NIF_TERM result;
  assert(socket->socket_zmq);
  if (zmq_bind(socket->socket_zmq, endpoint)) {
    result = return_zmq_errno(env, zmq_errno());
  }
  else {
    result = enif_make_atom(env, "ok");
  }

  enif_mutex_unlock(socket->mutex);
  free(endpoint);

  return result;
}

NIF(erlzmq_nif_unbind)
{
  erlzmq_socket_t * socket;
  unsigned endpoint_length;

  if (! enif_get_resource(env, argv[0], erlzmq_nif_resource_socket,
                          (void **) &socket)) {
    return enif_make_badarg(env);
  }

  if (! enif_get_list_length(env, argv[1], &endpoint_length)) {
    return enif_make_badarg(env);
  }

  if (socket->context->status != ERLZMQ_CONTEXT_STATUS_READY) {
    return return_zmq_errno(env, ETERM);
  }

  if (socket->status != ERLZMQ_SOCKET_STATUS_READY) {
    return return_zmq_errno(env, ENOTSOCK);
  }

  char * endpoint = (char *) malloc(endpoint_length + 1);
  assert(endpoint);
  if (! enif_get_string(env, argv[1], endpoint, endpoint_length + 1,
                        ERL_NIF_LATIN1)) {
    free(endpoint);
    return enif_make_badarg(env);
  }

  assert(socket->mutex);
  enif_mutex_lock(socket->mutex);

  if (socket->status != ERLZMQ_SOCKET_STATUS_READY) {
    enif_mutex_unlock(socket->mutex);
    free(endpoint);
    return return_zmq_errno(env, ENOTSOCK);
  }

  ERL_NIF_TERM result;
  assert(socket->socket_zmq);
  if (zmq_unbind(socket->socket_zmq, endpoint)) {
    result = return_zmq_errno(env, zmq_errno());
  }
  else {
    result = enif_make_atom(env, "ok");
  }

  enif_mutex_unlock(socket->mutex);
  free(endpoint);

  return result;
}

NIF(erlzmq_nif_connect)
{
  erlzmq_socket_t * socket;
  unsigned endpoint_length;

  if (! enif_get_resource(env, argv[0], erlzmq_nif_resource_socket,
                          (void **) &socket)) {
    return enif_make_badarg(env);
  }

  if (! enif_get_list_length(env, argv[1], &endpoint_length)) {
    return enif_make_badarg(env);
  }

  if (socket->context->status != ERLZMQ_CONTEXT_STATUS_READY) {
    return return_zmq_errno(env, ETERM);
  }

  if (socket->status != ERLZMQ_SOCKET_STATUS_READY) {
    return return_zmq_errno(env, ENOTSOCK);
  }

  char * endpoint = (char *) malloc(endpoint_length + 1);
  assert(endpoint);
  if (! enif_get_string(env, argv[1], endpoint, endpoint_length + 1,
                        ERL_NIF_LATIN1)) {
    free(endpoint);
    return enif_make_badarg(env);
  }

  assert(socket->mutex);
  enif_mutex_lock(socket->mutex);
  if (socket->status != ERLZMQ_SOCKET_STATUS_READY) {
    enif_mutex_unlock(socket->mutex);
    free(endpoint);
    return return_zmq_errno(env, ENOTSOCK);
  }

  ERL_NIF_TERM result;
  assert(socket->socket_zmq);
  if (zmq_connect(socket->socket_zmq, endpoint)) {
    result = return_zmq_errno(env, zmq_errno());
  }
  else {
    result = enif_make_atom(env, "ok");
  }

  enif_mutex_unlock(socket->mutex);
  free(endpoint);

  return result;
}

NIF(erlzmq_nif_disconnect)
{
  erlzmq_socket_t * socket;
  unsigned endpoint_length;

  if (! enif_get_resource(env, argv[0], erlzmq_nif_resource_socket,
                          (void **) &socket)) {
    return enif_make_badarg(env);
  }

  if (! enif_get_list_length(env, argv[1], &endpoint_length)) {
    return enif_make_badarg(env);
  }

  if (socket->context->status != ERLZMQ_CONTEXT_STATUS_READY) {
    return return_zmq_errno(env, ETERM);
  }

  if (socket->status != ERLZMQ_SOCKET_STATUS_READY) {
    return return_zmq_errno(env, ENOTSOCK);
  }

  char * endpoint = (char *) malloc(endpoint_length + 1);
  assert(endpoint);
  if (! enif_get_string(env, argv[1], endpoint, endpoint_length + 1,
                        ERL_NIF_LATIN1)) {
    free(endpoint);
    return enif_make_badarg(env);
  }

  assert(socket->mutex);
  enif_mutex_lock(socket->mutex);
  if (socket->status != ERLZMQ_SOCKET_STATUS_READY) {
    enif_mutex_unlock(socket->mutex);
    free(endpoint);
    return return_zmq_errno(env, ENOTSOCK);
  }

  ERL_NIF_TERM result;
  assert(socket->socket_zmq);
  if (zmq_disconnect(socket->socket_zmq, endpoint)) {
    result = return_zmq_errno(env, zmq_errno());
  }
  else {
    result = enif_make_atom(env, "ok");
  }

  enif_mutex_unlock(socket->mutex);
  free(endpoint);

  return result;
}

NIF(erlzmq_nif_setsockopt)
{
  erlzmq_socket_t * socket;
  int option_name;

  if (! enif_get_resource(env, argv[0], erlzmq_nif_resource_socket,
                          (void **) &socket)) {
    return enif_make_badarg(env);
  }

  if (! enif_get_int(env, argv[1], &option_name)) {
    return enif_make_badarg(env);
  }

  if (socket->context->status != ERLZMQ_CONTEXT_STATUS_READY) {
    return return_zmq_errno(env, ETERM);
  }

  if (socket->status != ERLZMQ_SOCKET_STATUS_READY) {
    return return_zmq_errno(env, ENOTSOCK);
  }

  ErlNifUInt64 value_uint64;
  ErlNifSInt64 value_int64;
  ErlNifBinary value_binary;
  uint8_t z85_str[41];
  int value_int;
  void *option_value;
  size_t option_len;
  switch (option_name) {
    // uint64_t
    case ZMQ_AFFINITY:

    #if ZMQ_VERSION_MAJOR > 4 || ZMQ_VERSION_MAJOR == 4 && ZMQ_VERSION_MINOR >= 2
    case ZMQ_VMCI_BUFFER_SIZE:
    case ZMQ_VMCI_BUFFER_MIN_SIZE:
    case ZMQ_VMCI_BUFFER_MAX_SIZE:
    #endif
      if (! enif_get_uint64(env, argv[2], &value_uint64)) {
        return enif_make_badarg(env);
      }
      option_value = &value_uint64;
      option_len = sizeof(int64_t);
      break;

    // int64_t
    case ZMQ_MAXMSGSIZE:
      if (! enif_get_int64(env, argv[2], &value_int64)) {
        return enif_make_badarg(env);
      }
      option_value = &value_int64;
      option_len = sizeof(int64_t);
      break;

    // binary
    case ZMQ_CONNECT_ROUTING_ID:
    case ZMQ_ROUTING_ID:
    case ZMQ_SUBSCRIBE:
    case ZMQ_UNSUBSCRIBE:

    // deprecated
    case ZMQ_TCP_ACCEPT_FILTER:
    
    // character string
    case ZMQ_GSSAPI_PRINCIPAL:
    case ZMQ_GSSAPI_SERVICE_PRINCIPAL:

    #if ZMQ_VERSION_MAJOR > 4 || ZMQ_VERSION_MAJOR == 4 && ZMQ_VERSION_MINOR >= 3
    // string
    case ZMQ_BINDTODEVICE:
    #endif

    #if ZMQ_VERSION_MAJOR > 4 || ZMQ_VERSION_MAJOR == 4 && ZMQ_VERSION_MINOR >= 2
    // string
    case ZMQ_SOCKS_PROXY:
    // binary
    case ZMQ_XPUB_WELCOME_MSG:
    #endif

    #if ZMQ_VERSION_MAJOR > 4 || ZMQ_VERSION_MAJOR == 4 && ZMQ_VERSION_MINOR >= 0
    // string
    case ZMQ_ZAP_DOMAIN:
    case ZMQ_PLAIN_PASSWORD:
    case ZMQ_PLAIN_USERNAME:
    #endif
      if (! enif_inspect_iolist_as_binary(env, argv[2], &value_binary)) {
        return enif_make_badarg(env);
      }
      option_value = value_binary.data;
      option_len = value_binary.size;
      break;
    
    #if ZMQ_VERSION_MAJOR > 4 || ZMQ_VERSION_MAJOR == 4 && ZMQ_VERSION_MINOR >= 0
    // binary or Z85 string
    case ZMQ_CURVE_PUBLICKEY:
    case ZMQ_CURVE_SECRETKEY:
    case ZMQ_CURVE_SERVERKEY:
    #endif
      if (! enif_inspect_iolist_as_binary(env, argv[2], &value_binary)) {
        return enif_make_badarg(env);
      }
      if (value_binary.size == 32) {
        // binary
        option_value = value_binary.data;
        option_len = value_binary.size;
      } else if (value_binary.size == 40) {
        // z85-encoded
        memcpy(z85_str, value_binary.data, 40);
        z85_str[40] = 0;
        option_value = z85_str;
        option_len = 40;
      } else {
        // XXX Perhaps should give reason for failure
        return enif_make_badarg(env);
      }
      break;
      
    // int
    case ZMQ_BACKLOG:
    case ZMQ_LINGER:
    case ZMQ_MULTICAST_HOPS:
    case ZMQ_RATE:
    case ZMQ_RCVBUF:
    case ZMQ_RCVHWM:
    case ZMQ_RCVTIMEO:
    case ZMQ_RECONNECT_IVL:
    case ZMQ_RECONNECT_IVL_MAX:
    case ZMQ_RECOVERY_IVL:
    case ZMQ_ROUTER_MANDATORY:
    case ZMQ_SNDBUF:
    case ZMQ_SNDHWM:
    case ZMQ_SNDTIMEO:
    case ZMQ_TCP_KEEPALIVE:
    case ZMQ_TCP_KEEPALIVE_CNT:
    case ZMQ_TCP_KEEPALIVE_IDLE:
    case ZMQ_TCP_KEEPALIVE_INTVL:
    case ZMQ_XPUB_VERBOSE:
    
    #if ZMQ_VERSION_MAJOR > 4 || ZMQ_VERSION_MAJOR == 4 && ZMQ_VERSION_MINOR >= 3
    case ZMQ_GSSAPI_SERVICE_PRINCIPAL_NAMETYPE:
    case ZMQ_GSSAPI_PRINCIPAL_NAMETYPE:
    #endif

    #if ZMQ_VERSION_MAJOR > 4 || ZMQ_VERSION_MAJOR == 4 && ZMQ_VERSION_MINOR >= 2
    case ZMQ_USE_FD:
    case ZMQ_VMCI_CONNECT_TIMEOUT:
    case ZMQ_MULTICAST_MAXTPDU:
    case ZMQ_TCP_MAXRT:
    case ZMQ_CONNECT_TIMEOUT:
    case ZMQ_XPUB_VERBOSER:
    case ZMQ_HEARTBEAT_TIMEOUT:
    case ZMQ_HEARTBEAT_TTL:
    case ZMQ_HEARTBEAT_IVL:
    case ZMQ_INVERT_MATCHING:
    case ZMQ_STREAM_NOTIFY:
    case ZMQ_XPUB_MANUAL:
    case ZMQ_HANDSHAKE_IVL:
    case ZMQ_XPUB_NODROP:
    #endif

    #if ZMQ_VERSION_MAJOR > 4 || ZMQ_VERSION_MAJOR == 4 && ZMQ_VERSION_MINOR >= 1
    case ZMQ_TOS:
    case ZMQ_ROUTER_HANDOVER:
    #endif

    #if ZMQ_VERSION_MAJOR > 4 || ZMQ_VERSION_MAJOR == 4 && ZMQ_VERSION_MINOR >= 0
    case ZMQ_ROUTER_RAW:
    case ZMQ_GSSAPI_PLAINTEXT:
    case ZMQ_GSSAPI_SERVER:
    case ZMQ_IMMEDIATE:
    case ZMQ_IPV6:
    case ZMQ_CURVE_SERVER:
    case ZMQ_CONFLATE:
    case ZMQ_REQ_RELAXED:
    case ZMQ_REQ_CORRELATE:
    case ZMQ_PROBE_ROUTER:
    case ZMQ_PLAIN_SERVER:
    #endif

    // deprecated
    case ZMQ_IPV4ONLY:
      if (! enif_get_int(env, argv[2], &value_int)) {
        return enif_make_badarg(env);
      }
      option_value = &value_int;
      option_len = sizeof(int);
      break;
    default:
      return enif_make_badarg(env);
  }

  assert(socket->mutex);
  enif_mutex_lock(socket->mutex);
  if (socket->status != ERLZMQ_SOCKET_STATUS_READY) {
    enif_mutex_unlock(socket->mutex);
    return return_zmq_errno(env, ENOTSOCK);
  }
  assert(socket->socket_zmq);
  if (zmq_setsockopt(socket->socket_zmq, option_name,
                          option_value, option_len)) {
    enif_mutex_unlock(socket->mutex);
    return return_zmq_errno(env, zmq_errno());
  }
  else {
    enif_mutex_unlock(socket->mutex);
    return enif_make_atom(env, "ok");
  }
}

NIF(erlzmq_nif_getsockopt)
{
  erlzmq_socket_t * socket;
  int option_name;

  if (! enif_get_resource(env, argv[0], erlzmq_nif_resource_socket,
                          (void **) &socket)) {
    return enif_make_badarg(env);
  }

  if (! enif_get_int(env, argv[1], &option_name)) {
    return enif_make_badarg(env);
  }

  if (socket->context->status != ERLZMQ_CONTEXT_STATUS_READY) {
    return return_zmq_errno(env, ETERM);
  }

  if (socket->status != ERLZMQ_SOCKET_STATUS_READY) {
    return return_zmq_errno(env, ENOTSOCK);
  }

  ErlNifBinary value_binary;
  int64_t value_int64;
  uint64_t value_uint64;
  char option_value[256];
  int value_int;
  size_t option_len;

  assert(socket->mutex);
  enif_mutex_lock(socket->mutex);
  if (socket->status != ERLZMQ_SOCKET_STATUS_READY) {
    enif_mutex_unlock(socket->mutex);
    return return_zmq_errno(env, ENOTSOCK);
  }

  switch(option_name) {
    // int64_t
    case ZMQ_MAXMSGSIZE:
      option_len = sizeof(value_int64);
      assert(socket->socket_zmq);
      if (zmq_getsockopt(socket->socket_zmq, option_name,
                              &value_int64, &option_len)) {
        enif_mutex_unlock(socket->mutex);
        return return_zmq_errno(env, zmq_errno());
      }
      enif_mutex_unlock(socket->mutex);
      return enif_make_tuple2(env, enif_make_atom(env, "ok"),
                              enif_make_int64(env, value_int64));
    // uint64_t
    case ZMQ_AFFINITY:
    
    #if ZMQ_VERSION_MAJOR > 4 || ZMQ_VERSION_MAJOR == 4 && ZMQ_VERSION_MINOR >= 2
    case ZMQ_VMCI_BUFFER_SIZE:
    case ZMQ_VMCI_BUFFER_MIN_SIZE:
    case ZMQ_VMCI_BUFFER_MAX_SIZE:
    #endif
      option_len = sizeof(value_uint64);
      assert(socket->socket_zmq);
      if (zmq_getsockopt(socket->socket_zmq, option_name,
                              &value_uint64, &option_len)) {
        enif_mutex_unlock(socket->mutex);
        return return_zmq_errno(env, zmq_errno());
      }
      enif_mutex_unlock(socket->mutex);
      return enif_make_tuple2(env, enif_make_atom(env, "ok"),
                              enif_make_uint64(env, value_uint64));
    // binary
    case ZMQ_ROUTING_ID:

    // string
    case ZMQ_GSSAPI_PRINCIPAL:
    case ZMQ_GSSAPI_SERVICE_PRINCIPAL:
    case ZMQ_LAST_ENDPOINT:
    
    #if ZMQ_VERSION_MAJOR > 4 || ZMQ_VERSION_MAJOR == 4 && ZMQ_VERSION_MINOR >= 3
    // string
    case ZMQ_BINDTODEVICE:
    #endif
    
    #if ZMQ_VERSION_MAJOR > 4 || ZMQ_VERSION_MAJOR == 4 && ZMQ_VERSION_MINOR >= 2
    // string
    case ZMQ_SOCKS_PROXY:
    #endif

    #if ZMQ_VERSION_MAJOR > 4 || ZMQ_VERSION_MAJOR == 4 && ZMQ_VERSION_MINOR >= 0
    // string
    case ZMQ_ZAP_DOMAIN:
    case ZMQ_PLAIN_PASSWORD:
    case ZMQ_PLAIN_USERNAME:
    
    // binary or Z85 string
    case ZMQ_CURVE_PUBLICKEY:
    case ZMQ_CURVE_SECRETKEY:
    case ZMQ_CURVE_SERVERKEY:
    #endif
      option_len = sizeof(option_value);
      assert(socket->socket_zmq);
      if (zmq_getsockopt(socket->socket_zmq, option_name,
                              option_value, &option_len)) {
        enif_mutex_unlock(socket->mutex);
        return return_zmq_errno(env, zmq_errno());
      }
      enif_mutex_unlock(socket->mutex);
      int alloc_success = enif_alloc_binary(option_len, &value_binary);
      assert(alloc_success);
      memcpy(value_binary.data, option_value, option_len);
      return enif_make_tuple2(env, enif_make_atom(env, "ok"),
                              enif_make_binary(env, &value_binary));
    // int
    case ZMQ_BACKLOG:
    case ZMQ_LINGER:
    case ZMQ_MULTICAST_HOPS:
    case ZMQ_RATE:
    case ZMQ_RCVBUF:
    case ZMQ_RCVHWM:
    case ZMQ_RCVTIMEO:
    case ZMQ_RECONNECT_IVL:
    case ZMQ_RECONNECT_IVL_MAX:
    case ZMQ_RECOVERY_IVL:
    case ZMQ_SNDBUF:
    case ZMQ_SNDHWM:
    case ZMQ_SNDTIMEO:
    case ZMQ_TCP_KEEPALIVE:
    case ZMQ_TCP_KEEPALIVE_CNT:
    case ZMQ_TCP_KEEPALIVE_IDLE:
    case ZMQ_TCP_KEEPALIVE_INTVL:
    case ZMQ_RCVMORE:
    case ZMQ_EVENTS:
    case ZMQ_TYPE:
    
    #if ZMQ_VERSION_MAJOR > 4 || ZMQ_VERSION_MAJOR == 4 && ZMQ_VERSION_MINOR >= 3
    case ZMQ_GSSAPI_SERVICE_PRINCIPAL_NAMETYPE:
    case ZMQ_GSSAPI_PRINCIPAL_NAMETYPE:
    #endif

    #if ZMQ_VERSION_MAJOR > 4 || ZMQ_VERSION_MAJOR == 4 && ZMQ_VERSION_MINOR >= 2
    case ZMQ_USE_FD:
    case ZMQ_VMCI_CONNECT_TIMEOUT:
    case ZMQ_MULTICAST_MAXTPDU:
    case ZMQ_THREAD_SAFE:
    case ZMQ_TCP_MAXRT:
    case ZMQ_CONNECT_TIMEOUT:
    case ZMQ_INVERT_MATCHING:
    case ZMQ_HANDSHAKE_IVL:
    #endif

    #if ZMQ_VERSION_MAJOR > 4 || ZMQ_VERSION_MAJOR == 4 && ZMQ_VERSION_MINOR >= 1
    case ZMQ_TOS:
    #endif

    #if ZMQ_VERSION_MAJOR > 4 || ZMQ_VERSION_MAJOR == 4 && ZMQ_VERSION_MINOR >= 0
    case ZMQ_IMMEDIATE:
    case ZMQ_IPV6:
    case ZMQ_CURVE_SERVER:
    case ZMQ_GSSAPI_PLAINTEXT:
    case ZMQ_GSSAPI_SERVER:
    case ZMQ_PLAIN_SERVER:
    case ZMQ_MECHANISM:
    #endif
    // FIXME SOCKET on Windows, int on POSIX
    case ZMQ_FD:

    // deprecated
    case ZMQ_IPV4ONLY:
      option_len = sizeof(value_int);
      assert(socket->socket_zmq);
      if (zmq_getsockopt(socket->socket_zmq, option_name,
                              &value_int, &option_len)) {
        enif_mutex_unlock(socket->mutex);
        return return_zmq_errno(env, zmq_errno());
      }
      enif_mutex_unlock(socket->mutex);
      return enif_make_tuple2(env, enif_make_atom(env, "ok"),
                              enif_make_int(env, value_int));
    default:
      enif_mutex_unlock(socket->mutex);
      return enif_make_badarg(env);
  }
}

NIF(erlzmq_nif_send)
{
  erlzmq_socket_t * socket;
  ErlNifBinary binary;
  int flags;
  zmq_msg_t msg;

  if (! enif_get_resource(env, argv[0], erlzmq_nif_resource_socket,
                          (void **) &socket)) {
    return enif_make_badarg(env);
  }

  if (socket->context->status != ERLZMQ_CONTEXT_STATUS_READY) {
    return return_zmq_errno(env, ETERM);
  }

  if (socket->status != ERLZMQ_SOCKET_STATUS_READY) {
    return return_zmq_errno(env, ENOTSOCK);
  }

  if (! enif_inspect_iolist_as_binary(env, argv[1], &binary)) {
    return enif_make_badarg(env);
  }

  if (! enif_get_int(env, argv[2], &flags)) {
    return enif_make_badarg(env);
  }

  if (zmq_msg_init_size(&msg, binary.size)) {
    return return_zmq_errno(env, zmq_errno());
  }

  void * data = zmq_msg_data(&msg);
  assert(data);

  memcpy(data, binary.data, binary.size);

  assert(socket->mutex);
  enif_mutex_lock(socket->mutex);

  if (socket->status != ERLZMQ_SOCKET_STATUS_READY) {
    enif_mutex_unlock(socket->mutex);
    const int ret = zmq_msg_close(&msg);
    assert(ret == 0);
    return return_zmq_errno(env, ENOTSOCK);
  }

  ERL_NIF_TERM result;
  assert(socket->socket_zmq);
  if (zmq_sendmsg(socket->socket_zmq, &msg, flags) == -1) {
    int const error = zmq_errno();
    result = return_zmq_errno(env, error);
  }
  else {
    result = enif_make_atom(env, "ok");
  }

  enif_mutex_unlock(socket->mutex);
  const int ret = zmq_msg_close(&msg);
  assert(ret == 0);
  return result;
}

NIF(erlzmq_nif_recv)
{
  erlzmq_socket_t * socket;
  int flags;

  if (! enif_get_resource(env, argv[0], erlzmq_nif_resource_socket,
                          (void **) &socket)) {
    return enif_make_badarg(env);
  }

  if (! enif_get_int(env, argv[1], &flags)) {
    return enif_make_badarg(env);
  }

  if (socket->context->status != ERLZMQ_CONTEXT_STATUS_READY) {
    return return_zmq_errno(env, ETERM);
  }

  if (socket->status != ERLZMQ_SOCKET_STATUS_READY) {
    return return_zmq_errno(env, ENOTSOCK);
  }

  zmq_msg_t msg;
  if (zmq_msg_init(&msg)) {
    return return_zmq_errno(env, zmq_errno());
  }

  assert(socket->mutex);
  enif_mutex_lock(socket->mutex);
  if (socket->status != ERLZMQ_SOCKET_STATUS_READY) {
    enif_mutex_unlock(socket->mutex);
    const int ret = zmq_msg_close(&msg);
    assert(ret == 0);
    return return_zmq_errno(env, ENOTSOCK);
  }

  ERL_NIF_TERM result;

  assert(socket->socket_zmq);
  if (zmq_recvmsg(socket->socket_zmq, &msg, flags) == -1) {
    int const error = zmq_errno();
    result = return_zmq_errno(env, error);
  }
  else {
    ErlNifBinary binary;
    int alloc_success = enif_alloc_binary(zmq_msg_size(&msg), &binary);
    assert(alloc_success);
    void * data = zmq_msg_data(&msg);
    assert(data);
    memcpy(binary.data, data, zmq_msg_size(&msg));

    result = enif_make_tuple2(env, enif_make_atom(env, "ok"),
                            enif_make_binary(env, &binary));
  }

  enif_mutex_unlock(socket->mutex);
  const int ret = zmq_msg_close(&msg);
  assert(ret == 0);

  return result;
}

NIF(erlzmq_nif_close)
{
  erlzmq_socket_t * socket;

  if (! enif_get_resource(env, argv[0], erlzmq_nif_resource_socket,
                          (void **) &socket)) {
    return enif_make_badarg(env);
  }

  if (socket->status != ERLZMQ_SOCKET_STATUS_READY) {
    return return_zmq_errno(env, ENOTSOCK);
  }

  assert(socket->mutex);
  enif_mutex_lock(socket->mutex);

  if (socket->status != ERLZMQ_SOCKET_STATUS_READY) {
    enif_mutex_unlock(socket->mutex);
    return return_zmq_errno(env, ENOTSOCK);
  }

  if (zmq_close(socket->socket_zmq) != 0) {
    int const error = zmq_errno();
    socket->status = ERLZMQ_SOCKET_STATUS_CLOSED;

    enif_mutex_unlock(socket->mutex);
    return return_zmq_errno(env, error);
  }
  else {
    socket->status = ERLZMQ_SOCKET_STATUS_CLOSED;

    enif_mutex_unlock(socket->mutex);

    enif_release_resource(socket);
    enif_release_resource(socket->context);

    return enif_make_atom(env, "ok");
  }
}

NIF(erlzmq_nif_term)
{
  erlzmq_context_t * context;

  if (! enif_get_resource(env, argv[0], erlzmq_nif_resource_context,
                          (void **) &context)) {
    return enif_make_badarg(env);
  }

  if (context->status != ERLZMQ_CONTEXT_STATUS_READY) {
    return return_zmq_errno(env, ETERM);
  }

  assert(context->mutex);
  enif_mutex_lock(context->mutex);

  if (context->status != ERLZMQ_CONTEXT_STATUS_READY) {
    enif_mutex_unlock(context->mutex);
    return return_zmq_errno(env, ETERM);
  }

  context->status = ERLZMQ_CONTEXT_STATUS_TERMINATING;

  enif_mutex_unlock(context->mutex);

  if (zmq_term(context->context_zmq) != 0) {
    int const error = zmq_errno();
    
    enif_mutex_lock(context->mutex);
    context->status = ERLZMQ_CONTEXT_STATUS_READY;
    enif_mutex_unlock(context->mutex);

    return return_zmq_errno(env, error);
  }
  else {
    enif_mutex_lock(context->mutex);
    context->status = ERLZMQ_CONTEXT_STATUS_TERMINATED;
    enif_mutex_unlock(context->mutex);

    enif_release_resource(context);

    return enif_make_atom(env, "ok");
  }
}

NIF(erlzmq_nif_ctx_set)
{
  erlzmq_context_t * context;

  if (! enif_get_resource(env, argv[0], erlzmq_nif_resource_context,
                          (void **) &context)) {
    return enif_make_badarg(env);
  }
  if (context->status != ERLZMQ_CONTEXT_STATUS_READY) {
    return return_zmq_errno(env, ETERM);
  }
  int option_name;

  if (! enif_get_int(env, argv[1], &option_name)) {
    return enif_make_badarg(env);
  }

  int value_int;
  switch (option_name) {
    // int
    case ZMQ_IO_THREADS:
    case ZMQ_MAX_SOCKETS:
    case ZMQ_IPV6:
    #if ZMQ_VERSION_MAJOR > 4 || ZMQ_VERSION_MAJOR == 4 && ZMQ_VERSION_MINOR >= 1
    case ZMQ_THREAD_SCHED_POLICY:
    case ZMQ_THREAD_PRIORITY:
    #endif
    #if ZMQ_VERSION_MAJOR > 4 || ZMQ_VERSION_MAJOR == 4 && ZMQ_VERSION_MINOR >= 2
    case ZMQ_BLOCKY:
    case ZMQ_MAX_MSGSZ:
    #endif
    #if ZMQ_VERSION_MAJOR > 4 || ZMQ_VERSION_MAJOR == 4 && ZMQ_VERSION_MINOR >= 3
    case ZMQ_THREAD_AFFINITY_CPU_ADD:
    case ZMQ_THREAD_AFFINITY_CPU_REMOVE:
    case ZMQ_THREAD_NAME_PREFIX:
    #endif
      if (! enif_get_int(env, argv[2], &value_int)) {
        return enif_make_badarg(env);
      }
      break;
    default:
      return enif_make_badarg(env);
  }

  assert(context->mutex);
  enif_mutex_lock(context->mutex);
  if (context->status != ERLZMQ_CONTEXT_STATUS_READY) {
    enif_mutex_unlock(context->mutex);
    return return_zmq_errno(env, ETERM);
  }
  assert(context->context_zmq);
  if (zmq_ctx_set(context->context_zmq, option_name,
                          value_int)) {
    enif_mutex_unlock(context->mutex);
    return return_zmq_errno(env, zmq_errno());
  }
  else {
    enif_mutex_unlock(context->mutex);
    return enif_make_atom(env, "ok");
  }
}

NIF(erlzmq_nif_ctx_get)
{
  erlzmq_context_t * context;
  int option_name;

  if (! enif_get_resource(env, argv[0], erlzmq_nif_resource_context,
                          (void **) &context)) {
    return enif_make_badarg(env);
  }

  if (context->status != ERLZMQ_CONTEXT_STATUS_READY) {
    return return_zmq_errno(env, ETERM);
  }

  if (! enif_get_int(env, argv[1], &option_name)) {
    return enif_make_badarg(env);
  }

  int value_int;
  switch(option_name) {
    // int
    case ZMQ_IO_THREADS:
    case ZMQ_MAX_SOCKETS:
    case ZMQ_IPV6:
    #if ZMQ_VERSION_MAJOR > 4 || ZMQ_VERSION_MAJOR == 4 && ZMQ_VERSION_MINOR >= 1
    case ZMQ_SOCKET_LIMIT:
    case ZMQ_THREAD_SCHED_POLICY:
    #endif
    #if ZMQ_VERSION_MAJOR > 4 || ZMQ_VERSION_MAJOR == 4 && ZMQ_VERSION_MINOR >= 2
    case ZMQ_MAX_MSGSZ:
    case ZMQ_BLOCKY:
    #endif
    #if ZMQ_VERSION_MAJOR > 4 || ZMQ_VERSION_MAJOR == 4 && ZMQ_VERSION_MINOR >= 3
    case ZMQ_THREAD_NAME_PREFIX:
    case ZMQ_MSG_T_SIZE:
    #endif
      assert(context->mutex);
      enif_mutex_lock(context->mutex);
      if (context->status != ERLZMQ_CONTEXT_STATUS_READY) {
        enif_mutex_unlock(context->mutex);
        return return_zmq_errno(env, ETERM);
      }
      assert(context->context_zmq);
      value_int = zmq_ctx_get(context->context_zmq, option_name);
      if (value_int == -1) {
        enif_mutex_unlock(context->mutex);
        return return_zmq_errno(env, zmq_errno());
      }

      enif_mutex_unlock(context->mutex);
      return enif_make_tuple2(env, enif_make_atom(env, "ok"),
                              enif_make_int(env, value_int));
    default:
      return enif_make_badarg(env);
  }
}

NIF(erlzmq_nif_curve_keypair)
{
  char public[41];
  char secret[41];
  ErlNifBinary pub_bin;
  ErlNifBinary sec_bin;
  if (zmq_curve_keypair(public, secret)) {
    return return_zmq_errno(env, zmq_errno());
  }
  int alloc_success = enif_alloc_binary(40, &pub_bin);
  assert(alloc_success);
  alloc_success = enif_alloc_binary(40, &sec_bin);
  assert(alloc_success);
  memcpy(pub_bin.data, public, 40);
  memcpy(sec_bin.data, secret, 40);
  return enif_make_tuple3(env, enif_make_atom(env, "ok"),
                          enif_make_binary(env, &pub_bin),
                          enif_make_binary(env, &sec_bin));

}

NIF(erlzmq_nif_z85_decode)
{
  ErlNifBinary value_binary;
  if (! enif_inspect_iolist_as_binary(env, argv[0], &value_binary)) {
    return enif_make_badarg(env);
  }
  if (value_binary.size % 5 != 0) { 
    return enif_make_badarg(env);
  }
  // 0-terminate the string
  size_t z85_size = value_binary.size;
  size_t dec_size = z85_size / 5 * 4;
  char *z85buf = (char*) malloc(z85_size+1);
  assert(z85buf);
  memcpy(z85buf, value_binary.data, value_binary.size);
  z85buf[value_binary.size] = 0;

  ErlNifBinary dec_bin;
  ERL_NIF_TERM ret;
  int alloc_success = enif_alloc_binary(dec_size, &dec_bin);
  assert(alloc_success);
  if (zmq_z85_decode (dec_bin.data, z85buf) == NULL) {
    ret = return_zmq_errno(env, zmq_errno());
  } else {
    ret = enif_make_tuple2(env, enif_make_atom(env, "ok"),
                                enif_make_binary(env, &dec_bin));
  }
  free(z85buf);
  return ret;
}

NIF(erlzmq_nif_z85_encode)
{
  ErlNifBinary value_binary;
  if (! enif_inspect_iolist_as_binary(env, argv[0], &value_binary)) {
    return enif_make_badarg(env);
  }
  if (value_binary.size % 4 != 0) { 
    return enif_make_badarg(env);
  }

  size_t z85_size = value_binary.size;
  size_t enc_size = z85_size / 4 * 5;

  // need to accomodate NULL terminator
  char *z85buf = (char*) malloc(enc_size+1);
  assert(z85buf);

  ERL_NIF_TERM ret;

  if (zmq_z85_encode(z85buf, value_binary.data, value_binary.size) == NULL) {
    ret = return_zmq_errno(env, zmq_errno());
  } else {
    ErlNifBinary enc_bin;
    int alloc_success = enif_alloc_binary(enc_size, &enc_bin);
    assert(alloc_success);
    // drop NULL terminator
    memcpy(enc_bin.data, z85buf, enc_size);
    ret = enif_make_tuple2(env, enif_make_atom(env, "ok"),
                                enif_make_binary(env, &enc_bin));
  }
  free(z85buf);
  return ret;
}

NIF(erlzmq_nif_has)
{
  unsigned capability_length;

  if (! enif_get_atom_length(env, argv[0], &capability_length, ERL_NIF_LATIN1)) {
    return enif_make_badarg(env);
  }

  char * capability = (char *) malloc(capability_length + 1);
  assert(capability);
  if (! enif_get_atom(env, argv[0], capability, capability_length + 1,
                        ERL_NIF_LATIN1)) {
    free(capability);
    return enif_make_badarg(env);
  }

  ERL_NIF_TERM result;
#ifdef ZMQ_HAS_CAPABILITIES
  if (zmq_has(capability) == 1) {
    result = enif_make_atom(env, "true");
  }
  else {
    result = enif_make_atom(env, "false");
  }
#else
  // version < 4.1
  result = enif_make_atom(env, "unknown");
#endif

  free(capability);

  return result;
}

NIF(erlzmq_nif_version)
{
  int major, minor, patch;
  zmq_version(&major, &minor, &patch);
  return enif_make_tuple3(env, enif_make_int(env, major),
                          enif_make_int(env, minor),
                          enif_make_int(env, patch));
}

static ERL_NIF_TERM return_zmq_errno(ErlNifEnv* env, int const value)
{
  switch (value) {
    case EPERM:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "eperm"));
    case ENOENT:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "enoent"));
    case ESRCH:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "esrch"));
    case EINTR:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "eintr"));
    case EIO:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "eio"));
    case ENXIO:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "enxio"));
    case ENOEXEC:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "enoexec"));
    case EBADF:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "ebadf"));
    case ECHILD:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "echild"));
    case EDEADLK:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "edeadlk"));
    case ENOMEM:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "enomem"));
    case EACCES:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "eacces"));
    case EFAULT:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "efault"));
    case ENOTBLK:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "enotblk"));
    case EBUSY:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "ebusy"));
    case EEXIST:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "eexist"));
    case EXDEV:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "exdev"));
    case ENODEV:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "enodev"));
    case ENOTDIR:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "enotdir"));
    case EISDIR:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "eisdir"));
    case EINVAL:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "einval"));
    case ENFILE:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "enfile"));
    case EMFILE:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "emfile"));
    case ETXTBSY:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "etxtbsy"));
    case EFBIG:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "efbig"));
    case ENOSPC:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "enospc"));
    case ESPIPE:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "espipe"));
    case EROFS:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "erofs"));
    case EMLINK:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "emlink"));
    case EPIPE:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "epipe"));
    case EAGAIN:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "eagain"));
    case EINPROGRESS:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "einprogress"));
    case EALREADY:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "ealready"));
    case ENOTSOCK:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "enotsock"));
    case EDESTADDRREQ:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "edestaddrreq"));
    case EMSGSIZE:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "emsgsize"));
    case EPROTOTYPE:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "eprototype"));
    case ENOPROTOOPT:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "eprotoopt"));
    case EPROTONOSUPPORT:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "eprotonosupport"));
    case ESOCKTNOSUPPORT:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "esocktnosupport"));
    case ENOTSUP:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "enotsup"));
    case EPFNOSUPPORT:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "epfnosupport"));
    case EAFNOSUPPORT:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "eafnosupport"));
    case EADDRINUSE:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "eaddrinuse"));
    case EADDRNOTAVAIL:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "eaddrnotavail"));
    case ENETDOWN:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "enetdown"));
    case ENETUNREACH:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "enetunreach"));
    case ENETRESET:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "enetreset"));
    case ECONNABORTED:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "econnaborted"));
    case ECONNRESET:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "econnreset"));
    case ENOBUFS:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "enobufs"));
    case EISCONN:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "eisconn"));
    case ENOTCONN:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "enotconn"));
    case ESHUTDOWN:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "eshutdown"));
    case ETOOMANYREFS:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "etoomanyrefs"));
    case ETIMEDOUT:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "etimedout"));
    case EHOSTUNREACH:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "ehostunreach"));
    case ECONNREFUSED:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "econnrefused"));
    case ELOOP:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "eloop"));
    case ENAMETOOLONG:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "enametoolong"));
    case EFSM:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "efsm"));
    case ENOCOMPATPROTO:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "enocompatproto"));
    case ETERM:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "eterm"));
    case EMTHREAD:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, "emthread"));
    default:
      return enif_make_tuple2(env, enif_make_atom(env, "error"),
                              enif_make_atom(env, erl_errno_id(value)));
  }
}

static void context_destructor(ErlNifEnv * env, erlzmq_context_t * context) {
  if (context->status != ERLZMQ_CONTEXT_STATUS_TERMINATED) {
    fprintf(stderr, "destructor reached for context while not terminated\n");
    assert(0);
  }

  if (context->mutex) {
    enif_mutex_destroy(context->mutex);
    context->mutex = 0;
  }
}

static void socket_destructor(ErlNifEnv * env, erlzmq_socket_t * socket) {
  if (socket->status != ERLZMQ_SOCKET_STATUS_CLOSED) {
    fprintf(stderr, "destructor reached for socket %" PRIu64 " while not closed\n", socket->socket_index);
    assert(0);
  }

  if (socket->mutex) {
    enif_mutex_destroy(socket->mutex);
    socket->mutex = 0;
  }
}

static int on_load(ErlNifEnv* env, void** priv_data, ERL_NIF_TERM load_info)
{
  erlzmq_nif_resource_context =
    enif_open_resource_type(env, NULL,
                            "erlzmq_nif_resource_context",
                            (ErlNifResourceDtor*)context_destructor,
                            ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER,
                            0);
  erlzmq_nif_resource_socket =
    enif_open_resource_type(env, NULL,
                            "erlzmq_nif_resource_socket",
                            (ErlNifResourceDtor*)socket_destructor,
                            ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER,
                            0);

  if (!erlzmq_nif_resource_context || !erlzmq_nif_resource_socket) {
    return -1;
  }
  else {
    return 0;
  }
}

static void on_unload(ErlNifEnv* env, void* priv_data) {
}

ERL_NIF_INIT(erlzmq_nif, nif_funcs, &on_load, NULL, NULL, &on_unload)

