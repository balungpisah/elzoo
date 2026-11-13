-module(luerl_fit_host).
-include("luerl.hrl").
-export([replace_environment/3, global/1, metatables/1, pairs/2, type/1]).

replace_environment(G, StringMeta, St) ->
    St#luerl{g=G,meta=#meta{string=StringMeta}}.
global(St) -> St#luerl.g.
metatables(#luerl{meta=M}) ->
    [{<<"nil">>, M#meta.nil}, {<<"boolean">>, M#meta.boolean},
     {<<"number">>, M#meta.number}, {<<"string">>, M#meta.string}].
pairs(T, St) ->
    #table{a=A,d=D} = luerl_heap:get_table(T, St),
    array:sparse_foldl(fun(K,V,Acc) -> [{K,V}|Acc] end,
                      ttdict:to_list(D), A).
type(V) -> luerl_lib_basic:type(V).
