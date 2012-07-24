%%% periodically dump reports of folsom metrics to graphite
-module(folsomite_server).
-behaviour(gen_server).

%% management api
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         code_change/3, terminate/2]).


-define(APP, folsomite).
-define(TIMER_MSG, '#flush').

-record(state, {graphite_host  :: inet:ip_address() | inet:hostname(),
                graphite_port  :: integer(),
                flush_interval :: integer(),
                base_key       :: string(),
                timer_ref      :: reference()}).


%% management api
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, no_arg, []).

%% gen_server callbacks
init(no_arg) ->
    FlushInterval = get_env(flush_interval),
    Ref = erlang:start_timer(FlushInterval, self(), ?TIMER_MSG),
    State = #state{graphite_host = get_env(graphite_host),
                   graphite_port = get_env(graphite_port),
                   flush_interval = FlushInterval,
                   base_key = node_key(),
                   timer_ref = Ref},
    {ok, State}.

handle_call(Call, _, State) ->
    unexpected(call, Call),
    {noreply, State}.

handle_cast(Cast, State) ->
    unexpected(cast, Cast),
    {noreply, State}.

handle_info({timeout, _R, ?TIMER_MSG},
            #state{timer_ref = _R, flush_interval = FlushInterval} = State) ->
    Metrics = get_stats(),
    send_stats(State, Metrics),
    Ref = erlang:start_timer(FlushInterval, self(), ?TIMER_MSG),
    {noreply, State#state{timer_ref = Ref}};
handle_info(Info, State) ->
    unexpected(info, Info),
    {noreply, State}.

terminate(_, _) -> ok.

code_change(_, State, _) -> {ok, State}.


%% internal
get_stats() ->
    Metrics = folsom_metrics:get_metrics_info(),
    lists:flatmap(fun expand_metric/1, Metrics).

expand_metric({Name, [{type, Type}]}) ->
    M = case Type of
            histogram ->
                proplists:delete(histogram,
                                 folsom_metrics:get_histogram_statistics(Name));
            Type1 ->
                case lists:member(Type1,
                                  [counter, gauge, meter, meter_reader]) of
                    true -> folsom_metrics:get_metric_value(Name);
                    false -> []
                end
        end,
    lists:flatten(expand(M, [Name]));
expand_metric(_) ->
    [].

expand({K, X}, NamePrefix) ->
    expand(X, [K | NamePrefix]);
expand([_|_] = Xs, NamePrefix) ->
    [expand(X, NamePrefix) || X <- Xs];
expand(X, NamePrefix) ->
    K = string:join(lists:map(fun a2l/1, lists:reverse(NamePrefix)), "."),
    [{K, X}].


send_stats(State, Metrics) ->
    Timestamp = num2str(unixtime()),
    lists:foreach(fun({K, V}) ->
                          zeta:svh(K, V, ok, [{tags, [folsomite]}])
                  end, Metrics),
    Message = [format1(State#state.base_key, M, Timestamp) || M <- Metrics],
    {ok, Socket} = folsomite_graphite_client_sup:get_client(),
    folsomite_graphite_client:send(Socket, Message).

format1(Base, {K, V}, Timestamp) ->
    ["folsomite.", Base, ".", K, " ", a2l(V), " ", Timestamp, "\n"].

num2str(NN) -> lists:flatten(io_lib:format("~w",[NN])).
unixtime()  -> {Meg, S, _} = os:timestamp(), Meg*1000000 + S.


node_key() ->
    NodeList = atom_to_list(node()),
    {ok, R} = re:compile("[\@\.]"),
    Opts = [global, {return, list}],
    re:replace(NodeList, R, "_", Opts).


a2l(X) when is_list(X) -> X;
a2l(X) when is_atom(X) -> atom_to_list(X);
a2l(X) when is_integer(X) -> integer_to_list(X);
a2l(X) when is_float(X) -> float_to_list(X).

get_env(Name) ->
    {ok, Value} = application:get_env(?APP, Name),
    Value.

unexpected(Type, Message) ->
    info(" unexpected ~p ~p~n", [Type, Message]).

info(Format, Args) ->
    log4erl:info(io_lib:format("~p(~p)" ++ Format, [?MODULE, self() | Args])).