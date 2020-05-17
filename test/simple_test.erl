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

max_sockets_test() ->
    {ok, C} = erlzmq:context(1, [{max_sockets, 33}]),
    ok = erlzmq:ctx_set(C, max_sockets, 90),
    Sockets = create_sockets(C, []),
    ?assertEqual(length(Sockets), 31),
    lists:foreach(fun (S) ->
        ok = erlzmq:close(S)
    end, Sockets),
    ok = erlzmq:term(C).

max_sockets_no_limit_test() ->
    {ok, C} = erlzmq:context(1),
    Sockets = create_sockets(C, []),
    ?assert(length(Sockets) > 0),
    lists:foreach(fun (S) ->
        ok = erlzmq:close(S)
    end, Sockets),
    ok = erlzmq:term(C).

create_sockets(Context, List) ->
    case erlzmq:socket(Context, [req, {active, true}]) of
        {ok, S} -> create_sockets(Context, [S | List]);
        {error, emfile} -> List
    end.

max_sockets_poll_limit_test_() ->
    {timeout, 10, [
        ?_assert(max_sockets_poll_limit() =:= ok)
    ]}.

max_sockets_poll_limit() ->
    {ok, C} = erlzmq:context(1),
    {ok, S1} = erlzmq:socket(C, [push, {active, false}]),
    ok = erlzmq:setsockopt(S1, immediate, 1),
    ok = erlzmq:setsockopt(S1, linger, 0),
    ok = erlzmq:connect(S1, <<"tcp://127.0.0.1:9472">>),
    
    A = create_sends(S1),
    ?assertEqual(emfile, A),
    ok = erlzmq:close(S1),
    ok = erlzmq:term(C),
    ok.

create_sends(S) ->
    Self = self(),
    spawn_link(fun () ->
        case erlzmq:send(S, <<>>) of
            {error, Error} ->
                Self ! Error
        end
    end),
    receive
        emfile -> emfile
    after
        10 -> create_sends(S)
    end.

close_while_sending_test() ->
    {ok, C} = erlzmq:context(),
    {ok, S1} = erlzmq:socket(C, [req, {active, false}]),
    spawn_link(fun () ->
        {error, enotsock} = erlzmq:send(S1, <<>>)
    end),
    timer:sleep(1000),
    ok = erlzmq:close(S1),
    ok = erlzmq:term(C).

close_while_receiving_test() ->
    {ok, C} = erlzmq:context(),
    {ok, S1} = erlzmq:socket(C, [rep, {active, false}]),
    spawn_link(fun () ->
        {error, enotsock} = erlzmq:recv(S1)
    end),
    timer:sleep(100),
    ok = erlzmq:close(S1),
    ok = erlzmq:term(C).

term_while_sending_test() ->
    {ok, C} = erlzmq:context(),
    {ok, S1} = erlzmq:socket(C, [req, {active, false}]),
    spawn_link(fun () ->
        {error, eterm} = erlzmq:send(S1, <<>>)
    end),
    timer:sleep(1000),
    spawn_link(fun () ->
        timer:sleep(500),
        ok = erlzmq:close(S1)
    end),
    ok = erlzmq:term(C).

term_while_receiving_test() ->
    {ok, C} = erlzmq:context(),
    {ok, S1} = erlzmq:socket(C, [rep, {active, false}]),
    spawn_link(fun () ->
        {error, eterm} = erlzmq:recv(S1)
    end),
    timer:sleep(1000),
    spawn_link(fun () ->
        timer:sleep(500),
        ok = erlzmq:close(S1)
    end),
    ok = erlzmq:term(C).

close_while_receiving_active_test() ->
    {ok, C} = erlzmq:context(),
    {ok, S1} = erlzmq:socket(C, [rep, {active, true}]),
    ok = erlzmq:bind(S1, <<"tcp://127.0.0.1:9472">>),
    ok = erlzmq:close(S1),
    ok = erlzmq:term(C),
    receive
        {zmq, S1, {error, enotsock}} -> ok
    end.

term_while_receiving_active_test() ->
    {ok, C} = erlzmq:context(),
    {ok, S1} = erlzmq:socket(C, [rep, {active, true}]),
    ok = erlzmq:bind(S1, <<"tcp://127.0.0.1:9473">>),
    spawn_link(fun () ->
        timer:sleep(500),
        ok = erlzmq:close(S1)
    end),
    ok = erlzmq:term(C),
    receive
        {zmq, S1, {error, eterm}} -> ok
    end.

close_while_terminating_test() ->
    {ok, C} = erlzmq:context(1),
    Sockets = create_sockets(C, []),
    ?assert(length(Sockets) > 0),
    lists:foreach(fun (S) ->
        spawn_link(fun () ->
            ok = erlzmq:close(S)
        end)
    end, Sockets),
    ok = erlzmq:term(C).
