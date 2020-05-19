-module(shutdown_stress_test).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlzmq.hrl").
-export_type([erlzmq_socket/0, erlzmq_context/0]).                              
-export([worker/2]).

shutdown_stress_test() ->
    ?assertMatch(ok, shutdown_stress_loop(10)).

shutdown_stress_loop(0) ->
    ok;
shutdown_stress_loop(N) ->
    {ok, C} = erlzmq:context(7),
    {ok, S1} = erlzmq:socket(C, rep),
    ?assertMatch(ok, shutdown_stress_worker_loop(20, C)),
    ?assertMatch(ok, join_procs(20)),
    ?assertMatch(ok, erlzmq:close(S1)),
    ?assertMatch(ok, erlzmq:term(C)),
    shutdown_stress_loop(N-1).

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
    {ok, S2} = erlzmq:socket(C, sub),
    spawn(?MODULE, worker, [self(), S2]),
    shutdown_stress_worker_loop(N-1, C).

worker(Pid, S) ->
    ?assertMatch(ok, erlzmq:connect(S, "tcp://127.0.0.1:5558")),
    ?assertMatch(ok, erlzmq:close(S)),
    Pid ! proc_end.
