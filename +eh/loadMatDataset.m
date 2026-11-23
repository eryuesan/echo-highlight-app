function dataset = loadMatDataset(matPath, opts)
%LOADMATDATASET 按用户确认的预览配置从 MAT 文件构造标准 dataset 结构体。
%   opts 字段：
%     matrixVar            - 矩阵变量名（必填）
%     transposeMatrix      - 是否转置（默认 false；每列为一次脉冲）
%     timeMode             - 'vector' | 'fs'（默认 'fs'）
%     timeVar              - timeMode=='vector' 时的时间向量变量名
%     timeUnit             - 's' | 'ms'（默认 's'）
%     fs_Hz                - timeMode=='fs' 时的采样率
%     t0_ms                - 起始时间 / 窗起点 (ms)，默认 0
%     indexOrigin          - '0' 表示 t0 + (0:N-1)/fs；'1' 表示 t0 + (1:N)/fs（适配练习05/09）
%     isRelativeWindowTime - logical，是否仅相对窗首时间
%     isTruncatedWindow    - logical，是否已截窗片段
%     inputType            - '原始实波形'|'带通波形'|'复解析信号'|'匹配输出'|'幅值包络'
%     originalScaleUnknown - logical，输入是否已归一化/原始尺度未知
%     axisVar              - 可选脉冲号或角度变量名（空表示按 1:M）
%     axisKind             - 'pulse' | 'angle'（默认 'pulse'）

assert(isfile(matPath), '未找到 MAT 文件：%s', matPath);
loaded = load(matPath);
assert(isfield(loaded, opts.matrixVar), 'MAT 文件中不存在变量 %s。', opts.matrixVar);

rawMat = double(loaded.(opts.matrixVar));
assert(isnumeric(rawMat) && ismatrix(rawMat) && ~isempty(rawMat), '所选变量不是有效二维数值矩阵。');
if isfield(opts, 'transposeMatrix') && opts.transposeMatrix
    rawMat = rawMat.';
end
if isrow(rawMat)
    rawMat = rawMat.';
end
[nSamples, nPulses] = size(rawMat);
assert(nSamples >= 3, '每列至少需要 3 个采样点。');

timeMode = 'fs';
if isfield(opts, 'timeMode') && ~isempty(opts.timeMode)
    timeMode = opts.timeMode;
end

if strcmp(timeMode, 'vector')
    assert(isfield(opts, 'timeVar') && isfield(loaded, opts.timeVar), '未找到所选时间向量。');
    t = double(loaded.(opts.timeVar)(:));
    assert(numel(t) == nSamples && isreal(t) && all(isfinite(t)), ...
        '时间向量长度（%d）与矩阵行数（%d）不匹配或含非有限值。', numel(t), nSamples);
    dt = diff(t);
    assert(all(dt > 0), '时间向量必须严格递增。');
    if isfield(opts, 'timeUnit') && strcmpi(opts.timeUnit, 'ms')
        t = t * 1e-3;
    end
    fs = 1 / mean(diff(t));
    timeSeconds = t;
else
    fs = double(opts.fs_Hz);
    assert(isfinite(fs) && fs > 0, '采样率必须为正有限数值。');
    t0_s = 0;
    if isfield(opts, 't0_ms') && isfinite(opts.t0_ms)
        t0_s = double(opts.t0_ms) * 1e-3;
    end
    idxOrigin = '0';
    if isfield(opts, 'indexOrigin') && ~isempty(opts.indexOrigin)
        idxOrigin = char(opts.indexOrigin);
    end
    if strcmp(idxOrigin, '1')
        timeSeconds = t0_s + (1:nSamples)' / fs;
    else
        timeSeconds = t0_s + (0:nSamples-1)' / fs;
    end
end

recordNumbers = 1:nPulses;
importedAngles = [];
if isfield(opts, 'axisVar') && ~isempty(opts.axisVar) && isfield(loaded, opts.axisVar)
    ax = double(loaded.(opts.axisVar)(:)).';
    assert(numel(ax) == nPulses && isreal(ax) && all(isfinite(ax)), ...
        '脉冲/角度向量长度（%d）与脉冲数（%d）不匹配。', numel(ax), nPulses);
    if isfield(opts, 'axisKind') && strcmp(opts.axisKind, 'angle')
        importedAngles = ax;
    else
        recordNumbers = ax;
    end
end

[folder, stem] = fileparts(matPath);
inputType = '原始实波形';
if isfield(opts, 'inputType') && ~isempty(opts.inputType)
    inputType = char(opts.inputType);
end

isRel = false;
if isfield(opts, 'isRelativeWindowTime'), isRel = logical(opts.isRelativeWindowTime); end
isTrunc = isRel;
if isfield(opts, 'isTruncatedWindow'), isTrunc = logical(opts.isTruncatedWindow); end
scaleUnknown = false;
if isfield(opts, 'originalScaleUnknown'), scaleUnknown = logical(opts.originalScaleUnknown); end

dataset = struct();
dataset.values = rawMat;
dataset.fs = fs;
dataset.timeSeconds = timeSeconds(:);
dataset.timeOrigin_s = timeSeconds(1);
dataset.isRelativeWindowTime = isRel;
dataset.isTruncatedWindow = isTrunc;
dataset.recordNumbers = recordNumbers;
dataset.recordFiles = repmat({[stem '.mat']}, 1, nPulses);
dataset.missingNumbers = [];
dataset.expectedCount = nPulses;
dataset.folder = folder;
dataset.datasetName = stem;
dataset.channel = opts.matrixVar;
dataset.channels = {opts.matrixVar};
dataset.dataOrigin = 'MAT';
dataset.inputType = inputType;
dataset.originalScaleUnknown = scaleUnknown;
if scaleUnknown
    dataset.unitLabel = '相对幅值（原始尺度未知）';
else
    dataset.unitLabel = '幅值';
end
dataset.importedAngles = importedAngles;
dataset.missingMetadata = 0;
end
