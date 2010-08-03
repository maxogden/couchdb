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

-record(spatial_group, {       
    sig=nil,
    db=nil,
    fd=nil,
    name, % design document ID
    def_lang,
    design_options=[],
    indexes,
    id_btree=nil, % the back-index
    current_seq=0,
    purge_seq=0,
    query_server=nil
%    waiting_delayed_commit=nil
    }).

% It's the tree strucure of the spatial index
% The counterpart to #spatial in the view server is #view
-record(spatial, {
    root_dir=nil,
    seq=0,
    % XXX delete fds, it's not needed any longer
    fds=[],
    treepos=nil,
    btree=nil,
    id_num = 0, % comes from couch_spatial_group requirements
    def = nil, % The function in the query/view server
    index_names = []
}).

-record(spatial_index_header, {
    seq=0,
    purge_seq=0,
    id_btree_state=nil, % pointer/position in file to back-index
    index_states=nil % pointers/positions to the indexes
}).

-record(spatial_query_args, {
    bbox=nil,
    stale=nil,
    count=false
}).

-record(spatial_fold_helper_funs, {
    start_response,
    send_row
}).
