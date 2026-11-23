function info = inspectMat(matPath)
%INSPECTMAT 预览 MAT 文件中的变量，识别候选回波矩阵、时间/采样率/角度变量，
%   并拦截仅含 TS 数值（无逐采样点波形）的 TS 结果文件。

assert(isfile(matPath), '未找到 MAT 文件：%s', matPath);
w = whos('-file', matPath);
assert(~isempty(w), 'MAT 文件为空。');

loaded = load(matPath);
matrixVars = struct('name', {}, 'size', {}, 'class', {}, 'isComplex', {}, ...
    'isNonNegative', {}, 'maxAbs', {}, 'suggestInputType', {});
vectorVars = struct('name', {}, 'length', {}, 'isStrictlyIncreasing', {}, 'minVal', {}, 'maxVal', {});
scalarVars = struct('name', {}, 'value', {});

hasTSOnlyStruct = false;
for k = 1:numel(w)
    name = w(k).name;
    val = loaded.(name);
    if isstruct(val) && isscalar(val)
        if isfield(val, 'TS_dB') && ~hasWaveformField(val)
            hasTSOnlyStruct = true;
        end
        continue
    elseif iscell(val) && ~isempty(val) && isstruct(val{1}) && isfield(val{1}, 'TS_dB')
        if ~hasWaveformField(val{1})
            hasTSOnlyStruct = true;
        end
        continue
    end

    if ~isnumeric(val) || isempty(val) || ~ismatrix(val)
        continue
    end

    sz = size(val);
    if isscalar(val) && isreal(val) && isfinite(val)
        scalarVars(end+1) = struct('name', name, 'value', double(val)); %#ok<AGROW>
    elseif isvector(val)
        v = double(val(:));
        inc = numel(v) >= 2 && isreal(v) && all(isfinite(v)) && all(diff(v) > 0);
        vectorVars(end+1) = struct('name', name, 'length', numel(v), ...
            'isStrictlyIncreasing', inc, 'minVal', min(real(v)), 'maxVal', max(real(v))); %#ok<AGROW>
        if numel(v) >= 16
            matrixVars(end+1) = buildMatrixEntry(name, val); %#ok<AGROW>
        end
    else
        % 2D 矩阵
        if max(sz) >= 16
            matrixVars(end+1) = buildMatrixEntry(name, val); %#ok<AGROW>
        end
    end
end

info = struct();
info.matPath = matPath;
info.matrixVars = matrixVars;
info.vectorVars = vectorVars;
info.scalarVars = scalarVars;
info.isTSResultOnly = isempty(matrixVars) && hasTSOnlyStruct;
if info.isTSResultOnly
    info.message = ['检测到该 MAT 文件仅包含目标强度（TS）结果数值，不含逐采样点波形矩阵。' ...
        '请改选原始 NI/LTT 采集文件夹，或包含逐采样点回波矩阵的 MAT 文件。'];
elseif isempty(matrixVars)
    info.message = 'MAT 文件中未找到可用的数值回波矩阵（至少需 16 个采样点）。';
else
    info.message = sprintf('找到 %d 个候选回波矩阵变量。', numel(matrixVars));
end
end

function tf = hasWaveformField(s)
fields = fieldnames(s);
tf = false;
for k = 1:numel(fields)
    v = s.(fields{k});
    if isnumeric(v) && ismatrix(v) && min(size(v)) >= 1 && max(size(v)) >= 64
        if ~ismember(fields{k}, {'TS_dB', 'directAmplitude', 'echoAmplitude', 'angle_deg', 'pulse', 'frequency_Hz'})
            tf = true;
            return
        end
    end
end
end

function entry = buildMatrixEntry(name, val)
isCpx = ~isreal(val);
finiteVals = val(isfinite(val));
if isempty(finiteVals)
    isNonNeg = false;
    maxAbsVal = NaN;
else
    isNonNeg = ~isCpx && all(finiteVals >= 0);
    maxAbsVal = double(max(abs(finiteVals)));
end
if isCpx
    suggest = '复解析信号';
elseif isNonNeg
    suggest = '幅值包络';
else
    suggest = '原始实波形';
end
entry = struct('name', name, 'size', size(val), 'class', class(val), ...
    'isComplex', isCpx, 'isNonNegative', isNonNeg, 'maxAbs', maxAbsVal, ...
    'suggestInputType', suggest);
end
