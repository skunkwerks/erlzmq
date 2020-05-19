-module(z85_test).
-include_lib("eunit/include/eunit.hrl").
-include_lib("erlzmq.hrl").
-export_type([erlzmq_socket/0, erlzmq_context/0]).

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
