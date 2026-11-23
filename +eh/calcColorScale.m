function [cmin, cmax, cbtk] = calcColorScale(data, fullRange)
%CALCCOLORSCALE 自动计算热图 colorbar 范围与美观刻度（与 TS App 一致）。
if nargin < 2, fullRange = false; end
data_vec = data(:);
data_vec = data_vec(isfinite(data_vec));
if isempty(data_vec)
    cmin = 0; cmax = 1; cbtk = [0 0.5 1];
    return;
end

n = numel(data_vec);
trim_n = floor(0.03 * n);
full_min = min(data_vec);
full_max = max(data_vec);
data_min = full_min;
data_max = full_max;
if ~fullRange && trim_n > 0 && full_min < full_max
    lower = mink(data_vec, trim_n + 1);
    upper = maxk(data_vec, trim_n + 1);
    if lower(end) < upper(end)
        data_min = lower(end);
        data_max = upper(end);
    end
end

span = data_max - data_min;
if span == 0
    pad = max(0.5, eps(data_min));
elseif data_min < 0 && data_max > 0
    pad = 0.10 * span;
else
    pad = 0.05 * span;
end
cmin_raw = data_min - pad;
cmax_raw = data_max + pad;
if full_max <= 0 && full_min < 0
    cmax_raw = min(0, cmax_raw);
elseif full_min >= 0 && full_max > 0
    cmin_raw = max(0, cmin_raw);
end

range_val = cmax_raw - cmin_raw;
rough_step = range_val / 6;
if rough_step <= 0 || ~isfinite(rough_step), rough_step = 1; end
magnitude = 10^floor(log10(rough_step));
if ~isfinite(magnitude) || magnitude == 0, magnitude = 1; end
nice_steps = [0.1 0.2 0.3 0.5 1 2 3 4 5 10 15 25];
[~, idx] = min(abs(nice_steps - rough_step / magnitude));
step = magnitude * nice_steps(idx);
if step <= 0 || ~isfinite(step), step = 1; end

cmin = step * floor(cmin_raw / step);
cmax = step * ceil(cmax_raw / step);
if cmin >= cmax, cmax = cmin + step; end
if cmax - cmin >= step
    inner_ticks = cmin:step:cmax;
else
    inner_ticks = [];
end
cbtk = unique([cmin inner_ticks cmax]);
if numel(cbtk) < 2, cbtk = [cmin cmax]; end
end
