-module(active_test).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlzmq.hrl").
-export_type([erlzmq_socket/0, erlzmq_context/0]).

receive_not_allowed_test() ->
    {ok, C} = erlzmq:context(),
    Endpoint1 = "inproc://act1",

    Pid = spawn_link(fun () ->
        timer:sleep(10000)
    end),

    {ok, To1} = erlzmq:socket(C, [pull, {active_pid, Pid}]),
    ok = erlzmq:bind(To1, Endpoint1),

    {ok, From} = erlzmq:socket(C, [push, {active, false}]),
    ok = erlzmq:connect(From, Endpoint1),

    ok = erlzmq:send(From, <<"A">>),
    
    ?assertEqual({error, active}, erlzmq:recv(To1)),

    ok = erlzmq:close(To1),
    ok = erlzmq:close(From),
    ok = erlzmq:term(C).

socket_not_active_if_pid_dies_after_bind_test() ->
    {ok, C} = erlzmq:context(),
    Endpoint1 = "inproc://act1",

    {Pid, _Ref} = spawn_monitor(fun () ->
        timer:sleep(100)
    end),

    {ok, To1} = erlzmq:socket(C, [pull, {active_pid, Pid}]),
    ok = erlzmq:bind(To1, Endpoint1),

    {ok, From} = erlzmq:socket(C, [push, {active, false}]),
    ok = erlzmq:connect(From, Endpoint1),

    receive
        {'DOWN', _, process, Pid, normal} -> ok
    end,

    timer:sleep(100),

    ok = erlzmq:send(From, <<"A">>),
    
    ?assertEqual({ok, <<"A">>}, erlzmq:recv(To1)),

    ok = erlzmq:close(To1),
    ok = erlzmq:close(From),
    ok = erlzmq:term(C).

socket_not_active_if_pid_dies_before_bind_test() ->
    {ok, C} = erlzmq:context(),
    Endpoint1 = "inproc://act1",

    {Pid, _Ref} = spawn_monitor(fun () ->
        timer:sleep(10)
    end),

    receive
        {'DOWN', _, process, Pid, normal} -> ok
    end,

    {ok, To1} = erlzmq:socket(C, [pull, {active_pid, Pid}]),
    ok = erlzmq:bind(To1, Endpoint1),

    {ok, From} = erlzmq:socket(C, [push, {active, false}]),
    ok = erlzmq:connect(From, Endpoint1),

    ok = erlzmq:send(From, <<"A">>),

    timer:sleep(100),
    
    ?assertEqual({ok, <<"A">>}, erlzmq:recv(To1)),

    ok = erlzmq:close(To1),
    ok = erlzmq:close(From),
    ok = erlzmq:term(C).
