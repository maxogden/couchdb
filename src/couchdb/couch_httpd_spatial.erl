% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(couch_httpd_spatial).
-include("couch_db.hrl").
-include("couch_spatial.hrl").

-export([handle_spatial_req/3, spatial_group_etag/2, spatial_group_etag/3,
         load_index/3]).

-import(couch_httpd,
        [send_json/2, send_json/3, send_method_not_allowed/2, send_chunk/2,
         start_json_response/2, start_json_response/3, end_json_response/1]).

handle_spatial_req(#httpd{method='GET',
        path_parts=[_, _, DName, _, SpatialName]}=Req, Db, DDoc) ->
    ?LOG_DEBUG("Spatial query (~p): ~n~p", [DName, DDoc#doc.id]),
    #spatial_query_args{
        bbox = Bbox,
        stale = Stale
    } = QueryArgs = parse_spatial_params(Req),
    {ok, Index, Group} = couch_spatial:get_spatial_index(
                           Db, DDoc#doc.id, SpatialName, Stale),
    output_spatial_index(Req, Index, Group, Db, QueryArgs);

handle_spatial_req(Req, _Db, _DDoc) ->
    send_method_not_allowed(Req, "GET,HEAD").

load_index(Req, Db, {DesignId, SpatialName}) ->
    QueryArgs = parse_spatial_params(Req),
    Stale = QueryArgs#spatial_query_args.stale,
    case couch_spatial:get_spatial_index(Db, DesignId, SpatialName, Stale) of
    {ok, Index, Group} ->
          {ok, Index, Group, QueryArgs};
    {not_found, Reason} ->
        throw({not_found, Reason})
    end.

%output_spatial_index(Req, Index, Group, Db,
%                     QueryArgs#spatial_query_args{count=true}) ->
output_spatial_index(Req, Index, Group, Db, QueryArgs) when
      QueryArgs#spatial_query_args.count == true ->
    {ok, Count} = vtree:count_lookup(Group#spatial_group.fd,
                                     Index#spatial.treepos,
                                     QueryArgs#spatial_query_args.bbox),
    send_json(Req, Count);

% counterpart in couch_httpd_view is output_map_view/6
output_spatial_index(Req, Index, Group, Db, QueryArgs) ->
    CurrentEtag = spatial_group_etag(Group, Db),
    HelperFuns = #spatial_fold_helper_funs{
        start_response = fun json_spatial_start_resp/3,
        send_row = fun send_json_spatial_row/3
    },
    couch_httpd:etag_respond(Req, CurrentEtag, fun() ->
        FoldFun = make_spatial_fold_funs(
                    Req, QueryArgs, CurrentEtag, Db,
                    Group#spatial_group.current_seq, HelperFuns),
        FoldAccInit = {undefined, ""},
        {ok, {Resp, _Acc}} = couch_spatial:fold(
                       Group, Index, FoldFun, FoldAccInit,
                       QueryArgs#spatial_query_args.bbox),
        finish_spatial_fold(Req, Resp)
    end).

% counterpart in couch_httpd_view is make_view_fold/7
make_spatial_fold_funs(Req, QueryArgs, Etag, Db, UpdateSeq, HelperFuns) ->
    #spatial_fold_helper_funs{
        start_response = StartRespFun,
        send_row = SendRowFun
    } = HelperFuns,
    % The Acc is there to output characters that belong to the previous line,
    % but only if one line follows (think of a comma separated list which
    % doesn't have a comma at the last item)
    fun({Bbox, DocId, Value}, {Resp, Acc}) ->
        case Resp of
        undefined ->
            {ok, NewResp, BeginBody} = StartRespFun(Req, Etag, UpdateSeq),
            {ok, Acc2} = SendRowFun(NewResp, {Bbox, DocId, Value}, BeginBody),
            {ok, {NewResp, Acc2}};
        Resp ->
            {ok, Acc2} = SendRowFun(Resp, {Bbox, DocId, Value}, Acc),
            {ok, {Resp, Acc2}}
        end
    end.

% counterpart in couch_httpd_view is finish_view_fold/5
finish_spatial_fold(Req, Resp) ->
    case Resp of
    undefined ->
        send_json(Req, 200, {[]});
    Resp ->
        % end the index
        send_chunk(Resp, "\r\n]}"),
        end_json_response(Resp)
    end.

% counterpart in couch_httpd_view is json_view_start_resp/6
json_spatial_start_resp(Req, Etag, UpdateSeq) ->
    {ok, Resp} = start_json_response(Req, 200, [{"Etag", Etag}]),
    BeginBody = io_lib:format(
            "{\"update_seq\":~w,\"rows\":[\r\n", [UpdateSeq]),
    {ok, Resp, BeginBody}.

% counterpart in couch_httpd_view is send_json_view_row/5
send_json_spatial_row(Resp, {Bbox, DocId, Value}, RowFront) ->
    JsonObj = {[{<<"id">>, DocId},
                  {<<"bbox">>, erlang:tuple_to_list(Bbox)},
                  {<<"value">>, Value}]},
    send_chunk(Resp, RowFront ++  ?JSON_ENCODE(JsonObj)),
    {ok, ",\r\n"}.


% counterpart in couch_httpd_view is view_group_etag/2 resp. /3
spatial_group_etag(Group, Db) ->
    spatial_group_etag(Group, Db, nil).
spatial_group_etag(#spatial_group{sig=Sig, current_seq=CurrentSeq}, _Db, Extra) ->
    couch_httpd:make_etag({Sig, CurrentSeq, Extra}).

parse_spatial_params(Req) ->
    QueryList = couch_httpd:qs(Req),
    QueryParams = lists:foldl(fun({K, V}, Acc) ->
        parse_view_param(K, V) ++ Acc
    end, [], QueryList),
    _QueryArgs = lists:foldl(fun({K, V}, Args2) ->
        validate_spatial_query(K, V, Args2)
    end, #spatial_query_args{}, lists:reverse(QueryParams)).

parse_view_param("bbox", Bbox) ->
    [{bbox, list_to_tuple(?JSON_DECODE("[" ++ Bbox ++ "]"))}];
parse_view_param("stale", "ok") ->
    [{stale, ok}];
parse_view_param("stale", _Value) ->
    throw({query_parse_error, <<"stale only available as stale=ok">>});
parse_view_param("count", "true") ->
    [{count, true}];
parse_view_param("count", _Value) ->
    throw({query_parse_error, <<"count only available as count=true">>});
parse_view_param(Key, Value) ->
    [{extra, {Key, Value}}].

validate_spatial_query(bbox, Value, Args) ->
    Args#spatial_query_args{bbox=Value};
validate_spatial_query(stale, ok, Args) ->
    Args#spatial_query_args{stale=ok};
validate_spatial_query(count, true, Args) ->
    Args#spatial_query_args{count=true};
validate_spatial_query(stale, _, Args) ->
    Args;
validate_spatial_query(extra, _Value, Args) ->
    Args.
