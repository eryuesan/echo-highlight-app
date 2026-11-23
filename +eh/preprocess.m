function out = preprocess(action, signal, fs, opts, progressFcn)
%PREPROCESS 信号预处理与包络提取工具集。
%   action:
%     'bandpass'      - 逐列带通滤波，opts.band_Hz = [f1 f2]
%     'matchedfilter' - 逐列匹配滤波（显式校正模板时延，返回与输入等长信号）
%                       opts: signalType ('LFM'|'CW'), fStart_Hz, fEnd_Hz,
%                             fCenter_Hz, pulseWidth_s, complexTemplate (可选)
%     'pulsehighpass' - 沿脉冲维零相位二阶巴特沃斯高通（默认关闭，仅用户显式启用）
%                       opts.cutoff_cyclesPerPulse
%     'envelope'      - 按 inputType 提取非负检测包络
%                       opts.inputType = '原始实波形'|'带通波形'|'复解析信号'|'匹配输出'|'幅值包络'

if nargin < 4, opts = struct(); end
if nargin < 5, progressFcn = []; end

switch lower(action)
    case 'bandpass'
        assert(~isempty(signal) && isnumeric(signal), '输入信号为空。');
        assert(isreal(signal), '带通滤波仅支持实值波形，复解析信号请直接取模或匹配。');
        b = double(opts.band_Hz);
        assert(numel(b) == 2 && all(isfinite(b)) && b(1) > 0 && b(2) > b(1) && b(2) < fs / 2, ...
            '带通频带须递增且在奈奎斯特频率（%g Hz）以内。', fs / 2);
        [nSamples, nCols] = size(signal);
        filtered = zeros(nSamples, nCols);
        lastPct = -1;
        for k = 1:nCols
            filtered(:, k) = bandpass(double(signal(:, k)), b, fs);
            pct = floor(100 * k / nCols);
            if ~isempty(progressFcn) && (pct ~= lastPct || k == nCols)
                progressFcn(k / nCols, sprintf('带通滤波  %d%%  （%d / %d 次脉冲）', pct, k, nCols));
                lastPct = pct;
            end
        end
        out = filtered;

    case 'matchedfilter'
        assert(~isempty(signal) && isnumeric(signal), '输入信号为空。');
        [nSamples, nCols] = size(signal);
        duration = double(opts.pulseWidth_s);
        pulseLength = round(duration * fs);
        assert(isfinite(duration) && pulseLength >= 1 && pulseLength < nSamples, ...
            '脉宽须大于等于 1 个采样点且小于记录长度。');

        tPulse = (0:pulseLength-1)' / fs;
        sigType = 'LFM';
        if isfield(opts, 'signalType') && ~isempty(opts.signalType)
            sigType = upper(char(opts.signalType));
        end
        useComplex = ~isreal(signal);
        if isfield(opts, 'complexTemplate') && ~isempty(opts.complexTemplate)
            useComplex = logical(opts.complexTemplate);
        end

        if strcmp(sigType, 'CW')
            fc = double(opts.fCenter_Hz);
            assert(isfinite(fc) && fc > 0 && fc < fs / 2, 'CW 频率须大于 0 且小于奈奎斯特频率。');
            phase = 2 * pi * fc * tPulse;
        else
            f1 = double(opts.fStart_Hz);
            f2 = double(opts.fEnd_Hz);
            assert(all(isfinite([f1 f2])) && f1 > 0 && f2 > f1 && f2 < fs / 2, ...
                'LFM 起止频率须递增且在奈奎斯特频率以内。');
            slope = (f2 - f1) / duration;
            phase = 2 * pi * (f1 * tPulse + 0.5 * slope * tPulse.^2);
        end

        if useComplex
            replica = exp(1i * phase);
        else
            replica = sin(phase);
        end
        energy = sum(abs(replica).^2);
        assert(energy > 0, '匹配模板能量为零。');
        kernel = conj(flipud(replica)) / energy;

        % conv(..., 'full') 零延时位置为 pulseLength（1-based），
        % 截取 pulseLength : pulseLength + nSamples - 1 与输入时间轴严格对齐。
        if useComplex
            matched = complex(zeros(nSamples, nCols));
        else
            matched = zeros(nSamples, nCols);
        end
        lastPct = -1;
        for k = 1:nCols
            fullOut = conv(double(signal(:, k)), kernel, 'full');
            matched(:, k) = fullOut(pulseLength : pulseLength + nSamples - 1);
            pct = floor(100 * k / nCols);
            if ~isempty(progressFcn) && (pct ~= lastPct || k == nCols)
                progressFcn(k / nCols, sprintf('匹配滤波  %d%%  （%d / %d 次脉冲）', pct, k, nCols));
                lastPct = pct;
            end
        end
        out = matched;

    case 'pulsehighpass'
        fc = double(opts.cutoff_cyclesPerPulse);
        assert(isfinite(fc) && fc > 0 && fc < 0.5, '截止频率须在 0 到 0.5 周期/脉冲之间。');
        assert(size(signal, 2) >= 2, '沿脉冲维高通至少需要 2 次脉冲。');
        out = pulseHighpassCore(double(signal), fc, progressFcn);

    case 'envelope'
        inputType = '原始实波形';
        if isfield(opts, 'inputType') && ~isempty(opts.inputType)
            inputType = char(opts.inputType);
        end
        sig = double(signal);
        switch inputType
            case '幅值包络'
                if ~isreal(sig)
                    out = abs(sig);
                elseif any(sig(:) < 0)
                    out = abs(sig);
                else
                    out = sig;
                end
            case '复解析信号'
                out = abs(sig);
            case '匹配输出'
                if ~isreal(sig)
                    out = abs(sig);
                elseif all(sig(isfinite(sig)) >= 0)
                    out = sig;
                else
                    out = abs(hilbert(sig));
                end
            otherwise
                % 原始实波形 / 带通波形
                if ~isreal(sig)
                    out = abs(sig);
                else
                    out = abs(hilbert(sig));
                end
        end

    otherwise
        error('echoHighlight:UnknownAction', '不支持的预处理操作：%s', action);
end
end

function filtered = pulseHighpassCore(block, fc, progressFcn)
n = size(block, 2);
bins = 0 : (2 * n - 1);
f = min(bins, 2 * n - bins) / (2 * n);
gain = zeros(size(f));
gain(2:end) = 1 ./ sqrt(1 + (fc ./ f(2:end)).^4);
filtered = zeros(size(block), 'like', block);
nRows = size(block, 1);
for startRow = 1:64:nRows
    if ~isempty(progressFcn)
        progressFcn((startRow - 1) / nRows, '脉冲维高通滤波中…');
    end
    rows = startRow : min(startRow + 63, nRows);
    data = block(rows, :);
    extended = [data, fliplr(data)];
    if isreal(data)
        y = ifft(fft(extended, [], 2) .* gain, [], 2, 'symmetric');
    else
        y = ifft(fft(extended, [], 2) .* gain, [], 2);
    end
    filtered(rows, :) = y(:, 1:n);
end
if ~isempty(progressFcn)
    progressFcn(1, '脉冲维高通完成');
end
end
