-module(immediate_test).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlzmq.hrl").
-export_type([erlzmq_socket/0, erlzmq_context/0]).                          

% First we're going to attempt to send messages to two
% pipes, one connected, the other not. We should see
% the PUSH load balancing to both pipes, and hence half
% of the messages getting queued, as connect() creates a
% pipe immediately.
immediate_1_test() ->
    {ok, C} = erlzmq:context(),
    Endpoint = "tcp://127.0.0.1:5558",

    {ok, To} = erlzmq:socket(C, pull),
    ok = erlzmq:setsockopt(To, linger, 0),
    ok = erlzmq:bind(To, Endpoint),

    {ok, From} = erlzmq:socket(C, push),
    ok = erlzmq:setsockopt(From, linger, 0),

    % This pipe will not connect (provided the ephemeral port is not 5556)
    ok = erlzmq:connect(From, "tcp://127.0.0.1:5556"),
    % This pipe will
    ok = erlzmq:connect(From, Endpoint),

    timer:sleep(100),

    % We send 10 messages, 5 should just get stuck in the queue
    % for the not-yet-connected pipe

    send(From, 10),

    % We now consume from the connected pipe
    % - we should see just 5

    erlzmq:setsockopt(To, rcvtimeo, 250),

    ?assertEqual(5, recv(To, 0)),

    ok = erlzmq:close(From),
    ok = erlzmq:close(To),
    ok = erlzmq:term(C).


% This time we will do the same thing, connect two pipes,
% one of which will succeed in connecting to a bound
% receiver, the other of which will fail. However, we will
% also set the delay attach on connect flag, which should
% cause the pipe attachment to be delayed until the connection
% succeeds.
immediate_2_test() ->
    {ok, C} = erlzmq:context(),
    Endpoint = "tcp://127.0.0.1:7558",

    {ok, To} = erlzmq:socket(C, pull),
    ok = erlzmq:setsockopt(To, linger, 0),
    ok = erlzmq:bind(To, Endpoint),

    {ok, From} = erlzmq:socket(C, push),
    ok = erlzmq:setsockopt(From, linger, 0),
    % Set the key flag
    ok = erlzmq:setsockopt(From, immediate, 1),

    % This pipe will not connect (provided the ephemeral port is not 5556)
    ok = erlzmq:connect(From, "tcp://127.0.0.1:5556"),
    % This pipe will
    ok = erlzmq:connect(From, Endpoint),

    timer:sleep(100),

    % Send 10 messages, all should be routed to the connected pipe

    send(From, 10),

    % We now consume from the connected pipe

    erlzmq:setsockopt(To, rcvtimeo, 250),

    ?assertEqual(10, recv(To, 0)),

    ok = erlzmq:close(From),
    ok = erlzmq:close(To),
    ok = erlzmq:term(C).

immediate_3_test() ->
    {ok, C} = erlzmq:context(),
    Endpoint = "tcp://127.0.0.1:9558",

    {ok, To} = erlzmq:socket(C, dealer),
    ok = erlzmq:setsockopt(To, linger, 0),
    ok = erlzmq:bind(To, Endpoint),

    {ok, From} = erlzmq:socket(C, dealer),
    ok = erlzmq:setsockopt(From, linger, 0),
    % Set the key flag
    ok = erlzmq:setsockopt(From, immediate, 1),

    % Frontend connects to backend using IMMEDIATE
    ok = erlzmq:connect(From, Endpoint),

    % Ping backend to frontend so we know when the connection is up
    ok = erlzmq:send(To, <<"Hello">>),
    {ok, <<"Hello">>} = erlzmq:recv(From),

    % Send message from frontend to backend
    ok = erlzmq:send(From, <<"Hello">>, [dontwait]),

    ok = erlzmq:close(To),

    timer:sleep(100),

    % Send a message, should fail
    ?assertMatch({error, eagain}, erlzmq:send(From, <<"Hello">>, [dontwait])),

    % Recreate backend socket

    {ok, To1} = erlzmq:socket(C, dealer),
    ok = erlzmq:setsockopt(To1, linger, 0),
    ok = erlzmq:bind(To1, Endpoint),

    % Ping backend to frontend so we know when the connection is up
    ok = erlzmq:send(To1, <<"Hello">>),
    {ok, <<"Hello">>} = erlzmq:recv(From),

    % After the reconnect, should succeed
    ?assertMatch(ok, erlzmq:send(From, <<"Hello">>, [dontwait])),

    ok = erlzmq:close(From),
    ok = erlzmq:close(To1),
    ok = erlzmq:term(C).

send(_, 0) ->
    ok;
send(From, N) ->
    ok = erlzmq:send(From, <<"Hello">>),
    send(From, N - 1).

recv(To, N) ->
    case erlzmq:recv(To) of
        {ok, <<"Hello">>} ->
            recv(To, N + 1);
        {error, eagain} ->
            N
    end.
