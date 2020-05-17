-module(hwm_test).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlzmq.hrl").
-export_type([erlzmq_socket/0, erlzmq_context/0]).                          

-define('MAX_SENDS', 1234).

hwm_test() ->
    % infinite
    ?assertEqual(count_msg(0, 0), ?MAX_SENDS),
    ?assertEqual(count_msg(1, 0), ?MAX_SENDS),
    ?assertEqual(count_msg(0, 1), ?MAX_SENDS),
    % finite
    ?assertEqual(count_msg(2, 1), 3),
    ?assertEqual(count_msg(1, 4), 5),
    % Send hwm of 1, send before bind so total that can be queued is 1
    ?assertEqual(count_msg_connect_close(1, 0), 1).

hwm_active_test() ->
    % infinite
    ?assertEqual(count_msg_active(0, 0), ?MAX_SENDS),
    ?assertEqual(count_msg_active(1, 0), ?MAX_SENDS),
    ?assertEqual(count_msg_active(0, 1), ?MAX_SENDS),
    % finite
    ?assertEqual(count_msg_active(2, 1), 3),
    ?assertEqual(count_msg_active(1, 4), 5).

send_dontwait(_, 0, C) ->
    C;
send_dontwait(From, N, C) ->
    case erlzmq:send(From, <<N>>, [dontwait]) of
        ok -> send_dontwait(From, N - 1, C + 1);
        _ -> C
    end.

recv_dontwait(To, N) ->
    case erlzmq:recv(To, [dontwait]) of
        {ok, _} ->
            recv_dontwait(To, N + 1);
        {error, eagain} ->
            N
    end.

recv_dontwait_active(To, N) ->
    receive
        {zmq, To, _, _} -> recv_dontwait_active(To, N + 1)
    after
        250 -> N
    end.

count_msg(SendHwm, RecvHwm) ->
    {ok, C} = erlzmq:context(),
    Endpoint = "inproc://a",

    {ok, To} = erlzmq:socket(C, [pull, {active, false}]),
    ok = erlzmq:setsockopt(To, rcvhwm, RecvHwm),
    ok = erlzmq:bind(To, Endpoint),

    {ok, From} = erlzmq:socket(C, [push, {active, false}]),
    ok = erlzmq:setsockopt(From, sndhwm, SendHwm),
    ok = erlzmq:connect(From, Endpoint),

    Sent = send_dontwait(From, ?MAX_SENDS, 0),

    timer:sleep(100),

    Received = recv_dontwait(To, 0),

    % only last message should be received
    ?assertEqual(Sent, Received),

    ok = erlzmq:close(From),
    ok = erlzmq:close(To),
    ok = erlzmq:term(C),
    Sent.

count_msg_active(SendHwm, RecvHwm) ->
    {ok, C} = erlzmq:context(),
    Endpoint = "inproc://a",

    {ok, To} = erlzmq:socket(C, [dealer, {active, true}]),
    ok = erlzmq:setsockopt(To, rcvhwm, RecvHwm),
    ok = erlzmq:bind(To, Endpoint),

    {ok, From} = erlzmq:socket(C, [dealer, {active, false}]),
    ok = erlzmq:setsockopt(From, sndhwm, SendHwm),
    ok = erlzmq:connect(From, Endpoint),

    Sent = send_dontwait(From, ?MAX_SENDS, 0),

    timer:sleep(100),

    Received = recv_dontwait_active(To, 0),

    % only last message should be received
    ?assertEqual(Sent, Received),

    ok = erlzmq:close(From),
    ok = erlzmq:close(To),
    ok = erlzmq:term(C),
    Sent.

count_msg_connect_close(SendHwm, RecvHwm) ->
    {ok, C} = erlzmq:context(),
    Endpoint = "inproc://a",

    {ok, From} = erlzmq:socket(C, [push, {active, false}]),
    ok = erlzmq:setsockopt(From, sndhwm, SendHwm),
    ok = erlzmq:connect(From, Endpoint),

    Sent = send_dontwait(From, ?MAX_SENDS, 0),
    ok = erlzmq:close(From),

    timer:sleep(100),

    {ok, To} = erlzmq:socket(C, [pull, {active, false}]),
    ok = erlzmq:setsockopt(To, rcvhwm, RecvHwm),
    ok = erlzmq:bind(To, Endpoint),

    Received = recv_dontwait(To, 0),

    % only last message should be received
    ?assertEqual(Sent, Received),
    
    ok = erlzmq:close(To),
    ok = erlzmq:term(C),
    Sent.
