-module(imap).

-include("imap.hrl").

-behaviour(gen_server).

-export([open_account/5, open_account/6, close_account/1, close_account/2,
         select/2, select/3, examine/2, examine/3, search/2, search/3,
         fetch/3, fetch/4, store/4, store/5, expunge/1, expunge/2
        ]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, code_change/3,
         terminate/2]).

-define(TIMEOUT, 5000).

%%%-----------------
%%% Client functions
%%%-----------------

open_account(ConnType, Host, Port, User, Pass) ->
  gen_server:start_link(?MODULE, {ConnType, Host, Port, User, Pass, ?TIMEOUT}, []).

open_account(ConnType, Host, Port, User, Pass, Timeout) ->
  gen_server:start_link(?MODULE, {ConnType, Host, Port, User, Pass, Timeout}, [{timeout, Timeout}]).

close_account(Account) ->
  close_account(Account, ?TIMEOUT).

close_account(Account, Timeout) ->
  gen_server:call(Account, {close_account, Timeout}, Timeout).

select(Account, Mailbox) ->
  select(Account, Mailbox, ?TIMEOUT).

select(Account, Mailbox, Timeout) ->
  gen_server:call(Account, {select, Mailbox, Timeout}, Timeout).

examine(Account, Mailbox) ->
  examine(Account, Mailbox, ?TIMEOUT).

examine(Account, Mailbox, Timeout) ->
  gen_server:call(Account, {examine, Mailbox, Timeout}, Timeout).

search(Account, SearchKeys) ->
  search(Account, SearchKeys, ?TIMEOUT).

search(Account, SearchKeys, Timeout) ->
  gen_server:call(Account, {search, SearchKeys, Timeout}, Timeout).

fetch(Account, SequenceSet, MsgDataItems) ->
  fetch(Account, SequenceSet, MsgDataItems, ?TIMEOUT).

fetch(Account, SequenceSet, MsgDataItems, Timeout) ->
  gen_server:call(Account, {fetch, SequenceSet, MsgDataItems, Timeout}, Timeout).

store(Account, SequenceSet, Flags, Action) ->
  store(Account, SequenceSet, Flags, Action, ?TIMEOUT).

store(Account, SequenceSet, Flags, Action, Timeout) ->
  gen_server:call(Account, {store, SequenceSet, Flags, Action, Timeout}, Timeout).

expunge(Account) ->
  expunge(Account, ?TIMEOUT).

expunge(Account, Timeout) ->
  gen_server:call(Account, {expunge, Timeout}, Timeout).

%%%-------------------
%%% Callback functions
%%%-------------------

init({ConnType, Host, Port, User, Pass, Timeout}) ->
  try
    {ok, Conn} = case ConnType of
                   tcp -> imap_fsm:connect(Host, Port);
                   ssl -> imap_fsm:connect_ssl(Host, Port)
                 end,
    ok = imap_fsm:login(Conn, User, Pass, Timeout),
    {ok, Conn}
  catch
    error:{badmatch, {error, Reason}} -> {stop, Reason}
  end.

handle_call({close_account, Timeout}, _From, Conn) ->
  try
    ok = imap_fsm:logout(Conn, Timeout),
    ok = imap_fsm:disconnect(Conn, Timeout),
    {stop, normal, ok, Conn}
  catch
    error:{badmatch, {error, Reason}} -> {stop, Reason, {error, Reason}, Conn}
  end;

handle_call({select, Mailbox, Timeout}, _From, Conn) ->
  {reply, imap_fsm:select(Conn, Mailbox, Timeout), Conn};
handle_call({examine, Mailbox, Timeout}, _From, Conn) ->
  {reply, imap_fsm:examine(Conn, Mailbox, Timeout), Conn};
handle_call({search, SearchKeys, Timeout}, _From, Conn) ->
  {reply, imap_fsm:search(Conn, SearchKeys, Timeout), Conn};
handle_call({fetch, SequenceSet, MsgDataItems, Timeout}, _From, Conn) ->
  {reply, imap_fsm:fetch(Conn, SequenceSet, MsgDataItems, Timeout), Conn};
handle_call({store, SequenceSet, Flags, Action, Timeout}, _From, Conn) ->
  {reply, imap_fsm:store(Conn, SequenceSet, Flags, Action, Timeout), Conn};
handle_call({expunge, Timeout}, _From, Conn) ->
  {reply, imap_fsm:expunge(Conn, Timeout), Conn};
handle_call(_, _From, Conn) ->
  {reply, ignored, Conn}.



handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(normal, _State) ->
  ok;
terminate(Reason, _State) ->
  {error, Reason}.

%%%-----------
%%% tests
%%%-----------

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").


-endif.
