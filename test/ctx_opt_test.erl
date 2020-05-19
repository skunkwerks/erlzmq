-module(ctx_opt_test).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlzmq.hrl").
-export_type([erlzmq_socket/0, erlzmq_context/0]).

ctx_opt_test() ->
    {ok, C} = erlzmq:context(),

    {ok, OrigIT} = erlzmq:ctx_get(C, io_threads),
    ?assertMatch(ok, erlzmq:ctx_set(C, io_threads, OrigIT * 2)),
    {ok, NewIT} = erlzmq:ctx_get(C, io_threads),
    ?assertMatch(NewIT, OrigIT * 2),
    ok = erlzmq:ctx_set(C, io_threads, OrigIT),

    {ok, 0} = erlzmq:ctx_get(C, ipv6),
    ?assertMatch(ok, erlzmq:ctx_set(C, ipv6, 1)),
    {ok, NewV6} = erlzmq:ctx_get(C, ipv6),
    ?assertMatch(NewV6, 1),
    ok = erlzmq:ctx_set(C, ipv6, 0),
    ok = erlzmq:term(C).
