%%% @author Søren Hilmer <sh@widetrail.dk>
%%% @doc
%%% ssh_scp module implementing client side scp (Secure CoPy) in Erlang
%%% @end
%%% Created : 25 Dec 2013 by Søren Hilmer <sh@widetrail.dk>

-module(ssh_scp).

-include_lib("kernel/include/file.hrl").
-include_lib("ssh/src/ssh_connect.hrl").


-include("include/ssh_scp_opts.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-include("localhost_connection.hrl").
-else.
-define(debugFmt, fun(_F,_A) -> ok end).
-endif.

-export([to/3,to/4,to_file/4,to_file/5,to_file/6]).
-export([permission_string_to_file_mode/1,file_mode_to_permission_string/1]).

%%--------------------------------------------------------------------
%% @doc copies the file or directory (recursively) in Filename 
%% to the remote and place it in Destination 
%% which must be an existing directory on the remote side,
%% using the supplied ssh connection, ConnectionRef. With default transfer options
%% The transferred file(s) will have the same permission as the source.
%% Connection timeout used is 30 seconds.
%%
%% @spec to(ConnectionRef, Filename, Destination) -> ok | {error, Reason}
%% @end
%%--------------------------------------------------------------------

to(ConnectionRef, Filename, Destination) ->
    ssh_scp:to(ConnectionRef, Filename, Destination,#ssh_scp_opts{timeout=30000}).

%%--------------------------------------------------------------------
%% @doc copies the file or directory (recursively) in Filename 
%% to the remote and place it in Destination, 
%% which must be an existing directory on the remote side,
%% using the supplied ssh connection, ConnectionRef. 
%% File modification times (atime, mtime) as well as connection timeout 
%% (defaults to 30 seconds) can be specified in Opts.
%% But the transferred file(s) will have the same permission as the source
%%
%% @spec to(ConnectionRef, Filename, Destination, Opts) -> ok | {error, Reason}
%% @end
%%--------------------------------------------------------------------
to(ConnectionRef, Filename, Destination, Opts) when is_record(Opts, ssh_scp_opts) ->
    Timeout = case Opts#ssh_scp_opts.timeout of undefined -> 30000; T -> T end,
    with_transfer_channel(
      ConnectionRef,Timeout, Destination,
      fun(ChannelId) -> 
              case traverse(ConnectionRef,ChannelId,filename:absname(Filename),Opts,Timeout) of 
                  ok -> wait_for_protocol_termination(ConnectionRef,ChannelId,Timeout);
                  Err -> Err
              end
      end).

%%--------------------------------------------------------------------
%% @doc copies the binary Content as a file to the remote and place it in Destination, 
%% which must be an existing directory on the remote side,
%% using the supplied ssh connection, ConnectionRef. 
%% The file will end up with permission "0640"
%% Connection timeout used is 30 seconds.
%%
%% @spec to_file(ConnectionRef, Filename, Destination, Content) -> ok | {error, Reason}
%% @end
%%--------------------------------------------------------------------
to_file(ConnectionRef, Filename, Destination, Content) when is_binary(Content) ->
    ssh_scp:to_file(ConnectionRef, Filename, Destination, Content, #ssh_scp_opts{timeout=30000,mode=permission_string_to_file_mode("0640")}).

%%--------------------------------------------------------------------
%% @doc copies the binary Content as a file to the remote and place it in Destination, 
%% which must be an existing directory on the remote side,
%% using the supplied ssh connection, ConnectionRef. 
%% The file will end up with the supplied permission.
%% Connection timeout used is 30 seconds.
%%
%% @spec to_file(ConnectionRef, Filename, Destination, Content, Permission) -> ok | {error, Reason}
%% @end
%%--------------------------------------------------------------------
to_file(ConnectionRef, Filename, Destination, Content, Permission) when is_binary(Content),is_list(Permission) ->
    ssh_scp:to_file(ConnectionRef, Filename, Destination, Content, #ssh_scp_opts{timeout=30000,mode=permission_string_to_file_mode(Permission)});

%%--------------------------------------------------------------------
%% @doc copies the binary Content as a file to the remote and place it in Destination, 
%% which must be an existing directory on the remote side,
%% using the supplied ssh connection, ConnectionRef. 
%% The file will end up with the permission,mtime,atime as specified in Opts.
%% Connection timeout canlikewise be specified in Opts defaults to 30 seconds.
%%
%% @spec to_file(ConnectionRef, Filename, Destination, Content, Opts) -> ok | {error, Reason}
%% @end
%%--------------------------------------------------------------------
to_file(ConnectionRef, Filename, Destination, Content, Opts) when is_binary(Content),is_record(Opts, ssh_scp_opts) ->
    Timeout = case Opts#ssh_scp_opts.timeout of undefined -> 30000; T -> T end,
    Permission = file_mode_to_permission_string(Opts#ssh_scp_opts.mode),
    with_transfer_channel(
      ConnectionRef,Timeout, Destination,
      fun(ChannelId) -> 
              case send_time_info(ConnectionRef,ChannelId,{Opts#ssh_scp_opts.mtime, Opts#ssh_scp_opts.atime},Timeout) of
                  ok ->
                      case send_file_header(ConnectionRef,ChannelId,Filename,Permission,size(Content),Timeout) of
                          ok -> case  send_content(ConnectionRef,ChannelId,
                                                   Timeout,
                                                   fun() ->
                                                           %%send content
                                                           ssh_connection:send(ConnectionRef, ChannelId, <<Content/binary,0>>)
                                                   end) of
                                    ok -> wait_for_protocol_termination(ConnectionRef,ChannelId,Timeout);
                                    Err2 -> Err2
                                end;
                          Err -> Err
                      end;
                  Err3  -> Err3
              end
      end).

%%--------------------------------------------------------------------
%% @doc copies the binary Content as a file to the remote and place it in Destination, 
%% which must be an existing directory on the remote side,
%% using the supplied ssh connection, ConnectionRef. 
%% The file will end up with the supplied permission.
%% Connection timeout can also be specified.
%% This is a convenience method for to_file(ConnectionRef, Filename, Destination, Content,Opts).
%%
%% @spec to_file(ConnectionRef, Filename, Destination, Content, Timeout, Permission) -> ok | {error, Reason}
%% @end
%%--------------------------------------------------------------------
to_file(ConnectionRef, Filename, Destination, Content, Timeout, Permission) when is_binary(Content),is_integer(Timeout),is_list(Permission) ->
    ssh_scp:to_file(ConnectionRef, Filename, Destination, Content, #ssh_scp_opts{timeout=Timeout,mode=permission_string_to_file_mode(Permission)}).


%%--------------------------------------------------------------------  
%% Traverse directory structure recursively. And transfer files
%%--------------------------------------------------------------------  
traverse(ConnectionRef,ChannelId,AbsName, Opts,Timeout) when is_record(Opts, ssh_scp_opts) ->
    case file:read_file_info(AbsName,[{time,posix}]) of
        {ok, FileInfo} ->
            Permission = file_mode_to_permission_string(FileInfo#file_info.mode),
            MTime = time_to_use(Opts#ssh_scp_opts.mtime, FileInfo#file_info.mtime),
            ATime = time_to_use(Opts#ssh_scp_opts.atime, FileInfo#file_info.atime),

            case send_time_info(ConnectionRef,ChannelId,{MTime,ATime},Timeout) of
                ok ->
                    case  FileInfo#file_info.type of
                        directory  -> 
                            send_dir_start(ConnectionRef,ChannelId,filename:basename(AbsName),Permission,Timeout),
                            
                            {ok, Filenames} = file:list_dir(AbsName),
                            lists:foreach(fun(BaseName)-> traverse(ConnectionRef,ChannelId,filename:join(AbsName,BaseName),Opts,Timeout) end, Filenames),
                            
                            send_dir_end(ConnectionRef,ChannelId,filename:basename(AbsName),Timeout);
                        
                        regular ->
                            send_file(ConnectionRef,ChannelId,AbsName,AbsName,Permission,FileInfo#file_info.size,Timeout);
                        
                        symlink-> 
                            case follow_link(AbsName) of
                                {regular, LinkedName, LinkedFileInfo} ->
                                    send_file(ConnectionRef,ChannelId,LinkedName,AbsName,Permission,LinkedFileInfo#file_info.size,Timeout);
                                {directory, LinkedName, _LinkedFileInfo} ->
                                    send_dir_start(ConnectionRef,ChannelId,filename:basename(AbsName),Permission,Timeout),
                                    
                                    {ok, Filenames} = file:list_dir(LinkedName),
                                    lists:foreach(fun(BaseName)-> traverse(ConnectionRef,ChannelId,filename:join(LinkedName,BaseName),Opts,Timeout) end, Filenames),
                                    
                                    send_dir_end(ConnectionRef,ChannelId,filename:basename(AbsName),Timeout);
                                {error, ReasonL} -> {error, ReasonL}
                            end;
                        
                        Other_File_Type -> {error, list_to_binary(io_lib:format("Cannot transfer file type ~p",[Other_File_Type]))}
                    end;
                Err -> Err
            end;
        {error, Reason1} -> {error, Reason1}
    end.

%%--------------------------------------------------------------
%% selects the time to use, either from file info or ssh_scp option
%%--------------------------------------------------------------
time_to_use(undefined,FileTime) ->
    FileTime;
time_to_use(OptsTime,_FileTime) ->
    OptsTime.

%%--------------------------------------------------------------
%% send time info for following file as per scp protocol
%%--------------------------------------------------------------
send_time_info(ConnectionRef,ChannelId,TimeTuple,Timeout) ->
    case TimeTuple of
        {undefined,_} -> ok;
        {_,undefined} -> ok;
        {Mtime, Atime} ->
            send_content(ConnectionRef,ChannelId,Timeout,
                         fun() ->
                                 %%send header
                                 Header = list_to_binary(lists:flatten(io_lib:format("T~B 0 ~B 0~n",[Mtime,Atime]))),
                                 ssh_connection:send(ConnectionRef, ChannelId, Header)
                 end)
    end.


%%--------------------------------------------------------------
%% send directory start as specified in scp protocol
%%--------------------------------------------------------------
send_dir_start(ConnectionRef,ChannelId,Name,Permission,Timeout) ->
    send_content(ConnectionRef,ChannelId,Timeout,
                 fun() ->
                         %%send header
                         Header = list_to_binary(lists:flatten(io_lib:format("D~s ~p ~s~n",[Permission, 0, Name]))),
                         ssh_connection:send(ConnectionRef, ChannelId, Header)
                 end).
    
%%--------------------------------------------------------------
%% send directory end as specified in scp protocol
%%--------------------------------------------------------------
send_dir_end(ConnectionRef, ChannelId, _Name,Timeout) ->
    send_content(ConnectionRef,ChannelId,Timeout,
                 fun() ->
                         %%send end dir
                         Header = list_to_binary(lists:flatten(io_lib:format("E~n",[]))),
                         ssh_connection:send(ConnectionRef, ChannelId, Header)
                 end).

%%--------------------------------------------------------------
%% send file header as specified in scp protocol
%%--------------------------------------------------------------
send_file_header(ConnectionRef,ChannelId,Name,Permission,Size,Timeout) ->
    send_content(ConnectionRef,ChannelId,Timeout,
                 fun() ->
                         %%send header
                         Header = list_to_binary(lists:flatten(io_lib:format("C~s ~p ~s~n",[Permission, Size, Name]))),
                         ssh_connection:send(ConnectionRef, ChannelId, Header)
                 end).

%%--------------------------------------------------------------
%% transfer file
%%--------------------------------------------------------------
send_file(ConnectionRef,ChannelId,Name,TransferName,Permission,Size,Timeout) ->
    case file:open(Name, [read, binary, raw]) of
        {ok, Handle} -> 
            case  send_file_header(ConnectionRef,ChannelId,filename:basename(TransferName),Permission,Size,Timeout) of 
                ok -> TransferResult = send_file_in_chunks(ConnectionRef,ChannelId,Handle,Timeout),
                      file:close(Handle),
                      TransferResult;
                Err -> file:close(Handle), Err
            end;
        {error, Reason2} -> {error, Reason2}
    end.

%%--------------------------------------------------------------
%% transfer the file content in ssh connection packet size chunks
%%--------------------------------------------------------------
send_file_in_chunks(ConnectionRef,ChannelId,Handle,Timeout) ->
    case file:read(Handle, ?DEFAULT_PACKET_SIZE) of %% use packetsize as chunksize
        {ok, Content} -> 
            case ssh_connection:send(ConnectionRef, ChannelId, Content) of
                ok -> send_file_in_chunks(ConnectionRef,ChannelId,Handle,Timeout);
                Err -> Err
            end;
        eof -> send_content(ConnectionRef,ChannelId,Timeout,
                            fun() ->
                                    %%done send terminating 0
                                    ssh_connection:send(ConnectionRef, ChannelId, <<"\0">>)
                            end)
    end.

%%--------------------------------------------------------------
%% wait for terminating 0, to terminate transfer (or error)
%%--------------------------------------------------------------
wait_for_protocol_termination(ConnectionRef,ChannelId,Timeout) ->
    case send_content(ConnectionRef,ChannelId,Timeout, fun() -> ok end) of
        ok ->
            case ssh_connection:close(ConnectionRef, ChannelId) of
                ok ->
                    case send_content(ConnectionRef,ChannelId,Timeout, fun() -> ok end) of
                        ok -> send_content(ConnectionRef,ChannelId,Timeout, fun() -> ok end);
                        Err -> Err
                    end;
                Err -> Err
            end;
        Err -> Err
    end.
    
    
%%--------------------------------------------------------------------
%% @doc
%% implements the actual file transfer to the remote side
%% @end
%%--------------------------------------------------------------------
send_content(ConnectionRef,ChannelId,Timeout,Transfer) ->
    receive
        {ssh_cm, ConnectionRef, Msg} ->
            case Msg of
                {closed, _ChannelId} -> ok;
                {eof, _ChannelId} -> 
                    {error, <<"Error: EOF">>};
                {exit_signal, _ChannelId, ExitSignal, ErrorMsg, _LanguageString} ->
                    {error, list_to_binary(io_lib:format("Remote SCP exit signal: ~p : ~p",[ExitSignal,ErrorMsg]))};
                {exit_status,_ChannelId,ExitStatus} ->
                    case ExitStatus of
                        0 -> ok;
                        _ -> {error, list_to_binary(io_lib:format("Remote SCP exit status: ~p",[ExitStatus]))}
                    end;
                {data,_ChannelId,_Type,<<1,ErrorRest/binary>>} ->
                    {error, ErrorRest};
                {data,ChannelId,_Type,<<0>>} ->
                    Transfer()
            end
    after Timeout ->
            {error, list_to_binary(io_lib:format("Timeout: ~p",[Timeout]))}
    end.  


%%--------------------------------------------------------------------
%% @doc
%% establish channel
%% @end
%%--------------------------------------------------------------------
with_transfer_channel(ConnectionRef, Timeout, Destination, F) ->
    case ssh_connection:session_channel(ConnectionRef, Timeout) of
        {ok, ChannelId} ->
            Cmd = lists:flatten(io_lib:format("scp -trq ~s",[Destination])),
            case ssh_connection:exec(ConnectionRef, ChannelId, Cmd, Timeout) of 
                success ->
                    F(ChannelId);
                failure -> 
                    {error, <<"Failed to execute remote scp">>}
            end;
        {error, Reason} -> {error, Reason}
    end.
    

%%--------------------------------------------------------------------
%% @doc Converts a a file mode integer to a permission string like "0640"
%% or undefined if Mode passed is an atom
%%
%% @spec file_mode_to_permission_string(Mode) -> string() | undefined
%% @end
%%--------------------------------------------------------------------
file_mode_to_permission_string(Mode) when is_atom(Mode) ->
    undefined;
file_mode_to_permission_string(Mode) when is_integer(Mode), Mode >= 0, Mode =< 65535 ->
    <<_H1:4,H:3,O:3,G:3,R:3>> = <<Mode:16>>,
    lists:concat(io_lib:format("~B~B~B~B",[H,O,G,R])).

%%--------------------------------------------------------------------
%% @doc Converts a string like "0644" to an integer, which can be passed
%% as file mode in the record ssh_scp_opts
%%
%% @spec permission_string_to_file_mode(Permission) -> integer()
%% @end
%%--------------------------------------------------------------------
permission_string_to_file_mode(Permission) when is_list(Permission) ->
    <<Mode:16>> = lists:foldl(fun(C,Acc)-> <<Acc/bitstring,C:3>> end, <<0:4>>, Permission),
    Mode.

follow_link(Name) ->
    case file:read_link(Name) of
        {ok, LinkedName} -> 
            case file:read_file_info(LinkedName,[{time,posix}]) of
                {ok, FileInfo} ->
                    case  FileInfo#file_info.type of
                        directory  -> {directory, LinkedName, FileInfo};
                        regular  -> {regular,LinkedName, FileInfo};
                        symlink  -> follow_link(LinkedName);
                        Other_File_Type -> {error, list_to_binary(io_lib:format("Cannot transfer file type ~p",[Other_File_Type]))}
                    end;
                Err2 -> Err2
            end;
        Err -> Err
    end.
    

%%--------------------------------------------------------------------
%% TEST functions
%%--------------------------------------------------------------------
-ifdef(TEST).

ensure_started(App) ->
    case application:start(App) of
        ok ->
            ok;
        {error, {already_started, App}} ->
            ok
    end.

start_dependencies() ->
    ensure_started(asn1),
    ensure_started(public_key),
    ensure_started(crypto),
    ensure_started(ssh).

setup() ->
    start_dependencies(),
    {ok, CWD} = file:get_cwd(),
    ok = file:write_file("LinkedFile", "filel1"),
    ok = file:make_dir("LinkedDir"),
    ok = file:write_file("LinkedDir/FileL", "filel2"),
    ok = file:make_dir("DirA"),
    ok = file:write_file("DirA/FileA", "filea"),
    ok = file:make_dir("DirA/DirB"),
    ok = file:make_symlink(CWD++"/LinkedFile","DirA/DirB/LinkB"),
    ok = file:make_symlink(CWD++"/LinkedDir","DirA/DirB/LinkDirB"),
    ok = file:write_file("DirA/DirB/FileB", "fileb"),
    ok = file:make_dir("DirA/DirC"),
    ok = file:make_dir("DirA/DirC/DirD"),
    ok = file:write_file("DirA/DirC/DirD/FileD", "filed"),
    ssh:connect("localhost",22, ?LOCALHOST_PARAMS, 30000).
    
cleanup(SSHConnection) ->
    ok = file:delete("DirA/DirC/DirD/FileD"),
    ok = file:del_dir("DirA/DirC/DirD"),
    ok = file:del_dir("DirA/DirC"),
    ok = file:delete("DirA/DirB/FileB"),
    ok = file:delete("DirA/DirB/LinkB"),
    ok = file:delete("DirA/DirB/LinkDirB"),
    ok = file:del_dir("DirA/DirB"),
    ok = file:delete("DirA/FileA"),
    ok = file:del_dir("DirA"),
    ok = file:delete("LinkedFile"),
    ok = file:delete("LinkedDir/FileL"),
    ok = file:del_dir("LinkedDir"),
    {ok,ConnectionRef} = SSHConnection,
    ssh:close(ConnectionRef).
    

to_test_() ->
    { setup,
      fun setup/0,
      fun cleanup/1,
      fun (SSHConnection) -> 
              [
               ?_test(to_remote_larger_file(SSHConnection)),
               ?_test(to_remote_small_file(SSHConnection)),
               ?_test(to_remote_binary(SSHConnection)),
               ?_test(to_remote_file_explicit_timestamp(SSHConnection)),
               ?_test(to_remote_binary_excplicit_timestamp(SSHConnection)),
               ?_test(to_remote_directory(SSHConnection))
              ]
      end
    }.


to_remote_small_file(SSHConnection) ->
    ?debugFmt("to_remote_small_file Working Dir ~p",[file:get_cwd()]),
    LocalFilename = "./hello",
    Content = <<"Hello SCP">>,
    ok = file:write_file(LocalFilename, Content),
    {ok, ConnectionRef} = SSHConnection,
    ?debugFmt("Connection established ~p",[ConnectionRef]),
    ok = ssh_scp:to(ConnectionRef, LocalFilename,"/tmp"),
    {ok, Content} = file:read_file("/tmp/"++filename:basename(LocalFilename)),
    ok = file:delete(LocalFilename).

to_remote_file_explicit_timestamp(SSHConnection) ->
    ?debugFmt("to_remote_small_file Working Dir ~p",[file:get_cwd()]),
    LocalFilename = "./hello_ts",
    Content = <<"Hello SCP2">>,
    ok = file:write_file(LocalFilename, Content),
    {ok, ConnectionRef} = SSHConnection,
    ?debugFmt("Connection established ~p",[ConnectionRef]),
    Opts = #ssh_scp_opts{atime=10000000,mtime=12000000},
    ok = ssh_scp:to(ConnectionRef, LocalFilename,"/tmp",Opts),
    {ok,FileInfo} = file:read_file_info("/tmp/"++filename:basename(LocalFilename),[{time,posix}]),
    24000000 = FileInfo#file_info.mtime + Opts#ssh_scp_opts.mtime,
    20000000 = FileInfo#file_info.atime + Opts#ssh_scp_opts.atime,
    {ok, Content} = file:read_file("/tmp/"++filename:basename(LocalFilename)),
    ok = file:delete(LocalFilename).


%% Larger just means larger than packet size for channel
to_remote_larger_file(SSHConnection) ->
    ?debugFmt("to_remote_larger_file Working Dir ~p",[file:get_cwd()]),
    LocalFilename = "./bighello",
    Content = crypto:rand_bytes(84000),
    ok = file:write_file(LocalFilename, Content),
    {ok, ConnectionRef} = SSHConnection,
    ?debugFmt("Connection established ~p",[ConnectionRef]),
    ok = ssh_scp:to(ConnectionRef, LocalFilename,"/tmp"),
    {ok, Content} = file:read_file("/tmp/"++filename:basename(LocalFilename)),
    ok = file:delete(LocalFilename).

to_remote_binary(SSHConnection) ->
    ?debugFmt("to_remote_binary Working Dir ~p",[file:get_cwd()]),
    Filename = "binhello",
    Content = crypto:rand_bytes(84000),
    {ok, ConnectionRef} = SSHConnection,
    ok = ssh_scp:to_file(ConnectionRef,Filename,"/tmp",Content,"0666"),
    {ok, Content} = file:read_file("/tmp/"++Filename).

to_remote_binary_excplicit_timestamp(SSHConnection) ->
    ?debugFmt("to_remote_binary Working Dir ~p",[file:get_cwd()]),
    Filename = "binhello_ts",
    Content = crypto:rand_bytes(84000),
    {ok, ConnectionRef} = SSHConnection,
    Opts = #ssh_scp_opts{atime=10000000,mtime=12000000,mode=permission_string_to_file_mode("0666")},
    ok = ssh_scp:to_file(ConnectionRef,Filename,"/tmp",Content,Opts),
    {ok,FileInfo} = file:read_file_info("/tmp/"++Filename,[{time,posix}]),
    24000000 = FileInfo#file_info.mtime + Opts#ssh_scp_opts.mtime,
    20000000 = FileInfo#file_info.atime + Opts#ssh_scp_opts.atime,
    {ok, Content} = file:read_file("/tmp/"++Filename).


to_remote_directory(SSHConnection) ->
    ?debugFmt("to_remote_directory Working Dir ~p",[file:get_cwd()]),
    {ok, ConnectionRef} = SSHConnection,
    ?debugFmt("Connection established ~p",[ConnectionRef]),
    ok = ssh_scp:to(ConnectionRef, "DirA","/tmp"),
    {ok,DirA_FileInfo} = file:read_file_info("/tmp/DirA",[{time,posix}]),
    directory  = DirA_FileInfo#file_info.type,
    {ok,DirB_FileInfo} = file:read_file_info("/tmp/DirA/DirB",[{time,posix}]),
    directory  = DirB_FileInfo#file_info.type,
    {ok,DirC_FileInfo} = file:read_file_info("/tmp/DirA/DirC",[{time,posix}]),
    directory  = DirC_FileInfo#file_info.type,
    {ok,DirD_FileInfo} = file:read_file_info("/tmp/DirA/DirC/DirD",[{time,posix}]),
    directory  = DirD_FileInfo#file_info.type,
    {ok,FileD_FileInfo} = file:read_file_info("/tmp/DirA/DirC/DirD/FileD",[{time,posix}]),
    regular  = FileD_FileInfo#file_info.type,
    {ok,FileA_FileInfo} = file:read_file_info("/tmp/DirA/FileA",[{time,posix}]),
    regular  = FileA_FileInfo#file_info.type,
    {ok,FileB_FileInfo} = file:read_file_info("/tmp/DirA/DirB/FileB",[{time,posix}]),
    regular  = FileB_FileInfo#file_info.type,
    {ok,FileB_Content} = file:read_file("/tmp/DirA/DirB/FileB"),
    FileB_Content = <<"fileb">>,
    {ok,FileD_Content} = file:read_file("/tmp/DirA/DirC/DirD/FileD"),
    FileD_Content = <<"filed">>,
    {ok,FileA_Content} = file:read_file("/tmp/DirA/FileA"),
    FileA_Content = <<"filea">>,
    %%the links
    {ok,LinkB_FileInfo} = file:read_file_info("/tmp/DirA/DirB/LinkB",[{time,posix}]),
    regular  = LinkB_FileInfo#file_info.type,
    {ok,LinkB_FileInfo} = file:read_file_info("/tmp/DirA/DirB/LinkB",[{time,posix}]),
    regular  = LinkB_FileInfo#file_info.type,
    {ok,LinkDirB_FileInfo} = file:read_file_info("/tmp/DirA/DirB/LinkDirB",[{time,posix}]),
    directory = LinkDirB_FileInfo#file_info.type,
    {ok,LinkB_Content} = file:read_file("/tmp/DirA/DirB/LinkB"),
    LinkB_Content = <<"filel1">>,
    {ok,FileL_FileInfo} = file:read_file_info("/tmp/DirA/DirB/LinkDirB/FileL",[{time,posix}]),
    regular = FileL_FileInfo#file_info.type,
    {ok,FileL_Content} = file:read_file("/tmp/DirA/DirB/LinkDirB/FileL"),
    FileL_Content = <<"filel2">>.    
    

-endif.
