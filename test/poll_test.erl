-module(poll_test).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlzmq.hrl").
-export_type([erlzmq_socket/0, erlzmq_context/0]).                          

poll_test() ->
    {ok, C} = erlzmq:context(),
    Endpoint = "tcp://127.0.0.1:5558",

    {ok, From} = erlzmq:socket(C, push),
    ?assertEqual({ok, []}, erlzmq:poll(From, [pollout], 0)),

    {ok, To} = erlzmq:socket(C, pull),
    ?assertEqual({ok, []}, erlzmq:poll(To, [pollin], 0)),

    ok = erlzmq:connect(From, Endpoint),
    ok = erlzmq:bind(To, Endpoint),

    ?assertEqual({ok, [pollout]}, erlzmq:poll(From, [pollout], 0)),
    ok = erlzmq:send(From, <<>>, [dontwait]),

    ?assertEqual({ok, [pollin]}, erlzmq:poll(To, [pollin], -1)),
    {ok, <<>>} = erlzmq:recv(To, [dontwait]),
    
    ok = erlzmq:close(To),
    ok = erlzmq:close(From),

    ok = erlzmq:term(C).
