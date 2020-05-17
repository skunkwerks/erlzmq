-module(linger_test).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlzmq.hrl").
-export_type([erlzmq_socket/0, erlzmq_context/0]).                          

no_linger_test() ->
    {ok, C} = erlzmq:context(),
    Endpoint = "tcp://127.0.0.1:5558",

    {ok, From} = erlzmq:socket(C, [push, {active, false}]),
    ok = erlzmq:setsockopt(From, linger, 0),
    ok = erlzmq:connect(From, Endpoint),

    ok = erlzmq:send(From, <<>>),
    ok = erlzmq:close(From),
    timer:sleep(100),

    {ok, To} = erlzmq:socket(C, [pull, {active, false}]),
    ok = erlzmq:bind(To, Endpoint),

    ok = erlzmq:setsockopt(To, rcvtimeo, 200),
    ?assertEqual({error, eagain}, erlzmq:recv(To, [])),
    ok = erlzmq:close(To),

    ok = erlzmq:term(C).

linger_infinite_test() ->
    {ok, C} = erlzmq:context(),
    Endpoint = "tcp://127.0.0.1:5558",

    {ok, From} = erlzmq:socket(C, [push, {active, false}]),
    ok = erlzmq:setsockopt(From, linger, -1),
    ok = erlzmq:connect(From, Endpoint),

    ok = erlzmq:send(From, <<>>),
    ok = erlzmq:close(From),    
    timer:sleep(100),

    {ok, To} = erlzmq:socket(C, [pull, {active, false}]),
    ok = erlzmq:bind(To, Endpoint),

    ?assertEqual({ok, <<>>}, erlzmq:recv(To, [])),
    ok = erlzmq:close(To),

    ok = erlzmq:term(C).

linger_finite_receive_before_test() ->
    {ok, C} = erlzmq:context(),
    Endpoint = "tcp://127.0.0.1:5558",

    {ok, From} = erlzmq:socket(C, [push, {active, false}]),
    ok = erlzmq:setsockopt(From, linger, 200),
    ok = erlzmq:connect(From, Endpoint),

    ok = erlzmq:send(From, <<>>),
    ok = erlzmq:close(From),
    timer:sleep(100),

    {ok, To} = erlzmq:socket(C, [pull, {active, false}]),
    ok = erlzmq:bind(To, Endpoint),

    ?assertEqual({ok, <<>>}, erlzmq:recv(To, [])),
    ok = erlzmq:close(To),

    ok = erlzmq:term(C).

linger_finite_receive_after_test() ->
    {ok, C} = erlzmq:context(),
    Endpoint = "tcp://127.0.0.1:5558",

    {ok, From} = erlzmq:socket(C, [push, {active, false}]),
    ok = erlzmq:setsockopt(From, linger, 200),
    ok = erlzmq:connect(From, Endpoint),

    ok = erlzmq:send(From, <<>>),
    ok = erlzmq:close(From),
    timer:sleep(300),

    {ok, To} = erlzmq:socket(C, [pull, {active, false}]),
    ok = erlzmq:bind(To, Endpoint),

    ok = erlzmq:setsockopt(To, rcvtimeo, 200),
    ?assertEqual({error, eagain}, erlzmq:recv(To, [])),
    ok = erlzmq:close(To),

    ok = erlzmq:term(C).

linger_blocks_term_test() ->
    {ok, C1} = erlzmq:context(),
    {ok, C2} = erlzmq:context(),
    Endpoint = "tcp://127.0.0.1:5558",

    {ok, From} = erlzmq:socket(C1, [push, {active, false}]),
    ok = erlzmq:setsockopt(From, linger, -1),
    ok = erlzmq:connect(From, Endpoint),

    ok = erlzmq:send(From, <<>>),
    ok = erlzmq:close(From),    
    timer:sleep(100),
    Self = self(),
    spawn_link(fun () ->
        ok = erlzmq:term(C1),
        Self ! terminated
    end),

    timer:sleep(300),

    receive
        terminated -> ?assert(false)
    after
        100 -> ok
    end,

    {ok, To} = erlzmq:socket(C2, [pull, {active, false}]),
    ok = erlzmq:bind(To, Endpoint),

    ?assertEqual({ok, <<>>}, erlzmq:recv(To, [])),

    receive
        terminated -> ok
    end,

    ok = erlzmq:close(To),
    ok = erlzmq:term(C2).
