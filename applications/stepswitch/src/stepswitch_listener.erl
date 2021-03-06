%%%-------------------------------------------------------------------
%%% @copyright (C) 2010-2011, VoIP INC
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(stepswitch_listener).

-behaviour(gen_listener).

-include("stepswitch.hrl").

%% API
-export([start_link/0]).
-export([init/1
         ,handle_call/3
         ,handle_cast/2
         ,handle_info/2
         ,handle_event/2
         ,terminate/2
         ,code_change/3
        ]).

-define(SERVER, ?MODULE).

-record(state, {resrcs = []}).

-define(BINDINGS, [{route, []}
                   ,{offnet_resource, []}
                   ,{authn, []}
                  ]).
-define(RESPONDERS, [{stepswitch_inbound, [{<<"dialplan">>, <<"route_req">>}]}
                     ,{stepswitch_outbound, [{<<"resource">>, <<"offnet_req">>}]}
                     ,{stepswitch_authn_req, [{<<"directory">>, <<"authn_req">>}]}
                    ]).
-define(QUEUE_NAME, <<"stepswitch_listener">>).
-define(QUEUE_OPTIONS, [{exclusive, false}, {nowait, false}]).
-define(CONSUME_OPTIONS, [{exclusive, false}]).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_listener:start_link({local, ?SERVER}, ?MODULE, [{bindings, ?BINDINGS}
                                                        ,{responders, ?RESPONDERS}
                                                        ,{queue_name, ?QUEUE_NAME}
                                                        ,{queue_options, ?QUEUE_OPTIONS}
                                                        ,{consume_options, ?CONSUME_OPTIONS}
                                                       ], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    lager:debug("starting new stepswitch outbound responder"),
    _ = wh_couch_connections:add_change_handler(?RESOURCES_DB),
    stepswitch_maintenance:refresh(),
    {ok, #state{resrcs=get_resrcs()}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call({lookup_number, Number}, From, State) ->
    P = proc_lib:spawn(fun() ->
                               gen_server:reply(From, stepswitch_util:lookup_number(Number))
                       end),
    lager:debug("spawned lookup_number req: ~p", [P]),
    {noreply, State};

handle_call({reload_resrcs}, _, State) ->
    {reply, ok, State#state{resrcs=get_resrcs()}};

handle_call({process_number, Number}, From, #state{resrcs=Resrcs}=State) ->
    P = proc_lib:spawn(fun() ->
                               Num = wnm_util:to_e164(wh_util:to_binary(Number)),
                               EPs = print_endpoints(stepswitch_util:evaluate_number(Num, Resrcs), 0, []),
                               gen_server:reply(From, EPs)
                       end),
    lager:debug("spawned process_number req for ~s: ~p", [Number, P]),
    {noreply, State};

handle_call({process_number, Number, Flags}, From, #state{resrcs=R1}=State) ->
    P = proc_lib:spawn(fun() ->
                               R2 = stepswitch_util:evaluate_flags(Flags, R1),
                               Num = wnm_util:to_e164(wh_util:to_binary(Number)),
                               EPs = print_endpoints(stepswitch_util:evaluate_number(Num, R2), 0, []),
                               gen_server:reply(From, EPs)
                       end),
    lager:debug("spawned process_number req for ~s w/ flags: ~p", [Number, P]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info({document_changes, <<"_design/", _/binary>>, _}, State) ->
    {noreply, State, hibernate};
handle_info({document_changes, DocId, [Changes]}, #state{resrcs=Resrcs}=State) ->
    Rev = wh_json:get_value(<<"rev">>, Changes),
    case lists:keysearch(DocId, #resrc.id, Resrcs) of
        {value, #resrc{rev=Rev}} -> {noreply, State, hibernate};
        _ ->
            lager:info("reloading offnet resource ~s", [DocId]),
            {noreply, State#state{resrcs=update_resrc(DocId, Resrcs)}, hibernate}
    end;
handle_info({document_deleted, <<"_design/", _/binary>>}, State) ->
    {noreply, State, hibernate};
handle_info({document_deleted, DocId}, #state{resrcs=Resrcs}=State) ->
    case lists:keyfind(DocId, #resrc.id, Resrcs) of
        false -> {noreply, State};
        _ ->
            lager:info("removing offnet resource ~s", [DocId]),
            {noreply, State#state{resrcs=lists:keydelete(DocId, #resrc.id, Resrcs)}, hibernate}
    end;
handle_info({'document_deleted', _DocId, 'undefined'}, State) ->
    {'noreply', State};
handle_info(_Info, State) ->
    lager:debug("unhandled message: ~p", [_Info]),
    {'noreply', State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
handle_event(_JObj, #state{resrcs=Rs}) ->
    {'reply', [{'resources', Rs}]}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Gets a list of all active resources from the DB
%% @end
%%--------------------------------------------------------------------
-spec get_resrcs() -> [#resrc{}].
get_resrcs() ->
    case couch_mgr:get_results(?RESOURCES_DB, ?LIST_RESOURCES_BY_ID, [include_docs]) of
        {ok, Resrcs} ->
            [stepswitch_util:create_resrc(wh_json:get_value(<<"doc">>, R))
             || R <- Resrcs, wh_util:is_true(wh_json:get_value([<<"doc">>, <<"enabled">>], R, 'true'))];
        {error, _}=E ->
            E
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Syncs a resource with the DB and updates it in the list
%% of resources
%% @end
%%--------------------------------------------------------------------
-spec update_resrc(ne_binary(), [#resrc{},...] | []) -> [#resrc{},...] | [].
update_resrc(DocId, Resrcs) ->
    lager:debug("received notification that resource ~s has changed", [DocId]),
    case couch_mgr:open_doc(?RESOURCES_DB, DocId) of
        {ok, JObj} ->
            case wh_json:is_true(<<"enabled">>, JObj) of
                'true' ->
                    NewResrc = stepswitch_util:create_resrc(JObj),
                    lager:debug("resource ~s updated to rev ~s", [DocId, NewResrc#resrc.rev]),
                    [NewResrc|lists:keydelete(DocId, #resrc.id, Resrcs)];
                'false' ->
                    lager:debug("resource ~s disabled", [DocId]),
                    lists:keydelete(DocId, #resrc.id, Resrcs)
            end;
        {error, R} ->
            lager:debug("removing resource ~s, ~w", [DocId, R]),
            lists:keydelete(DocId, #resrc.id, Resrcs)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Builds a list of tuples for humans from the lookup number request
%% @end
%%--------------------------------------------------------------------
-spec print_endpoints(endpoints(), non_neg_integer(), list()) -> list().
print_endpoints([], _, Acc) ->
    lists:reverse(Acc);
print_endpoints([{_, GracePeriod, Number, [Gateway], _}|T], Delay, Acc0) ->
    print_endpoints(T, Delay + GracePeriod, [print_endpoint(Number, Gateway, Delay)|Acc0]);
print_endpoints([{_, GracePeriod, Number, Gateways, _}|T], Delay, Acc0) ->
    {D2, Acc1} = lists:foldl(fun(Gateway, {0, AccIn}) ->
                                     {2, [print_endpoint(Number, Gateway, 0)|AccIn]};
                                 (Gateway, {D0, AccIn}) ->
                                     {D0 + 2, [print_endpoint(Number, Gateway, D0)|AccIn]}
                            end, {Delay, Acc0}, Gateways),
    print_endpoints(T, D2 - 2 + GracePeriod, Acc1).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Builds a tuple for humans from the lookup number request
%% @end
%%--------------------------------------------------------------------
-spec print_endpoint(ne_binary(), #gateway{}, non_neg_integer()) -> {ne_binary(), non_neg_integer(), ne_binary()}.
print_endpoint(Number, #gateway{resource_id=ResourceID}=Gateway, Delay) ->
    {ResourceID, Delay, stepswitch_util:get_dialstring(Gateway, Number)}.
