-module(erlzmq_test).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlzmq.hrl").
-export_type([erlzmq_socket/0, erlzmq_context/0]).                              
-export([worker/2]).

% provides some context for failures only viewable within the C code
%-define(PRINT_DEBUG, true).

-ifdef(PRINT_DEBUG).
% use stderr while bypassing the io server to avoid buffering
-define(PRINT_START,
        PRINT_PORT = open_port({fd, 0, 2}, [out, {line, 256}]),
        port_command(PRINT_PORT,
                     io_lib:format("~w:~w start~n", [?MODULE, ?LINE]))).
-define(PRINT_CHECK(ANY),
        port_command(PRINT_PORT,
                     io_lib:format("~w:~w ~p~n", [?MODULE, ?LINE, ANY]))).
-define(PRINT_END, 
        port_command(PRINT_PORT,
                     io_lib:format("~w:~w end~n", [?MODULE, ?LINE])),
        port_close(PRINT_PORT),
        ok).
-else.
-define(PRINT_START, ok).
-define(PRINT_CHECK(_), ok).
-define(PRINT_END, ok).
-endif.

invalid_rep_test() ->
    ?PRINT_START,
    {ok, Ctx} = erlzmq:context(),

    {ok, XrepSocket} = erlzmq:socket(Ctx, [xrep, {active, false}]),
    {ok, ReqSocket} = erlzmq:socket(Ctx, [req, {active, false}]),

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
    ok = erlzmq:term(Ctx),
    ?PRINT_END.

pair_inproc_test() ->
    ?PRINT_START,
    basic_tests("inproc://tester", pair, pair, active),
    basic_tests("inproc://tester", pair, pair, passive),
    ?PRINT_END.

pair_ipc_test() ->
    ?PRINT_START,
    basic_tests("ipc:///tmp/tester", pair, pair, active),
    basic_tests("ipc:///tmp/tester", pair, pair, passive),
    ?PRINT_END.

pair_tcp_test() ->
    ?PRINT_START,
    basic_tests("tcp://127.0.0.1:5554", pair, pair, active),
    basic_tests("tcp://127.0.0.1:5555", pair, pair, passive),
    ?PRINT_END.

reqrep_device_test() ->
    ?PRINT_START,
    {ok, Ctx} = erlzmq:context(),

    %%  Create a req/rep device.
    {ok, Xreq} = erlzmq:socket(Ctx, [xreq, {active, false}]),
    ok = erlzmq:bind(Xreq, "tcp://127.0.0.1:5560"),
    {ok, Xrep} = erlzmq:socket(Ctx, [xrep, {active, false}]),
    ok = erlzmq:bind(Xrep, "tcp://127.0.0.1:5561"),

    %%  Create a worker.
    {ok, Rep} = erlzmq:socket(Ctx, [rep, {active, false}]),
    ok= erlzmq:connect(Rep, "tcp://127.0.0.1:5560"),

    %%  Create a client.
    {ok, Req} = erlzmq:socket(Ctx, [req, {active, false}]),
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
    ok = erlzmq:term(Ctx),
    ?PRINT_END.


reqrep_inproc_test() ->
    ?PRINT_START,
    basic_tests("inproc://test", req, rep, active),
    basic_tests("inproc://test", req, rep, passive),
    ?PRINT_END.

reqrep_ipc_test() ->
    ?PRINT_START,
    basic_tests("ipc:///tmp/tester", req, rep, active),
    basic_tests("ipc:///tmp/tester", req, rep, passive),
    ?PRINT_END.

reqrep_tcp_test() ->
    ?PRINT_START,
    basic_tests("tcp://127.0.0.1:5556", req, rep, active),
    basic_tests("tcp://127.0.0.1:5557", req, rep, passive),
    ?PRINT_END.

bad_init_test() ->
    ?PRINT_START,
    ?assertEqual({error, einval}, erlzmq:context(-1)),
    ?PRINT_END.

version_test() ->
    ?PRINT_START,
    {Major, Minor, Patch} = erlzmq:version(),
    ?assert(is_integer(Major) andalso is_integer(Minor) andalso is_integer(Patch)),
    ?PRINT_END.

shutdown_stress_test() ->
    ?PRINT_START,
    ?assertMatch(ok, shutdown_stress_loop(10)),
    ?PRINT_END.

shutdown_stress_loop(0) ->
    ok;
shutdown_stress_loop(N) ->
    {ok, C} = erlzmq:context(7),
    {ok, S1} = erlzmq:socket(C, [rep, {active, false}]),
    ?assertMatch(ok, shutdown_stress_worker_loop(20, C)),
    ?assertMatch(ok, join_procs(20)),
    ?assertMatch(ok, erlzmq:close(S1)),
    ?assertMatch(ok, erlzmq:term(C)),
    shutdown_stress_loop(N-1).

shutdown_no_blocking_test() ->
    ?PRINT_START,
    {ok, C} = erlzmq:context(),
    {ok, S} = erlzmq:socket(C, [pub, {active, false}]),
    ok = erlzmq:close(S),
    ?assertEqual(ok, erlzmq:term(C, 500)),
    ?PRINT_END.

shutdown_blocking_test() ->
    ?PRINT_START,
    {ok, C} = erlzmq:context(),
    {ok, S} = erlzmq:socket(C, [pub, {active, false}]),
    case erlzmq:term(C, 0) of
        {error, {timeout, _}} ->
            % typical
            ok;
        ok ->
            % very infrequent
            ok
    end,
    ok = erlzmq:close(S),
    ?PRINT_END.

ctx_opt_test() ->
    ?PRINT_START,
    {ok, CDefault} = erlzmq:context(),
    {ok, OrigMS} = erlzmq:ctx_get(CDefault, max_sockets),
    ok = erlzmq:term(CDefault),
    {ok, C} = erlzmq:context([{max_sockets, OrigMS * 2}]),
    {ok, NewMS} = erlzmq:ctx_get(C, max_sockets),
    ?assertMatch(NewMS, OrigMS * 2),
    ok = erlzmq:ctx_set(C, max_sockets, OrigMS),

    {ok, OrigIT} = erlzmq:ctx_get(C, io_threads),
    ?assertMatch(ok, erlzmq:ctx_set(C, io_threads, OrigIT * 2)),
    {ok, NewIT} = erlzmq:ctx_get(C, io_threads),
    ?assertMatch(NewIT, OrigIT * 2),
    ok = erlzmq:ctx_set(C, io_threads, OrigIT),

    {ok, 0} = erlzmq:ctx_get(C, ipv6),
    ?assertMatch(ok, erlzmq:ctx_set(C, ipv6, 1)),
    {ok, NewV6} = erlzmq:ctx_get(C, ipv6),
    ?assertMatch(NewV6, 1),
    ok = erlzmq:ctx_set(C, ipv6, 0),
    ok = erlzmq:term(C),

    ?PRINT_END.

join_procs(0) ->
    ok;
join_procs(N) ->
    receive
        proc_end ->
            join_procs(N-1)
    after
        2000 ->
            throw(stuck)
    end.

shutdown_stress_worker_loop(0, _) ->
    ok;
shutdown_stress_worker_loop(N, C) ->
    {ok, S2} = erlzmq:socket(C, [sub, {active, false}]),
    spawn(?MODULE, worker, [self(), S2]),
    shutdown_stress_worker_loop(N-1, C).

worker(Pid, S) ->
    ?assertMatch(ok, erlzmq:connect(S, "tcp://127.0.0.1:5558")),
    ?assertMatch(ok, erlzmq:close(S)),
    Pid ! proc_end.

create_bound_pair(Ctx, Type1, Type2, Mode, Transport) ->
    Active = if
        Mode =:= active ->
            true;
        Mode =:= passive ->
            false
    end,
    {ok, S1} = erlzmq:socket(Ctx, [Type1, {active, Active}]),
    {ok, S2} = erlzmq:socket(Ctx, [Type2, {active, Active}]),
    ok = erlzmq:bind(S1, Transport),
    ok = erlzmq:connect(S2, Transport),
    {S1, S2}.

ping_pong({S1, S2}, Msg, active) ->
    ok = erlzmq:send(S1, Msg, [sndmore]),
    ok = erlzmq:send(S1, Msg),
    receive
        {zmq, S2, Msg, [rcvmore]} ->
            ok
    after
        1000 ->
            ?assertMatch({ok, Msg}, timeout)
    end,
    receive
        {zmq, S2, Msg, []} ->
            ok
    after
        1000 ->
            ?assertMatch({ok, Msg}, timeout)
    end,
    ok = erlzmq:send(S2, Msg),
    receive
        {zmq, S1, Msg, []} ->
            ok
    after
        1000 ->
            ?assertMatch({ok, Msg}, timeout)
    end,
    ok = erlzmq:send(S1, Msg),
    receive
        {zmq, S2, Msg, []} ->
            ok
    after
        1000 ->
            ?assertMatch({ok, Msg}, timeout)
    end,
    ok = erlzmq:send(S2, Msg),
    receive
        {zmq, S1, Msg, []} ->
            ok
    after
        1000 ->
            ?assertMatch({ok, Msg}, timeout)
    end,
    ok;

ping_pong({S1, S2}, Msg, passive) ->
    ok = erlzmq:send(S1, Msg),
    ?assertMatch({ok, Msg}, erlzmq:recv(S2)),
    ok = erlzmq:send(S2, Msg),
    ?assertMatch({ok, Msg}, erlzmq:recv(S1)),
    ok = erlzmq:send(S1, Msg, [sndmore]),
    ok = erlzmq:send(S1, Msg),
    ?assertMatch({ok, Msg}, erlzmq:recv(S2)),
    ?assertMatch({ok, Msg}, erlzmq:recv(S2)),
    ok.

basic_tests(Transport, Type1, Type2, Mode) ->
    {ok, C} = erlzmq:context(1),
    {S1, S2} = create_bound_pair(C, Type1, Type2, Mode, Transport),
    ping_pong({S1, S2}, <<"XXX">>, Mode),
    ok = erlzmq:close(S1),
    ok = erlzmq:close(S2),
    ok = erlzmq:term(C).

z85_decode_test() ->
    % Amusing test-case from http://rfc.zeromq.org/spec:32
    ?assertEqual({ok, <<16#86, 16#4F, 16#D2, 16#6F, 16#B5, 16#59, 16#F7, 16#5B>>},
                 erlzmq:z85_decode(<<"HelloWorld">>)),
    ?assertEqual(badarg, try erlzmq:z85_decode(atom) catch error:X -> X end),
    ?assertEqual(badarg, try erlzmq:z85_decode(<<1>>) catch error:X -> X end).

z85_encode_test() ->
    ?assertEqual({ok, <<"HelloWorld">>},
                 erlzmq:z85_encode(<<16#86, 16#4F, 16#D2, 16#6F, 16#B5, 16#59, 16#F7, 16#5B>>)),
    ?assertEqual(badarg, try erlzmq:z85_encode(atom) catch error:X -> X end),
    ?assertEqual(badarg, try erlzmq:z85_encode(<<1>>) catch error:X -> X end).
