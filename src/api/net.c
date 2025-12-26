#include <SDL3_net/SDL_net.h>
#include <stdbool.h>

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

#include <mbedtls/ssl.h>
#include <mbedtls/x509_crt.h>
#include <mbedtls/ctr_drbg.h>
#include <mbedtls/entropy.h>
#include <mbedtls/error.h>

#define API_TYPE_NET_ADDRESS "NetAddress"
#define API_TYPE_NET_TCP "NetTCP"
#define API_TYPE_NET_UDP "NetUDP"
#define API_TYPE_NET_SERVER "NetServer"
#define API_TYPE_NET_DATAGRAM "NetDataGram"

typedef enum ConnectionType {
  TCP,
  UDP
} ConnectionType;

typedef struct Connection {
  void* socket;
  ConnectionType type;
  Uint16 port;
  bool is_ssl;
  mbedtls_ssl_context ssl;
  mbedtls_ssl_config conf;
  mbedtls_ctr_drbg_context drbg;
  mbedtls_entropy_context entropy;
  mbedtls_x509_crt cacert;
} Connection;

typedef struct Address {
  NET_Address* address;
  char hostname[254];
} Address;

typedef struct Server {
  NET_Server* server;
  Uint16 port;
} Server;

typedef struct DataGram {
  NET_Datagram* datagram;
} DataGram;

static char CACERT_BUNDLE[1024] = { 0 };


static int sdl_mbedtls_send(void *ctx, const unsigned char *buf, size_t len) {
  NET_StreamSocket *sock = ctx;

  if (NET_WriteToStreamSocket(sock, buf, (int)len)) {
    return (int)len;
  }

  return MBEDTLS_ERR_SSL_INTERNAL_ERROR;
}

static int sdl_mbedtls_recv(void *ctx, unsigned char *buf, size_t len) {
  NET_StreamSocket *sock = ctx;
  int rc = NET_ReadFromStreamSocket(sock, buf, (int)len);

  if (rc > 0) return rc;
  if (rc == 0) return MBEDTLS_ERR_SSL_WANT_READ;

  return MBEDTLS_ERR_SSL_INTERNAL_ERROR;
}

bool load_cacert_bundle(mbedtls_x509_crt *cacert) {
  // load previous or path to custom bundle like https://curl.se/ca/cacert.pem
  if (
    strlen(CACERT_BUNDLE) > 0
    &&
    mbedtls_x509_crt_parse_file(cacert, CACERT_BUNDLE) == 0
  )
    return true;

#if defined(SDL_PLATFORM_LINUX) || defined(SDL_PLATFORM_UNIX) || \
    defined(SDL_PLATFORM_FREEBSD) || defined(SDL_PLATFORM_NETBSD) || \
    defined(SDL_PLATFORM_OPENBSD)
  const char *paths[] = {
    "/etc/ssl/certs/ca-certificates.crt",
    "/etc/pki/tls/certs/ca-bundle.crt",
    "/etc/ssl/ca-bundle.pem",
    "/usr/local/share/certs/ca-root-nss.crt",
    "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem",
    "/etc/ssl/cert.pem",
    NULL
  };

  for (int i = 0; paths[i]; i++) {
    if (mbedtls_x509_crt_parse_file(cacert, paths[i]) == 0) {
      strcpy(CACERT_BUNDLE, paths[i]);
      return true;
    }
  }
#endif

  return false;
}

/******************************************************************************/
/* Library Functions                                                          */
/******************************************************************************/

static int f_set_cacert_path(lua_State* L) {
  const char* path = luaL_checkstring(L, 1);
  strcpy(CACERT_BUNDLE, path);
  return 0;
}

static int f_get_cacert_path(lua_State* L) {
  if (strlen(CACERT_BUNDLE) > 0) {
    lua_pushstring(L, CACERT_BUNDLE);
  } else {
    mbedtls_x509_crt cacert;
    mbedtls_x509_crt_init(&cacert);

    if (load_cacert_bundle(&cacert))
      lua_pushstring(L, CACERT_BUNDLE);
    else
      lua_pushnil(L);

    mbedtls_x509_crt_free(&cacert);
  }

  return 1;
}

static int f_resolve_address(lua_State* L) {
  const char* hostname = luaL_checkstring(L, 1);

  NET_Address* address;
  if ((address = NET_ResolveHostname(hostname)) != NULL) {
    Address* self = lua_newuserdata(L, sizeof(Address));
    self->address = address;
    strcpy(self->hostname, hostname);
    luaL_setmetatable(L, API_TYPE_NET_ADDRESS);
    return 1;
  }

  lua_pushnil(L);
  lua_pushstring(L, SDL_GetError());
  return 2;
}

static int f_get_local_addresses(lua_State* L) {
  int count = 0;
  NET_Address** list = NET_GetLocalAddresses(&count);

  if (!list) {
    lua_pushnil(L);
    lua_pushstring(L, SDL_GetError());
  } else if (count > 0) {
    lua_createtable(L, count, 0);
    for(int i=0; i<count; i++) {
      Address* self = lua_newuserdata(L, sizeof(Address));
      NET_RefAddress(list[i]);
      self->address = list[i];
      strcpy(self->hostname, NET_GetAddressString(list[i]));
      luaL_setmetatable(L, API_TYPE_NET_ADDRESS);
      lua_rawseti(L, -2, i+1);
    }
  } else {
    lua_pushnil(L);
    lua_pushstring(L, "no local address found");
  }

  NET_FreeLocalAddresses(list);

  return count > 0 ? 1 : 2;
}

static int f_open_tcp(lua_State* L) {
  Address* address = (Address*) luaL_checkudata(L, 1, API_TYPE_NET_ADDRESS);
  unsigned short port = luaL_checkinteger(L, 2);
  bool ssl = lua_isnoneornil(L, 3) ? false : lua_toboolean(L, 3);

  NET_StreamSocket* socket = NET_CreateClient(address->address, port);

  if (socket == NULL) {
    lua_pushnil(L);
    lua_pushstring(L, SDL_GetError());
    return 2;
  }

  Connection* self = lua_newuserdata(L, sizeof(Connection));
  self->type = TCP;
  self->socket = socket;
  self->port = port;
  self->is_ssl = ssl;

  luaL_setmetatable(L, API_TYPE_NET_TCP);

  int rc = 0;
  if (ssl) {
    mbedtls_ssl_init(&self->ssl);
    mbedtls_ssl_config_init(&self->conf);
    mbedtls_ctr_drbg_init(&self->drbg);
    mbedtls_entropy_init(&self->entropy);
    mbedtls_x509_crt_init(&self->cacert);

    const char *pers = "pragtical_sdl3_net_tls_client";

    if (
      (rc = mbedtls_ctr_drbg_seed(
        &self->drbg,
        mbedtls_entropy_func,
        &self->entropy,
        (const unsigned char *)pers,
        strlen(pers)
      )) != 0
    )
      goto ssl_error;

    if (
      (rc = mbedtls_ssl_config_defaults(
        &self->conf,
        MBEDTLS_SSL_IS_CLIENT,
        MBEDTLS_SSL_TRANSPORT_STREAM,
        MBEDTLS_SSL_PRESET_DEFAULT
      )) != 0
    )
      goto ssl_error;

    mbedtls_ssl_conf_rng(&self->conf, mbedtls_ctr_drbg_random, &self->drbg);

    if (load_cacert_bundle(&self->cacert)) {
      mbedtls_ssl_conf_ca_chain(&self->conf, &self->cacert, NULL);
      mbedtls_ssl_conf_authmode(&self->conf, MBEDTLS_SSL_VERIFY_REQUIRED);
    } else {
      mbedtls_ssl_conf_authmode(&self->conf, MBEDTLS_SSL_VERIFY_NONE);
    }

    if ((rc = mbedtls_ssl_setup(&self->ssl, &self->conf)) != 0)
      goto ssl_error;

    if((rc = mbedtls_ssl_set_hostname(&self->ssl, address->hostname)) != 0)
      goto ssl_error;

    mbedtls_ssl_set_bio(
      &self->ssl, self->socket, sdl_mbedtls_send, sdl_mbedtls_recv, NULL
    );
  }

  return 1;

ssl_error:
  mbedtls_ssl_close_notify(&self->ssl);
  mbedtls_ssl_free(&self->ssl);
  mbedtls_ssl_config_free(&self->conf);
  mbedtls_ctr_drbg_free(&self->drbg);
  mbedtls_entropy_free(&self->entropy);
  mbedtls_x509_crt_free(&self->cacert);
  NET_DestroyStreamSocket(socket);

  char errbuf[128];
  mbedtls_strerror(rc, errbuf, sizeof(errbuf));
  lua_pushnil(L);
  lua_pushstring(L, errbuf);

  return 2;
}

static int f_open_udp(lua_State* L) {
  Address* address = (Address*) luaL_checkudata(L, 1, API_TYPE_NET_ADDRESS);
  unsigned short port = luaL_checkinteger(L, 2);

  NET_DatagramSocket* socket = NET_CreateDatagramSocket(address->address, port);

  if (socket == NULL) {
    lua_pushnil(L);
    lua_pushstring(L, SDL_GetError());
    return 2;
  }

  Connection* self = lua_newuserdata(L, sizeof(Connection));
  self->type = UDP;
  self->socket = socket;
  self->port = port;

  luaL_setmetatable(L, API_TYPE_NET_UDP);

  return 1;
}

static int f_create_server(lua_State* L) {
  int params = lua_gettop(L);

  Address* address = NULL;
  unsigned short port = 0;

  if (params > 1) {
    address = (Address*) luaL_checkudata(L, 1, API_TYPE_NET_ADDRESS);
    port = luaL_checkinteger(L, 2);
  } else {
    port = luaL_checkinteger(L, 1);
  }

  NET_Server* server = NET_CreateServer(
    address ? address->address : NULL, port
  );

  if (server == NULL) {
    lua_pushnil(L);
    lua_pushstring(L, SDL_GetError());
    return 2;
  }

  Server* self = lua_newuserdata(L, sizeof(Server));
  self->server = server;
  self->port = port;

  luaL_setmetatable(L, API_TYPE_NET_SERVER);

  return 1;
}

static int f_gc(lua_State *L) {
  NET_Quit();
  return 0;
}

/******************************************************************************/
/* Address Methods                                                            */
/******************************************************************************/

static int m_address_wait_until_resolved(lua_State* L) {
  Address* self = (Address*) luaL_checkudata(L, 1, API_TYPE_NET_ADDRESS);
  Sint32 timeout = luaL_optint(L, 2, 0);
  NET_Status status = NET_WaitUntilResolved(self->address, timeout);

  int ret = 1;
  switch(status){
    case NET_SUCCESS:
      lua_pushstring(L, "success");
      break;
    case NET_WAITING:
      lua_pushstring(L, "waiting");
      break;
    case NET_FAILURE:
      lua_pushstring(L, "failure");
      lua_pushstring(L, SDL_GetError());
      ret++;
      break;
  }

  return ret;
}

static int m_address_get_status(lua_State* L) {
  Address* self = (Address*) luaL_checkudata(L, 1, API_TYPE_NET_ADDRESS);
  NET_Status status = NET_GetAddressStatus(self->address);

  int ret = 1;
  switch(status){
    case NET_SUCCESS:
      lua_pushstring(L, "success");
      break;
    case NET_WAITING:
      lua_pushstring(L, "waiting");
      break;
    case NET_FAILURE:
      lua_pushstring(L, "failure");
      lua_pushstring(L, SDL_GetError());
      ret++;
      break;
  }

  return ret;
}

static int m_address_get_ip(lua_State* L) {
  Address* self = (Address*) luaL_checkudata(L, 1, API_TYPE_NET_ADDRESS);
  const char* address = NET_GetAddressString(self->address);

  if (address)
    lua_pushstring(L, address);
  else
    lua_pushnil(L);

  return 1;
}

static int m_address_get_hostname(lua_State* L) {
  Address* self = (Address*) luaL_checkudata(L, 1, API_TYPE_NET_ADDRESS);
  if(strlen(self->hostname) > 0) {
    lua_pushstring(L, self->hostname);
    return 1;
  }
  return m_address_get_ip(L);
}

static int mm_address_tostring(lua_State* L) {
  return m_address_get_hostname(L);
}

static int mm_address_gc(lua_State* L) {
  Address* self = (Address*) luaL_checkudata(L, 1, API_TYPE_NET_ADDRESS);
  NET_UnrefAddress(self->address);
  return 0;
}

/******************************************************************************/
/* Server                                                                     */
/******************************************************************************/

static int m_server_accept(lua_State* L) {
  Server* self = (Server*) luaL_checkudata(L, 1, API_TYPE_NET_SERVER);

  NET_StreamSocket *client_socket = NULL;
  bool accepted = NET_AcceptClient(self->server, &client_socket);

  if (!accepted) {
    lua_pushnil(L);
    lua_pushstring(L, SDL_GetError());
    return 2;
  } else if(client_socket) {
    Connection* client = lua_newuserdata(L, sizeof(Connection));
    client->type = TCP;
    client->socket = client_socket;
    luaL_setmetatable(L, API_TYPE_NET_TCP);
  }

  return 1;
}

static int m_server_get_port(lua_State* L) {
  Server* self = (Server*) luaL_checkudata(L, 1, API_TYPE_NET_SERVER);
  lua_pushinteger(L, self->port);
  return 1;
}

static int mm_server_gc(lua_State* L) {
  Server* self = (Server*) luaL_checkudata(L, 1, API_TYPE_NET_SERVER);
  NET_DestroyServer(self->server);
  return 0;
}

/******************************************************************************/
/* TCP Methods                                                                */
/******************************************************************************/

static int m_tcp_wait_until_connected(lua_State* L) {
  Connection* self = (Connection*) luaL_checkudata(L, 1, API_TYPE_NET_TCP);
  Sint32 timeout = luaL_optint(L, 2, 0);

  double start_time = (
    SDL_GetPerformanceCounter() / (double) SDL_GetPerformanceFrequency()
  ) * 1000;

  // First check the TCP connection status
  NET_Status status = NET_WaitUntilConnected(self->socket, timeout);

  int ret = 1;

  if (status != NET_SUCCESS) {
    switch (status){
      case NET_WAITING:
        lua_pushstring(L, "waiting");
        break;
      case NET_FAILURE:
        lua_pushstring(L, "failure");
        lua_pushstring(L, SDL_GetError());
        ret++;
        break;
      case NET_SUCCESS:
        // never reached, used to silence warning
        break;
    }
    return ret;
  }

  // Now check handshake status if ssl enabled
  hand_shake:
  if (self->is_ssl) {
    int rc = mbedtls_ssl_handshake(&self->ssl);
    if (rc == 0) {
      lua_pushstring(L, "success");
    } else if (rc == MBEDTLS_ERR_SSL_WANT_READ || rc == MBEDTLS_ERR_SSL_WANT_WRITE) {
      double end_time =
        (SDL_GetPerformanceCounter() / (double) SDL_GetPerformanceFrequency())
        * 1000
        - start_time
      ;
      if(timeout == -1 || (timeout > 0 && timeout > end_time)) {
        SDL_Delay(5);
        goto hand_shake;
      }
      lua_pushstring(L, "waiting");
    } else {
      char errbuf[128];
      mbedtls_strerror(rc, errbuf, sizeof(errbuf));
      lua_pushstring(L, "failure");
      lua_pushstring(L, errbuf);
      ret++;
    }
    return ret;
  }

  lua_pushstring(L, "success");
  return ret;
}


static int m_tcp_get_address(lua_State* L) {
  Connection* self = (Connection*) luaL_checkudata(L, 1, API_TYPE_NET_TCP);

  NET_Address* address = NET_GetStreamSocketAddress(self->socket);

  if(!address) {
    lua_pushnil(L);
    lua_pushstring(L, SDL_GetError());
    return 2;
  }

  Address* addr = (Address*) lua_newuserdata(L, sizeof(Address));
  addr->address = address;
  addr->hostname[0] = '\0';
  NET_RefAddress(addr->address);
  luaL_setmetatable(L, API_TYPE_NET_ADDRESS);

  return 1;
}

static int m_tcp_get_status(lua_State* L) {
  Connection* self = (Connection*) luaL_checkudata(L, 1, API_TYPE_NET_TCP);

  NET_Status status = NET_GetConnectionStatus(self->socket);

  int ret = 1;

  // If TCP is not ready, just return TCP status
  if (status != NET_SUCCESS) {
    switch (status){
      case NET_WAITING:
        lua_pushstring(L, "waiting");
        break;
      case NET_FAILURE:
        lua_pushstring(L, "failure");
        lua_pushstring(L, SDL_GetError());
        ret++;
        break;
      case NET_SUCCESS:
        // never reached, used to silence warning
        break;
    }
    return ret;
  }

  // If TCP succeeded and it's SSL, do handshake
  if (self->is_ssl) {
    int rc = mbedtls_ssl_handshake(&self->ssl);

    if (rc == 0) {
      lua_pushstring(L, "success");
    } else if (rc == MBEDTLS_ERR_SSL_WANT_READ || rc == MBEDTLS_ERR_SSL_WANT_WRITE) {
      lua_pushstring(L, "waiting");
    } else {
      char errbuf[128];
      mbedtls_strerror(rc, errbuf, sizeof(errbuf));
      lua_pushstring(L, "failure");
      lua_pushstring(L, errbuf);
      ret++;
    }
    return ret;
  }

  lua_pushstring(L, "success");
  return ret;
}

static int m_tcp_write(lua_State* L) {
  Connection* self = (Connection*) luaL_checkudata(L, 1, API_TYPE_NET_TCP);

  size_t data_len = 0;
  const char* data = luaL_checklstring(L, 2, &data_len);

  if (!self->is_ssl) {
    bool sent = NET_WriteToStreamSocket(self->socket, data, data_len);

    if (!sent) {
      lua_pushboolean(L, 0);
      lua_pushstring(L, SDL_GetError());
      return 2;
    }

    lua_pushboolean(L, 1);
  } else {
    int rc = mbedtls_ssl_write(&self->ssl, (const unsigned char*)data, data_len);
    if (rc >= 0) {
      lua_pushboolean(L, 1);
    } else {
      // Real error
      char errbuf[128];
      mbedtls_strerror(rc, errbuf, sizeof(errbuf));
      lua_pushboolean(L, 0);
      lua_pushstring(L, errbuf);
      return 2;
    }
  }

  return 1;
}

static int m_tcp_get_pending_writes(lua_State* L) {
  Connection* self = (Connection*) luaL_checkudata(L, 1, API_TYPE_NET_TCP);

  int pending = NET_GetStreamSocketPendingWrites(self->socket);

  if(pending == -1) {
    lua_pushnil(L);
    lua_pushstring(L, SDL_GetError());
    return 2;
  }

  lua_pushinteger(L, pending);

  return 1;
}

static int m_tcp_wait_until_drained(lua_State* L) {
  Connection* self = (Connection*) luaL_checkudata(L, 1, API_TYPE_NET_TCP);
  Sint32 timeout = luaL_optint(L, 2, 0);

  int pending = NET_WaitUntilStreamSocketDrained(self->socket, timeout);

  if(pending == -1) {
    lua_pushnil(L);
    lua_pushstring(L, SDL_GetError());
    return 2;
  }

  lua_pushinteger(L, pending);

  return 1;
}

static int m_tcp_read(lua_State* L) {
  Connection* self = (Connection*) luaL_checkudata(L, 1, API_TYPE_NET_TCP);
  const size_t max_len = luaL_checkinteger(L, 2);

  char* data = SDL_malloc(max_len);

  int return_count = 1;
  if (!self->is_ssl) {
    size_t received = NET_ReadFromStreamSocket(self->socket, data, max_len);
    if (received == -1) {
      lua_pushnil(L);
      lua_pushstring(L, SDL_GetError());
      return_count = 2;
    } else {
      lua_pushlstring(L, data, received);
    }
  } else {
    int rc = mbedtls_ssl_read(&self->ssl, (unsigned char*) data, max_len);
    if (rc >= 0) {
      lua_pushlstring(L, data, rc);
    } else if (rc == MBEDTLS_ERR_SSL_WANT_READ) {
      lua_pushstring(L, "");
    } else {
      char errbuf[128];
      mbedtls_strerror(rc, errbuf, sizeof(errbuf));
      lua_pushnil(L);
      lua_pushstring(L, errbuf);
      return_count = 2;
    }
  }

  SDL_free(data);

  return return_count;
}

static int m_tcp_close(lua_State* L) {
  Connection* self = (Connection*) luaL_checkudata(L, 1, API_TYPE_NET_TCP);
  if (self->socket) {
    if (self->is_ssl) {
      mbedtls_ssl_close_notify(&self->ssl);
      mbedtls_ssl_free(&self->ssl);
      mbedtls_ssl_config_free(&self->conf);
      mbedtls_ctr_drbg_free(&self->drbg);
      mbedtls_entropy_free(&self->entropy);
      mbedtls_x509_crt_free(&self->cacert);
    }
    NET_DestroyStreamSocket(self->socket);
    self->socket = NULL;
  }
  return 0;
}

static int mm_tcp_gc(lua_State* L) {
  return m_tcp_close(L);
}

/******************************************************************************/
/* UDP Methods                                                                */
/******************************************************************************/

static int m_udp_send(lua_State* L) {
  Connection* self = (Connection*) luaL_checkudata(L, 1, API_TYPE_NET_UDP);
  Address* address = (Address*) luaL_checkudata(L, 2, API_TYPE_NET_ADDRESS);
  Uint16 port = luaL_checkint(L, 3);

  size_t data_len = 0;
  const char* data = luaL_checklstring(L, 4, &data_len);

  bool sent = NET_SendDatagram(self->socket, address->address, port, data, data_len);

  if(!sent) {
    lua_pushboolean(L, 0);
    lua_pushstring(L, SDL_GetError());
    return 2;
  }

  lua_pushboolean(L, 1);

  return 1;
}

static int m_udp_receive(lua_State* L) {
  Connection* self = (Connection*) luaL_checkudata(L, 1, API_TYPE_NET_UDP);

  NET_Datagram *dgram = NULL;

  bool received = NET_ReceiveDatagram(self->socket, &dgram);

  if(!received) {
    lua_pushnil(L);
    lua_pushstring(L, SDL_GetError());
    return 2;
  }

  if (dgram) {
    DataGram* data = (DataGram*) lua_newuserdata(L, sizeof(DataGram));
    data->datagram = dgram;
    luaL_setmetatable(L, API_TYPE_NET_DATAGRAM);
    return 1;
  }

  return 0;
}

static int m_udp_close(lua_State* L) {
  Connection* self = (Connection*) luaL_checkudata(L, 1, API_TYPE_NET_UDP);
  if (self->socket) {
    NET_DestroyDatagramSocket(self->socket);
    self->socket = NULL;
  }
  return 0;
}

static int mm_udp_gc(lua_State* L) {
  return m_udp_close(L);
}

/******************************************************************************/
/* DataGram                                                                   */
/******************************************************************************/

static int m_datagram_get_data(lua_State* L) {
  DataGram* self = (DataGram*) luaL_checkudata(L, 1, API_TYPE_NET_DATAGRAM);
  lua_pushlstring(L, (const char*)self->datagram->buf, self->datagram->buflen);
  return 1;
}

static int m_datagram_get_address(lua_State* L) {
  DataGram* self = (DataGram*) luaL_checkudata(L, 1, API_TYPE_NET_DATAGRAM);
  Address* address = (Address*) lua_newuserdata(L, sizeof(Address));
  address->address = self->datagram->addr;
  address->hostname[0] = '\0';
  NET_RefAddress(address->address);
  luaL_setmetatable(L, API_TYPE_NET_ADDRESS);
  return 1;
}

static int m_datagram_get_port(lua_State* L) {
  DataGram* self = (DataGram*) luaL_checkudata(L, 1, API_TYPE_NET_DATAGRAM);
  lua_pushinteger(L, self->datagram->port);
  return 1;
}

static int mm_datagram_gc(lua_State* L) {
  DataGram* self = (DataGram*) luaL_checkudata(L, 1, API_TYPE_NET_DATAGRAM);
  NET_DestroyDatagram(self->datagram);
  return 0;
}


static const struct luaL_Reg net_lib[] = {
  { "set_cacert_path",     f_set_cacert_path     },
  { "get_cacert_path",     f_get_cacert_path     },
  { "resolve_address",     f_resolve_address     },
  { "get_local_addresses", f_get_local_addresses },
  { "open_tcp",            f_open_tcp            },
  { "open_udp",            f_open_udp            },
  { "create_server",       f_create_server       },
  { "__gc",                f_gc                  },
  { NULL, NULL}
};

static const struct luaL_Reg net_address_object[] = {
  { "wait_until_resolved", m_address_wait_until_resolved },
  { "get_status",          m_address_get_status          },
  { "get_hostname",        m_address_get_hostname        },
  { "get_ip",              m_address_get_ip              },
  { "__tostring",          mm_address_tostring           },
  { "__gc",                mm_address_gc                 },
  { NULL, NULL}
};

static const struct luaL_Reg net_server_object[] = {
  { "accept",   m_server_accept   },
  { "get_port", m_server_get_port },
  { "__gc",     mm_server_gc      },
  { NULL, NULL}
};

static const struct luaL_Reg net_tcp_object[] = {
  { "read",                 m_tcp_read                 },
  { "write",                m_tcp_write                },
  { "get_status",           m_tcp_get_status           },
  { "get_address",          m_tcp_get_address          },
  { "get_pending_writes",   m_tcp_get_pending_writes   },
  { "wait_until_drained",   m_tcp_wait_until_drained   },
  { "wait_until_connected", m_tcp_wait_until_connected },
  { "close",                m_tcp_close                },
  { "__gc",                 mm_tcp_gc                  },
  { NULL, NULL}
};

static const struct luaL_Reg net_udp_object[] = {
  { "send",             m_udp_send             },
  { "receive",          m_udp_receive          },
  { "close",            m_udp_close            },
  { "__gc",             mm_udp_gc              },
  { NULL, NULL}
};

static const struct luaL_Reg net_datagram_object[] = {
  { "get_data",    m_datagram_get_data    },
  { "get_address", m_datagram_get_address },
  { "get_port",    m_datagram_get_port    },
  { "__gc",        mm_datagram_gc         },
  { NULL, NULL}
};


#ifdef LUA_JITLIBNAME
static void luajit_register_net_gc(lua_State *L) {
  lua_newuserdata(L, 1);
  if (luaL_newmetatable(L, "luajit_net_gc_mt")) {
      lua_pushcfunction(L, f_gc);
      lua_setfield(L, -2, "__gc");
  }
  lua_setmetatable(L, -2);
  lua_setfield(L, LUA_REGISTRYINDEX, "luajit_net_gc");
}
#endif

int luaopen_net(lua_State *L) {
  if(!NET_Init()) {
    luaL_error(L, "Error initializing network subsystem: %s", SDL_GetError());
  }

  luaL_newmetatable(L, API_TYPE_NET_ADDRESS);
  luaL_setfuncs(L, net_address_object, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");

  luaL_newmetatable(L, API_TYPE_NET_SERVER);
  luaL_setfuncs(L, net_server_object, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");

  luaL_newmetatable(L, API_TYPE_NET_TCP);
  luaL_setfuncs(L, net_tcp_object, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");

  luaL_newmetatable(L, API_TYPE_NET_UDP);
  luaL_setfuncs(L, net_udp_object, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");

  luaL_newmetatable(L, API_TYPE_NET_DATAGRAM);
  luaL_setfuncs(L, net_datagram_object, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");

#ifdef LUA_JITLIBNAME
  luajit_register_net_gc(L);
#endif

  luaL_newlib(L, net_lib);

  return 1;
}
