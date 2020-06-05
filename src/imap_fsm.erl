-module(imap_fsm).

-include("imap.hrl").

-behaviour(gen_fsm).

%% api
-export([connect/2, connect/3, connect_ssl/2, connect_ssl/3, login/3, login/4,
         logout/1, logout/2, noop/1, noop/2, disconnect/1, disconnect/2,
         select/2, select/3, examine/2, examine/3,
         search/2, search/3,
         fetch/3, fetch/4,
         store/4, store/5,
         expunge/1, expunge/2
        ]).

%% callbacks
-export([init/1, handle_event/3, handle_sync_event/4, handle_info/3,
         code_change/4, terminate/3]).

%% state funs
-export([server_greeting/2, server_greeting/3, not_authenticated/2,
         not_authenticated/3, authenticated/2, authenticated/3,
         loggingout/2, loggingout/3]).

-define(TIMEOUT, 5000).


%%%--- TODO TODO TODO -------------------------------------------------------------------
%%% Objetivos:
%%%
%%% Escanear INBOX, listar mensajes, coger un mensaje entero, parsear MIME y generar JSON
%%%--------------------------------------------------------------------------------------

%%%--- TODO TODO TODO -------------------------
%%% 1. Implementar LIST, SELECT, ...
%%% 2. Implementar la respuesta con LOGIN: "* CAPABILITY IMAP4rev1 UNSELECT ..."
%%% 3. Filtrar mensajes de error_logger para desactivar los de este modulo, desactivar por defecto el logger?
%%%--------------------------------------------

%%%-----------------
%%% Client functions
%%%-----------------

connect(Host, Port) ->
  gen_fsm:start_link(?MODULE, {tcp, Host, Port}, []).

connect(Host, Port, Timeout) ->
  gen_fsm:start_link(?MODULE, {tcp, Host, Port}, [{timeout, Timeout}]).

connect_ssl(Host, Port) ->
  gen_fsm:start_link(?MODULE, {ssl, Host, Port}, []).

connect_ssl(Host, Port, Timeout) ->
  gen_fsm:start_link(?MODULE, {ssl, Host, Port}, [{timeout, Timeout}]).

login(Conn, User, Pass) ->
  login(Conn, User, Pass, ?TIMEOUT).

login(Conn, User, Pass, Timeout) ->
  gen_fsm:sync_send_event(Conn, {command, login, {User, Pass}}, Timeout).

logout(Conn) ->
  logout(Conn, ?TIMEOUT).

logout(Conn, Timeout) ->
  gen_fsm:sync_send_event(Conn, {command, logout, {}}, Timeout).

noop(Conn) ->
  noop(Conn, ?TIMEOUT).

noop(Conn, Timeout) ->
  gen_fsm:sync_send_event(Conn, {command, noop, {}}, Timeout).

disconnect(Conn) ->
  disconnect(Conn, ?TIMEOUT).

disconnect(Conn, Timeout) ->
  gen_fsm:sync_send_all_state_event(Conn, {command, disconnect, {}}, Timeout).

select(Conn, Mailbox) ->
  select(Conn, Mailbox, ?TIMEOUT).

select(Conn, Mailbox, Timeout) ->
  gen_fsm:sync_send_event(Conn, {command, select, Mailbox}, Timeout).

examine(Conn, Mailbox) ->
  examine(Conn, Mailbox, ?TIMEOUT).

examine(Conn, Mailbox, Timeout) ->
  gen_fsm:sync_send_event(Conn, {command, examine, Mailbox}, Timeout).

search(Conn, SearchKeys) ->
  search(Conn, SearchKeys, ?TIMEOUT).

search(Conn, SearchKeys, Timeout) ->
  gen_fsm:sync_send_event(Conn, {command, search, SearchKeys}, Timeout).

fetch(Conn, SequenceSet, MsgDataItems) ->
  fetch(Conn, SequenceSet, MsgDataItems, ?TIMEOUT).

fetch(Conn, SequenceSet, MsgDataItems, Timeout) ->
  gen_fsm:sync_send_event(Conn, {command, fetch, [SequenceSet, MsgDataItems]}, Timeout).

store(Conn, SequenceSet, Flags, Action) ->
  store(Conn, SequenceSet, Flags, Action, ?TIMEOUT).

store(Conn, SequenceSet, Flags, Action, Timeout) ->
  gen_fsm:sync_send_event(Conn, {command, store, [SequenceSet, Flags, Action]}, Timeout).

expunge(Conn) ->
  expunge(Conn, ?TIMEOUT).

expunge(Conn, Timeout) ->
  gen_fsm:sync_send_event(Conn, {command, expunge, []}, Timeout).

%%%-------------------
%%% Callback functions
%%%-------------------

init({SockType, Host, Port}) ->
  case imap_util:sock_connect(SockType, Host, Port, [list, {packet, line}]) of
    {ok, Sock} ->
      ?LOG_INFO("IMAP connection open", []),
      {ok, server_greeting, #state_data{socket = Sock, socket_type = SockType}};
    {error, Reason} ->
      {stop, Reason}
  end.

server_greeting(Command = {command, _, _}, From, StateData) ->
  NewStateData = StateData#state_data{enqueued_commands =
    [{Command, From} | StateData#state_data.enqueued_commands]},
  ?LOG_DEBUG("command enqueued: ~p", [Command]),
  {next_state, server_greeting, NewStateData}.

server_greeting(_ResponseLine={{response, untagged, "OK", Capabilities}, _}, StateData) ->
  %%?LOG_DEBUG("greeting received: ~p", [ResponseLine]),
  EnqueuedCommands = lists:reverse(StateData#state_data.enqueued_commands),
  NewStateData = StateData#state_data{server_capabilities = Capabilities,
                                      enqueued_commands = []},
  lists:foreach(fun({Command, From}) ->
    gen_fsm:send_event(self(), {enqueued_command, Command, From})
  end, EnqueuedCommands),
  {next_state, not_authenticated, NewStateData};
server_greeting(_ResponseLine = {{response, _, _, _}, _}, StateData) ->
  %%?LOG_ERROR(server_greeting, "unrecognized greeting: ~p", [ResponseLine]),
  {stop, unrecognized_greeting, StateData}.

%% TODO: hacer un comando `tag CAPABILITY' si tras hacer login no hemos
%%       recibido las CAPABILITY, en el login con el OK
not_authenticated(Command = {command, _, _}, From, StateData) ->
  handle_command(Command, From, not_authenticated, StateData).

not_authenticated({enqueued_command, Command, From}, StateData) ->
  ?LOG_DEBUG("command dequeued: ~p", [Command]),
  handle_command(Command, From, not_authenticated, StateData);
not_authenticated(ResponseLine = {{response, _, _, _}, _}, StateData) ->
  handle_response(ResponseLine, not_authenticated, StateData).

authenticated(Command = {command, _, _}, From, StateData) ->
  handle_command(Command, From, authenticated, StateData).

authenticated(ResponseLine = {{response, _, _, _}, _}, StateData) ->
  handle_response(ResponseLine, authenticated, StateData).

loggingout(Command = {command, _, _}, From, StateData) ->
  handle_command(Command, From, loggingout, StateData).

loggingout(ResponseLine = {{response, _, _, _}, _}, StateData) ->
  handle_response(ResponseLine, loggingout, StateData).

%% TODO: reconexion en caso de desconexion inesperada
handle_info({SockTypeClosed, Sock}, StateName,
            StateData = #state_data{socket = Sock}) when
    SockTypeClosed == tcp_closed; SockTypeClosed == ssl_closed ->
  NewStateData = StateData#state_data{socket = closed},
  case StateName of
    loggingout ->
      ?LOG_INFO("IMAP connection closed", []),
      {next_state, loggingout, NewStateData};
    StateName ->
      ?LOG_ERROR(handle_info, "IMAP connection closed unexpectedly", []),
      {next_state, loggingout, NewStateData}
  end;
handle_info({SockType, Sock, Line}, StateName,
            StateData = #state_data{socket = Sock}) when
    SockType == tcp; SockType == ssl ->
  ?LOG_DEBUG("line received: ~s", [imap_util:clean_line(Line)]),
  case imap_resp:parse_response(imap_util:clean_line(Line)) of
    {ok, Response} ->
      ?MODULE:StateName({Response, Line}, StateData);
    {error, nomatch} ->
      ?LOG_ERROR(handle_info, "unrecognized response: ~p",
                 [imap_util:clean_line(Line)]),
      {stop, unrecognized_response, StateData}
  end.

handle_event(_Event, StateName, StateData) ->
  %%?LOG_WARNING(handle_event, "fsm handle_event ignored: ~p", [Event]),
  {next_state, StateName, StateData}.

handle_sync_event({command, disconnect, {}}, _From, _StateName, StateData) ->
  case StateData#state_data.socket of
    closed ->
      true;
    Sock ->
      ok = imap_util:sock_close(StateData#state_data.socket_type, Sock),
      ?LOG_INFO("IMAP connection closed", [])
  end,
  {stop, normal, ok, StateData}.

code_change(_OldVsn, StateName, StateData, _Extra) ->
  {ok, StateName, StateData}.

terminate(normal, _StateName, _StateData) ->
  ?LOG_DEBUG("gen_fsm terminated normally", []),
  ok;
terminate(Reason, _StateName, _StateData) ->
  ?LOG_DEBUG("gen_fsm terminated because an error occurred", []),
  {error, Reason}.

%%%--------------------------------------
%%% Commands/Responses handling functions
%%%--------------------------------------

handle_response({Response = {response, untagged, _, _}, _}, StateName, StateData) ->
  NewStateData = StateData#state_data{untagged_responses_received =
    [Response | StateData#state_data.untagged_responses_received]},
  {next_state, StateName, NewStateData};
handle_response({Response = {response, Tag, _, _}, Line}, StateName, StateData) ->
  ResponsesReceived =
    case StateData#state_data.untagged_responses_received of
      [] ->
        [Response];
      UntaggedResponsesReceived ->
        lists:reverse([Response | UntaggedResponsesReceived])
    end,
  try
      imap_util:extract_dict_element(Tag,
           StateData#state_data.commands_pending_response)
  of
    {ok, {Command, From}, CommandsPendingResponse} ->
      NewStateData = StateData#state_data{
                       commands_pending_response = CommandsPendingResponse,
                       untagged_responses_received = []
                      },
      NextStateName = imap_resp:analyze_response(StateName, ResponsesReceived,
                                                 Command, From),
      {next_state, NextStateName, NewStateData}
  catch
    error:{badmatch, error} ->
       ?LOG_DEBUG("Tag not found, assumming the line is untagged", []),
       handle_response({{response, untagged, Line, []}, Line}, StateName, StateData)
  end.

handle_command(Command, From, StateName, StateData) ->
  case imap_cmd:send_command(StateData#state_data.socket_type,
                             StateData#state_data.socket, Command) of
    {ok, Tag} ->
      NewStateData = StateData#state_data{commands_pending_response =
        dict:store(Tag, {Command, From},
                   StateData#state_data.commands_pending_response)},
      {next_state, StateName, NewStateData};
    {error, Reason} ->
      {stop, Reason, StateData}
  end.


%%
%% Tests
%%
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").


-endif.
