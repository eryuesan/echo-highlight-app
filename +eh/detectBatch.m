function batch = detectBatch(envelopeMat, timeSeconds, fs, pulseIndices, recordNumbers, recordFiles, angles_deg, searchWindows_ms, maskZones_ms, params, progressFcn)
%DETECTBATCH 对选定脉冲范围执行逐列亮点检测，支持共享/逐列归一化与进度取消。

if nargin < 11, progressFcn = []; end

time_ms = double(timeSeconds(:)) * 1e3;
pulseIndices = double(pulseIndices(:).');
nSelected = numel(pulseIndices);
assert(nSelected >= 1, '请至少选择 1 次脉冲。');

[segments, searchMask, interferenceMask] = eh.buildSegments(time_ms, searchWindows_ms, maskZones_ms);

% 可选滑动平均平滑（单位 ms，0 表示关闭）
smooth_ms = 0;
if isfield(params, 'smooth_ms') && isfinite(params.smooth_ms)
    smooth_ms = max(0, double(params.smooth_ms));
end
smoothSamples = round(smooth_ms * 1e-3 * fs);
if smooth_ms > 0 && smoothSamples > 1
    smoothedSelected = movmean(double(envelopeMat(:, pulseIndices)), smoothSamples, 1);
else
    smoothSamples = 1;
    smoothedSelected = double(envelopeMat(:, pulseIndices));
end

normMode = 'batch';
if isfield(params, 'normMode') && ~isempty(params.normMode)
    normMode = lower(char(params.normMode));
end
normScope = 'search_windows';
if isfield(params, 'normScope') && ~isempty(params.normScope)
    normScope = lower(char(params.normScope));
end

% 计算归一化基准
refPerCol = zeros(1, nSelected);
if strcmp(normScope, 'full_record')
    refMask = true(numel(time_ms), 1);
    scopeDesc = '整条记录';
else
    refMask = searchMask;
    scopeDesc = sprintf('%d 个搜索窗有效段', size(searchWindows_ms, 1));
end

if strcmp(normMode, 'batch')
    if any(refMask)
        block = smoothedSelected(refMask, :);
        finiteBlock = block(isfinite(block));
        if isempty(finiteBlock)
            batchRef = 0;
        else
            batchRef = max(finiteBlock);
        end
    else
        batchRef = 0;
    end
    refPerCol(:) = batchRef;
    normDesc = sprintf('批次共用基准（脉冲 %d–%d，%s，基准=%.5g）', ...
        pulseIndices(1), pulseIndices(end), scopeDesc, batchRef);
else
    for k = 1:nSelected
        if any(refMask)
            v = smoothedSelected(refMask, k);
            fv = v(isfinite(v));
            if isempty(fv)
                refPerCol(k) = 0;
            else
                refPerCol(k) = max(fv);
            end
        else
            refPerCol(k) = 0;
        end
    end
    normDesc = sprintf('逐列归一化（%s）', scopeDesc);
end

colResults = cell(1, nSelected);
lastPct = -1;
for k = 1:nSelected
    colResults{k} = eh.detectColumn(smoothedSelected(:, k), time_ms, fs, segments, params, refPerCol(k));
    pct = floor(100 * k / nSelected);
    if ~isempty(progressFcn) && (pct ~= lastPct || k == nSelected)
        progressFcn(k / nSelected, sprintf('逐脉冲检测  %d%%  （%d / %d）', pct, k, nSelected));
        lastPct = pct;
    end
end

if isempty(angles_deg)
    anglesOut = nan(1, nSelected);
else
    anglesOut = double(angles_deg(:).');
end

batch = struct();
batch.timestamp = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));
batch.fs = fs;
batch.timeSeconds = double(timeSeconds(:));
batch.time_ms = time_ms;
batch.pulseIndices = pulseIndices;
batch.recordNumbers = double(recordNumbers(pulseIndices));
batch.recordFiles = recordFiles(pulseIndices);
batch.angles_deg = anglesOut;
batch.searchWindows_ms = searchWindows_ms;
batch.maskZones_ms = maskZones_ms;
batch.segments = segments;
batch.searchMask = searchMask;
batch.interferenceMask = interferenceMask;
batch.params = params;
batch.smoothSamples = smoothSamples;
batch.smoothedEnvelope = smoothedSelected;
batch.normMode = normMode;
batch.normScope = normScope;
batch.normRefPerCol = refPerCol;
batch.normDescription = normDesc;
batch.widthDefinition = 'halfprom (ms)';
batch.colResults = colResults;
end
