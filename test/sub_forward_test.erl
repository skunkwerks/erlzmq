-module(sub_forward_test).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlzmq.hrl").
-export_type([erlzmq_socket/0, erlzmq_context/0]).                          

sub_forward_test() ->
    {ok, C} = erlzmq:context(),
    Endpoint1 = "tcp://127.0.0.1:5558",
    Endpoint2 = "tcp://127.0.0.1:5559",

    {ok, Xpub} = erlzmq:socket(C, xpub),
    ok = erlzmq:bind(Xpub, Endpoint1),

    {ok, Xsub} = erlzmq:socket(C, xsub),
    ok = erlzmq:bind(Xsub, Endpoint2),

    {ok, Pub} = erlzmq:socket(C, pub),
    ok = erlzmq:connect(Pub, Endpoint2),

    {ok, Sub} = erlzmq:socket(C, sub),
    ok = erlzmq:connect(Sub, Endpoint1),

    % Subscribe for all messages.
    ok = erlzmq:setsockopt(Sub, subscribe, ""),

    % Pass the subscription upstream through the device

    {ok, Subscription} = erlzmq:recv(Xpub),
    ok = erlzmq:send(Xsub, Subscription),

    timer:sleep(100),

    % Send an empty message
    ok = erlzmq:send(Pub, <<"">>),

    % Pass the message downstream through the device
    {ok, Message} = erlzmq:recv(Xsub),
    ok = erlzmq:send(Xpub, Message),

    % Receive the message in the subscriber
    ?assertEqual({ok, <<"">>}, erlzmq:recv(Sub)),

    ok = erlzmq:close(Pub),
    ok = erlzmq:close(Sub),
    ok = erlzmq:close(Xpub),
    ok = erlzmq:close(Xsub),
    ok = erlzmq:term(C).
