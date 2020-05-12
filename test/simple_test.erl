-module(simple_test).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlzmq.hrl").
-export_type([erlzmq_socket/0, erlzmq_context/0]).                          

context_init_term_test() ->
    {ok, C} = erlzmq:context(),
    ok = erlzmq:term(C).

socket_init_close_test() ->
    {ok, C} = erlzmq:context(),
    {ok, S1} = erlzmq:socket(C, [req, {active, false}]),
    ok = erlzmq:close(S1),
    ok = erlzmq:term(C).

context_term_before_test() ->
    {ok, C} = erlzmq:context(),
    {ok, S} = erlzmq:socket(C, [pub, {active, false}]),
    spawn_link(fun () ->
        timer:sleep(300),
        ok = erlzmq:close(S)
    end),
    ok = erlzmq:term(C).

bind_connect_passive_test() ->
    {ok, C} = erlzmq:context(),
    {ok, S1} = erlzmq:socket(C, [req, {active, false}]),
    {ok, S2} = erlzmq:socket(C, [rep, {active, false}]),
    ok = erlzmq:bind(S2, <<"tcp://127.0.0.1:5558">>),
    ok = erlzmq:connect(S1, <<"tcp://127.0.0.1:5558">>),
    ok = erlzmq:close(S1),
    ok = erlzmq:close(S2),
    ok = erlzmq:term(C).

bind_connect_active_test() ->
    {ok, C} = erlzmq:context(),
    {ok, S1} = erlzmq:socket(C, [req, {active, true}]),
    {ok, S2} = erlzmq:socket(C, [rep, {active, true}]),
    ok = erlzmq:bind(S2, <<"tcp://127.0.0.1:5558">>),
    ok = erlzmq:connect(S1, <<"tcp://127.0.0.1:5558">>),
    ok = erlzmq:close(S1),
    ok = erlzmq:close(S2),
    ok = erlzmq:term(C).

send_recv_passive_test() ->
    {ok, C} = erlzmq:context(),
    {ok, S1} = erlzmq:socket(C, [req, {active, false}]),
    {ok, S2} = erlzmq:socket(C, [rep, {active, false}]),
    ok = erlzmq:bind(S2, <<"tcp://127.0.0.1:5558">>),
    ok = erlzmq:connect(S1, <<"tcp://127.0.0.1:5558">>),
    ok = erlzmq:send(S1, <<"abc">>),
    {ok, <<"abc">>} = erlzmq:recv(S2),
    ok = erlzmq:close(S1),
    ok = erlzmq:close(S2),
    ok = erlzmq:term(C).

send_recv_active_test() ->
    {ok, C} = erlzmq:context(),
    {ok, S1} = erlzmq:socket(C, [req, {active, true}]),
    {ok, S2} = erlzmq:socket(C, [rep, {active, true}]),
    ok = erlzmq:bind(S2, <<"tcp://127.0.0.1:5558">>),
    ok = erlzmq:connect(S1, <<"tcp://127.0.0.1:5558">>),
    ok = erlzmq:send(S1, <<"abc">>),
    receive
        {zmq, S2, <<"abc">>, []} -> ok
    end,
    ok = erlzmq:close(S1),
    ok = erlzmq:close(S2),
    ok = erlzmq:term(C).
