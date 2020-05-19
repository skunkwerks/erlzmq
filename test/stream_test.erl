-module(stream_test).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlzmq.hrl").
-export_type([erlzmq_socket/0, erlzmq_context/0]).                          

stream_to_stream_test() ->
    {ok, C} = erlzmq:context(),
    Endpoint = "tcp://127.0.0.1:7432",

    % We'll be using this socket in raw mode
    {ok, To} = erlzmq:socket(C, stream),
    ok = erlzmq:setsockopt(To, stream_notify, 1),
    ok = erlzmq:bind(To, Endpoint),

    % We'll be using this socket as the other peer
    {ok, From} = erlzmq:socket(C, stream),
    ok = erlzmq:setsockopt(From, linger, 0),
    ok = erlzmq:connect(From, Endpoint),

    % Connecting sends a zero message
    % First frame is routing id
    {ok, RIdTo0} = erlzmq:recv(To),
    % Second frame is zero
    ?assertEqual({ok, <<>>}, erlzmq:recv(To)),
    {ok, RIdFrom0} = erlzmq:recv(From),
    ?assertEqual({ok, <<>>}, erlzmq:recv(From)),

    % Sent HTTP request on client socket
    ok = erlzmq:send(From, RIdFrom0, [sndmore]),
    ok = erlzmq:send(From, <<"GET /\n\n">>, []),

    ?assertEqual({ok, RIdTo0}, erlzmq:recv(To)),
    ?assertEqual({ok, <<"GET /\n\n">>}, erlzmq:recv(To)),

    % send response
    Resp = <<"HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\nHello, World!">>,
    ok = erlzmq:send(To, RIdTo0, [sndmore]),
    ok = erlzmq:send(To, Resp, [sndmore]),
    % Send zero to close connection to client
    ok = erlzmq:send(To, RIdTo0, [sndmore]),
    ok = erlzmq:send(To, <<>>, []),

    ?assertEqual({ok, RIdFrom0}, erlzmq:recv(From)),
    ?assertEqual({ok, Resp}, erlzmq:recv(From)),

    % Get disconnection notification
    % test_stream.cpp has this test commented out with
    % FIXME: why does this block? Bug in STREAM disconnect notification?
    % ?assertEqual({ok, RIdFrom0}, erlzmq:recv(From)),
    % ?assertEqual({ok, <<>>}, erlzmq:recv(From)),

    ok = erlzmq:close(From),
    ok = erlzmq:close(To),
    ok = erlzmq:term(C).
