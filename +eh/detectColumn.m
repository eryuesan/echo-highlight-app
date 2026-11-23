function colOut = detectColumn(envRaw, time_ms, fs, segments, params, refAmp)
%DETECTCOLUMN 对单列包络在各连续有效段内独立寻峰、可选合并并选取代表峰。
%   envRaw   : 已平滑（若启用平滑）的原始尺度非负包络向量 (N×1)
%   time_ms  : 时间轴 (N×1, ms)
%   fs       : 采样率 (Hz)
%   segments : eh.buildSegments 输出的有效段数组
%   params   : 检测参数结构体
%   refAmp   : 归一化基准（<=0 表示全零信号）

colOut = struct();
colOut.status = 'ok';
colOut.refAmp = refAmp;
colOut.candidates = emptyCandidates();
colOut.highlights = emptyHighlights();

if isempty(segments)
    colOut.status = 'no_valid_data';
    return
end

allIdx = vertcat(segments.sampleIndices);
if isempty(allIdx) || ~all(isfinite(envRaw(allIdx)))
    colOut.status = 'no_valid_data';
    return
end

if ~isfinite(refAmp) || refAmp <= 0
    colOut.status = 'zero_signal';
    return
end

envNorm = envRaw / refAmp;
minProm = double(params.minProminence);
minDistSamples = max(1, round(double(params.minDistance_ms) * 1e-3 * fs));
minHeight = -Inf;
if isfield(params, 'minHeight') && isfinite(params.minHeight)
    minHeight = double(params.minHeight);
end
enableMerge = isfield(params, 'enableMerge') && logical(params.enableMerge);
mergeGap_ms = 2.0;
if isfield(params, 'mergeGap_ms') && isfinite(params.mergeGap_ms)
    mergeGap_ms = double(params.mergeGap_ms);
end
mergeSamples = max(0, round(mergeGap_ms * 1e-3 * fs));

candSample = zeros(0, 1);
candWinSample = zeros(0, 1);
candWinIdx = zeros(0, 1);
candSegIdx = zeros(0, 1);
candAmpRaw = zeros(0, 1);
candAmpNorm = zeros(0, 1);
candPromNorm = zeros(0, 1);
candPromRaw = zeros(0, 1);
candWidthMs = zeros(0, 1);

for s = 1:numel(segments)
    segIdx = segments(s).sampleIndices;
    if numel(segIdx) < 3
        continue
    end
    segVal = envNorm(segIdx);
    if all(segVal == segVal(1))
        continue
    end

    if minDistSamples < numel(segVal)
        [pks, locs, widths, proms] = findpeaks(segVal, ...
            'MinPeakProminence', minProm, ...
            'MinPeakDistance', minDistSamples, ...
            'MinPeakHeight', minHeight, ...
            'WidthReference', 'halfprom');
    else
        % 段长小于等于最小峰间距时，该段至多保留 1 个最高候选峰
        [pks, locs, widths, proms] = findpeaks(segVal, ...
            'MinPeakProminence', minProm, ...
            'MinPeakHeight', minHeight, ...
            'WidthReference', 'halfprom');
        if numel(pks) > 1
            [~, best] = max(pks);
            pks = pks(best); locs = locs(best);
            widths = widths(best); proms = proms(best);
        end
    end

    if isempty(locs)
        continue
    end
    fullIdx = segIdx(locs(:));
    winIdx = repmat(segments(s).windowIndex, numel(fullIdx), 1);
    segId = repmat(segments(s).segmentIndex, numel(fullIdx), 1);
    winLoc = fullIdx - segments(s).windowStartSample + 1;

    candSample = [candSample; fullIdx]; %#ok<AGROW>
    candWinSample = [candWinSample; winLoc]; %#ok<AGROW>
    candWinIdx = [candWinIdx; winIdx]; %#ok<AGROW>
    candSegIdx = [candSegIdx; segId]; %#ok<AGROW>
    candAmpNorm = [candAmpNorm; pks(:)]; %#ok<AGROW>
    candAmpRaw = [candAmpRaw; envRaw(fullIdx)]; %#ok<AGROW>
    candPromNorm = [candPromNorm; proms(:)]; %#ok<AGROW>
    candPromRaw = [candPromRaw; proms(:) * refAmp]; %#ok<AGROW>
    candWidthMs = [candWidthMs; widths(:) / fs * 1e3]; %#ok<AGROW>
end

if isempty(candSample)
    colOut.status = 'ok_zero_peaks';
    return
end

[candSample, order] = sort(candSample);
candWinSample = candWinSample(order);
candWinIdx = candWinIdx(order);
candSegIdx = candSegIdx(order);
candAmpRaw = candAmpRaw(order);
candAmpNorm = candAmpNorm(order);
candPromNorm = candPromNorm(order);
candPromRaw = candPromRaw(order);
candWidthMs = candWidthMs(order);
candTimeMs = time_ms(candSample);
nCand = numel(candSample);

% 分组与代表峰选择（不跨屏蔽区/不同连续有效段合并）
groupNum = zeros(nCand, 1);
if enableMerge
    gCount = 0;
    for k = 1:nCand
        if k == 1
            gCount = 1;
        else
            sameSeg = (candSegIdx(k) == candSegIdx(k - 1));
            gapSamples = candSample(k) - candSample(k - 1);
            if ~sameSeg || gapSamples > mergeSamples
                gCount = gCount + 1;
            end
        end
        groupNum(k) = gCount;
    end
else
    groupNum = (1:nCand).';
    gCount = nCand;
end

isSelected = false(nCand, 1);
cands = repmat(emptyCandidates(), nCand, 1);
for k = 1:nCand
    cands(k) = struct( ...
        'CandidateId', k, ...
        'WindowIndex', candWinIdx(k), ...
        'SegmentIndex', candSegIdx(k), ...
        'SampleIndex', candSample(k), ...
        'WindowSampleIndex', candWinSample(k), ...
        'Time_ms', candTimeMs(k), ...
        'Amplitude_raw', candAmpRaw(k), ...
        'Amplitude_norm', candAmpNorm(k), ...
        'Prominence_raw', candPromRaw(k), ...
        'Prominence_norm', candPromNorm(k), ...
        'Width_ms', candWidthMs(k), ...
        'Group', groupNum(k), ...
        'AutoSelected', false, ...
        'Source', 'auto');
end

highs = repmat(emptyHighlights(), gCount, 1);
for g = 1:gCount
    members = find(groupNum == g);
    best = members(1);
    for m = 2:numel(members)
        idx = members(m);
        if candPromNorm(idx) > candPromNorm(best)
            best = idx;
        elseif candPromNorm(idx) == candPromNorm(best)
            if candAmpNorm(idx) > candAmpNorm(best)
                best = idx;
            end
        end
    end
    isSelected(best) = true;
    cands(best).AutoSelected = true;

    highs(g) = struct( ...
        'Highlight', g, ...
        'CandidateId', best, ...
        'WindowIndex', candWinIdx(best), ...
        'SegmentIndex', candSegIdx(best), ...
        'SampleIndex', candSample(best), ...
        'WindowSampleIndex', candWinSample(best), ...
        'Time_ms', candTimeMs(best), ...
        'Amplitude_raw', candAmpRaw(best), ...
        'Amplitude_norm', candAmpNorm(best), ...
        'Prominence_raw', candPromRaw(best), ...
        'Prominence_norm', candPromNorm(best), ...
        'Width_ms', candWidthMs(best), ...
        'Group', g, ...
        'MergedPeakCount', numel(members), ...
        'GroupStart_ms', candTimeMs(members(1)), ...
        'GroupEnd_ms', candTimeMs(members(end)), ...
        'MemberIds', {members(:).'}, ...
        'RelativeDelay_ms', NaN, ...
        'PreviousGap_ms', NaN, ...
        'Source', 'auto');
end

% 计算同窗内相对首代表峰延时与相邻代表峰间距（ms）
winIds = unique([highs.WindowIndex]);
for wi = 1:numel(winIds)
    inW = find([highs.WindowIndex] == winIds(wi));
    t0 = highs(inW(1)).Time_ms;
    for j = 1:numel(inW)
        hIdx = inW(j);
        highs(hIdx).RelativeDelay_ms = highs(hIdx).Time_ms - t0;
        if j == 1
            highs(hIdx).PreviousGap_ms = NaN;
        else
            highs(hIdx).PreviousGap_ms = highs(hIdx).Time_ms - highs(inW(j - 1)).Time_ms;
        end
    end
end

colOut.candidates = cands;
colOut.highlights = highs;
end

function s = emptyCandidates()
s = struct('CandidateId', {}, 'WindowIndex', {}, 'SegmentIndex', {}, ...
    'SampleIndex', {}, 'WindowSampleIndex', {}, 'Time_ms', {}, ...
    'Amplitude_raw', {}, 'Amplitude_norm', {}, 'Prominence_raw', {}, ...
    'Prominence_norm', {}, 'Width_ms', {}, 'Group', {}, 'AutoSelected', {}, ...
    'Source', {});
end

function s = emptyHighlights()
s = struct('Highlight', {}, 'CandidateId', {}, 'WindowIndex', {}, 'SegmentIndex', {}, ...
    'SampleIndex', {}, 'WindowSampleIndex', {}, 'Time_ms', {}, ...
    'Amplitude_raw', {}, 'Amplitude_norm', {}, 'Prominence_raw', {}, ...
    'Prominence_norm', {}, 'Width_ms', {}, 'Group', {}, 'MergedPeakCount', {}, ...
    'GroupStart_ms', {}, 'GroupEnd_ms', {}, 'MemberIds', {}, ...
    'RelativeDelay_ms', {}, 'PreviousGap_ms', {}, 'Source', {});
end
