function [segments, searchMask, interferenceMask] = buildSegments(time_ms, searchWindows_ms, maskZones_ms)
%BUILDSEGMENTS 校验搜索窗互不重叠，并将每个搜索窗减去干扰屏蔽区，生成连续有效段。
%   segments: struct 数组，字段包括
%     windowIndex, segmentIndex, start_ms, end_ms,
%     windowStartSample, sampleIndices

time_ms = double(time_ms(:));
nSamples = numel(time_ms);
assert(nSamples >= 1, '时间轴为空。');

if isempty(searchWindows_ms)
    segments = emptySegments();
    searchMask = false(nSamples, 1);
    interferenceMask = buildInterferenceMask(time_ms, maskZones_ms);
    return
end

assert(size(searchWindows_ms, 2) == 2 && all(isfinite(searchWindows_ms(:))), ...
    '搜索窗边界必须为有限数值。');

nWin = size(searchWindows_ms, 1);
for w = 1:nWin
    assert(searchWindows_ms(w, 2) > searchWindows_ms(w, 1), ...
        '搜索窗 %d 的结束时间必须大于起始时间。', w);
end

% 首版要求搜索窗互不重叠，重叠时明确指出冲突的窗号
for i = 1:nWin
    for j = i+1:nWin
        if searchWindows_ms(i, 1) < searchWindows_ms(j, 2) && ...
           searchWindows_ms(j, 1) < searchWindows_ms(i, 2)
            error('echoHighlight:WindowOverlap', ...
                '搜索窗 %d（%.4g–%.4g ms）与 搜索窗 %d（%.4g–%.4g ms）存在重叠，请分开各窗后再检测。', ...
                i, searchWindows_ms(i, 1), searchWindows_ms(i, 2), ...
                j, searchWindows_ms(j, 1), searchWindows_ms(j, 2));
        end
    end
end

interferenceMask = buildInterferenceMask(time_ms, maskZones_ms);
searchMask = false(nSamples, 1);
segments = emptySegments();
segCounter = 0;

for w = 1:nWin
    wStart = searchWindows_ms(w, 1);
    wEnd = searchWindows_ms(w, 2);
    inWin = time_ms >= wStart & time_ms <= wEnd;
    winIdx = find(inWin);
    if isempty(winIdx)
        continue
    end
    winStartSample = winIdx(1);
    validInWin = inWin & ~interferenceMask;
    searchMask = searchMask | validInWin;

    % 将 validInWin 拆分为连续的样本段，避免跨干扰区寻峰或合并
    d = diff([false; validInWin; false]);
    starts = find(d == 1);
    ends = find(d == -1) - 1;

    for s = 1:numel(starts)
        idx = (starts(s):ends(s)).';
        segCounter = segCounter + 1;
        segments(segCounter) = struct( ...
            'windowIndex', w, ...
            'segmentIndex', segCounter, ...
            'start_ms', time_ms(idx(1)), ...
            'end_ms', time_ms(idx(end)), ...
            'windowStartSample', winStartSample, ...
            'sampleIndices', idx);
    end
end
end

function mask = buildInterferenceMask(time_ms, maskZones_ms)
mask = false(numel(time_ms), 1);
if isempty(maskZones_ms)
    return
end
assert(size(maskZones_ms, 2) == 2 && all(isfinite(maskZones_ms(:))), ...
    '干扰屏蔽区边界必须为有限数值。');
for k = 1:size(maskZones_ms, 1)
    assert(maskZones_ms(k, 2) > maskZones_ms(k, 1), ...
        '干扰屏蔽区 %d 的结束时间必须大于起始时间。', k);
    mask = mask | (time_ms >= maskZones_ms(k, 1) & time_ms <= maskZones_ms(k, 2));
end
end

function s = emptySegments()
s = struct('windowIndex', {}, 'segmentIndex', {}, 'start_ms', {}, 'end_ms', {}, ...
    'windowStartSample', {}, 'sampleIndices', {});
end
