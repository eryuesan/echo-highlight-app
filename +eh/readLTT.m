function dataset = readLTT(selected, channel, progressFcn)
%READLTT 读取 LTT 工况文件夹（逐记录 CSV + 同名 TXT 校验）。
%   dataset = eh.readLTT(selected, channel, progressFcn)
%   - 保留原始 M 采集序号与文件名，不静默填补或改写缺号。

if nargin < 2, channel = ''; end
if nargin < 3, progressFcn = []; end

assert(isfolder(selected), '未找到 LTT 工况文件夹：%s', selected);
files = dir(fullfile(selected, '*.csv'));
if isempty(files)
    child = fullfile(selected, '00000');
    files = dir(fullfile(child, '*.csv'));
    assert(~isempty(files), '%s：未找到 CSV。请选择一个 LTT 工况或其 00000 子目录。', selected);
    selected = child;
end

tokens = regexp({files.name}, '^(.*)_M(\d+)\.csv$', 'tokens', 'once', 'ignorecase');
bad = find(cellfun(@isempty, tokens), 1);
assert(isempty(bad), '%s：文件名须以 _M采集序号.csv 结尾。', files(bad).name);

prefixes = cellfun(@(t) t{1}, tokens, 'UniformOutput', false);
assert(isscalar(unique(prefixes)), '%s：检测到不同采集文件前缀，请将不同工况分开。', selected);

indices = cellfun(@(t) str2double(t{2}), tokens);
assert(all(isfinite(indices)) && numel(unique(indices)) == numel(indices), ...
    '%s：M 采集序号无效或重复。', selected);
[indices, order] = sort(indices);
files = files(order);

count = numel(files);
missingMetadata = 0;
baseline = [];
channelNames = {};
sampleRate = NaN;
channelIndex = 1;
values = [];

for k = 1:count
    if ~isempty(progressFcn)
        progressFcn((k - 1) / count, sprintf('LTT · %d / %d 次采集', k, count));
    end
    csvPath = fullfile(selected, files(k).name);
    try
        [times, channels, volts, rate] = readLTTRecord(csvPath);
        if k == 1
            baseline = times;
            channelNames = channels;
            sampleRate = rate;
            if isempty(channel)
                channel = channels{1};
            end
            channelIndex = find(strcmp(channels, channel), 1);
            assert(~isempty(channelIndex), '找不到所选通道 %s。', channel);
            values = zeros(numel(times), count);
        else
            assert(isequal(channels, channelNames), '电压通道名称或顺序与首个文件不一致。');
            assert(numel(times) == numel(baseline), ...
                '采样点数与首个文件不一致（%d / %d）。', numel(times), numel(baseline));
            tol = max(1e-12, 1 / sampleRate * 1e-5);
            assert(all(abs(times - baseline) <= tol), '时间轴与首个文件不一致。');
        end
        hasMeta = checkLTTMetadata(csvPath, rate, numel(times), numel(channels));
        missingMetadata = missingMetadata + ~hasMeta;
        values(:, k) = volts(:, channelIndex); %#ok<AGROW>
    catch err
        error('echoHighlight:LTTRecord', '%s：%s', files(k).name, err.message);
    end
    if ~isempty(progressFcn)
        progressFcn(k / count, sprintf('LTT · %d / %d 次采集 · %s', k, count, channel));
    end
end

[~, id] = fileparts(selected);
if strcmp(id, '00000')
    [~, id] = fileparts(fileparts(selected));
end

dataset = struct();
dataset.values = values;
dataset.fs = sampleRate;
dataset.timeSeconds = baseline(:);
dataset.timeOrigin_s = baseline(1);
dataset.isRelativeWindowTime = false;
dataset.isTruncatedWindow = false;
dataset.recordNumbers = indices(:).';
dataset.recordFiles = {files.name};
dataset.missingNumbers = [];
dataset.expectedCount = count;
dataset.folder = selected;
dataset.datasetName = id;
dataset.channel = channel;
dataset.channels = channelNames;
dataset.dataOrigin = 'LTT';
dataset.inputType = '原始实波形';
dataset.originalScaleUnknown = false;
dataset.unitLabel = '电压 / V';
dataset.importedAngles = [];
dataset.missingMetadata = missingMetadata;
end

function [times, channels, volts, rate] = readLTTRecord(path)
fid = fopen(path, 'rt');
assert(fid >= 0, '无法打开文件。');
cleanup = onCleanup(@() fclose(fid));
header = fgetl(fid);
assert(ischar(header), 'CSV 为空。');
header = erase(header, char(65279));
headers = strtrim(strsplit(header, ';'));
headers = cellfun(@(s) strtrim(erase(s, '"')), headers, 'UniformOutput', false);

timeIndex = find(strcmpi(headers, 'Time [s]'));
assert(isscalar(timeIndex), '表头须有且仅有一列 Time [s]。');
voltageTokens = regexp(headers, '^(.+?)\s*\[V\]$', 'tokens', 'once');
voltageIndex = find(~cellfun(@isempty, voltageTokens));
assert(~isempty(voltageIndex), '表头未找到单位为 [V] 的电压通道。');
channels = cellfun(@(t) strtrim(t{1}), voltageTokens(voltageIndex), 'UniformOutput', false);
assert(numel(unique(channels)) == numel(channels), '电压通道名重复。');

data = readmatrix(path, 'Delimiter', ';', 'NumHeaderLines', 1, 'FileType', 'text');
assert(size(data, 2) == numel(headers) && size(data, 1) >= 2, ...
    'CSV 数据列数与表头不符或不足两个采样点。');
times = data(:, timeIndex);
volts = data(:, voltageIndex);
assert(all(isfinite(times)) && all(isfinite(volts(:))), '时间或电压存在缺失或非有限值。');
intervals = diff(times);
assert(all(intervals > 0), '时间列必须严格递增。');
dt = mean(intervals);
assert(all(abs(intervals - dt) <= max(1e-12, dt * 1e-5)), '时间列不是等间隔采样。');
rate = 1 / dt;
assert(isfinite(rate) && rate > 0, '时间列无法确定有效采样率。');
end

function available = checkLTTMetadata(csvPath, rate, samples, channels)
[parent, name] = fileparts(csvPath);
path = fullfile(parent, [name '.txt']);
available = isfile(path);
if ~available, return; end
metadata = fileread(path);
number = '([0-9]+(?:\.[0-9]*)?(?:[eE][+-]?\d+)?)';

token = regexpi(metadata, ['Timebase:\s*' number '\s*(GHz|MHz|kHz|Hz)'], 'tokens', 'once');
if ~isempty(token)
    units = {'hz', 'khz', 'mhz', 'ghz'};
    multiplier = 1000^(find(strcmpi(token{2}, units), 1) - 1);
    value = str2double(token{1}) * multiplier;
    mantissa = regexp(token{1}, '^\d+(?:\.(\d*))?', 'tokens', 'once');
    decimals = 0;
    if ~isempty(mantissa) && ~isempty(mantissa{1}), decimals = numel(mantissa{1}); end
    exponent = regexp(token{1}, '[eE]([+-]?\d+)', 'tokens', 'once');
    power = 0;
    if ~isempty(exponent), power = str2double(exponent{1}); end
    tol = 0.5 * 10^(power - decimals) * multiplier + rate * 1e-8;
    assert(abs(rate - value) <= tol, 'TXT Timebase 频率与 CSV 不一致（TXT %g Hz，CSV %g Hz）。', value, rate);
end

period = regexpi(metadata, ['Timebase:[^\r\n]*\(\s*' number '\s*(ns|us|µs|μs|ms|s)\s*\)'], 'tokens', 'once');
if ~isempty(period)
    switch lower(period{2})
        case 'ns', factor = 1e-9;
        case {'us', 'µs', 'μs'}, factor = 1e-6;
        case 'ms', factor = 1e-3;
        otherwise, factor = 1;
    end
    dt = str2double(period{1}) * factor;
    assert(abs(dt - 1 / rate) <= max(1e-12, dt * 1e-5), 'TXT Timebase 采样间隔与 CSV 不一致。');
end

token = regexpi(metadata, 'Sequences:\s*(\d+)(?:\s*\[\s*(\d+)\s+channels?\s+each\])?', 'tokens', 'once');
if ~isempty(token)
    assert(str2double(token{1}) == samples, ...
        'TXT Sequences 与 CSV 点数不一致（TXT %s，CSV %d）。', token{1}, samples);
    if numel(token) > 1 && ~isempty(token{2})
        assert(str2double(token{2}) == channels, 'TXT 通道数与 CSV 电压通道数不一致。');
    end
end
end
