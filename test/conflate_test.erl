-module(conflate_test).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlzmq.hrl").
-export_type([erlzmq_socket/0, erlzmq_context/0]).                          

conflate_test() ->
    {ok, C} = erlzmq:context(),
    Endpoint = "tcp://127.0.0.1:5558",

    {ok, To} = erlzmq:socket(C, [pull, {active, false}]),
    ok = erlzmq:setsockopt(To, conflate, 1),
    ok = erlzmq:bind(To, Endpoint),

    {ok, From} = erlzmq:socket(C, [push, {active, false}]),
    ok = erlzmq:connect(From, Endpoint),

    send(From, 20),

    timer:sleep(100),

    % only last message should be received
    ?assertEqual({ok, <<1>>}, erlzmq:recv(To)),

    ok = erlzmq:close(From),
    ok = erlzmq:close(To),
    ok = erlzmq:term(C).

conflate_active_test() ->
    {ok, C} = erlzmq:context(),
    Endpoint = "tcp://127.0.0.1:5558",

    {ok, To} = erlzmq:socket(C, [pull, {active, true}]),
    ok = erlzmq:setsockopt(To, conflate, 1),
    ok = erlzmq:bind(To, Endpoint),

    {ok, From} = erlzmq:socket(C, [push, {active, false}]),
    ok = erlzmq:connect(From, Endpoint),

    send(From, 20),

    timer:sleep(100),

    % only last message should be received
    receive
        {zmq, To, <<1>>, []} -> ok
    end,
    receive
        {zmq, To, _, _} -> ?assert(false)
    after
        500 -> ok
    end,

    ok = erlzmq:close(From),
    ok = erlzmq:close(To),
    ok = erlzmq:term(C).

send(_, 0) ->
    ok;
send(From, N) ->
    ok = erlzmq:send(From, <<N>>),
    send(From, N - 1).
