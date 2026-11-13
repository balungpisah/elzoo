#define _POSIX_C_SOURCE 200809L
#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "lobject.h"

#define MEMORY (16u * 1024 * 1024)
#define VALUE (1024u * 1024)
#define STEPS 1000000
#define DEPTH 200

typedef struct { size_t used; unsigned steps; const char *stop; int block; int continued; } Budget;
static Budget *budget(lua_State *L) { return *(Budget **)lua_getextraspace(L); }
static void *alloc_lua(void *ud, void *p, size_t old, size_t n) {
  Budget *b = ud;
  if (!p) old = 0;
  if (!n) { free(p); b->used -= old; return NULL; }
  if (n > old && n - old > MEMORY - b->used) {
    b->stop = "memory_exceeded"; return NULL;
  }
  void *q = realloc(p, n);
  if (q) b->used = b->used - old + n;
  else if (n > old) b->stop = "memory_exceeded";
  return q;
}
static void *allocator(void *ud, void *p, size_t old, size_t n) {
  Budget *b = ud;
  if (!p && old == LUA_TSTRING && n > VALUE + offsetof(TString,contents) + 1) {
    b->stop = "value_size_exceeded"; return NULL;
  }
  return alloc_lua(ud,p,old,n);
}
static int stopped(lua_State *L) { return luaL_error(L,"host limit"); }
static void hook(lua_State *L, lua_Debug *ar) {
  Budget *b = budget(L);
  if (ar->event == LUA_HOOKCOUNT && ++b->steps >= STEPS) b->stop = "steps_exceeded";
  if (ar->event == LUA_HOOKCALL) {
    lua_Debug frame;
    if (lua_getstack(L,DEPTH,&frame)) b->stop = "depth_exceeded";
  }
  if (b->stop) stopped(L);
}
static int safe_pcall(lua_State *L) {
  luaL_checkany(L,1);
  int status = lua_pcall(L,lua_gettop(L)-1,LUA_MULTRET,0);
  if (budget(L)->stop) return stopped(L);
  lua_pushboolean(L,status == LUA_OK); lua_insert(L,1);
  return lua_gettop(L);
}
static int unlisted(lua_State *L) {
  lua_pushfstring(L,"unlisted name: %s",lua_tostring(L,2));return lua_error(L);
}
static int echo(lua_State *L) {
  const char *s=lua_type(L,1)==LUA_TSTRING?lua_tostring(L,1):NULL;
  if (s && !strcmp(s,"continued")) budget(L)->continued=1;
  if (budget(L)->block) { struct timespec t={10,0}; nanosleep(&t,NULL); }
  lua_settop(L,1); return 1;
}
static void copy_names(lua_State *L,int from,int to,const char *names) {
  char copy[512]; snprintf(copy,sizeof(copy),"%s",names);
  for (char *s=strtok(copy," ");s;s=strtok(NULL," ")) {
    lua_getfield(L,from,s); lua_setfield(L,to,s);
  }
}
static void library(lua_State *L,int env,const char *name,const char *names) {
  lua_getglobal(L,name); int from=lua_gettop(L);
  lua_newtable(L); int to=lua_gettop(L);
  copy_names(L,from,to,names);
  if (!strcmp(name,"string")) {
    lua_pushliteral(L,""); lua_newtable(L);
    lua_pushvalue(L,to); lua_setfield(L,-2,"__index");
    lua_setmetatable(L,-2);lua_pop(L,1);
  }
  lua_setfield(L,env,name); lua_pop(L,1);
}
static void environment(lua_State *L,const char *mode) {
  lua_newtable(L); int env=lua_gettop(L);
  lua_pushglobaltable(L); int globals=lua_gettop(L);
  copy_names(L,globals,env,"pairs ipairs next select type tostring tonumber error assert");
  lua_pop(L,1);
  library(L,env,"string","byte char find format gmatch gsub len lower match pack packsize rep reverse sub unpack upper");
  library(L,env,"table","concat insert move pack remove sort unpack");
  library(L,env,"math","abs acos asin atan ceil cos deg exp floor fmod huge log max maxinteger min mininteger modf pi rad sin sqrt tan tointeger type ult");
  lua_pushcfunction(L,echo); lua_setfield(L,env,"helper_echo");
  if (strcmp(mode,"no_pcall")) { lua_pushcfunction(L,safe_pcall); lua_setfield(L,env,"pcall"); }
  if (!strcmp(mode,"coroutine")) { lua_getglobal(L,"coroutine"); lua_setfield(L,env,"coroutine"); }
  if (strcmp(mode,"nil")) {
    lua_newtable(L); lua_pushcfunction(L,unlisted); lua_setfield(L,-2,"__index"); lua_setmetatable(L,env);
  }
}

typedef struct { char data[VALUE+1]; size_t n; const char *error; } Buffer;
static void add(Buffer *b,const char *s,size_t n) {
  if (b->error) return;
  if (n > VALUE-b->n) { b->error="value_size_exceeded"; return; }
  memcpy(b->data+b->n,s,n); b->n+=n; b->data[b->n]=0;
}
static void str(Buffer *b,const char *s,size_t n) {
  add(b,"\"",1);
  for (size_t i=0;i<n;i++) {
    unsigned char c=(unsigned char)s[i]; char escaped[7];
    if (c=='"' || c=='\\') { escaped[0]='\\';escaped[1]=(char)c; add(b,escaped,2); }
    else if (c<32 || c>=127) { snprintf(escaped,sizeof(escaped),"\\u%04x",c);add(b,escaped,6); }
    else add(b,(const char *)&s[i],1);
  }
  add(b,"\"",1);
}
static int cmp(const void *a,const void *b) { return strcmp(*(char *const *)a,*(char *const *)b); }
static void plain(lua_State *L,int idx,Buffer *b,int depth) {
  idx=lua_absindex(L,idx);
  if (depth>DEPTH) { b->error="depth_exceeded"; return; }
  if (!lua_checkstack(L,4)) { b->error="depth_exceeded";return; }
  switch (lua_type(L,idx)) {
    case LUA_TNIL: add(b,"null",4); break;
    case LUA_TBOOLEAN: { const char *s=lua_toboolean(L,idx)?"true":"false";add(b,s,strlen(s)); break; }
    case LUA_TNUMBER: {
      char s[64];
      if (lua_isinteger(L,idx)) snprintf(s,sizeof(s),"%lld",(long long)lua_tointeger(L,idx));
      else if (isfinite(lua_tonumber(L,idx))) snprintf(s,sizeof(s),"%.17g",lua_tonumber(L,idx));
      else { b->error="nonfinite result"; return; }
      add(b,s,strlen(s)); break;
    }
    case LUA_TSTRING: { size_t n; const char *s=lua_tolstring(L,idx,&n);str(b,s,n);break; }
    case LUA_TTABLE: {
      /* A canonical list of key/value pairs preserves mixed Lua key types. */
      char **entries=NULL; size_t count=0,total=0;
      lua_pushnil(L);
      while (lua_next(L,idx)) {
        Buffer *entry=malloc(sizeof(Buffer));
        if (!entry) { b->error="host serialization allocation"; lua_pop(L,2); break; }
        entry->n=0;entry->error=NULL;entry->data[0]=0;
        add(entry,"[",1); plain(L,-2,entry,depth+1);add(entry,",",1);
        plain(L,-1,entry,depth+1);add(entry,"]",1);
        if (entry->error || total+entry->n>VALUE) {
          b->error=entry->error?entry->error:"value_size_exceeded";free(entry);lua_pop(L,2);break;
        }
        total+=entry->n;
        char **next=realloc(entries,(count+1)*sizeof(char *));
        if (!next) { b->error="host serialization allocation";free(entry);lua_pop(L,2);break; }
        entries=next; entries[count]=strdup(entry->data);free(entry);
        if (!entries[count]) { b->error="host serialization allocation";lua_pop(L,2);break; }
        count++;
        lua_pop(L,1);
      }
      qsort(entries,count,sizeof(char *),cmp);add(b,"[",1);
      for (size_t i=0;i<count;i++) { if (i) add(b,",",1);if(entries[i]) add(b,entries[i],strlen(entries[i]));free(entries[i]); }
      free(entries);add(b,"]",1);break;
    }
    default: b->error="non_plain_value";
  }
}
static void audit(lua_State *L,int env) {
  lua_newtable(L); int result=lua_gettop(L);
  lua_pushvalue(L,env); lua_setfield(L,result,"environment");
  lua_getmetatable(L,env);lua_setfield(L,result,"environment_metatable");
  lua_pushliteral(L,"");lua_getmetatable(L,-1);
  lua_setfield(L,result,"string_metatable");lua_pop(L,1);
  /* Encode names and types rather than export the callable objects. */
}
static void names(lua_State *L,int idx,Buffer *b,int depth) {
  idx=lua_absindex(L,idx);
  if (depth>4) { add(b,"\"depth\"",7);return; }
  add(b,"{",1);int first=1;lua_pushnil(L);
  while(lua_next(L,idx)) {
    if(!first)add(b,",",1);
    first=0;
    size_t n;const char *key=lua_tolstring(L,-2,&n);str(b,key,n);add(b,":",1);
    if(lua_istable(L,-1)) names(L,-1,b,depth+1);
    else {const char *t=luaL_typename(L,-1);str(b,t,strlen(t));}
    lua_pop(L,1);
  }
  add(b,"}",1);
}
static int run(lua_State *L) {
  const char *mode=lua_tostring(L,1);size_t n;const char *source=lua_tolstring(L,2,&n);
  luaL_openlibs(L);environment(L,mode);int env=lua_gettop(L);
  if (!strcmp(mode,"audit")) { audit(L,env);return 1; }
  int status=luaL_loadbufferx(L,source,n,"=probe","t");
  if (status!=LUA_OK) return lua_error(L);
  lua_pushvalue(L,env);lua_setupvalue(L,-2,1);
  if (strcmp(mode,"block")) lua_sethook(L,hook,LUA_MASKCOUNT|LUA_MASKCALL,1);
  lua_call(L,0,1);return 1;
}
int main(int argc,char **argv) {
  const char *mode=argc>1?argv[1]:"policy";
  puts("{\"ready\":true}");fflush(stdout);
  uint32_t size;
  while(fread(&size,4,1,stdin)==1) {
    size=((size&255)<<24)|((size&65280)<<8)|((size>>8)&65280)|(size>>24);
    if(size>VALUE) return 2;
    char *source=malloc(size+1);if(!source)return 2;
    if(fread(source,1,size,stdin)!=size){free(source);return 2;}source[size]=0;
    Budget b={0};b.block=!strcmp(mode,"block");
    lua_State *L=lua_newstate(allocator,&b);if(!L){free(source);return 2;}
    *(Budget **)lua_getextraspace(L)=&b;
    lua_pushcfunction(L,run);lua_pushstring(L,mode);lua_pushlstring(L,source,size);free(source);
    int status=lua_pcall(L,2,1,0);lua_sethook(L,NULL,0,0);
    Buffer *out=calloc(1,sizeof(Buffer));if(!out)return 2;
    const char *outcome="ok";
    if(b.stop) {outcome=b.stop;str(out,b.stop,strlen(b.stop));}
    else if(status!=LUA_OK) {
      const char *message=lua_tostring(L,-1);if(!message)message="runtime error";
      const char *un=strstr(message,"unlisted name: ");
      outcome=un?"unlisted_name":"error";
      /* Only fixed chunk labels and explicitly unlisted names cross the boundary. */
      str(out,un?un:"runtime error",strlen(un?un:"runtime error"));
    } else if(!strcmp(mode,"audit")) names(L,-1,out,0);
    else plain(L,-1,out,0);
    if(out->error) {outcome=!strcmp(out->error,"value_size_exceeded")||!strcmp(out->error,"depth_exceeded")?out->error:"error";const char *e=out->error;memset(out,0,sizeof(*out));str(out,e,strlen(e));}
    printf("{\"outcome\":\"%s\",\"detail\":%s,\"steps\":%u,\"continued\":%s}\n",outcome,out->data,b.steps,b.continued?"true":"false");fflush(stdout);
    free(out);lua_close(L);
  }
  return 0;
}
