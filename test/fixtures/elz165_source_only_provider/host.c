/* SPDX-License-Identifier: Apache-2.0 */
#include <stdio.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

int main(int argc, char **argv) {
  if (argc != 2) return 1;
  lua_State *state = luaL_newstate();
  if (state == NULL) return 1;
  luaL_openlibs(state);
  if (luaL_loadstring(state, argv[1]) != LUA_OK) {
    puts("load_error");
  } else if (lua_pcall(state, 0, LUA_MULTRET, 0) != LUA_OK) {
    puts("call_error");
  } else if (lua_gettop(state) == 1 && lua_isinteger(state, -1)) {
    printf("integer %lld\n", (long long)lua_tointeger(state, -1));
  } else {
    printf("results %d\n", lua_gettop(state));
  }
  lua_close(state);
  return 0;
}
