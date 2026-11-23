function report = run_v1_verification(ex09Dir, niDir)
%RUN_V1_VERIFICATION 首版「回波亮点检测与后处理」App 自动化验收与回归测试。
%   report = run_v1_verification()
%   report = run_v1_verification(ex09Dir, niDir)
%   覆盖：
%     1. 静态代码检查 (checkcode)
%     2. 练习 01：已知延时单回波 + 截窗一致定位
%     3. 练习 02/03：多亮点真值对照、有限分辨率与近峰合并
%     4. 练习 09：前 5 列实测候选与代表峰逐项回归（对照 candidates/counts/result.csv）
%     5. 固定方位宽窗三峰人工复核（剔除、补点、撤销、重导出核对）+ TS-only MAT 拦截
%     6. 边界条件（全零、整窗屏蔽、单脉冲、重叠窗校验、批处理取消）
%     7. 真实 NI 采集文件夹端到端实测（若提供 niDir）

if nargin < 1, ex09Dir = ''; end
if nargin < 2, niDir = ''; end

testDir = fileparts(mfilename('fullpath'));
appDir = fileparts(testDir);
addpath(appDir);

report = struct();
fprintf('========== 回波亮点检测与后处理 App 首版验收 ==========\n');

%% 1. 静态代码检查 (checkcode)
fprintf('\n[1/7] 静态代码检查 (checkcode)...\n');
mFiles = [dir(fullfile(appDir, '*.m')); dir(fullfile(appDir, '+eh', '*.m'))];
warnCount = 0;
for k = 1:numel(mFiles)
    fp = fullfile(mFiles(k).folder, mFiles(k).name);
    info = checkcode(fp, '-id');
    if ~isempty(info)
        for j = 1:numel(info)
            fprintf('  [WARN] %s (L%d) [%s]: %s\n', mFiles(k).name, info(j).line, info(j).id, info(j).message);
        end
        warnCount = warnCount + numel(info);
    end
end
fprintf('  检查 %d 个文件，共 %d 条提示。\n', numel(mFiles), warnCount);
report.staticWarnings = warnCount;

%% 2. 练习 01：已知延时单回波 + 截窗矩阵一致性
fprintf('\n[2/7] 练习 01：已知延时单回波与截窗定位一致性...\n');
fs1 = 100e3; pulseDur1 = 3e-3; fc1 = 12e3; bw1 = 8e3;
trueDelays = [4, 7] * 1e-3;
N1 = 1400; pLen1 = round(pulseDur1 * fs1);
tPulse1 = (0:pLen1-1)' / fs1;
fStart1 = fc1 - bw1/2; fEnd1 = fc1 + bw1/2;
slope1 = bw1 / pulseDur1;
tx1 = exp(1i * 2 * pi * (fStart1 * tPulse1 + 0.5 * slope1 * tPulse1.^2));
echoMat1 = complex(zeros(N1, 2));
for k = 1:2
    q = round(trueDelays(k) * fs1);
    echoMat1(q + (1:pLen1), k) = tx1;
end
mf1 = eh.preprocess('matchedfilter', echoMat1, fs1, struct( ...
    'signalType', 'LFM', 'fStart_Hz', fStart1, 'fEnd_Hz', fEnd1, ...
    'pulseWidth_s', pulseDur1, 'complexTemplate', true));
env1 = eh.preprocess('envelope', mf1, fs1, struct('inputType', '匹配输出'));
tSec1 = (0:N1-1)' / fs1;
p1 = struct('smooth_ms', 0, 'normMode', 'column', 'normScope', 'search_windows', ...
    'minProminence', 0.5, 'minDistance_ms', 0.5, 'enableMerge', false, 'mergeGap_ms', 1.0);
b1 = eh.detectBatch(env1, tSec1, fs1, [1 2], [1 2], {'syn1', 'syn2'}, [], [0 10], [], p1);
estMs1 = [b1.colResults{1}.highlights(1).Time_ms, b1.colResults{2}.highlights(1).Time_ms];
errSamples1 = abs(estMs1 - trueDelays * 1e3) * 1e-3 * fs1;
assert(all(errSamples1 <= 1.0), '练习01 延时误差超过 1 采样点！');

% 截窗片段导入一致性检查：截取 [2, 9] ms 片段并指定 t0_ms
winRows = find(tSec1 * 1e3 >= 2 & tSec1 * 1e3 <= 9);
tmpMat1 = [tempname '.mat'];
cTmp1 = onCleanup(@() deleteIfExists(tmpMat1)); %#ok<NASGU>
truncEnv = env1(winRows, :); %#ok<NASGU>
save(tmpMat1, 'truncEnv');
dsTrunc = eh.loadMatDataset(tmpMat1, struct( ...
    'matrixVar', 'truncEnv', 'timeMode', 'fs', 'fs_Hz', fs1, ...
    't0_ms', tSec1(winRows(1)) * 1e3, 'indexOrigin', '0', ...
    'inputType', '幅值包络', 'isRelativeWindowTime', false));
b1Trunc = eh.detectBatch(dsTrunc.values, dsTrunc.timeSeconds, dsTrunc.fs, [1 2], [1 2], ...
    dsTrunc.recordFiles, [], [2 9], [], p1);
estTruncMs1 = [b1Trunc.colResults{1}.highlights(1).Time_ms, b1Trunc.colResults{2}.highlights(1).Time_ms];
assert(max(abs(estTruncMs1 - estMs1)) < 1e-9, '完整记录选窗与截窗矩阵导入定位不一致！');
fprintf('  PASS: 估计=[%.4f, %.4f] ms，最大误差=%.3f 样点；截窗一致误差=0。\n', ...
    estMs1(1), estMs1(2), max(errSamples1));
report.ex01MaxErrorSamples = max(errSamples1);

%% 3. 练习 02 & 03：多亮点、近峰合并与带宽分辨
fprintf('\n[3/7] 练习 02/03：多亮点真值对照、近峰合并与有限分辨率...\n');
% 练习 02
trueDelay2 = [4, 4.9, 6.2] * 1e-3;
amps2 = [1, 0.55, 0.35]; ph2 = [0, pi/3, -pi/4];
N2 = 1500; echo2 = complex(zeros(N2, 1));
for k = 1:3
    q = round(trueDelay2(k) * fs1);
    echo2(q + (1:pLen1)) = echo2(q + (1:pLen1)) + amps2(k) * exp(1i * ph2(k)) * tx1;
end
mf2 = eh.preprocess('matchedfilter', echo2, fs1, struct( ...
    'signalType', 'LFM', 'fStart_Hz', fStart1, 'fEnd_Hz', fEnd1, ...
    'pulseWidth_s', pulseDur1, 'complexTemplate', true));
env2 = eh.preprocess('envelope', mf2, fs1, struct('inputType', '匹配输出'));
tSec2 = (0:N2-1)' / fs1;
p2 = struct('smooth_ms', 0, 'normMode', 'column', 'normScope', 'full_record', ...
    'minProminence', 0.18, 'minDistance_ms', 0.4, 'enableMerge', false, 'mergeGap_ms', 1.0);
b2 = eh.detectBatch(env2, tSec2, fs1, 1, 1, {'ex02'}, [], [2 10], [], p2);
t2Est = [b2.colResults{1}.highlights.Time_ms];
assert(numel(t2Est) == 3, '练习02 应检出 3 个亮点，实际 %d。', numel(t2Est));
err2_ms = abs(t2Est - trueDelay2 * 1e3);
assert(all(err2_ms <= 1e3 / fs1 + 1e-9), '练习02 时刻误差超限。');
% 开启近峰合并 (1.0 ms)：4.0 与 4.9 ms 合为 1 组，总代表峰变为 2
p2m = p2; p2m.enableMerge = true; p2m.mergeGap_ms = 1.0;
b2m = eh.detectBatch(env2, tSec2, fs1, 1, 1, {'ex02'}, [], [2 10], [], p2m);
assert(numel(b2m.colResults{1}.candidates) == 3 && numel(b2m.colResults{1}.highlights) == 2, ...
    '练习02 启用 1.0 ms 合并后应为 3 候选 -> 2 代表峰。');

% 练习 03：B = 2 kHz（分辨不开 -> 1 峰） vs B = 12 kHz（分辨开 -> 2 峰）
trueDelay3 = [5.0, 5.2] * 1e-3;
bwList3 = [2e3, 12e3];
counts3 = zeros(1, 2);
pLen3 = round(4e-3 * fs1); tPulse3 = (0:pLen3-1)' / fs1;
for ti = 1:2
    bw = bwList3(ti); f1_3 = 20e3 - bw/2; f2_3 = 20e3 + bw/2;
    tx3 = exp(1i * 2 * pi * (f1_3 * tPulse3 + 0.5 * (bw / 4e-3) * tPulse3.^2));
    echo3 = complex(zeros(1400, 1));
    for k = 1:2
        q = round(trueDelay3(k) * fs1);
        echo3(q + (1:pLen3)) = echo3(q + (1:pLen3)) + tx3;
    end
    mf3 = eh.preprocess('matchedfilter', echo3, fs1, struct( ...
        'signalType', 'LFM', 'fStart_Hz', f1_3, 'fEnd_Hz', f2_3, ...
        'pulseWidth_s', 4e-3, 'complexTemplate', true));
    env3 = eh.preprocess('envelope', mf3, fs1, struct('inputType', '匹配输出'));
    p3 = struct('smooth_ms', 0, 'normMode', 'column', 'normScope', 'full_record', ...
        'minProminence', 0.08, 'minDistance_ms', 0.05, 'minHeight', 0.5, ...
        'enableMerge', false, 'mergeGap_ms', 0);
    b3 = eh.detectBatch(env3, (0:1399)' / fs1, fs1, 1, 1, {'ex03'}, [], [4.7 5.5], [], p3);
    counts3(ti) = numel(b3.colResults{1}.highlights);
end
assert(counts3(1) == 1 && counts3(2) == 2, '练习03 预期 [1, 2] 峰，实际 [%d, %d]。', counts3(1), counts3(2));
fprintf('  PASS: 练习02 3/3 命中（最大误差 %.4f ms），合并测试 3→2；练习03 带宽 2/12 kHz 检出 [%d, %d] 峰。\n', ...
    max(err2_ms), counts3(1), counts3(2));
report.ex02MaxError_ms = max(err2_ms);
report.ex03Counts = counts3;

%% 4. 练习 09：实测候选与代表峰逐项回归
fprintf('\n[4/7] 练习 09：前 5 列实测候选与代表峰回归...\n');
if ~isempty(ex09Dir) && isfile(fullfile(ex09Dir, 'matched_echo_0_20deg.mat'))
    ds09 = eh.loadMatDataset(fullfile(ex09Dir, 'matched_echo_0_20deg.mat'), struct( ...
        'matrixVar', 'echo', 'timeMode', 'fs', 'fs_Hz', 1e6, ...
        't0_ms', 0, 'indexOrigin', '1', 'inputType', '幅值包络'));
    allAng = linspace(0, 20, size(ds09.values, 2));
    p09 = struct('smooth_ms', 0.021, 'normMode', 'batch', 'normScope', 'full_record', ...
        'minProminence', 0.10, 'minDistance_ms', 0.45, 'enableMerge', true, 'mergeGap_ms', 2.0);
    b09 = eh.detectBatch(ds09.values, ds09.timeSeconds, ds09.fs, 1:5, 1:5, ...
        ds09.recordFiles, allAng(1:5), [0, ds09.timeSeconds(end)*1e3], [15 25; 29 33.5], p09);
    rs09 = eh.reviewState('init', b09, '练习09 匹配包络', false);
    m09 = eh.reviewState('materialize', rs09);

    refCand = readtable(fullfile(ex09Dir, 'output', 'candidates.csv'));
    refCount = readtable(fullfile(ex09Dir, 'output', 'counts.csv'));
    refRes = readtable(fullfile(ex09Dir, 'output', 'result.csv'));

    assert(isequal(m09.countsTable.AutoCandidateCount, refCount.CandidateCount), '09 候选数与 counts.csv 不符！');
    assert(isequal(m09.countsTable.AutoHighlightCount, refCount.SelectedCount), '09 代表峰数与 counts.csv 不符！');
    assert(isequal(m09.candidatesTable.SampleIndex, refCand.SampleIndex), '09 候选样本索引与 candidates.csv 不符！');
    assert(isequal(m09.highlightsTable.SampleIndex, refRes.SampleIndex), '09 代表峰索引与 result.csv 不符！');
    maxAmpDiff = max(abs(m09.highlightsTable.Amplitude_norm - refRes.Amplitude_rel));
    maxPromDiff = max(abs(m09.highlightsTable.Prominence_norm - refRes.Prominence_rel));
    assert(maxAmpDiff < 1e-12 && maxPromDiff < 1e-12, '09 幅值或显著度数值与参考表存在偏差！');
    fprintf('  PASS: 5 列候选数=%s，代表峰数=%s，样本索引 100%% 一致，幅值/显著度最大差=%.2e。\n', ...
        mat2str(m09.countsTable.AutoCandidateCount.'), mat2str(m09.countsTable.AutoHighlightCount.'), ...
        max(maxAmpDiff, maxPromDiff));
    report.ex09Verified = true;
else
    fprintf('  SKIP: 未提供 ex09Dir 或缺少 matched_echo_0_20deg.mat。\n');
    report.ex09Verified = false;
end

%% 5. 固定方位宽窗三峰人工复核 + 导出核对 + TS-only MAT 拦截
fprintf('\n[5/7] 固定方位宽窗三峰人工复核（剔除/补点/撤销/重导出）与 TS-only 拦截...\n');
fs5 = 100e3; t5 = (0:1999)' / fs5;
peaksT = [12.0, 13.4, 16.8] * 1e-3;
peaksA = [1.0, 0.65, 0.35];
env5 = zeros(numel(t5), 4);
for col = 1:4
    for pk = 1:3
        env5(:, col) = env5(:, col) + peaksA(pk) * exp(-0.5 * ((t5 - peaksT(pk)) / 0.12e-3).^2);
    end
end
p5 = struct('smooth_ms', 0, 'normMode', 'batch', 'normScope', 'search_windows', ...
    'minProminence', 0.10, 'minDistance_ms', 0.4, 'enableMerge', false, 'mergeGap_ms', 2.0);
b5 = eh.detectBatch(env5, t5, fs5, 1:4, [101 102 104 105], {'p1','p2','p4','p5'}, [], [10 18], [], p5);
rs5 = eh.reviewState('init', b5, '合成固定方位包络', false);
% 对第 2 列剔除第 3 个峰（16.8 ms）
cv2Before = eh.reviewState('column_view', rs5, 2);
assert(cv2Before.reviewedHighlightCount == 3);
rs5 = eh.reviewState('reject', rs5, 2, cv2Before.items(3).CandidateId);
cv2AfterRej = eh.reviewState('column_view', rs5, 2);
assert(cv2AfterRej.autoCandidateCount == 3 && cv2AfterRej.autoHighlightCount == 3 && cv2AfterRej.reviewedHighlightCount == 2);
% 手工补 1 个峰
mp = struct('WindowIndex', 1, 'SampleIndex', 1500, 'WindowSampleIndex', 500, ...
    'Time_ms', t5(1500)*1e3, 'Amplitude_raw', env5(1500, 2), 'Amplitude_norm', env5(1500, 2), ...
    'SignalSource', '合成固定方位包络');
rs5 = eh.reviewState('add_manual', rs5, 2, mp);
cv2AfterAdd = eh.reviewState('column_view', rs5, 2);
assert(cv2AfterAdd.reviewedHighlightCount == 3 && cv2AfterAdd.manualAddedCount == 1);
% 撤销手工补点 -> 回到 2 个代表峰
rs5 = eh.reviewState('undo', rs5);
cv2AfterUndo = eh.reviewState('column_view', rs5, 2);
assert(cv2AfterUndo.reviewedHighlightCount == 2 && cv2AfterUndo.manualAddedCount == 0);
% 导出 CSV + MAT 并回读核对
outTmpDir = tempname;
cOut5 = onCleanup(@() rmdirIfExists(outTmpDir)); %#ok<NASGU>
eh.exportResults('csv', outTmpDir, rs5);
eh.exportResults('mat', fullfile(outTmpDir, 'session.mat'), rs5, struct('name', 'syn5'));
cTbl = readtable(fullfile(outTmpDir, 'candidates.csv'));
hTbl = readtable(fullfile(outTmpDir, 'highlights.csv'));
cntTbl = readtable(fullfile(outTmpDir, 'counts.csv'));
assert(cntTbl.AutoCandidateCount(2) == 3 && cntTbl.ReviewedHighlightCount(2) == 2);
assert(sum(cTbl.PulseIndex == 2) == 3 && sum(hTbl.PulseIndex == 2) == 2);
assert(isequal(cntTbl.RecordNumber.', [101 102 104 105]), '缺号记录编号被改写！');
loadedSess = load(fullfile(outTmpDir, 'session.mat'));
assert(numel(loadedSess.session.manualEdits) == 1 && strcmp(loadedSess.session.manualEdits(1).Action, 'reject'));

% 测试 TS-only MAT 拦截
tsOnlyPath = [tempname '.mat'];
cTsOnly = onCleanup(@() deleteIfExists(tsOnlyPath)); %#ok<NASGU>
result = struct('TS_dB', [-10 -12 -11], 'angle_deg', [0 1 2], 'frequency_Hz', 30e3); %#ok<NASGU>
save(tsOnlyPath, 'result');
tsInfo = eh.inspectMat(tsOnlyPath);
assert(tsInfo.isTSResultOnly, '未能拦截仅含 TS 数值的 MAT 文件！');
fprintf('  PASS: 人工剔除/补点/撤销/导出三表与 MAT 追溯、缺号保留及 TS-only MAT 拦截全部通过。\n');
report.reviewAndExportVerified = true;

%% 6. 边界与中断测试（全零、整窗屏蔽、单脉冲、重叠窗、取消批处理）
fprintf('\n[6/7] 边界与中断测试...\n');
% 全零信号
bZero = eh.detectBatch(zeros(500, 2), (0:499)'/fs5, fs5, [1 2], [1 2], {'z1','z2'}, [], [0 4], [], p5);
assert(all(cellfun(@(c) strcmp(c.status, 'zero_signal'), bZero.colResults)), '全零信号状态应为 zero_signal。');
% 整窗屏蔽
bMasked = eh.detectBatch(env5(:, 1), t5, fs5, 1, 1, {'m1'}, [], [10 18], [10 18], p5);
assert(strcmp(bMasked.colResults{1}.status, 'no_valid_data'), '整窗屏蔽状态应为 no_valid_data。');
% 搜索窗重叠校验
overlapCaught = false;
try
    eh.buildSegments(t5*1e3, [10 15; 14 18], []);
catch err
    overlapCaught = strcmp(err.identifier, 'echoHighlight:WindowOverlap') && contains(err.message, '1') && contains(err.message, '2');
end
assert(overlapCaught, '重叠搜索窗未抛出带窗号的错误！');
% 取消批处理不破坏旧结果
prevState = rs5;
cancelCaught = false;
try
    eh.detectBatch(env5, t5, fs5, 1:4, 1:4, {'a','b','c','d'}, [], [10 18], [], p5, ...
        @(frac, ~) cancelOnHalf(frac));
catch err
    cancelCaught = strcmp(err.identifier, 'echoHighlight:Cancelled');
end
assert(cancelCaught && isequaln(prevState, rs5), '取消批处理后异常捕获或旧状态保护失败！');
fprintf('  PASS: 全零、整窗屏蔽、单脉冲、重叠窗报错及批处理取消保护全部通过。\n');
report.edgeCasesVerified = true;

%% 7. 真实 NI 采集文件夹端到端实测
fprintf('\n[7/7] 真实 NI 数据端到端实测...\n');
if ~isempty(niDir) && isfolder(niDir)
    dsNI = eh.readNI(niDir, '', []);
    nCols = size(dsNI.values, 2);
    testRange = 1:min(10, nCols);
    bpNI = eh.preprocess('bandpass', dsNI.values(:, testRange), dsNI.fs, struct('band_Hz', [15e3 45e3]));
    envNI = eh.preprocess('envelope', bpNI, dsNI.fs, struct('inputType', '带通波形'));
    tEnd_ms = dsNI.timeSeconds(end) * 1e3;
    pNI = struct('smooth_ms', 0.05, 'normMode', 'batch', 'normScope', 'search_windows', ...
        'minProminence', 0.12, 'minDistance_ms', 0.3, 'enableMerge', false, 'mergeGap_ms', 1.0);
    bNI = eh.detectBatch(envNI, dsNI.timeSeconds, dsNI.fs, 1:numel(testRange), ...
        dsNI.recordNumbers(testRange), dsNI.recordFiles(testRange), [], ...
        [0, tEnd_ms], [], pNI);
    rsNI = eh.reviewState('init', bNI, 'NI 带通包络', false);
    mNI = eh.reviewState('materialize', rsNI);
    niTmpOut = tempname;
    cNiOut = onCleanup(@() rmdirIfExists(niTmpOut)); %#ok<NASGU>
    eh.exportResults('csv', niTmpOut, rsNI);
    fprintf('  PASS: NI %s (%s, %d点×%d列, fs=%g kHz)，测试前 %d 列，检出 %d 个代表峰并成功导出 CSV。\n', ...
        dsNI.datasetName, dsNI.channel, size(dsNI.values, 1), nCols, dsNI.fs/1e3, ...
        numel(testRange), height(mNI.highlightsTable));
    report.niVerified = true;
    report.niSummary = struct('dataset', dsNI.datasetName, 'channel', dsNI.channel, ...
        'samples', size(dsNI.values, 1), 'pulses', nCols, 'fs', dsNI.fs, ...
        'testedPulses', numel(testRange), 'highlightsFound', height(mNI.highlightsTable));
else
    fprintf('  SKIP: 未提供有效 niDir。\n');
    report.niVerified = false;
end

fprintf('\n========== 验收测试全部完成 ==========\n');
end

function cancelOnHalf(frac)
if frac >= 0.5
    error('echoHighlight:Cancelled', '模拟用户取消。');
end
end

function deleteIfExists(p)
if isfile(p), delete(p); end
end

function rmdirIfExists(p)
if isfolder(p), rmdir(p, 's'); end
end
