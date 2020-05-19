-module(conflate_test).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlzmq.hrl").
-export_type([erlzmq_socket/0, erlzmq_context/0]).                          

conflate_test() ->
    {ok, C} = erlzmq:context(),
    Endpoint = "tcp://127.0.0.1:5558",

    {ok, To} = erlzmq:socket(C, pull),
    ok = erlzmq:setsockopt(To, conflate, 1),
    ok = erlzmq:bind(To, Endpoint),

    {ok, From} = erlzmq:socket(C, push),
    ok = erlzmq:connect(From, Endpoint),

    send(From, 20),

    timer:sleep(100),

    % only last message should be received
    ?assertEqual({ok, <<1>>}, erlzmq:recv(To)),

    ok = erlzmq:close(From),
    ok = erlzmq:close(To),
    ok = erlzmq:term(C).

send(_, 0) ->
    ok;
send(From, N) ->
    ok = erlzmq:send(From, <<N>>),
    send(From, N - 1).
