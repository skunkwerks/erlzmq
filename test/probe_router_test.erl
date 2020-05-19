-module(probe_router_test).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlzmq.hrl").
-export_type([erlzmq_socket/0, erlzmq_context/0]).                          

probe_router_router_test() ->
    {ok, C} = erlzmq:context(),
    Endpoint = "tcp://127.0.0.1:5558",

    {ok, To} = erlzmq:socket(C, router),
    ok = erlzmq:bind(To, Endpoint),

    {ok, From} = erlzmq:socket(C, router),
    ok = erlzmq:setsockopt(From, routing_id, <<"X">>),
    ok = erlzmq:setsockopt(From, probe_router, 1),
    ok = erlzmq:connect(From, Endpoint),

    % We expect a routing id=X + empty message from client
    ?assertEqual({ok, <<"X">>}, erlzmq:recv(To)),
    ?assertEqual({ok, <<>>}, erlzmq:recv(To)),

    ok = erlzmq:send(To, <<"X">>, [sndmore]),
    ok = erlzmq:send(To, <<"Hello">>),

    % receive the routing ID, which is auto-generated in this case, since the
    % peer did not set one explicitly
    {ok, _RoutingId} = erlzmq:recv(From),
    ?assertMatch({ok, 1}, erlzmq:getsockopt(From, rcvmore)),
    ?assertEqual({ok, <<"Hello">>}, erlzmq:recv(From)),

    ok = erlzmq:close(From),
    ok = erlzmq:close(To),
    ok = erlzmq:term(C).

probe_router_dealer_test() ->
    {ok, C} = erlzmq:context(),
    Endpoint = "tcp://127.0.0.1:5558",

    {ok, To} = erlzmq:socket(C, router),
    ok = erlzmq:bind(To, Endpoint),

    {ok, From} = erlzmq:socket(C, dealer),
    ok = erlzmq:setsockopt(From, routing_id, <<"X">>),
    ok = erlzmq:setsockopt(From, probe_router, 1),
    ok = erlzmq:connect(From, Endpoint),

    % We expect a routing id=X + empty message from client
    ?assertEqual({ok, <<"X">>}, erlzmq:recv(To)),
    ?assertEqual({ok, <<>>}, erlzmq:recv(To)),

    ok = erlzmq:send(To, <<"X">>, [sndmore]),
    ok = erlzmq:send(To, <<"Hello">>),

    ?assertEqual({ok, <<"Hello">>}, erlzmq:recv(From)),

    ok = erlzmq:close(From),
    ok = erlzmq:close(To),
    ok = erlzmq:term(C).
