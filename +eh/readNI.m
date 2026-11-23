function dataset = readNI(selected, channel, progressFcn)
%READNI 读取 NI 采集文件夹（JSON + 逐脉冲通道 MAT 文件）。
%   dataset = eh.readNI(selected, channel, progressFcn)
%   - channel 为空时默认读取排序后的第一个通道，并返回所有可用通道列表。
%   - 始终保留真实脉冲号与文件名，缺号不静默改写。

if nargin < 2, channel = ''; end
if nargin < 3, progressFcn = []; end

assert(isfolder(selected), '未找到 NI 采集文件夹：%s', selected);
[~, id] = fileparts(selected);
jsonPath = fullfile(selected, [id '.json']);
assert(isfile(jsonPath), '目录中缺少采集参数文件 %s.json。', id);

meta = jsondecode(fileread(jsonPath));
assert(isfield(meta, 'SampleRate_Hz_') && isfield(meta, 'CollectTimes') && ...
    isfield(meta, 'SingalTime_ms_'), 'JSON 缺少必要采集字段。');
rate = double(meta.SampleRate_Hz_);
expectedCount = double(meta.CollectTimes);
samples = round(double(meta.SingalTime_ms_) * rate / 1000);
assert(rate > 0 && samples >= 2 && expectedCount >= 1 && expectedCount == fix(expectedCount), ...
    'JSON 采集参数无效。');

files = dir(fullfile(selected, [id '_*_ai*.mat']));
pattern = ['^' regexptranslate('escape', id) '_([1-9]\d*)_(ai\d+)\.mat$'];
tokens = regexp({files.name}, pattern, 'tokens', 'once');
validMask = ~cellfun(@isempty, tokens);
files = files(validMask);
tokens = tokens(validMask);
assert(~isempty(tokens), '目录中没有符合命名规则的 NI 通道 MAT 文件。');

allChannels = unique(cellfun(@(t) t{2}, tokens, 'UniformOutput', false));
[~, chOrder] = sort(cellfun(@(c) str2double(c(3:end)), allChannels));
allChannels = allChannels(chOrder);

if isempty(channel)
    channel = allChannels{1};
else
    assert(ismember(channel, allChannels), '目录中不存在通道 %s。', channel);
end

chMask = cellfun(@(t) strcmp(t{2}, channel), tokens);
chFiles = files(chMask);
chTokens = tokens(chMask);
recNums = cellfun(@(t) str2double(t{1}), chTokens);
[recNums, sortIdx] = sort(recNums);
chFiles = chFiles(sortIdx);
assert(numel(unique(recNums)) == numel(recNums), '检测到重复的 NI 脉冲编号。');

count = numel(chFiles);
values = zeros(samples, count);
filenames = cell(1, count);

for k = 1:count
    name = chFiles(k).name;
    filenames{k} = name;
    loaded = load(fullfile(selected, name));
    varNames = fieldnames(loaded);
    assert(isscalar(varNames), '文件 %s 中的信号变量不唯一。', name);
    v = loaded.(varNames{1});
    assert(isnumeric(v) && isreal(v) && isvector(v) && numel(v) == samples && ...
        all(isfinite(v(:))), '文件 %s 的波形或采样点数异常。', name);
    values(:, k) = double(v(:));
    if ~isempty(progressFcn) && (mod(k, 20) == 0 || k == count)
        progressFcn(k / count, sprintf('NI · %d / %d 次脉冲 · %s', k, count, channel));
    end
end

missingNums = setdiff(1:expectedCount, recNums);

dataset = struct();
dataset.values = values;
dataset.fs = rate;
dataset.timeSeconds = (0:samples-1)' / rate;
dataset.timeOrigin_s = 0;
dataset.isRelativeWindowTime = false;
dataset.isTruncatedWindow = false;
dataset.recordNumbers = recNums(:).';
dataset.recordFiles = filenames;
dataset.missingNumbers = missingNums(:).';
dataset.expectedCount = expectedCount;
dataset.folder = selected;
dataset.datasetName = id;
dataset.channel = channel;
dataset.channels = allChannels;
dataset.dataOrigin = 'NI';
dataset.inputType = '原始实波形';
dataset.originalScaleUnknown = false;
dataset.unitLabel = '幅值';
dataset.importedAngles = [];
dataset.missingMetadata = 0;
end
