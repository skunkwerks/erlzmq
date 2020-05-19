-module(version_test).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlzmq.hrl").
-export_type([erlzmq_socket/0, erlzmq_context/0]).

version_test() ->
    {Major, Minor, Patch} = erlzmq:version(),
    ?assert(is_integer(Major) andalso is_integer(Minor) andalso is_integer(Patch)).
