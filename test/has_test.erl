-module(has_test).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlzmq.hrl").
-export_type([erlzmq_socket/0, erlzmq_context/0]).

has_test() ->
    ?assert(erlzmq:has(ipc)),
    ?assert(not(erlzmq:has(foobar))).
