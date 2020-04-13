-module(rlx_tar).

-export([make_tar/3,
         format_error/1]).

-include("relx.hrl").
-include("rlx_log.hrl").

make_tar(Release, OutputDir, State) ->
    Name = rlx_release:name(Release),
    Vsn = rlx_release:vsn(Release),

    ?log_debug("beginning make_tar for release ~p-~s", [Name, Vsn]),
    IsRelxSasl = rlx_state:is_relx_sasl(State),

    ErtsVersion = rlx_release:erts(Release),

    OverlayVars = rlx_overlay:generate_overlay_vars(State, Release),
    OverlayFiles = overlay_files(OverlayVars, rlx_state:get(State, overlay, undefined), OutputDir),
    ConfigFiles = config_files(Vsn, OutputDir),

    StartClean = filename:join(["releases", Vsn, "start_clean.boot"]),
    NoDotErlang = filename:join(["releases", Vsn, "no_dot_erlang.boot"]),

    ExtraFiles = OverlayFiles ++ ConfigFiles ++
        [{StartClean, filename:join([OutputDir, StartClean])},
         {NoDotErlang, filename:join([OutputDir, NoDotErlang])},
         {filename:join(["releases", "start_erl.data"]),
          filename:join([OutputDir, "releases", "start_erl.data"])},
         {filename:join(["releases", "RELEASES"]),
          filename:join([OutputDir, "releases", "RELEASES"])},
         {"bin", filename:join([OutputDir, "bin"])}],

    SystemLibs = rlx_state:get(State, system_libs, true),

    Opts = [{path, [filename:join([OutputDir, "lib", "*", "ebin"])]},
            {dirs, app_dirs(State)},
            silent,
            {outdir, OutputDir} |
            case rlx_state:get(State, include_erts, true) of
                true ->
                    ErtsVersion = rlx_release:erts(Release),
                    ErtsDir = filename:join([OutputDir, "erts-" ++ ErtsVersion]),
                    case filelib:is_dir(ErtsDir) of
                        true ->
                            %% systools:make_tar looks for directory erts-vsn in
                            %% the dir passed to `erts'
                            [{erts, OutputDir}];
                        false ->
                            [{erts, code:root_dir()}]
                    end;
                false ->
                    [];
                ErtsDir ->
                    [{erts, ErtsDir}]
            end] ++ case IsRelxSasl of
                        true ->
                            %% file tuples for erl_tar:add are the reverse of erl_tar:create so swap them
                            [{extra_files, [{From, To} || {To, From} <- ExtraFiles]}];
                        false ->
                            []
                    end ++ case SystemLibs of
                               true ->
                                   [];
                               false ->
                                   [{variables, [{"SYSTEM_LIB_DIR", code:lib_dir()}]},
                                    {var_tar, omit}]
                           end,
    try systools:make_tar(filename:join([OutputDir, "releases", Vsn, Name]), Opts) of
        Result when Result =:= ok orelse (is_tuple(Result) andalso
                                          element(1, Result) =:= ok) ->
            maybe_print_warnings(Result),
            case IsRelxSasl of
                true ->
                    %% we used extra_files to copy in the overlays
                    %% nothing to do now but rename the tarball to <relname>-<vsn>.tar.gz
                    TarFile = filename:join(OutputDir, [Name, "-", Vsn, ".tar.gz"]),
                    file:rename(filename:join(OutputDir, [Name, ".tar.gz"]), TarFile),
                    {ok, State};
                false ->
                    %% unpack the tarball to a temporary directory and repackage it with
                    %% the overlays and other files we need to complete the target system
                    TempDir = rlx_file_utils:mkdtemp(),
                    try
                        update_tar(ExtraFiles, State, TempDir, OutputDir, Name, Vsn, ErtsVersion)
                    catch
                        ?WITH_STACKTRACE(Type, Exception, Stacktrace)
                           ?log_debug("exception updating tarball ~p:~p stacktrace=~p",
                                      [Type, Exception, Stacktrace]),
                           erlang:error(?RLX_ERROR({tar_update_error, Type, Exception}))
                    after
                        rlx_file_utils:remove(TempDir, [recursive])
                    end
            end;
        error ->
            erlang:error(?RLX_ERROR({tar_unknown_generation_error, Name, Vsn}));
        {error, Module, Errors} ->
            erlang:error(?RLX_ERROR({tar_generation_error, Module, Errors}))
    catch
        _:{badarg, Args} ->
            erlang:error(?RLX_ERROR({make_tar, {badarg, Args}}))
    end.

%% since we print the warnings already in `rlx_assemble' we just print these as debug logs
maybe_print_warnings({ok, Module, Warnings}) when Warnings =/= [] ->
    ?log_debug("Warnings generating release:~n~s", [Module:format_warning(Warnings)]);
maybe_print_warnings(_) ->
    ok.

format_error({make_tar, {badarg, Args}}) ->
    io_lib:format("Unknown args given to systools:make_tar/2: ~p", [Args]);
format_error({tar_unknown_generation_error, Module, Vsn}) ->
    io_lib:format("Tarball generation error of ~s ~s", [Module, Vsn]);
format_error({tar_update_error, Type, Exception}) ->
    io_lib:format("Exception updating contents of release tarball ~s:~s", [Type, Exception]);
format_error({tar_generation_error, Module, Errors}) ->
    io_lib:format("Tarball generation errors:~n~s", [Module:format_error(Errors)]).

%%

%% used to add additional files to the release tarball when using systools
%% before the `extra_files' feature was added to `make_tar'
update_tar(ExtraFiles, State, TempDir, OutputDir, Name, Vsn, ErtsVersion) ->
    TarFile = filename:join(OutputDir, [Name, "-", Vsn, ".tar.gz"]),
    ?log_debug("updating tarball ~s with extra files ~p", [TarFile, ExtraFiles]),
    IncludeErts = rlx_state:get(State, include_erts, true),
    file:rename(filename:join(OutputDir, [Name, ".tar.gz"]), TarFile),
    erl_tar:extract(TarFile, [{cwd, TempDir}, compressed]),
    ok =
        erl_tar:create(TarFile,
                       [{"releases", filename:join(TempDir, "releases")},
                        {filename:join(["releases", "start_erl.data"]),
                         filename:join([OutputDir, "releases", "start_erl.data"])},
                        {filename:join(["releases", "RELEASES"]),
                         filename:join([OutputDir, "releases", "RELEASES"])},
                        {"bin", filename:join([OutputDir, "bin"])} |
                        case IncludeErts of
                            false ->
                                [{"lib", filename:join(TempDir, "lib")}];
                            _ ->
                                [{"lib", filename:join(TempDir, "lib")},
                                 {"erts-"++ErtsVersion, filename:join(TempDir, "erts-"++ErtsVersion)}]
                        end]++ExtraFiles, [dereference,compressed]),
    ?log_debug("update tarball ~s completed", [TarFile]),
    {ok, State}.

%% include each of these config files if they exist
config_files(Vsn, OutputDir) ->
    VMArgs = {filename:join(["releases", Vsn, "vm.args"]),
              filename:join([OutputDir, "releases", Vsn, "vm.args"])},
    VMArgsSrc = {filename:join(["releases", Vsn, "vm.args.src"]),
                 filename:join([OutputDir, "releases", Vsn, "vm.args.src"])},

    %% when we drop support for OTP-20 we can require the use of .src files and not deal with .orig
    VMArgsOrig = {filename:join(["releases", Vsn, "vm.args.orig"]),
                  filename:join([OutputDir, "releases", Vsn, "vm.args.orig"])},
    SysConfigOrig = {filename:join(["releases", Vsn, "sys.config.orig"]),
                     filename:join([OutputDir, "releases", Vsn, "sys.config.orig"])},
    [{NameInArchive, Filename} || {NameInArchive, Filename} <- [VMArgsSrc, VMArgs, VMArgsOrig, SysConfigOrig],
                                  filelib:is_file(Filename)].

%% convert overlays to a list of {NameInArchive, Filename} tuples to pass to `erl_tar' or `make_tar'
overlay_files(_, undefined, _) ->
    [];
overlay_files(OverlayVars, Overlay, OutputDir) ->
    [begin
         To = to(O),
         File = rlx_overlay:render_string(OverlayVars, To),
         {rlx_util:to_string(File), rlx_util:to_string(filename:join(OutputDir, File))}
     end || O <- Overlay, filter(O)].

to({link, _, To}) ->
    To;
to({copy, From, "./"}) ->
    filename:basename(From);
to({copy, From, "."}) ->
    filename:basename(From);
to({copy, _, To}) ->
    To;
to({mkdir, To}) ->
    To;
to({template, _, To}) ->
    To.

filter({_, _, "bin/"++_}) ->
    false;
filter({link, _, _}) ->
    true;
filter({copy, _, _}) ->
    true;
filter({mkdir, _}) ->
    true;
filter({template, _, _}) ->
    true;
filter(_) ->
    false.

%% if `include_src' is true then include the `src' and `include' directories of each application
app_dirs(State) ->
    case include_src_or_default(State) of
        false ->
            [];
        true ->
            [include, src]
    end.

%% when running `tar' the default is to exclude src
include_src_or_default(State) ->
    case rlx_state:include_src(State) of
        undefined ->
            false;
        IncludeSrc ->
            IncludeSrc
    end.