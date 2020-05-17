-module(timeo_test).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlzmq.hrl").
-export_type([erlzmq_socket/0, erlzmq_context/0]).                          

timeo() ->
    {ok, Ctx} = erlzmq:context(),
    %%  Create a disconnected socket.
    {ok, Sb} = erlzmq:socket(Ctx, [dealer, {active, false}]),
    ok = erlzmq:bind(Sb, "inproc://timeout_test"),
    %%  Check whether non-blocking recv returns immediately.
    {error, eagain} = erlzmq:recv(Sb, [dontwait]),
    %%  Check whether recv timeout is honoured.
    Timeout0 = 500,
    ok = erlzmq:setsockopt(Sb, rcvtimeo, Timeout0),
    {Elapsed0, _} =
        timer:tc(fun() ->
                         ?assertMatch({error, eagain}, erlzmq:recv(Sb))
                 end),
    ?assert(Elapsed0 > 440000 andalso Elapsed0 < 550000),

    %%  Check whether connection during the wait doesn't distort the timeout.
    Timeout1 = 2000,
    ok = erlzmq:setsockopt(Sb, rcvtimeo, Timeout1),
    proc_lib:spawn(fun() ->
                           timer:sleep(1000),
                           {ok, Sc} = erlzmq:socket(Ctx, [dealer, {active, false}]),
                           ok = erlzmq:connect(Sc, "inproc://timeout_test"),
                           timer:sleep(1000),
                           % can't match here as close may return eterm on terminated context
                           erlzmq:close(Sc)
                   end),
    {Elapsed1, _} = timer:tc(fun() ->
                                     ?assertMatch({error, eagain}, erlzmq:recv(Sb))
                             end),
    ?assert(Elapsed1 > 1900000 andalso Elapsed1 < 2100000),

    %%  Check that timeouts don't break normal message transfer.
    {ok, Sc} = erlzmq:socket(Ctx, [dealer, {active, false}]),
    ok = erlzmq:setsockopt(Sb, rcvtimeo, Timeout1),
    ok = erlzmq:setsockopt(Sb, sndtimeo, Timeout1),
    ok = erlzmq:connect(Sc, "inproc://timeout_test"),

    Buff = <<"12345678ABCDEFGH12345678abcdefgh">>,
    ok = erlzmq:send(Sc, Buff),
    case erlzmq:recv(Sb) of
        {ok, Buff} ->
            ok;
        {error, eagain} ->
            timeout
    end,
    %%  Clean-up.
    ok = erlzmq:close(Sc),
    ok = erlzmq:close(Sb),
    ok = erlzmq:term (Ctx),
    ok.

timeo_test_() ->
    % sometimes this test can timeout with the default timeout
    {timeout, 10, [
        ?_assert(timeo() =:= ok)
    ]}.

timeo_active_test_() ->
    % sometimes this test can timeout with the default timeout
    {timeout, 10, [
        ?_assert(timeo_active() =:= ok)
    ]}.

timeo_active() ->
    {ok, Ctx} = erlzmq:context(),
    %%  Create a disconnected socket.
    {ok, Sb} = erlzmq:socket(Ctx, [dealer, {active, true}]),
    Timeout0 = 300,
    ok = erlzmq:setsockopt(Sb, rcvtimeo, Timeout0),
    ok = erlzmq:setsockopt(Sb, sndtimeo, Timeout0),
    ok = erlzmq:bind(Sb, "inproc://timeout_test"),
    % no timeout
    receive
        a -> ?assert(false)
    after
        2 * Timeout0 -> ok
    end,

    % send timeout
    {Elapsed0, _} =
        timer:tc(fun() ->
                         ?assertMatch({error, eagain}, erlzmq:send(Sb, <<"A">>))
                 end),
    ?assert(Elapsed0 > 300000 andalso Elapsed0 < 320000),

    % timed out send is not received
    {ok, Sc} = erlzmq:socket(Ctx, [dealer, {active, true}]),
    ok = erlzmq:connect(Sc, "inproc://timeout_test"),
    receive
        a -> ?assert(false)
    after
        2 * Timeout0 -> ok
    end,

    %%  Check that timeouts don't break normal message transfer.

    Buff = <<"12345678ABCDEFGH12345678abcdefgh">>,
    ok = erlzmq:send(Sb, Buff),
    ok = erlzmq:send(Sc, Buff),
    receive
        {zmq, Sc, Buff, []} -> ok
    after
        2 * Timeout0 -> ?assert(false)
    end,
    receive
        {zmq, Sb, Buff, []} -> ok
    after
        2 * Timeout0 -> ?assert(false)
    end,

    %%  Clean-up.
    ok = erlzmq:close(Sc),
    ok = erlzmq:close(Sb),
    ok = erlzmq:term (Ctx),
    ok.
