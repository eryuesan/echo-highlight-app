function out = reviewState(action, varargin)
%REVIEWSTATE 非破坏性人工复核状态机。
%   保留不可变的自动检测快照 (autoBatch)，将所有人工操作记录在 edits 日志中，
%   并通过 materialize 实时生成复核后的候选表、代表峰表与计数表。
%
%   支持的 action:
%     'init'             : state = eh.reviewState('init', batch, signalSourceDesc, originalScaleUnknown)
%     'reject'           : state = eh.reviewState('reject', state, colPos, candId)
%     'accept'           : state = eh.reviewState('accept', state, colPos, candId)
%     'promote'          : state = eh.reviewState('promote', state, colPos, candId)
%     'add_manual'       : state = eh.reviewState('add_manual', state, colPos, manualPeak)
%     'undo'             : state = eh.reviewState('undo', state)
%     'archive_redetect' : state = eh.reviewState('archive_redetect', oldState, newBatch, signalSourceDesc, originalScaleUnknown)
%     'materialize'      : mat = eh.reviewState('materialize', state)
%     'column_view'      : cv = eh.reviewState('column_view', state, colPos)

switch lower(action)
    case 'init'
        batch = varargin{1};
        signalSourceDesc = '';
        if numel(varargin) >= 2, signalSourceDesc = char(varargin{2}); end
        scaleUnknown = false;
        if numel(varargin) >= 3, scaleUnknown = logical(varargin{3}); end

        state = struct();
        state.autoBatch = batch;
        state.signalSource = signalSourceDesc;
        state.originalScaleUnknown = scaleUnknown;
        state.edits = emptyEdits();
        state.nextEditId = 1;
        state.nextManualId = 100001;
        state.archivedReviews = {};
        state.hasArchivedWarning = false;
        out = state;

    case 'archive_redetect'
        oldState = varargin{1};
        newBatch = varargin{2};
        signalSourceDesc = '';
        if numel(varargin) >= 3, signalSourceDesc = char(varargin{3}); end
        scaleUnknown = false;
        if numel(varargin) >= 4, scaleUnknown = logical(varargin{4}); end

        newState = eh.reviewState('init', newBatch, signalSourceDesc, scaleUnknown);
        if ~isempty(oldState) && isstruct(oldState) && isfield(oldState, 'edits')
            prevArchive = {};
            if isfield(oldState, 'archivedReviews'), prevArchive = oldState.archivedReviews; end
            if ~isempty(oldState.edits)
                entry = struct( ...
                    'archivedAt', char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')), ...
                    'previousTimestamp', oldState.autoBatch.timestamp, ...
                    'previousParams', oldState.autoBatch.params, ...
                    'previousEdits', oldState.edits, ...
                    'note', '重新检测前自动归档的人工复核记录（需对照新结果核对是否仍适用）');
                prevArchive{end+1} = entry;
                newState.hasArchivedWarning = true;
            end
            newState.archivedReviews = prevArchive;
        end
        out = newState;

    case {'reject', 'accept', 'promote'}
        state = varargin{1};
        colPos = double(varargin{2});
        candId = double(varargin{3});
        edit = struct( ...
            'EditId', state.nextEditId, ...
            'Timestamp', char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')), ...
            'ColPos', colPos, ...
            'PulseIndex', state.autoBatch.pulseIndices(colPos), ...
            'RecordNumber', state.autoBatch.recordNumbers(colPos), ...
            'Action', lower(action), ...
            'CandidateId', candId, ...
            'ManualPeak', []);
        state.edits(end+1) = edit;
        state.nextEditId = state.nextEditId + 1;
        out = state;

    case 'add_manual'
        state = varargin{1};
        colPos = double(varargin{2});
        mp = varargin{3};
        mp.CandidateId = state.nextManualId;
        state.nextManualId = state.nextManualId + 1;
        edit = struct( ...
            'EditId', state.nextEditId, ...
            'Timestamp', char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')), ...
            'ColPos', colPos, ...
            'PulseIndex', state.autoBatch.pulseIndices(colPos), ...
            'RecordNumber', state.autoBatch.recordNumbers(colPos), ...
            'Action', 'add_manual', ...
            'CandidateId', mp.CandidateId, ...
            'ManualPeak', mp);
        state.edits(end+1) = edit;
        state.nextEditId = state.nextEditId + 1;
        out = state;

    case 'undo'
        state = varargin{1};
        if ~isempty(state.edits)
            state.edits(end) = [];
        end
        out = state;

    case 'column_view'
        state = varargin{1};
        colPos = double(varargin{2});
        out = buildColumnView(state, colPos);

    case 'materialize'
        state = varargin{1};
        out = materializeAll(state);

    otherwise
        error('echoHighlight:UnknownReviewAction', '不支持的复核操作：%s', action);
end
end

function cv = buildColumnView(state, colPos)
batch = state.autoBatch;
colAuto = batch.colResults{colPos};
refAmp = batch.normRefPerCol(colPos);

% 1. 从自动候选起步
nAuto = numel(colAuto.candidates);
items = repmat(emptyItem(), nAuto, 1);
for k = 1:nAuto
    c = colAuto.candidates(k);
    if c.AutoSelected
        rStatus = 'accepted';
    else
        rStatus = 'member_unselected';
    end
    items(k) = struct( ...
        'CandidateId', c.CandidateId, ...
        'WindowIndex', c.WindowIndex, ...
        'SegmentIndex', c.SegmentIndex, ...
        'SampleIndex', c.SampleIndex, ...
        'WindowSampleIndex', c.WindowSampleIndex, ...
        'Time_ms', c.Time_ms, ...
        'Amplitude_raw', c.Amplitude_raw, ...
        'Amplitude_norm', c.Amplitude_norm, ...
        'Prominence_raw', c.Prominence_raw, ...
        'Prominence_norm', c.Prominence_norm, ...
        'Width_ms', c.Width_ms, ...
        'Group', c.Group, ...
        'AutoSelected', logical(c.AutoSelected), ...
        'ReviewSelected', logical(c.AutoSelected), ...
        'ReviewStatus', rStatus, ...
        'Source', 'auto', ...
        'SignalSource', state.signalSource);
end

% 2. 按时间顺序回放本列的人工修改
colEdits = state.edits([state.edits.ColPos] == colPos);
manualAdded = 0;
manualRejected = 0;

for e = 1:numel(colEdits)
    ed = colEdits(e);
    switch ed.Action
        case 'reject'
            idx = find([items.CandidateId] == ed.CandidateId, 1);
            if ~isempty(idx)
                items(idx).ReviewSelected = false;
                items(idx).ReviewStatus = 'rejected';
            end
        case 'accept'
            idx = find([items.CandidateId] == ed.CandidateId, 1);
            if ~isempty(idx)
                items(idx).ReviewSelected = true;
                items(idx).ReviewStatus = 'accepted';
            end
        case 'promote'
            idx = find([items.CandidateId] == ed.CandidateId, 1);
            if ~isempty(idx)
                g = items(idx).Group;
                if g > 0
                    sameG = find([items.Group] == g);
                    for s = sameG(:).'
                        if s ~= idx && items(s).ReviewSelected
                            items(s).ReviewSelected = false;
                            items(s).ReviewStatus = 'member_unselected';
                        end
                    end
                end
                items(idx).ReviewSelected = true;
                items(idx).ReviewStatus = 'promoted';
            end
        case 'add_manual'
            mp = ed.ManualPeak;
            newItem = struct( ...
                'CandidateId', mp.CandidateId, ...
                'WindowIndex', mp.WindowIndex, ...
                'SegmentIndex', 0, ...
                'SampleIndex', mp.SampleIndex, ...
                'WindowSampleIndex', mp.WindowSampleIndex, ...
                'Time_ms', mp.Time_ms, ...
                'Amplitude_raw', mp.Amplitude_raw, ...
                'Amplitude_norm', mp.Amplitude_norm, ...
                'Prominence_raw', NaN, ...
                'Prominence_norm', NaN, ...
                'Width_ms', NaN, ...
                'Group', 0, ...
                'AutoSelected', false, ...
                'ReviewSelected', true, ...
                'ReviewStatus', 'manual_added', ...
                'Source', 'manual', ...
                'SignalSource', mp.SignalSource);
            items(end+1) = newItem; %#ok<AGROW>
    end
end

if ~isempty(items)
    items = items(:);
    [~, ord] = sort([items.Time_ms]);
    items = items(ord);
end

for k = 1:numel(items)
    if strcmp(items(k).Source, 'manual') && items(k).ReviewSelected
        manualAdded = manualAdded + 1;
    end
    if strcmp(items(k).Source, 'auto') && strcmp(items(k).ReviewStatus, 'rejected')
        manualRejected = manualRejected + 1;
    end
end

% 3. 提取复核后的代表亮点并重算同窗相对首峰延时与相邻间距
selIdx = find([items.ReviewSelected]);
nHigh = numel(selIdx);
highs = repmat(emptyHighItem(), nHigh, 1);
for h = 1:nHigh
    it = items(selIdx(h));
    if it.Group > 0
        gMembers = items([items.Group] == it.Group & strcmp({items.Source}, 'auto'));
        mCount = numel(gMembers);
        gStart = min([gMembers.Time_ms]);
        gEnd = max([gMembers.Time_ms]);
    else
        mCount = 1;
        gStart = it.Time_ms;
        gEnd = it.Time_ms;
    end
    highs(h) = struct( ...
        'Highlight', h, ...
        'CandidateId', it.CandidateId, ...
        'WindowIndex', it.WindowIndex, ...
        'SampleIndex', it.SampleIndex, ...
        'WindowSampleIndex', it.WindowSampleIndex, ...
        'Time_ms', it.Time_ms, ...
        'Amplitude_raw', it.Amplitude_raw, ...
        'Amplitude_norm', it.Amplitude_norm, ...
        'Prominence_raw', it.Prominence_raw, ...
        'Prominence_norm', it.Prominence_norm, ...
        'Width_ms', it.Width_ms, ...
        'Group', it.Group, ...
        'MergedPeakCount', mCount, ...
        'GroupStart_ms', gStart, ...
        'GroupEnd_ms', gEnd, ...
        'RelativeDelay_ms', NaN, ...
        'PreviousGap_ms', NaN, ...
        'AutoSelected', it.AutoSelected, ...
        'ReviewStatus', it.ReviewStatus, ...
        'Source', it.Source, ...
        'SignalSource', it.SignalSource);
end

if nHigh > 0
    winIds = unique([highs.WindowIndex]);
    for wi = 1:numel(winIds)
        inW = find([highs.WindowIndex] == winIds(wi));
        t0 = highs(inW(1)).Time_ms;
        for j = 1:numel(inW)
            hi = inW(j);
            highs(hi).RelativeDelay_ms = highs(hi).Time_ms - t0;
            if j == 1
                highs(hi).PreviousGap_ms = NaN;
            else
                highs(hi).PreviousGap_ms = highs(hi).Time_ms - highs(inW(j - 1)).Time_ms;
            end
        end
    end
end

cv = struct();
cv.colPos = colPos;
cv.pulseIndex = batch.pulseIndices(colPos);
cv.recordNumber = batch.recordNumbers(colPos);
cv.recordFile = batch.recordFiles{colPos};
cv.angle_deg = batch.angles_deg(colPos);
cv.status = colAuto.status;
cv.refAmp = refAmp;
cv.items = items;
cv.highlights = highs;
cv.autoCandidateCount = nAuto;
cv.autoHighlightCount = numel(colAuto.highlights);
cv.reviewedHighlightCount = nHigh;
cv.manualAddedCount = manualAdded;
cv.manualRejectedCount = manualRejected;
cv.editCount = numel(colEdits);
end

function mat = materializeAll(state)
batch = state.autoBatch;
nCols = numel(batch.pulseIndices);

candRows = {};
highRows = {};
countRows = cell(nCols, 12);
colViews = cell(1, nCols);

for c = 1:nCols
    cv = buildColumnView(state, c);
    colViews{c} = cv;

    countRows(c, :) = { ...
        cv.pulseIndex, cv.recordNumber, cv.recordFile, cv.angle_deg, ...
        cv.autoCandidateCount, cv.autoHighlightCount, cv.reviewedHighlightCount, ...
        cv.manualAddedCount, cv.manualRejectedCount, cv.editCount, ...
        cv.refAmp, cv.status};

    for k = 1:numel(cv.items)
        it = cv.items(k);
        candRows(end+1, :) = { ...
            cv.pulseIndex, cv.recordNumber, cv.recordFile, cv.angle_deg, ...
            it.CandidateId, it.WindowIndex, it.SampleIndex, it.WindowSampleIndex, ...
            it.Time_ms, it.Amplitude_raw, it.Amplitude_norm, ...
            it.Prominence_raw, it.Prominence_norm, it.Width_ms, ...
            batch.widthDefinition, it.Group, it.AutoSelected, it.ReviewSelected, ...
            it.ReviewStatus, it.Source, it.SignalSource, ...
            batch.normMode, cv.refAmp, state.originalScaleUnknown}; %#ok<AGROW>
    end

    for h = 1:numel(cv.highlights)
        hi = cv.highlights(h);
        highRows(end+1, :) = { ...
            cv.pulseIndex, cv.recordNumber, cv.recordFile, cv.angle_deg, ...
            hi.Highlight, hi.CandidateId, hi.WindowIndex, ...
            hi.SampleIndex, hi.WindowSampleIndex, hi.Time_ms, ...
            hi.RelativeDelay_ms, hi.PreviousGap_ms, ...
            hi.Amplitude_raw, hi.Amplitude_norm, ...
            hi.Prominence_raw, hi.Prominence_norm, hi.Width_ms, ...
            batch.widthDefinition, hi.Group, hi.MergedPeakCount, ...
            hi.GroupStart_ms, hi.GroupEnd_ms, ...
            hi.AutoSelected, hi.ReviewStatus, hi.Source, hi.SignalSource, ...
            batch.normMode, cv.refAmp, state.originalScaleUnknown}; %#ok<AGROW>
    end
end

candVarNames = {'PulseIndex', 'RecordNumber', 'RecordFile', 'Angle_deg', ...
    'CandidateId', 'WindowIndex', 'SampleIndex', 'WindowSampleIndex', ...
    'Time_ms', 'Amplitude_raw', 'Amplitude_norm', ...
    'Prominence_raw', 'Prominence_norm', 'Width_ms', ...
    'WidthDef', 'Group', 'AutoSelected', 'ReviewSelected', ...
    'ReviewStatus', 'Source', 'SignalSource', ...
    'NormMode', 'NormReference', 'OriginalScaleUnknown'};

highVarNames = {'PulseIndex', 'RecordNumber', 'RecordFile', 'Angle_deg', ...
    'Highlight', 'CandidateId', 'WindowIndex', ...
    'SampleIndex', 'WindowSampleIndex', 'Time_ms', ...
    'RelativeDelay_ms', 'PreviousGap_ms', ...
    'Amplitude_raw', 'Amplitude_norm', ...
    'Prominence_raw', 'Prominence_norm', 'Width_ms', ...
    'WidthDef', 'Group', 'MergedPeakCount', ...
    'GroupStart_ms', 'GroupEnd_ms', ...
    'AutoSelected', 'ReviewStatus', 'Source', 'SignalSource', ...
    'NormMode', 'NormReference', 'OriginalScaleUnknown'};

countVarNames = {'PulseIndex', 'RecordNumber', 'RecordFile', 'Angle_deg', ...
    'AutoCandidateCount', 'AutoHighlightCount', 'ReviewedHighlightCount', ...
    'ManualAddedCount', 'ManualRejectedCount', 'ManualEditCount', ...
    'NormReference', 'Status'};

if isempty(candRows)
    candTable = emptyTableWithSchema(candVarNames);
else
    candTable = cell2table(candRows, 'VariableNames', candVarNames);
end

if isempty(highRows)
    highTable = emptyTableWithSchema(highVarNames);
else
    highTable = cell2table(highRows, 'VariableNames', highVarNames);
end

countTable = cell2table(countRows, 'VariableNames', countVarNames);

mat = struct();
mat.candidatesTable = candTable;
mat.highlightsTable = highTable;
mat.countsTable = countTable;
mat.colViews = colViews;
end

function t = emptyTableWithSchema(varNames)
args = cell(1, numel(varNames));
for k = 1:numel(varNames)
    if ismember(varNames{k}, {'RecordFile', 'WidthDef', 'ReviewStatus', 'Source', 'SignalSource', 'NormMode', 'Status'})
        args{k} = cell(0, 1);
    elseif ismember(varNames{k}, {'AutoSelected', 'ReviewSelected', 'OriginalScaleUnknown'})
        args{k} = false(0, 1);
    else
        args{k} = zeros(0, 1);
    end
end
t = table(args{:}, 'VariableNames', varNames);
end

function s = emptyEdits()
s = struct('EditId', {}, 'Timestamp', {}, 'ColPos', {}, 'PulseIndex', {}, ...
    'RecordNumber', {}, 'Action', {}, 'CandidateId', {}, 'ManualPeak', {});
end

function s = emptyItem()
s = struct('CandidateId', {}, 'WindowIndex', {}, 'SegmentIndex', {}, ...
    'SampleIndex', {}, 'WindowSampleIndex', {}, 'Time_ms', {}, ...
    'Amplitude_raw', {}, 'Amplitude_norm', {}, 'Prominence_raw', {}, ...
    'Prominence_norm', {}, 'Width_ms', {}, 'Group', {}, ...
    'AutoSelected', {}, 'ReviewSelected', {}, 'ReviewStatus', {}, ...
    'Source', {}, 'SignalSource', {});
end

function s = emptyHighItem()
s = struct('Highlight', {}, 'CandidateId', {}, 'WindowIndex', {}, ...
    'SampleIndex', {}, 'WindowSampleIndex', {}, 'Time_ms', {}, ...
    'Amplitude_raw', {}, 'Amplitude_norm', {}, 'Prominence_raw', {}, ...
    'Prominence_norm', {}, 'Width_ms', {}, 'Group', {}, ...
    'MergedPeakCount', {}, 'GroupStart_ms', {}, 'GroupEnd_ms', {}, ...
    'RelativeDelay_ms', {}, 'PreviousGap_ms', {}, 'AutoSelected', {}, ...
    'ReviewStatus', {}, 'Source', {}, 'SignalSource', {});
end
