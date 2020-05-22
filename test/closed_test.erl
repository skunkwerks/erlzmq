-module(closed_test).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlzmq.hrl").
-export_type([erlzmq_socket/0, erlzmq_context/0]).                          

terminated_context_test() ->
    {ok, C} = erlzmq:context(),
    ok = erlzmq:term(C),
    ?assertEqual({error, eterm}, erlzmq:socket(C, req)),
    ?assertEqual({error, eterm}, erlzmq:ctx_set(C, max_sockets, 1)),
    ?assertEqual({error, eterm}, erlzmq:term(C)).

closed_socket_test() ->
    {ok, C} = erlzmq:context(),
    {ok, To} = erlzmq:socket(C, pull),
    ok = erlzmq:close(To),
    ?assertEqual({error, enotsock}, erlzmq:send(To, <<>>)),
    ?assertEqual({error, enotsock}, erlzmq:close(To)),
    ok = erlzmq:term(C).
