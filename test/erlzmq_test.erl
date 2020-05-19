-module(erlzmq_test).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlzmq.hrl").
-export_type([erlzmq_socket/0, erlzmq_context/0]).                              


invalid_rep_test() ->
    {ok, Ctx} = erlzmq:context(),

    {ok, XrepSocket} = erlzmq:socket(Ctx, xrep),
    {ok, ReqSocket} = erlzmq:socket(Ctx, req),

    ok = erlzmq:setsockopt(XrepSocket, linger, 0),
    ok = erlzmq:setsockopt(ReqSocket, linger, 0),
    ok = erlzmq:bind(XrepSocket, "inproc://hi"),
    ok = erlzmq:connect(ReqSocket, "inproc://hi"),

    %%  Initial request.
    ok = erlzmq:send(ReqSocket, <<"r">>),

    %%  Receive the request.
    {ok, Addr} = erlzmq:recv(XrepSocket),
    {ok, Bottom} = erlzmq:recv(XrepSocket),
    {ok, _Body} = erlzmq:recv(XrepSocket),

    %%  Send invalid reply.
    ok = erlzmq:send(XrepSocket, Addr),

    %%  Send valid reply.
    ok = erlzmq:send(XrepSocket, Addr, [sndmore]),
    ok = erlzmq:send(XrepSocket, Bottom, [sndmore]),
    ok = erlzmq:send(XrepSocket, <<"b">>),

    %%  Check whether we've got the valid reply.
    {ok, <<"b">>} = erlzmq:recv(ReqSocket),

    %%  Tear down the wiring.
    ok = erlzmq:close(XrepSocket),
    ok = erlzmq:close(ReqSocket),
    ok = erlzmq:term(Ctx).

pair_inproc_test() ->
    basic_tests("inproc://tester", pair, pair).

pair_ipc_test() ->
    basic_tests("ipc:///tmp/tester", pair, pair).

pair_tcp_test() ->
    basic_tests("tcp://127.0.0.1:5555", pair, pair).

reqrep_device_test() ->
    {ok, Ctx} = erlzmq:context(),

    %%  Create a req/rep device.
    {ok, Xreq} = erlzmq:socket(Ctx, xreq),
    ok = erlzmq:bind(Xreq, "tcp://127.0.0.1:5560"),
    {ok, Xrep} = erlzmq:socket(Ctx, xrep),
    ok = erlzmq:bind(Xrep, "tcp://127.0.0.1:5561"),

    %%  Create a worker.
    {ok, Rep} = erlzmq:socket(Ctx, rep),
    ok= erlzmq:connect(Rep, "tcp://127.0.0.1:5560"),

    %%  Create a client.
    {ok, Req} = erlzmq:socket(Ctx, req),
    ok = erlzmq:connect(Req, "tcp://127.0.0.1:5561"),

    %%  Send a request.
    ok = erlzmq:send(Req, <<"ABC">>, [sndmore]),
    ok = erlzmq:send(Req, <<"DEF">>),


    %%  Pass the request through the device.
    lists:foreach(fun(_) ->
                          {ok, Msg} = erlzmq:recv(Xrep),
                          {ok, RcvMore}= erlzmq:getsockopt(Xrep, rcvmore),
                          case RcvMore of
                              0 ->
                                  ok = erlzmq:send(Xreq, Msg);
                              _ ->
                                  ok = erlzmq:send(Xreq, Msg, [sndmore])
                          end
                  end,
                  lists:seq(1, 4)),

    %%  Receive the request.
    {ok, Buff0} = erlzmq:recv(Rep),
    ?assertMatch(<<"ABC">>, Buff0),
    {ok, RcvMore1} = erlzmq:getsockopt(Rep, rcvmore),
    ?assert(RcvMore1 > 0),
    {ok, Buff1} = erlzmq:recv(Rep),
    ?assertMatch(<<"DEF">>, Buff1),
    {ok, RcvMore2} = erlzmq:getsockopt(Rep, rcvmore),
    ?assertMatch(0, RcvMore2),

    %%  Send the reply.
    ok = erlzmq:send(Rep, <<"GHI">>, [sndmore]),
    ok = erlzmq:send (Rep, <<"JKL">>),

    %%  Pass the reply through the device.
    lists:foreach(fun(_) ->
                          {ok, Msg} = erlzmq:recv(Xreq),
                          {ok,RcvMore3} = erlzmq:getsockopt(Xreq, rcvmore),
                          case RcvMore3 of
                              0 ->
                                  ok = erlzmq:send(Xrep, Msg);
                              _ ->
                                  ok = erlzmq:send(Xrep, Msg, [sndmore])
                          end
                  end, lists:seq(1, 4)),

    %%  Receive the reply.
    {ok, Buff2} = erlzmq:recv(Req),
    ?assertMatch(<<"GHI">>, Buff2),
    {ok, RcvMore4} = erlzmq:getsockopt(Req, rcvmore),
    ?assert(RcvMore4 > 0),
    {ok, Buff3} = erlzmq:recv(Req),
    ?assertMatch(<<"JKL">>, Buff3),
    {ok, RcvMore5} = erlzmq:getsockopt(Req, rcvmore),
    ?assertMatch(0, RcvMore5),

    %%  Clean up.
    ok = erlzmq:close(Req),
    ok = erlzmq:close(Rep),
    ok = erlzmq:close(Xrep),
    ok = erlzmq:close(Xreq),
    ok = erlzmq:term(Ctx).

reqrep_inproc_test() ->
    basic_tests("inproc://test", req, rep).

reqrep_ipc_test() ->
    basic_tests("ipc:///tmp/tester", req, rep).

reqrep_tcp_test() ->
    basic_tests("tcp://127.0.0.1:5557", req, rep).


create_bound_pair(Ctx, Type1, Type2, Transport) ->
    {ok, S1} = erlzmq:socket(Ctx, Type1),
    {ok, S2} = erlzmq:socket(Ctx, Type2),
    ok = erlzmq:bind(S1, Transport),
    ok = erlzmq:connect(S2, Transport),
    {S1, S2}.

ping_pong({S1, S2}, Msg) ->
    ok = erlzmq:send(S1, Msg),
    ?assertMatch({ok, Msg}, erlzmq:recv(S2)),
    ok = erlzmq:send(S2, Msg),
    ?assertMatch({ok, Msg}, erlzmq:recv(S1)),
    ok = erlzmq:send(S1, Msg, [sndmore]),
    ok = erlzmq:send(S1, Msg),
    ?assertMatch({ok, Msg}, erlzmq:recv(S2)),
    ?assertMatch({ok, Msg}, erlzmq:recv(S2)),
    ok.

basic_tests(Transport, Type1, Type2) ->
    {ok, C} = erlzmq:context(1),
    {S1, S2} = create_bound_pair(C, Type1, Type2, Transport),
    ping_pong({S1, S2}, <<"XXX">>),
    ok = erlzmq:close(S1),
    ok = erlzmq:close(S2),
    ok = erlzmq:term(C).
