function echo_highlight_app
%ECHO_HIGHLIGHT_APP 水池声学实验「回波亮点检测与后处理」独立 MATLAB App（首版）。
%   支持 NI/LTT 文件夹与 MAT 回波矩阵导入、带通与精确时延校正匹配滤波、
%   多搜索窗与多干扰屏蔽区、逐脉冲分段寻峰、可选候选峰合并、
%   全组热图与 2:1 单脉冲人工复核（接受/剔除/设为代表/手工补点/撤销），
%   以及 CSV/MAT/出版级 PNG+FIG 导出。

appDir = fileparts(mfilename('fullpath'));
if isempty(appDir), appDir = pwd; end
addpath(appDir);

%% 颜色与主窗口
blue = [0.09 0.26 0.36];
mist = [0.94 0.96 0.97];
barColor = [0.92 0.95 0.96];
ink = [0.12 0.28 0.33];

fig = uifigure('Name', '回波亮点检测与后处理', 'WindowState', 'maximized', 'Color', mist);
root = uigridlayout(fig, [2 2], 'RowHeight', {42, '1x'}, 'ColumnWidth', {370, '1x'}, ...
    'Padding', [10 8 10 10], 'ColumnSpacing', 10, 'RowSpacing', 8, 'BackgroundColor', mist);

%% 顶栏
hdr = uigridlayout(root, [1 3], 'ColumnWidth', {240, '1x', 86}, ...
    'Padding', [14 5 8 5], 'BackgroundColor', blue);
hdr.Layout.Row = 1; hdr.Layout.Column = [1 2];
uilabel(hdr, 'Text', '回波亮点检测与后处理  v1.0', 'FontWeight', 'bold', ...
    'FontSize', 15, 'FontColor', 'white');
headerSummary = uilabel(hdr, 'Text', '请从左侧导入 NI/LTT 采集文件夹或 MAT 回波矩阵。', ...
    'FontSize', 11, 'FontColor', [0.85 0.93 0.96]);
uibutton(hdr, 'Text', '使用说明', 'BackgroundColor', [0.16 0.35 0.44], ...
    'FontColor', 'white', 'ButtonPushedFcn', @showHelp);

%% 状态变量
dataset = [];
bpSignal = [];
mfSignal = [];
hpSignal = [];
activeSignal = [];
activeSignalDesc = '未加载';
envelopeMat = [];
rState = [];          % eh.reviewState 结构体
materialized = [];    % eh.reviewState('materialize', rState)
selectedRowCandId = [];
pickStart = [];
manualAddMode = false;
heatScale = struct('mode', '自动', 'limits', []);
gateHandles = gobjects(0);

%% 左侧可滚动控制栏 + 固定状态栏
sidebar = uigridlayout(root, [2 1], 'RowHeight', {'1x', 54}, ...
    'Padding', [0 0 0 0], 'RowSpacing', 5);
sidebar.Layout.Row = 2; sidebar.Layout.Column = 1;

nRows = 33;
rowH = repmat({27}, 1, nRows);
rowH([1 7 15 19 28]) = {24};
form = uigridlayout(sidebar, [nRows 3], 'ColumnWidth', {126, '1x', '1x'}, ...
    'RowHeight', rowH, 'RowSpacing', 4, 'ColumnSpacing', 6, ...
    'Padding', [6 4 8 6], 'BackgroundColor', [0.98 0.985 0.99], 'Scrollable', 'on');

% --- 分组 1：数据与采集方式 ---
sectionHeading(1, '1. 数据与采集方式');
uilabel(form, 'Text', '数据入口');
sourceMenu = uidropdown(form, 'Items', {'NI 文件夹', 'LTT 文件夹', 'MAT 回波矩阵'}, ...
    'Value', 'NI 文件夹', 'ValueChangedFcn', @sourceChanged);
sourceMenu.Layout.Row = 2; sourceMenu.Layout.Column = [2 3];

loadBtn = uibutton(form, 'Text', '选择数据…', 'ButtonPushedFcn', @loadData, ...
    'BackgroundColor', blue, 'FontColor', 'white');
loadBtn.Layout.Row = 3; loadBtn.Layout.Column = [1 2];
channelMenu = uidropdown(form, 'Items', {'通道/变量'}, 'Enable', 'off', ...
    'ValueChangedFcn', @changeChannel);
channelMenu.Layout.Row = 3; channelMenu.Layout.Column = 3;

dataInfoLabel = uilabel(form, 'Text', '尚未加载数据', 'FontSize', 11, 'FontColor', ink);
wide(dataInfoLabel, 4);

uilabel(form, 'Text', '采集方式');
acqMode = uidropdown(form, 'Items', {'合置角度扫描', '分置接收方位角扫描', '固定方位重复采集'}, ...
    'Value', '固定方位重复采集', 'ValueChangedFcn', @acqModeChanged);
acqMode.Layout.Row = 5; acqMode.Layout.Column = [2 3];

pulseRange = numFields(6, '处理脉冲 (首/末)', [1 1], @rangeChanged);

% --- 分组 2：信号与滤波 ---
sectionHeading(7, '2. 信号与滤波');
angleRange = numFields(8, '首末角度 / °', [0 360], @angleChanged);
set(angleRange, 'Enable', 'off');

uilabel(form, 'Text', '输入信号类型');
inputTypeMenu = uidropdown(form, 'Items', {'原始实波形', '带通波形', '复解析信号', '匹配输出', '幅值包络'}, ...
    'Value', '原始实波形', 'ValueChangedFcn', @inputTypeChanged);
inputTypeMenu.Layout.Row = 9; inputTypeMenu.Layout.Column = [2 3];

bandFields = numFields(10, '带通频带 / kHz', [15 45], @nop);

sigTypeRow = uigridlayout(form, [1 3], 'ColumnWidth', {76, '1x', '1x'}, 'Padding', [0 0 0 0]);
wide(sigTypeRow, 11);
tplType = uidropdown(sigTypeRow, 'Items', {'LFM', 'CW'}, 'Value', 'LFM', ...
    'ValueChangedFcn', @tplTypeChanged);
lfmF1 = uieditfield(sigTypeRow, 'numeric', 'Value', 20, 'Tooltip', 'LFM 起始频率 (kHz) 或 CW 频率 (kHz)');
lfmF2 = uieditfield(sigTypeRow, 'numeric', 'Value', 40, 'Tooltip', 'LFM 终止频率 (kHz)');

pwField = numFields(12, '模板脉宽 / ms', 0.1, @nop);

filtBtnRow = uigridlayout(form, [1 3], 'ColumnWidth', {'1x', '1x', '1x'}, 'Padding', [0 0 0 0]);
wide(filtBtnRow, 13);
uibutton(filtBtnRow, 'Text', '带通滤波', 'ButtonPushedFcn', @runBandpass);
uibutton(filtBtnRow, 'Text', '匹配滤波', 'ButtonPushedFcn', @runMatched);
uibutton(filtBtnRow, 'Text', '用原输入', 'ButtonPushedFcn', @useRawInput);

hpRow = uigridlayout(form, [1 3], 'ColumnWidth', {112, '1x', 76}, 'Padding', [0 0 0 0]);
wide(hpRow, 14);
hpCheck = uicheckbox(hpRow, 'Text', '脉冲维高通', 'Value', false, ...
    'Tooltip', '默认关闭：固定方位下稳定回波会被脉冲维高通削弱', 'ValueChangedFcn', @hpToggle);
hpCutoff = uieditfield(hpRow, 'numeric', 'Value', 0.01, 'Enable', 'off', ...
    'Tooltip', '截止频率（周期/脉冲，0 到 0.5 之间）');
hpBtn = uibutton(hpRow, 'Text', '应用高通', 'Enable', 'off', 'ButtonPushedFcn', @runPulseHP);

% --- 分组 3：搜索窗与干扰区 ---
sectionHeading(15, '3. 搜索窗与干扰区');
winEditor = uigridlayout(form, [2 4], 'ColumnWidth', {68, '1x', '1x', 28}, ...
    'RowHeight', {26, 26}, 'RowSpacing', 3, 'Padding', [0 0 0 0]);
wide(winEditor, 16);
winEdits = gobjects(0, 2); winLabels = gobjects(0); winDelBtns = gobjects(0);
addWinBtn = uibutton(winEditor, 'Text', '＋ 添加搜索窗', 'ButtonPushedFcn', @appendSearchWin);

maskEditor = uigridlayout(form, [1 4], 'ColumnWidth', {68, '1x', '1x', 28}, ...
    'RowHeight', {26}, 'RowSpacing', 3, 'Padding', [0 0 0 0]);
wide(maskEditor, 17);
maskEdits = gobjects(0, 2); maskLabels = gobjects(0); maskDelBtns = gobjects(0);
addMaskBtn = uibutton(maskEditor, 'Text', '＋ 添加干扰屏蔽区', 'ButtonPushedFcn', @appendMaskZone);

sigActiveLabel = uilabel(form, 'Text', '检测信号：未加载', 'FontSize', 11, 'FontColor', ink);
wide(sigActiveLabel, 18);

% --- 分组 4：检测参数 ---
sectionHeading(19, '4. 检测参数');
smoothField = numFields(20, '包络平滑 / ms', 0, @nop);
smoothField.Tooltip = '0 表示关闭平滑；正数按 ms 换算为滑动平均点数';

uilabel(form, 'Text', '归一化方式');
normModeMenu = uidropdown(form, 'Items', {'批次共用基准', '逐列归一化'}, ...
    'ItemsData', {'batch', 'column'}, 'Value', 'batch');
normModeMenu.Layout.Row = 21; normModeMenu.Layout.Column = 2;
normScopeMenu = uidropdown(form, 'Items', {'搜索窗有效段', '整条记录'}, ...
    'ItemsData', {'search_windows', 'full_record'}, 'Value', 'search_windows');
normScopeMenu.Layout.Row = 21; normScopeMenu.Layout.Column = 3;

promField = numFields(22, '最小显著度(归一)', 0.10, @nop);
promField.Tooltip = '基于归一化线性包络幅值（0–1 尺度）的峰显著度';
distField = numFields(23, '最小峰间距 / ms', 0.45, @nop);

mergeRow = uigridlayout(form, [1 3], 'ColumnWidth', {120, '1x', 46}, 'Padding', [0 0 0 0]);
wide(mergeRow, 24);
mergeCheck = uicheckbox(mergeRow, 'Text', '启用候选峰合并', 'Value', false, ...
    'ValueChangedFcn', @mergeToggle);
mergeGapField = uieditfield(mergeRow, 'numeric', 'Value', 2.0, 'Enable', 'off', ...
    'Tooltip', '同一有效段内相邻候选峰时差不超过该值时归为一组');
uilabel(mergeRow, 'Text', 'ms');

normInfoLabel = uilabel(form, 'Text', '归一化基准：待检测', 'FontSize', 10.5, 'FontColor', ink);
wide(normInfoLabel, 25);

runBtnRow = uigridlayout(form, [1 2], 'ColumnWidth', {'1x', '1x'}, 'Padding', [0 0 0 0]);
wide(runBtnRow, 26);
uibutton(runBtnRow, 'Text', '先试算当前脉冲', 'ButtonPushedFcn', @runSinglePulse, ...
    'BackgroundColor', [0.16 0.42 0.44], 'FontColor', 'white');
uibutton(runBtnRow, 'Text', '应用到选定脉冲范围', 'ButtonPushedFcn', @runBatchDetect, ...
    'BackgroundColor', blue, 'FontColor', 'white');

reviewInfoLabel = uilabel(form, 'Text', '复核状态：尚未检测', 'FontSize', 11, 'FontColor', ink);
wide(reviewInfoLabel, 27);

% --- 分组 5：复核与导出 ---
sectionHeading(28, '5. 复核与导出');
uilabel(form, 'Text', '导出图幅');
exportSizeMenu = uidropdown(form, ...
    'Items', {'小图 · 8 × 6 cm · 8 pt', '大图 · 16 × 12 cm · 11 pt'}, ...
    'ItemsData', [8 16], 'Value', 8);
exportSizeMenu.Layout.Row = 29; exportSizeMenu.Layout.Column = [2 3];

expRow1 = uigridlayout(form, [1 2], 'ColumnWidth', {'1x', '1x'}, 'Padding', [0 0 0 0]);
wide(expRow1, 30);
expCsvBtn = uibutton(expRow1, 'Text', '导出 CSV 三表', 'Enable', 'off', 'ButtonPushedFcn', @doExportCsv);
expMatBtn = uibutton(expRow1, 'Text', '导出工程 MAT', 'Enable', 'off', 'ButtonPushedFcn', @doExportMat);

expRow2 = uigridlayout(form, [1 2], 'ColumnWidth', {'1x', '1x'}, 'Padding', [0 0 0 0]);
wide(expRow2, 31);
expHeatBtn = uibutton(expRow2, 'Text', '导出热图 PNG+FIG', 'Enable', 'off', 'ButtonPushedFcn', @(~,~) doExportSingleFig(heatAx, '热图'));
expTraceBtn = uibutton(expRow2, 'Text', '导出单脉冲 PNG+FIG', 'Enable', 'off', 'ButtonPushedFcn', @(~,~) doExportSingleFig(traceAx, '单脉冲复核'));

expBundleBtn = uibutton(form, 'Text', '一键导出全部图表与数据', 'Enable', 'off', ...
    'BackgroundColor', blue, 'FontColor', 'white', 'ButtonPushedFcn', @doExportBundle);
wide(expBundleBtn, 32);

expCountBtn = uibutton(form, 'Text', '导出计数图 PNG+FIG', 'Enable', 'off', ...
    'ButtonPushedFcn', @(~,~) doExportSingleFig(countAx, '逐脉冲计数'));
wide(expCountBtn, 33);

% 默认添加 1 条搜索窗
appendSearchWin();

% 底部固定状态栏
footer = uigridlayout(sidebar, [1 2], 'ColumnWidth', {'1x', 68}, ...
    'Padding', [6 4 6 4], 'ColumnSpacing', 4, 'BackgroundColor', [0.91 0.95 0.96]);
statusLabel = uilabel(footer, 'Text', '就绪：请选择 NI/LTT 文件夹或 MAT 回波矩阵。', ...
    'WordWrap', 'on', 'FontColor', ink, 'FontSize', 11);
refreshBtn = uibutton(footer, 'Text', '刷新视图', 'Enable', 'off', 'ButtonPushedFcn', @refreshAllViews);

%% 右侧主工作区（Tab 1: 热图与逐脉冲复核；Tab 2: 逐脉冲计数与总表）
tabs = uitabgroup(root);
tabs.Layout.Row = 2; tabs.Layout.Column = 2;
mainTab = uitab(tabs, 'Title', '热图与逐脉冲复核');
summaryTab = uitab(tabs, 'Title', '逐脉冲计数与总表');

% --- Tab 1 ---
mainFrame = uigridlayout(mainTab, [1 1], 'Padding', [0 0 0 0]);
viewport = uipanel(mainFrame, 'BorderType', 'none', 'AutoResizeChildren', 'off');
mainLayout = uigridlayout(viewport, [8 1], ...
    'RowHeight', {38, 420, 34, 20, 38, 360, 210, 14}, ...
    'Padding', [10 8 10 8], 'RowSpacing', 4, 'BackgroundColor', 'white', 'Scrollable', 'on');

% 热图工具栏
heatBar = uigridlayout(mainLayout, [1 8], ...
    'ColumnWidth', {54, 120, 54, 152, 68, 68, 82, '1x'}, ...
    'Padding', [8 4 8 4], 'ColumnSpacing', 6, 'BackgroundColor', barColor);
uilabel(heatBar, 'Text', '热图层', 'FontWeight', 'bold', 'FontColor', ink);
layerMenu = uidropdown(heatBar, 'Items', {'检测包络 (dB)', '当前分析信号 (dB)', '原始输入 (dB)'}, ...
    'Value', '检测包络 (dB)', 'ValueChangedFcn', @(~,~) drawHeatmap());
uilabel(heatBar, 'Text', '交互模式', 'FontWeight', 'bold', 'FontColor', ink);
pickMenu = uidropdown(heatBar, 'Items', {'点击查看脉冲', '点两次选脉冲范围', '点两次选搜索窗 1'}, ...
    'Value', '点击查看脉冲', 'ValueChangedFcn', @armPick);
chkShowWin = uicheckbox(heatBar, 'Text', '搜索窗', 'Value', true, 'ValueChangedFcn', @(~,~) drawHeatOverlays());
chkShowMask = uicheckbox(heatBar, 'Text', '屏蔽区', 'Value', true, 'ValueChangedFcn', @(~,~) drawHeatOverlays());
chkShowCand = uicheckbox(heatBar, 'Text', '自动候选', 'Value', true, 'ValueChangedFcn', @(~,~) drawHeatOverlays());
chkShowHigh = uicheckbox(heatBar, 'Text', '复核亮点', 'Value', true, 'ValueChangedFcn', @(~,~) drawHeatOverlays());

heatAx = uiaxes(mainLayout);
styleAxes(heatAx);
xlabel(heatAx, '脉冲序号'); ylabel(heatAx, '时间 / ms');

% 独立色阶条（不触发重算）
scaleRow = uigridlayout(mainLayout, [1 8], ...
    'ColumnWidth', {64, 90, 32, 68, 32, 68, 92, '1x'}, ...
    'Padding', [8 3 8 3], 'ColumnSpacing', 5, 'BackgroundColor', [0.96 0.97 0.98]);
uilabel(scaleRow, 'Text', '热图色阶', 'FontWeight', 'bold', 'FontColor', ink);
scaleModeMenu = uidropdown(scaleRow, 'Items', {'自动', '完整范围', '锁定'}, ...
    'Value', '自动', 'ValueChangedFcn', @(~,~) applyUserScale(false));
uilabel(scaleRow, 'Text', '下限');
scaleLowField = uieditfield(scaleRow, 'numeric', 'Value', -40, 'Limits', [-Inf Inf]);
uilabel(scaleRow, 'Text', '上限');
scaleHighField = uieditfield(scaleRow, 'numeric', 'Value', 0, 'Limits', [-Inf Inf]);
uibutton(scaleRow, 'Text', '应用并锁定', 'ButtonPushedFcn', @(~,~) applyUserScale(true), ...
    'BackgroundColor', [0.86 0.91 0.93], 'FontColor', ink);
uilabel(scaleRow, 'Text', '拖动色条不触发重算', 'FontSize', 10.5, 'FontColor', ink);

scaleInfoLabel = uilabel(mainLayout, 'Text', '', 'FontSize', 11, 'FontColor', ink);

% 单脉冲复核工具栏
traceBar = uigridlayout(mainLayout, [1 11], ...
    'ColumnWidth', {62, 68, 62, 72, 72, 74, 62, 62, 72, 82, '1x'}, ...
    'Padding', [6 4 6 4], 'ColumnSpacing', 5, 'BackgroundColor', barColor);
uibutton(traceBar, 'Text', '◀ 上一列', 'ButtonPushedFcn', @(~,~) stepPulse(-1));
curPulseField = uieditfield(traceBar, 'numeric', 'Value', 1, 'RoundFractionalValues', 'on', ...
    'Limits', [1 Inf], 'ValueChangedFcn', @(~,~) onPulseChanged());
uibutton(traceBar, 'Text', '下一列 ▶', 'ButtonPushedFcn', @(~,~) stepPulse(1));
chkOverlayRaw = uicheckbox(traceBar, 'Text', '原波形', 'Value', false, 'ValueChangedFcn', @(~,~) drawTrace());
chkZoomWin = uicheckbox(traceBar, 'Text', '聚焦窗', 'Value', false, 'ValueChangedFcn', @(~,~) drawTrace());
acceptBtn = uibutton(traceBar, 'Text', '接受', 'Enable', 'off', 'ButtonPushedFcn', @(~,~) doPeakAction('accept'));
rejectBtn = uibutton(traceBar, 'Text', '剔除', 'Enable', 'off', 'ButtonPushedFcn', @(~,~) doPeakAction('reject'), ...
    'BackgroundColor', [0.86 0.34 0.28], 'FontColor', 'white');
promoteBtn = uibutton(traceBar, 'Text', '设为代表', 'Enable', 'off', 'ButtonPushedFcn', @(~,~) doPeakAction('promote'));
addManualBtn = uibutton(traceBar, 'Text', '＋手工补点', 'Enable', 'off', 'ButtonPushedFcn', @toggleManualAdd);
undoBtn = uibutton(traceBar, 'Text', '撤销', 'Enable', 'off', 'ButtonPushedFcn', @doUndo);
traceMetaLabel = uilabel(traceBar, 'Text', '', 'FontSize', 11, 'FontColor', ink);

traceAx = uiaxes(mainLayout);
styleAxes(traceAx);
pbaspect(traceAx, [2 1 1]);
xlabel(traceAx, '时间 / ms'); ylabel(traceAx, '幅值');

peakTable = uitable(mainLayout, 'ColumnName', ...
    {'ID', '窗号', '时刻(ms)', '相对首峰(ms)', '相邻间距(ms)', '原始幅值', '归一幅值', '显著度', '半高宽(ms)', '组号', '来源', '复核状态'}, ...
    'RowName', {}, 'SelectionType', 'row', 'CellSelectionCallback', @onPeakRowSelect);

uilabel(mainLayout, 'Text', '');

% --- Tab 2: 逐脉冲计数与总表 ---
sumLayout = uigridlayout(summaryTab, [4 1], 'RowHeight', {36, 300, 34, '1x'}, ...
    'Padding', [10 8 10 8], 'RowSpacing', 6, 'BackgroundColor', 'white');

countBar = uigridlayout(sumLayout, [1 2], 'ColumnWidth', {'1x', 240}, ...
    'Padding', [8 4 8 4], 'BackgroundColor', barColor);
countSummaryLabel = uilabel(countBar, 'Text', '尚无批量检测结果。', 'FontWeight', 'bold', 'FontColor', ink);
tableSwitch = uidropdown(countBar, 'Items', {'代表峰总表 (highlights)', '全部候选表 (candidates)', '逐脉冲计数表 (counts)'}, ...
    'Value', '代表峰总表 (highlights)', 'ValueChangedFcn', @(~,~) updateSummaryTable());

countAx = uiaxes(sumLayout);
styleAxes(countAx);
xlabel(countAx, '脉冲序号'); ylabel(countAx, '代表峰数量');

uilabel(sumLayout, 'Text', '提示：点击下方总表任意一行，将自动跳回「热图与逐脉冲复核」并定位该脉冲。', ...
    'FontSize', 11, 'FontColor', ink);

summaryTable = uitable(sumLayout, 'RowName', {}, 'SelectionType', 'row', ...
    'CellSelectionCallback', @onSummaryRowSelect);

viewport.SizeChangedFcn = @sizeMainPage;
fig.WindowButtonUpFcn = @captureDraggedScale;
sizeMainPage();
drawnow;
scroll(mainLayout, 'top');

%% ==================== 布局与通用辅助 ====================
    function nop(varargin)
    end

    function wide(ctrl, r)
        ctrl.Layout.Row = r;
        ctrl.Layout.Column = [1 3];
    end

    function sectionHeading(r, txt)
        lbl = uilabel(form, 'Text', ['  ' txt], 'FontWeight', 'bold', ...
            'FontColor', [0.10 0.28 0.34], 'BackgroundColor', [0.87 0.92 0.94]);
        wide(lbl, r);
    end

    function h = numFields(r, labelTxt, initVals, cb)
        lbl = uilabel(form, 'Text', labelTxt);
        lbl.Layout.Row = r; lbl.Layout.Column = 1;
        h = gobjects(1, numel(initVals));
        for idx = 1:numel(initVals)
            f = uieditfield(form, 'numeric', 'Value', initVals(idx), 'ValueChangedFcn', cb);
            f.Layout.Row = r;
            if isscalar(initVals)
                f.Layout.Column = [2 3];
            else
                f.Layout.Column = idx + 1;
            end
            h(idx) = f;
        end
    end

    function sizeMainPage(varargin)
        vp = getpixelposition(viewport);
        if vp(3) < 50 || vp(4) < 50, return; end
        topFixed = 38 + 34 + 20 + 3 * mainLayout.RowSpacing + sum(mainLayout.Padding([2 4]));
        heatH = max(260, floor(vp(4)) - topFixed);
        traceW = max(200, vp(3) - sum(mainLayout.Padding([1 3])) - 20);
        traceH = max(220, round(traceW / 2));
        mainLayout.RowHeight = {38, heatH, 34, 20, 38, traceH, 210, 14};
    end

    function showHelp(varargin)
        msg = { ...
            '「回波亮点检测与后处理」首版工作流：', ...
            '1. 左侧选择 NI/LTT 文件夹或 MAT 回波矩阵，确认通道与采集方式。', ...
            '2. 如需预处理，分别执行带通滤波或 CW/LFM 匹配滤波（自动校正模板时延）。', ...
            '3. 在热图上选择「点两次选搜索窗/屏蔽区」或直接输入时间边界（搜索窗互不重叠）。', ...
            '4. 调好显著度与最小峰间距后，先点「先试算当前脉冲」，满意再「应用到选定脉冲范围」。', ...
            '5. 点击热图任意列，在下方 2:1 单脉冲图与明细表中人工复核（接受/剔除/设为代表/补点/撤销）。', ...
            '6. 导出时同时保留自动检测候选与复核后结果，方便日后追溯。'};
        uialert(fig, strjoin(msg, newline), '使用说明', 'Icon', 'info');
    end

%% ==================== 搜索窗与干扰屏蔽区动态列表 ====================
    function appendSearchWin(varargin)
        n = size(winEdits, 1) + 1;
        winLabels(n) = uilabel(winEditor, 'Text', sprintf('窗 %d /ms', n));
        defaultLow = 0; defaultHigh = 10;
        if ~isempty(dataset)
            tMs = dataset.timeSeconds * 1e3;
            defaultLow = tMs(1); defaultHigh = tMs(end);
        end
        winEdits(n, 1) = uieditfield(winEditor, 'numeric', 'Value', defaultLow, 'ValueChangedFcn', @(~,~) onGateEdited());
        winEdits(n, 2) = uieditfield(winEditor, 'numeric', 'Value', defaultHigh, 'ValueChangedFcn', @(~,~) onGateEdited());
        winDelBtns(n) = uibutton(winEditor, 'Text', '−', 'ButtonPushedFcn', @dropSearchWin);
        relayoutWinEditor();
        syncPickItems();
        if n > 1, onGateEdited(); end
    end

    function dropSearchWin(src, ~)
        idx = find(winDelBtns == src, 1);
        if isempty(idx) || size(winEdits, 1) <= 1, return; end
        delete(winLabels(idx)); delete(winEdits(idx, :)); delete(winDelBtns(idx));
        winLabels(idx) = []; winEdits(idx, :) = []; winDelBtns(idx) = [];
        relayoutWinEditor();
        syncPickItems();
        onGateEdited();
    end

    function relayoutWinEditor()
        n = size(winEdits, 1);
        winEditor.RowHeight = repmat({26}, 1, n + 1);
        form.RowHeight{16} = 26 * (n + 1) + 3 * n;
        for j = 1:n
            winLabels(j).Text = sprintf('窗 %d /ms', j);
            winLabels(j).Layout.Row = j; winLabels(j).Layout.Column = 1;
            winEdits(j, 1).Layout.Row = j; winEdits(j, 1).Layout.Column = 2;
            winEdits(j, 2).Layout.Row = j; winEdits(j, 2).Layout.Column = 3;
            winDelBtns(j).Layout.Row = j; winDelBtns(j).Layout.Column = 4;
            winDelBtns(j).Enable = matlab.lang.OnOffSwitchState(n > 1);
        end
        addWinBtn.Layout.Row = n + 1; addWinBtn.Layout.Column = [1 4];
    end

    function appendMaskZone(varargin)
        n = size(maskEdits, 1) + 1;
        maskLabels(n) = uilabel(maskEditor, 'Text', sprintf('屏蔽 %d', n));
        maskEdits(n, 1) = uieditfield(maskEditor, 'numeric', 'Value', 0, 'ValueChangedFcn', @(~,~) onGateEdited());
        maskEdits(n, 2) = uieditfield(maskEditor, 'numeric', 'Value', 0, 'ValueChangedFcn', @(~,~) onGateEdited());
        maskDelBtns(n) = uibutton(maskEditor, 'Text', '−', 'ButtonPushedFcn', @dropMaskZone);
        relayoutMaskEditor();
        syncPickItems();
        onGateEdited();
    end

    function dropMaskZone(src, ~)
        idx = find(maskDelBtns == src, 1);
        if isempty(idx), return; end
        delete(maskLabels(idx)); delete(maskEdits(idx, :)); delete(maskDelBtns(idx));
        maskLabels(idx) = []; maskEdits(idx, :) = []; maskDelBtns(idx) = [];
        relayoutMaskEditor();
        syncPickItems();
        onGateEdited();
    end

    function relayoutMaskEditor()
        n = size(maskEdits, 1);
        maskEditor.RowHeight = repmat({26}, 1, n + 1);
        form.RowHeight{17} = 26 * (n + 1) + 3 * n;
        for j = 1:n
            maskLabels(j).Text = sprintf('屏蔽 %d', j);
            maskLabels(j).Layout.Row = j; maskLabels(j).Layout.Column = 1;
            maskEdits(j, 1).Layout.Row = j; maskEdits(j, 1).Layout.Column = 2;
            maskEdits(j, 2).Layout.Row = j; maskEdits(j, 2).Layout.Column = 3;
            maskDelBtns(j).Layout.Row = j; maskDelBtns(j).Layout.Column = 4;
        end
        addMaskBtn.Layout.Row = n + 1; addMaskBtn.Layout.Column = [1 4];
    end

    function syncPickItems()
        pickStart = [];
        items = {'点击查看脉冲', '点两次选脉冲范围'};
        for j = 1:size(winEdits, 1)
            items{end+1} = sprintf('点两次选搜索窗 %d', j); %#ok<AGROW>
        end
        for j = 1:size(maskEdits, 1)
            items{end+1} = sprintf('点两次选屏蔽区 %d', j); %#ok<AGROW>
        end
        pickMenu.Items = items;
        pickMenu.Value = items{1};
    end

    function [wins, masks] = collectGates()
        nW = size(winEdits, 1);
        wins = zeros(nW, 2);
        for j = 1:nW
            wins(j, :) = [winEdits(j, 1).Value, winEdits(j, 2).Value];
        end
        nM = size(maskEdits, 1);
        masks = zeros(0, 2);
        for j = 1:nM
            v1 = maskEdits(j, 1).Value; v2 = maskEdits(j, 2).Value;
            if v2 > v1
                masks(end+1, :) = [v1 v2]; %#ok<AGROW>
            end
        end
    end

    function onGateEdited()
        drawHeatOverlays();
        drawTrace();
    end

%% ==================== 数据加载（NI / LTT / MAT） ====================
    function sourceChanged(varargin)
        statusLabel.Text = ['已切换入口：' sourceMenu.Value '，请点击「选择数据…」。'];
    end

    function loadData(varargin)
        try
            switch sourceMenu.Value
                case 'NI 文件夹'
                    sel = uigetdir(pwd, '选择含 JSON 与 MAT 的 NI 采集文件夹');
                    if isequal(sel, 0), return; end
                    loadNIFolder(sel, '');
                case 'LTT 文件夹'
                    sel = uigetdir(pwd, '选择 LTT 工况文件夹或其 00000 子目录');
                    if isequal(sel, 0), return; end
                    loadLTTFolder(sel, '');
                case 'MAT 回波矩阵'
                    [fn, fp] = uigetfile('*.mat', '选择回波矩阵 MAT 文件', pwd);
                    if isequal(fn, 0), return; end
                    loadMatFlow(fullfile(fp, fn));
            end
        catch err
            if strcmp(err.identifier, 'echoHighlight:Cancelled')
                statusLabel.Text = '已取消读取，保留原有状态。';
                return
            end
            uialert(fig, err.message, '读取数据失败');
        end
    end

    function loadNIFolder(sel, ch)
        dlg = uiprogressdlg(fig, 'Title', '读取 NI 数据', 'Message', '正在扫描通道…', ...
            'Cancelable', 'on', 'CancelText', '取消');
        c = onCleanup(@() close(dlg));
        cb = @(frac, msg) updateProgress(dlg, frac, msg);
        if isempty(ch)
            [~, id] = fileparts(sel);
            files = dir(fullfile(sel, [id '_*_ai*.mat']));
            tok = regexp({files.name}, ['^' regexptranslate('escape', id) '_[1-9]\d*_(ai\d+)\.mat$'], 'tokens', 'once');
            tok = tok(~cellfun(@isempty, tok));
            assert(~isempty(tok), '目录中未找到符合命名规则的 NI 通道 MAT 文件。');
            chs = unique(cellfun(@(t) t{1}, tok, 'UniformOutput', false));
            [~, ord] = sort(cellfun(@(s) str2double(s(3:end)), chs));
            chs = chs(ord);
            ch = chs{1};
            if numel(chs) > 1
                [idx, ok] = listdlg('PromptString', '选择要读取的通道', 'SelectionMode', 'single', ...
                    'ListString', chs, 'Name', '选择 NI 通道');
                if ~ok, return; end
                ch = chs{idx};
            end
        end
        ds = eh.readNI(sel, ch, cb);
        commitDataset(ds);
    end

    function loadLTTFolder(sel, ch)
        dlg = uiprogressdlg(fig, 'Title', '读取 LTT 数据', 'Message', '正在读取 CSV 与 TXT…', ...
            'Cancelable', 'on', 'CancelText', '取消');
        c = onCleanup(@() close(dlg));
        cb = @(frac, msg) updateProgress(dlg, frac, msg);
        ds = eh.readLTT(sel, ch, cb);
        commitDataset(ds);
    end

    function loadMatFlow(matPath)
        info = eh.inspectMat(matPath);
        if info.isTSResultOnly
            uialert(fig, info.message, '仅含 TS 数值文件', 'Icon', 'warning');
            return
        end
        assert(~isempty(info.matrixVars), '%s', info.message);
        opts = promptMatOptions(info);
        if isempty(opts), return; end
        ds = eh.loadMatDataset(matPath, opts);
        commitDataset(ds);
    end

    function opts = promptMatOptions(info)
        opts = [];
        d = uifigure('Name', 'MAT 回波矩阵预览与确认', 'Position', [200 160 540 460], ...
            'WindowStyle', 'modal', 'Color', mist);
        g = uigridlayout(d, [11 3], 'ColumnWidth', {138, '1x', '1x'}, ...
            'RowHeight', {28, 48, 28, 28, 28, 28, 28, 28, 28, 28, 36}, ...
            'Padding', [14 12 14 12], 'RowSpacing', 6, 'ColumnSpacing', 8);

        matNames = {info.matrixVars.name};
        uilabel(g, 'Text', '回波矩阵变量');
        mDrop = uidropdown(g, 'Items', matNames, 'Value', matNames{1});
        mDrop.Layout.Row = 1; mDrop.Layout.Column = [2 3];

        previewLbl = uilabel(g, 'Text', '', 'WordWrap', 'on', 'FontColor', ink, ...
            'BackgroundColor', [0.92 0.95 0.96]);
        previewLbl.Layout.Row = 2; previewLbl.Layout.Column = [1 3];

        uilabel(g, 'Text', '矩阵方向');
        chkTrans = uicheckbox(g, 'Text', '转置（当前行为脉冲、列为快时间时勾选）', 'Value', false);
        chkTrans.Layout.Row = 3; chkTrans.Layout.Column = [2 3];

        uilabel(g, 'Text', '时间轴来源');
        tMode = uidropdown(g, 'Items', {'按采样率与起点生成', '使用 MAT 中时间向量'}, ...
            'ItemsData', {'fs', 'vector'}, 'Value', 'fs');
        tMode.Layout.Row = 4; tMode.Layout.Column = [2 3];

        vecNames = ['(无)', {info.vectorVars.name}];
        uilabel(g, 'Text', '时间向量 / 单位');
        tVarDrop = uidropdown(g, 'Items', vecNames, 'Value', vecNames{1}, 'Enable', 'off');
        tVarDrop.Layout.Row = 5; tVarDrop.Layout.Column = 2;
        tUnitDrop = uidropdown(g, 'Items', {'s', 'ms'}, 'Value', 's', 'Enable', 'off');
        tUnitDrop.Layout.Row = 5; tUnitDrop.Layout.Column = 3;

        uilabel(g, 'Text', '采样率(Hz) / 窗起点(ms)');
        defaultFs = 1e6;
        fsCand = find(strcmpi({info.scalarVars.name}, 'fs'), 1);
        if ~isempty(fsCand), defaultFs = info.scalarVars(fsCand).value; end
        fsEdit = uieditfield(g, 'numeric', 'Value', defaultFs);
        fsEdit.Layout.Row = 6; fsEdit.Layout.Column = 2;
        t0Edit = uieditfield(g, 'numeric', 'Value', 0);
        t0Edit.Layout.Row = 6; t0Edit.Layout.Column = 3;

        uilabel(g, 'Text', '时间起点约定');
        origDrop = uidropdown(g, 'Items', {'从 t0 起算 (0:N-1)/fs', '从 t0+1/fs 起算 (1:N)/fs'}, ...
            'ItemsData', {'0', '1'}, 'Value', '0');
        origDrop.Layout.Row = 7; origDrop.Layout.Column = [2 3];

        uilabel(g, 'Text', '输入信号类型');
        inTypeDrop = uidropdown(g, 'Items', {'原始实波形', '带通波形', '复解析信号', '匹配输出', '幅值包络'}, ...
            'Value', info.matrixVars(1).suggestInputType);
        inTypeDrop.Layout.Row = 8; inTypeDrop.Layout.Column = [2 3];

        uilabel(g, 'Text', '脉冲/角度向量(可选)');
        axVarDrop = uidropdown(g, 'Items', vecNames, 'Value', vecNames{1});
        axVarDrop.Layout.Row = 9; axVarDrop.Layout.Column = 2;
        axKindDrop = uidropdown(g, 'Items', {'脉冲号', '角度 (°)'}, 'ItemsData', {'pulse', 'angle'}, 'Value', 'pulse');
        axKindDrop.Layout.Row = 9; axKindDrop.Layout.Column = 3;

        chkRel = uicheckbox(g, 'Text', '仅相对窗首时间（已截窗片段）', 'Value', false);
        chkRel.Layout.Row = 10; chkRel.Layout.Column = [1 2];
        chkNorm = uicheckbox(g, 'Text', '输入已归一化（原始尺度未知）', 'Value', false);
        chkNorm.Layout.Row = 10; chkNorm.Layout.Column = 3;

        btnCancel = uibutton(g, 'Text', '取消', 'ButtonPushedFcn', @(~,~) delete(d));
        btnCancel.Layout.Row = 11; btnCancel.Layout.Column = 2;
        btnOk = uibutton(g, 'Text', '确认导入', 'BackgroundColor', blue, 'FontColor', 'white', ...
            'ButtonPushedFcn', @confirmMat);
        btnOk.Layout.Row = 11; btnOk.Layout.Column = 3;

        mDrop.ValueChangedFcn = @(~,~) updatePreview();
        chkTrans.ValueChangedFcn = @(~,~) updatePreview();
        tMode.ValueChangedFcn = @(~,~) toggleTimeMode();
        updatePreview();

        uiwait(d);

        function toggleTimeMode()
            isVec = strcmp(tMode.Value, 'vector');
            tVarDrop.Enable = matlab.lang.OnOffSwitchState(isVec);
            tUnitDrop.Enable = matlab.lang.OnOffSwitchState(isVec);
            fsEdit.Enable = matlab.lang.OnOffSwitchState(~isVec);
            t0Edit.Enable = matlab.lang.OnOffSwitchState(~isVec);
            origDrop.Enable = matlab.lang.OnOffSwitchState(~isVec);
        end

        function updatePreview()
            idx = find(strcmp(matNames, mDrop.Value), 1);
            mv = info.matrixVars(idx);
            sz = mv.size;
            if chkTrans.Value, sz = fliplr(sz); end
            cpxStr = '实数'; if mv.isComplex, cpxStr = '复数'; end
            previewLbl.Text = sprintf('变量 %s：采样点数=%d × 脉冲数=%d · %s (%s) · 最大绝对值=%.5g · 建议类型：%s', ...
                mv.name, sz(1), sz(2), mv.class, cpxStr, mv.maxAbs, mv.suggestInputType);
            inTypeDrop.Value = mv.suggestInputType;
            chkNorm.Value = mv.isNonNegative && abs(mv.maxAbs - 1) < 1e-3;
        end

        function confirmMat(varargin)
            opts = struct();
            opts.matrixVar = mDrop.Value;
            opts.transposeMatrix = chkTrans.Value;
            opts.timeMode = tMode.Value;
            if strcmp(tMode.Value, 'vector') && ~strcmp(tVarDrop.Value, '(无)')
                opts.timeVar = tVarDrop.Value;
                opts.timeUnit = tUnitDrop.Value;
            else
                opts.timeMode = 'fs';
                opts.fs_Hz = fsEdit.Value;
                opts.t0_ms = t0Edit.Value;
                opts.indexOrigin = origDrop.Value;
            end
            opts.inputType = inTypeDrop.Value;
            opts.isRelativeWindowTime = chkRel.Value;
            opts.isTruncatedWindow = chkRel.Value;
            opts.originalScaleUnknown = chkNorm.Value;
            if ~strcmp(axVarDrop.Value, '(无)')
                opts.axisVar = axVarDrop.Value;
                opts.axisKind = axKindDrop.Value;
            else
                opts.axisVar = '';
                opts.axisKind = 'pulse';
            end
            delete(d);
        end
    end

    function changeChannel(src, ~)
        if isempty(dataset), return; end
        try
            if strcmp(dataset.dataOrigin, 'NI')
                loadNIFolder(dataset.folder, src.Value);
            elseif strcmp(dataset.dataOrigin, 'LTT')
                loadLTTFolder(dataset.folder, src.Value);
            end
        catch err
            src.Value = dataset.channel;
            if strcmp(err.identifier, 'echoHighlight:Cancelled')
                statusLabel.Text = '已取消切换通道。';
                return
            end
            uialert(fig, err.message, '切换通道失败');
        end
    end

    function commitDataset(ds)
        dataset = ds;
        bpSignal = []; mfSignal = []; hpSignal = [];
        rState = []; materialized = []; selectedRowCandId = [];
        manualAddMode = false;
        addManualBtn.BackgroundColor = [0.96 0.96 0.96];
        addManualBtn.FontColor = [0 0 0];

        channelMenu.Items = ds.channels;
        channelMenu.Value = ds.channel;
        channelMenu.Enable = matlab.lang.OnOffSwitchState(numel(ds.channels) > 1);

        inputTypeMenu.Value = ds.inputType;
        nPulses = size(ds.values, 2);
        pulseRange(1).Value = 1; pulseRange(2).Value = nPulses;
        curPulseField.Limits = [1 max(1, nPulses)];
        curPulseField.Value = 1;

        if ~isempty(ds.importedAngles)
            acqMode.Value = '合置角度扫描';
            angleRange(1).Value = ds.importedAngles(1);
            angleRange(2).Value = ds.importedAngles(end);
            set(angleRange, 'Enable', 'on');
        end

        % 更新第 1 个搜索窗默认覆盖整个时间范围
        tMs = ds.timeSeconds * 1e3;
        if size(winEdits, 1) >= 1
            winEdits(1, 1).Value = tMs(1);
            winEdits(1, 2).Value = tMs(end);
        end

        setActiveSignal(ds.values, ds.inputType, ['原始输入 (' ds.inputType ')']);

        relTag = '';
        if ds.isRelativeWindowTime, relTag = ' · [相对窗首]'; end
        scaleTag = '';
        if ds.originalScaleUnknown, scaleTag = ' · [原始尺度未知]'; end
        gapTag = '';
        if ~isempty(ds.missingNumbers), gapTag = sprintf(' · 缺号 %d 次', numel(ds.missingNumbers)); end

        dataInfoLabel.Text = sprintf('%s · %d点×%d列 · %g kHz%s%s%s', ...
            ds.datasetName, size(ds.values, 1), nPulses, ds.fs / 1e3, relTag, scaleTag, gapTag);
        headerSummary.Text = sprintf('%s | %s | %s | %.3f–%.3f ms%s', ...
            ds.dataOrigin, ds.datasetName, ds.channel, tMs(1), tMs(end), relTag);

        refreshBtn.Enable = 'on';
        setReviewButtonsEnabled(false);
        setExportButtonsEnabled(false);
        reviewInfoLabel.Text = '复核状态：数据已就绪，请先试算或批量检测。';
        peakTable.Data = {};
        summaryTable.Data = {};
        cla(countAx);

        drawHeatmap();
        drawTrace();
        statusLabel.Text = sprintf('已加载 %s（%d 点 × %d 脉冲，fs = %g kHz）。', ...
            ds.datasetName, size(ds.values, 1), nPulses, ds.fs / 1e3);
    end

%% ==================== 预处理与包络 ====================
    function setActiveSignal(sig, inType, desc)
        activeSignal = sig;
        activeSignalDesc = desc;
        envelopeMat = eh.preprocess('envelope', sig, dataset.fs, struct('inputType', inType));
        edgeNote = '';
        if ~isempty(dataset) && dataset.isTruncatedWindow
            edgeNote = '（已截窗输入，注意边界影响）';
        end
        sigActiveLabel.Text = ['检测信号：' desc edgeNote];
    end

    function inputTypeChanged(varargin)
        if isempty(dataset), return; end
        setActiveSignal(activeSignal, inputTypeMenu.Value, ['当前信号按「' inputTypeMenu.Value '」取包络']);
        drawHeatmap();
        drawTrace();
    end

    function tplTypeChanged(varargin)
        isCW = strcmp(tplType.Value, 'CW');
        lfmF2.Enable = matlab.lang.OnOffSwitchState(~isCW);
    end

    function hpToggle(varargin)
        on = hpCheck.Value;
        hpCutoff.Enable = matlab.lang.OnOffSwitchState(on);
        hpBtn.Enable = matlab.lang.OnOffSwitchState(on);
    end

    function runBandpass(varargin)
        if isempty(dataset), uialert(fig, '请先导入数据。', '未加载数据'); return; end
        dlg = uiprogressdlg(fig, 'Title', '带通滤波', 'Message', '正在滤波…', ...
            'Cancelable', 'on', 'CancelText', '取消');
        c = onCleanup(@() close(dlg));
        try
            b = [bandFields(1).Value, bandFields(2).Value] * 1e3;
            bpSignal = eh.preprocess('bandpass', dataset.values, dataset.fs, ...
                struct('band_Hz', b), @(f, m) updateProgress(dlg, f, m));
            inputTypeMenu.Value = '带通波形';
            setActiveSignal(bpSignal, '带通波形', sprintf('带通滤波 %.3g–%.3g kHz', b(1)/1e3, b(2)/1e3));
            drawHeatmap(); drawTrace();
            statusLabel.Text = '带通滤波完成。';
        catch err
            if strcmp(err.identifier, 'echoHighlight:Cancelled')
                statusLabel.Text = '已取消带通滤波。'; return
            end
            uialert(fig, err.message, '带通滤波失败');
        end
    end

    function runMatched(varargin)
        if isempty(dataset), uialert(fig, '请先导入数据。', '未加载数据'); return; end
        dlg = uiprogressdlg(fig, 'Title', '匹配滤波', 'Message', '正在匹配滤波（自动时延校正）…', ...
            'Cancelable', 'on', 'CancelText', '取消');
        c = onCleanup(@() close(dlg));
        try
            opts = struct('signalType', tplType.Value, 'pulseWidth_s', pwField.Value * 1e-3);
            if strcmp(tplType.Value, 'CW')
                opts.fCenter_Hz = lfmF1.Value * 1e3;
                tplDesc = sprintf('CW %.3g kHz, %.3g ms', lfmF1.Value, pwField.Value);
            else
                opts.fStart_Hz = lfmF1.Value * 1e3;
                opts.fEnd_Hz = lfmF2.Value * 1e3;
                tplDesc = sprintf('LFM %.3g–%.3g kHz, %.3g ms', lfmF1.Value, lfmF2.Value, pwField.Value);
            end
            srcSig = dataset.values;
            if ~isempty(bpSignal), srcSig = bpSignal; end
            mfSignal = eh.preprocess('matchedfilter', srcSig, dataset.fs, ...
                opts, @(f, m) updateProgress(dlg, f, m));
            inputTypeMenu.Value = '匹配输出';
            setActiveSignal(mfSignal, '匹配输出', ['匹配输出（' tplDesc '，已时延校正）']);
            drawHeatmap(); drawTrace();
            statusLabel.Text = '匹配滤波完成（已校正模板时延）。';
        catch err
            if strcmp(err.identifier, 'echoHighlight:Cancelled')
                statusLabel.Text = '已取消匹配滤波。'; return
            end
            uialert(fig, err.message, '匹配滤波失败');
        end
    end

    function useRawInput(varargin)
        if isempty(dataset), return; end
        inputTypeMenu.Value = dataset.inputType;
        setActiveSignal(dataset.values, dataset.inputType, ['原始输入 (' dataset.inputType ')']);
        drawHeatmap(); drawTrace();
        statusLabel.Text = '已恢复使用原始输入信号。';
    end

    function runPulseHP(varargin)
        if isempty(dataset), uialert(fig, '请先导入数据。', '未加载数据'); return; end
        dlg = uiprogressdlg(fig, 'Title', '脉冲维高通', 'Message', '正在处理…', ...
            'Cancelable', 'on', 'CancelText', '取消');
        c = onCleanup(@() close(dlg));
        try
            hpSignal = eh.preprocess('pulsehighpass', activeSignal, dataset.fs, ...
                struct('cutoff_cyclesPerPulse', hpCutoff.Value), @(f, m) updateProgress(dlg, f, m));
            setActiveSignal(hpSignal, inputTypeMenu.Value, ...
                sprintf('%s + 脉冲维高通(%.4g)', activeSignalDesc, hpCutoff.Value));
            drawHeatmap(); drawTrace();
            statusLabel.Text = '脉冲维高通完成。';
        catch err
            if strcmp(err.identifier, 'echoHighlight:Cancelled')
                statusLabel.Text = '已取消脉冲维高通。'; return
            end
            uialert(fig, err.message, '脉冲维高通失败');
        end
    end

%% ==================== 采集方式与脉冲范围 ====================
    function acqModeChanged(varargin)
        isFixed = strcmp(acqMode.Value, '固定方位重复采集');
        set(angleRange, 'Enable', matlab.lang.OnOffSwitchState(~isFixed));
        drawHeatmap();
        drawCountChart();
    end

    function rangeChanged(varargin)
        drawHeatOverlays();
    end

    function angleChanged(varargin)
        drawHeatmap();
    end

    function [pIdx, angles] = getSelectedRangeAndAngles()
        nTot = size(dataset.values, 2);
        p1 = round(pulseRange(1).Value); p2 = round(pulseRange(2).Value);
        assert(p1 >= 1 && p2 <= nTot && p2 >= p1, ...
            '处理脉冲范围须在 1 至 %d 之间且末脉冲不小于首脉冲。', nTot);
        pIdx = p1:p2;
        if strcmp(acqMode.Value, '固定方位重复采集')
            angles = [];
        elseif ~isempty(dataset.importedAngles) && numel(dataset.importedAngles) == nTot
            angles = dataset.importedAngles(pIdx);
        else
            a1 = angleRange(1).Value; a2 = angleRange(2).Value;
            if isscalar(pIdx)
                angles = a1;
            else
                angles = linspace(a1, a2, numel(pIdx));
            end
        end
    end

    function mergeToggle(varargin)
        mergeGapField.Enable = matlab.lang.OnOffSwitchState(mergeCheck.Value);
    end

    function params = collectDetectParams()
        params = struct();
        params.smooth_ms = max(0, smoothField.Value);
        params.normMode = normModeMenu.Value;
        params.normScope = normScopeMenu.Value;
        params.minProminence = promField.Value;
        params.minDistance_ms = distField.Value;
        params.enableMerge = mergeCheck.Value;
        params.mergeGap_ms = mergeGapField.Value;
        assert(isfinite(params.minProminence) && params.minProminence >= 0, '最小显著度须为非负有限数值。');
        assert(isfinite(params.minDistance_ms) && params.minDistance_ms > 0, '最小峰间距须大于 0 ms。');
        if params.enableMerge
            assert(isfinite(params.mergeGap_ms) && params.mergeGap_ms >= 0, '候选峰合并间隔须为非负有限数值。');
        end
    end

%% ==================== 检测执行（试算当前脉冲 / 批量应用） ====================
    function runSinglePulse(varargin)
        if isempty(dataset), uialert(fig, '请先导入数据。', '未加载数据'); return; end
        try
            k = min(size(dataset.values, 2), max(1, round(curPulseField.Value)));
            curPulseField.Value = k;
            [wins, masks] = collectGates();
            params = collectDetectParams();
            [~, allAngles] = getSelectedRangeAndAngles();
            ang = [];
            if ~isempty(allAngles)
                p1 = round(pulseRange(1).Value); p2 = round(pulseRange(2).Value);
                if k >= p1 && k <= p2
                    ang = allAngles(k - p1 + 1);
                end
            end
            batch = eh.detectBatch(envelopeMat, dataset.timeSeconds, dataset.fs, ...
                k, dataset.recordNumbers, dataset.recordFiles, ang, wins, masks, params, []);
            commitDetection(batch, sprintf('已试算脉冲 %d（发现 %d 候选 / %d 代表峰）', ...
                k, numel(batch.colResults{1}.candidates), numel(batch.colResults{1}.highlights)));
        catch err
            uialert(fig, err.message, '试算当前脉冲失败');
        end
    end

    function runBatchDetect(varargin)
        if isempty(dataset), uialert(fig, '请先导入数据。', '未加载数据'); return; end
        dlg = uiprogressdlg(fig, 'Title', '逐脉冲亮点检测', 'Message', '准备检测…', ...
            'Cancelable', 'on', 'CancelText', '取消');
        c = onCleanup(@() close(dlg));
        try
            [pIdx, angles] = getSelectedRangeAndAngles();
            [wins, masks] = collectGates();
            params = collectDetectParams();
            batch = eh.detectBatch(envelopeMat, dataset.timeSeconds, dataset.fs, ...
                pIdx, dataset.recordNumbers, dataset.recordFiles, angles, ...
                wins, masks, params, @(f, m) updateProgress(dlg, f, m));
            commitDetection(batch, sprintf('批量检测完成：共 %d 列脉冲。', numel(pIdx)));
        catch err
            if strcmp(err.identifier, 'echoHighlight:Cancelled')
                statusLabel.Text = '已取消本轮检测，保留上一次完整结果。';
                return
            end
            uialert(fig, err.message, '批量检测失败');
        end
    end

    function commitDetection(newBatch, msg)
        if isempty(rState)
            rState = eh.reviewState('init', newBatch, activeSignalDesc, dataset.originalScaleUnknown);
        else
            rState = eh.reviewState('archive_redetect', rState, newBatch, activeSignalDesc, dataset.originalScaleUnknown);
        end
        materialized = eh.reviewState('materialize', rState);
        selectedRowCandId = [];
        normInfoLabel.Text = newBatch.normDescription;

        if ~ismember(round(curPulseField.Value), newBatch.pulseIndices)
            curPulseField.Value = newBatch.pulseIndices(1);
        end

        setReviewButtonsEnabled(true);
        setExportButtonsEnabled(true);
        updateReviewStatusLabel();
        drawHeatOverlays();
        drawTrace();
        drawCountChart();
        updateSummaryTable();
        statusLabel.Text = msg;
    end

    function updateReviewStatusLabel()
        if isempty(rState)
            reviewInfoLabel.Text = '复核状态：尚未检测';
            return
        end
        nEdits = numel(rState.edits);
        warnTxt = '';
        if rState.hasArchivedWarning
            warnTxt = ' · [重算前旧复核已归档，请核对]';
        end
        reviewInfoLabel.Text = sprintf('复核状态：已人工修改 %d 次%s', nEdits, warnTxt);
        undoBtn.Enable = matlab.lang.OnOffSwitchState(nEdits > 0);
    end

%% ==================== 绘图：全组热图 + 独立色阶 ====================
    function drawHeatmap()
        if isempty(dataset), return; end
        captureDraggedScale();
        switch layerMenu.Value
            case '检测包络 (dB)'
                mat = envelopeMat;
            case '当前分析信号 (dB)'
                mat = abs(activeSignal);
            otherwise
                mat = abs(dataset.values);
        end
        nCols = size(mat, 2);
        tMs = dataset.timeSeconds * 1e3;
        db = 20 * log10(max(abs(mat), 0));

        cla(heatAx);
        im = imagesc(heatAx, [1 nCols], tMs([1 end]), db);
        im.ButtonDownFcn = @onHeatClick;
        heatAx.YDir = 'normal';
        colormap(heatAx, jet(256));
        xlim(heatAx, [0.5, nCols + 0.5]);
        ylim(heatAx, tMs([1 end]));
        heatAx.ButtonDownFcn = @onHeatClick;

        if strcmp(acqMode.Value, '固定方位重复采集')
            xlabel(heatAx, '脉冲列号 (pin)');
        elseif strcmp(acqMode.Value, '分置接收方位角扫描')
            xlabel(heatAx, '脉冲列号（对应接收方位角见标注）');
        else
            xlabel(heatAx, '脉冲列号（对应目标转角见标注）');
        end
        yTxt = '时间 / ms';
        if dataset.isRelativeWindowTime, yTxt = '相对窗首时间 / ms'; end
        ylabel(heatAx, yTxt);

        applyScaleToHeat(im);
        styleAxes(heatAx);
        disableDefaultInteractivity(heatAx);
        drawHeatOverlays();
    end

    function applyScaleToHeat(im)
        data = im.CData;
        finiteMask = isfinite(data);
        if ~any(finiteMask(:))
            colorbar(heatAx, 'off');
            setappdata(heatAx, 'scaleBounds', []);
            scaleInfoLabel.Text = '当前热图全为零或无有效数据。';
            return
        end
        if strcmp(heatScale.mode, '锁定') && numel(heatScale.limits) == 2
            bounds = heatScale.limits;
            ticks = linspace(bounds(1), bounds(2), 6);
        else
            [lo, hi, ticks] = eh.calcColorScale(data, strcmp(heatScale.mode, '完整范围'));
            bounds = [lo hi];
        end
        clim(heatAx, bounds);
        cb = colorbar(heatAx);
        cb.Ticks = ticks;
        setappdata(heatAx, 'scaleBarHandle', cb);
        setappdata(heatAx, 'scaleBounds', bounds);
        scaleLowField.Value = bounds(1);
        scaleHighField.Value = bounds(2);
        scaleModeMenu.Value = heatScale.mode;
        total = numel(data);
        below = nnz(data < bounds(1));
        above = nnz(finiteMask & data > bounds(2));
        scaleInfoLabel.Text = sprintf('%s · 色阶 [%.4g, %.4g] dB · 低于下限 %.2f%% · 高于上限 %.2f%%', ...
            heatScale.mode, bounds(1), bounds(2), 100 * below / total, 100 * above / total);
    end

    function applyUserScale(manualLock)
        if isempty(dataset), return; end
        if manualLock
            lo = scaleLowField.Value; hi = scaleHighField.Value;
            if ~isfinite(lo) || ~isfinite(hi) || lo >= hi
                uialert(fig, '请输入有限且下限小于上限的色阶范围。', '色阶范围');
                return
            end
            heatScale.mode = '锁定';
            heatScale.limits = [lo hi];
        else
            heatScale.mode = scaleModeMenu.Value;
            if strcmp(heatScale.mode, '锁定')
                heatScale.limits = heatAx.CLim;
            else
                heatScale.limits = [];
            end
        end
        im = findobj(heatAx, 'Type', 'image');
        if ~isempty(im), applyScaleToHeat(im(1)); end
    end

    function captureDraggedScale(varargin)
        prev = getappdata(heatAx, 'scaleBounds');
        cb = getappdata(heatAx, 'scaleBarHandle');
        if isempty(prev) || ~isgraphics(cb, 'colorbar') || isempty(findobj(heatAx, 'Type', 'image'))
            return
        end
        cur = heatAx.CLim;
        if isequal(cur, prev) && strcmp(cb.LimitsMode, 'manual')
            cur = cb.Limits;
        end
        if isequal(cur, prev) || any(~isfinite(cur)) || cur(1) >= cur(2)
            return
        end
        heatScale.mode = '锁定';
        heatScale.limits = cur;
        im = findobj(heatAx, 'Type', 'image');
        if ~isempty(im), applyScaleToHeat(im(1)); end
    end

    function drawHeatOverlays()
        delete(gateHandles(isgraphics(gateHandles)));
        gateHandles = gobjects(0);
        if isempty(dataset), return; end

        hold(heatAx, 'on');
        nCols = size(dataset.values, 2);
        [wins, masks] = collectGates();

        % 当前处理脉冲范围竖虚线
        p1 = pulseRange(1).Value; p2 = pulseRange(2).Value;
        gateHandles(end+1) = xline(heatAx, p1, 'w:', 'LineWidth', 1.0, 'HitTest', 'off');
        gateHandles(end+1) = xline(heatAx, p2, 'w:', 'LineWidth', 1.0, 'HitTest', 'off');
        % 当前查看脉冲高亮线
        curP = curPulseField.Value;
        gateHandles(end+1) = xline(heatAx, curP, 'w--', 'LineWidth', 1.4, 'HitTest', 'off');

        if chkShowWin.Value
            for j = 1:size(wins, 1)
                if wins(j, 2) > wins(j, 1)
                    gateHandles(end+1) = yline(heatAx, wins(j, 1), 'm-', 'LineWidth', 1.1, ...
                        'Label', sprintf('窗%d', j), 'LabelColor', 'm', 'HitTest', 'off'); %#ok<AGROW>
                    gateHandles(end+1) = yline(heatAx, wins(j, 2), 'm-', 'LineWidth', 1.1, 'HitTest', 'off'); %#ok<AGROW>
                end
            end
        end

        if chkShowMask.Value
            for j = 1:size(masks, 1)
                px = [0.5, nCols + 0.5, nCols + 0.5, 0.5];
                py = [masks(j, 1), masks(j, 1), masks(j, 2), masks(j, 2)];
                gateHandles(end+1) = patch(heatAx, px, py, [0.55 0.55 0.55], ...
                    'FaceAlpha', 0.35, 'EdgeColor', [0.85 0.85 0.85], 'LineStyle', '--', 'HitTest', 'off'); %#ok<AGROW>
            end
        end

        if ~isempty(materialized)
            ct = materialized.candidatesTable;
            ht = materialized.highlightsTable;
            if chkShowCand.Value && height(ct) > 0
                nonSel = ct(~ct.ReviewSelected, :);
                if height(nonSel) > 0
                    gateHandles(end+1) = scatter(heatAx, nonSel.PulseIndex, nonSel.Time_ms, ...
                        24, [0.82 0.84 0.86], 'o', 'LineWidth', 0.9, 'HitTest', 'off');
                end
            end
            if chkShowHigh.Value && height(ht) > 0
                gateHandles(end+1) = scatter(heatAx, ht.PulseIndex, ht.Time_ms, ...
                    34, [1.0 0.42 0.10], 'filled', 'MarkerEdgeColor', 'w', ...
                    'LineWidth', 0.7, 'HitTest', 'off');
            end
        end
        hold(heatAx, 'off');
    end

%% ==================== 交互点选（热图 & 单脉冲图） ====================
    function armPick(varargin)
        pickStart = [];
        if strcmp(pickMenu.Value, '点击查看脉冲')
            statusLabel.Text = '当前模式：点击热图任意列查看并复核该脉冲。';
        else
            statusLabel.Text = ['选区模式（' pickMenu.Value '）：请在图上依次点击两个边界。'];
        end
    end

    function onHeatClick(~, event)
        if isempty(dataset), return; end
        pt = event.IntersectionPoint;
        col = min(size(dataset.values, 2), max(1, round(pt(1))));
        tVal = pt(2);
        if strcmp(pickMenu.Value, '点击查看脉冲')
            curPulseField.Value = col;
            selectedRowCandId = [];
            onPulseChanged();
            return
        end
        if strcmp(pickMenu.Value, '点两次选脉冲范围')
            applyTwoPointBoundary(pulseRange, col, true);
        elseif startsWith(pickMenu.Value, '点两次选搜索窗 ')
            idx = str2double(extractAfter(pickMenu.Value, '点两次选搜索窗 '));
            applyTwoPointBoundary(winEdits(idx, :), tVal, false);
        elseif startsWith(pickMenu.Value, '点两次选屏蔽区 ')
            idx = str2double(extractAfter(pickMenu.Value, '点两次选屏蔽区 '));
            applyTwoPointBoundary(maskEdits(idx, :), tVal, false);
        end
    end

    function onTraceClick(~, event)
        if isempty(dataset), return; end
        tVal = event.IntersectionPoint(1);
        tMs = dataset.timeSeconds * 1e3;
        tVal = max(tMs(1), min(tMs(end), tVal));

        if manualAddMode
            addManualPeakAtTime(tVal);
            return
        end
        if startsWith(pickMenu.Value, '点两次选搜索窗 ')
            idx = str2double(extractAfter(pickMenu.Value, '点两次选搜索窗 '));
            applyTwoPointBoundary(winEdits(idx, :), tVal, false);
        elseif startsWith(pickMenu.Value, '点两次选屏蔽区 ')
            idx = str2double(extractAfter(pickMenu.Value, '点两次选屏蔽区 '));
            applyTwoPointBoundary(maskEdits(idx, :), tVal, false);
        end
    end

    function applyTwoPointBoundary(targetPair, val, isInt)
        if isempty(pickStart)
            pickStart = val;
            statusLabel.Text = sprintf('已选第一边界 %.5g，请点击另一端。', val);
        else
            b = sort([pickStart val]);
            if isInt, b = round(b); end
            targetPair(1).Value = b(1);
            targetPair(2).Value = b(2);
            pickStart = [];
            pickMenu.Value = '点击查看脉冲';
            onGateEdited();
            statusLabel.Text = sprintf('边界已更新为 [%.5g, %.5g]。', b(1), b(2));
        end
    end

%% ==================== 单脉冲复核图与候选明细表 ====================
    function stepPulse(delta)
        if isempty(dataset), return; end
        nCols = size(dataset.values, 2);
        curPulseField.Value = min(nCols, max(1, round(curPulseField.Value) + delta));
        selectedRowCandId = [];
        onPulseChanged();
    end

    function onPulseChanged()
        if isempty(dataset), return; end
        drawHeatOverlays();
        drawTrace();
    end

    function colPos = findColPosInState(pulseCol)
        colPos = [];
        if isempty(rState), return; end
        colPos = find(rState.autoBatch.pulseIndices == pulseCol, 1);
    end

    function drawTrace()
        if isempty(dataset), return; end
        k = min(size(dataset.values, 2), max(1, round(curPulseField.Value)));
        curPulseField.Value = k;
        tMs = dataset.timeSeconds * 1e3;

        colPos = findColPosInState(k);
        if ~isempty(colPos)
            envRaw = rState.autoBatch.smoothedEnvelope(:, colPos);
            refAmp = rState.autoBatch.normRefPerCol(colPos);
            if refAmp > 0
                yPlot = envRaw / refAmp;
                yLbl = '归一化幅值';
            else
                yPlot = envRaw;
                yLbl = '幅值（全零）';
            end
        else
            envRaw = envelopeMat(:, k);
            m = max(envRaw(isfinite(envRaw)));
            if isempty(m) || m <= 0, m = 1; end
            yPlot = envRaw / m;
            yLbl = '相对幅值（预览）';
        end

        cla(traceAx);
        hold(traceAx, 'on');

        [wins, masks] = collectGates();
        yTop = max([1.12; yPlot(isfinite(yPlot)) * 1.12]);
        if ~isfinite(yTop) || yTop <= 0, yTop = 1.12; end
        yBot = 0;

        if chkOverlayRaw.Value && isreal(activeSignal)
            rawCol = double(activeSignal(:, k));
            mr = max(abs(rawCol(isfinite(rawCol))));
            if isempty(mr) || mr <= 0, mr = 1; end
            hRaw = plot(traceAx, tMs, rawCol / mr, 'Color', [0.76 0.82 0.86], 'LineWidth', 0.7);
            hRaw.ButtonDownFcn = @onTraceClick;
            yBot = -1.05;
        end

        % 绘制干扰屏蔽区底色
        for j = 1:size(masks, 1)
            patch(traceAx, [masks(j, 1) masks(j, 2) masks(j, 2) masks(j, 1)], ...
                [yBot yBot yTop yTop], [0.92 0.88 0.84], 'EdgeColor', 'none', ...
                'FaceAlpha', 0.65, 'HitTest', 'off');
        end

        % 绘制搜索窗边界
        for j = 1:size(wins, 1)
            if wins(j, 2) > wins(j, 1)
                xline(traceAx, wins(j, 1), '-', 'Color', [0.70 0.14 0.52], 'LineWidth', 1.0, ...
                    'Label', sprintf('窗%d', j), 'HitTest', 'off');
                xline(traceAx, wins(j, 2), '-', 'Color', [0.70 0.14 0.52], 'LineWidth', 1.0, 'HitTest', 'off');
            end
        end

        hEnv = plot(traceAx, tMs, yPlot, 'Color', [0.12 0.32 0.54], 'LineWidth', 1.2);
        hEnv.ButtonDownFcn = @onTraceClick;

        % 叠加本列候选峰、代表峰、已剔除峰、手工补点及表格高亮
        recNum = dataset.recordNumbers(k);
        metaStr = sprintf('列 %d · 记录号 %g', k, recNum);
        if ~isempty(colPos)
            cv = eh.reviewState('column_view', rState, colPos);
            if isfinite(cv.angle_deg)
                metaStr = sprintf('%s · %.3g°', metaStr, cv.angle_deg);
            end
            metaStr = sprintf('%s · 状态:%s · 自动%d→复核%d', ...
                metaStr, cv.status, cv.autoHighlightCount, cv.reviewedHighlightCount);

            items = cv.items;
            % 未入选成员候选（灰空心圆）
            mIdx = find(~[items.ReviewSelected] & ~strcmp({items.ReviewStatus}, 'rejected'));
            if ~isempty(mIdx)
                plot(traceAx, [items(mIdx).Time_ms], [items(mIdx).Amplitude_norm], 'o', ...
                    'Color', [0.52 0.56 0.60], 'MarkerSize', 6, 'LineWidth', 1.1, 'HitTest', 'off');
            end
            % 人工剔除峰（灰色叉号）
            rIdx = find(strcmp({items.ReviewStatus}, 'rejected'));
            if ~isempty(rIdx)
                plot(traceAx, [items(rIdx).Time_ms], [items(rIdx).Amplitude_norm], 'x', ...
                    'Color', [0.50 0.50 0.50], 'MarkerSize', 9, 'LineWidth', 1.6, 'HitTest', 'off');
            end
            % 复核有效代表峰（自动=橙色实心圆，手工补点=青色菱形）
            for h = 1:numel(cv.highlights)
                hi = cv.highlights(h);
                if strcmp(hi.Source, 'manual')
                    plot(traceAx, hi.Time_ms, hi.Amplitude_norm, 'd', ...
                        'Color', [0.02 0.45 0.52], 'MarkerFaceColor', [0.10 0.72 0.78], ...
                        'MarkerSize', 7, 'HitTest', 'off');
                else
                    plot(traceAx, hi.Time_ms, hi.Amplitude_norm, 'o', ...
                        'Color', [0.80 0.28 0.08], 'MarkerFaceColor', [1.0 0.44 0.12], ...
                        'MarkerSize', 7, 'HitTest', 'off');
                end
                text(traceAx, hi.Time_ms, hi.Amplitude_norm + 0.04 * (yTop - yBot), ...
                    sprintf('%d', hi.Highlight), 'HorizontalAlignment', 'center', ...
                    'FontWeight', 'bold', 'Color', [0.68 0.18 0.04], 'HitTest', 'off');
            end
            % 表格当前选中行高亮
            if ~isempty(selectedRowCandId)
                sIdx = find([items.CandidateId] == selectedRowCandId, 1);
                if ~isempty(sIdx)
                    plot(traceAx, items(sIdx).Time_ms, items(sIdx).Amplitude_norm, '+', ...
                        'Color', [0.88 0.10 0.10], 'MarkerSize', 14, 'LineWidth', 2.0, 'HitTest', 'off');
                end
            end
            populatePeakTable(cv);
        else
            peakTable.Data = {};
        end

        hold(traceAx, 'off');
        grid(traceAx, 'on');
        ylim(traceAx, [yBot, yTop]);
        if chkZoomWin.Value && ~isempty(wins) && any(wins(:, 2) > wins(:, 1))
            validW = wins(wins(:, 2) > wins(:, 1), :);
            pad = 0.05 * max(0.1, max(validW(:, 2)) - min(validW(:, 1)));
            xlim(traceAx, [min(validW(:, 1)) - pad, max(validW(:, 2)) + pad]);
        else
            xlim(traceAx, tMs([1 end]));
        end
        xLbl = '时间 / ms';
        if dataset.isRelativeWindowTime, xLbl = '相对窗首时间 / ms'; end
        xlabel(traceAx, xLbl); ylabel(traceAx, yLbl);
        title(traceAx, sprintf('单脉冲复核 · %s', metaStr));
        traceMetaLabel.Text = metaStr;
        pbaspect(traceAx, [2 1 1]);
        styleAxes(traceAx);
        traceAx.ButtonDownFcn = @onTraceClick;
        disableDefaultInteractivity(traceAx);
    end

    function populatePeakTable(cv)
        items = cv.items;
        n = numel(items);
        rows = cell(n, 12);
        % 查找每个 item 在 highlights 中的相对延时与相邻间距
        for j = 1:n
            it = items(j);
            relD = NaN; prevG = NaN;
            if ~isempty(cv.highlights)
                hIdx = find([cv.highlights.CandidateId] == it.CandidateId, 1);
                if ~isempty(hIdx)
                    relD = cv.highlights(hIdx).RelativeDelay_ms;
                    prevG = cv.highlights(hIdx).PreviousGap_ms;
                end
            end
            rows(j, :) = { ...
                it.CandidateId, it.WindowIndex, round(it.Time_ms, 4), ...
                round(relD, 4), round(prevG, 4), ...
                round(it.Amplitude_raw, 5), round(it.Amplitude_norm, 4), ...
                round(it.Prominence_norm, 4), round(it.Width_ms, 4), ...
                it.Group, it.Source, translateStatus(it.ReviewStatus)};
        end
        peakTable.Data = rows;
    end

    function s = translateStatus(code)
        switch code
            case 'accepted', s = '有效代表峰';
            case 'rejected', s = '人工剔除';
            case 'promoted', s = '人工设为代表';
            case 'manual_added', s = '手工补点';
            case 'member_unselected', s = '组内成员峰';
            otherwise, s = code;
        end
    end

%% ==================== 人工复核操作 ====================
    function setReviewButtonsEnabled(tf)
        st = matlab.lang.OnOffSwitchState(tf);
        acceptBtn.Enable = st;
        rejectBtn.Enable = st;
        promoteBtn.Enable = st;
        addManualBtn.Enable = st;
        if ~tf, undoBtn.Enable = 'off'; end
    end

    function onPeakRowSelect(~, event)
        if isempty(event.Indices) || isempty(peakTable.Data), return; end
        r = event.Indices(1, 1);
        selectedRowCandId = peakTable.Data{r, 1};
        drawTrace();
    end

    function doPeakAction(act)
        if isempty(rState), return; end
        colPos = findColPosInState(round(curPulseField.Value));
        if isempty(colPos)
            uialert(fig, '当前脉冲不在本次检测结果范围内，请先试算或批量检测。', '无法复核');
            return
        end
        if isempty(selectedRowCandId)
            uialert(fig, '请先在下方明细表中点击选中要操作的一行候选峰。', '未选中峰');
            return
        end
        rState = eh.reviewState(act, rState, colPos, selectedRowCandId);
        materialized = eh.reviewState('materialize', rState);
        updateReviewStatusLabel();
        drawHeatOverlays();
        drawTrace();
        drawCountChart();
        updateSummaryTable();
        statusLabel.Text = sprintf('已对脉冲 %d 的峰 ID=%d 执行「%s」。', ...
            curPulseField.Value, selectedRowCandId, act);
    end

    function toggleManualAdd(varargin)
        if isempty(rState), return; end
        manualAddMode = ~manualAddMode;
        if manualAddMode
            addManualBtn.BackgroundColor = [0.05 0.55 0.60];
            addManualBtn.FontColor = 'white';
            statusLabel.Text = '手工补点已开启：请在单脉冲复核图上点击要补充峰的位置。';
        else
            addManualBtn.BackgroundColor = [0.96 0.96 0.96];
            addManualBtn.FontColor = [0 0 0];
            statusLabel.Text = '已退出手工补点模式。';
        end
    end

    function addManualPeakAtTime(tVal)
        colPos = findColPosInState(round(curPulseField.Value));
        if isempty(colPos)
            uialert(fig, '当前脉冲不在本次检测结果范围内，无法补点。', '手工补点');
            toggleManualAdd();
            return
        end
        tMs = rState.autoBatch.time_ms;
        [~, sIdx] = min(abs(tMs - tVal));
        % 判断落入哪个搜索窗（未落入则记 0）
        wins = rState.autoBatch.searchWindows_ms;
        winIdx = 0; winStart = 1;
        for j = 1:size(wins, 1)
            if tMs(sIdx) >= wins(j, 1) && tMs(sIdx) <= wins(j, 2)
                winIdx = j;
                wSamples = find(tMs >= wins(j, 1) & tMs <= wins(j, 2), 1);
                if ~isempty(wSamples), winStart = wSamples; end
                break
            end
        end
        ampRaw = rState.autoBatch.smoothedEnvelope(sIdx, colPos);
        refAmp = rState.autoBatch.normRefPerCol(colPos);
        if refAmp > 0, ampNorm = ampRaw / refAmp; else, ampNorm = NaN; end

        mp = struct( ...
            'WindowIndex', winIdx, ...
            'SampleIndex', sIdx, ...
            'WindowSampleIndex', sIdx - winStart + 1, ...
            'Time_ms', tMs(sIdx), ...
            'Amplitude_raw', ampRaw, ...
            'Amplitude_norm', ampNorm, ...
            'SignalSource', rState.signalSource);
        rState = eh.reviewState('add_manual', rState, colPos, mp);
        materialized = eh.reviewState('materialize', rState);
        selectedRowCandId = rState.edits(end).CandidateId;
        toggleManualAdd();
        updateReviewStatusLabel();
        drawHeatOverlays();
        drawTrace();
        drawCountChart();
        updateSummaryTable();
        statusLabel.Text = sprintf('已在脉冲 %d 的 %.4f ms 处手工补点。', curPulseField.Value, tMs(sIdx));
    end

    function doUndo(varargin)
        if isempty(rState) || isempty(rState.edits), return; end
        rState = eh.reviewState('undo', rState);
        materialized = eh.reviewState('materialize', rState);
        updateReviewStatusLabel();
        drawHeatOverlays();
        drawTrace();
        drawCountChart();
        updateSummaryTable();
        statusLabel.Text = '已撤销最近一次人工复核操作。';
    end

%% ==================== Tab 2：逐脉冲计数图与总表 ====================
    function drawCountChart()
        if isempty(materialized), return; end
        ct = materialized.countsTable;
        cla(countAx);
        hold(countAx, 'on');
        x = ct.PulseIndex;
        bar(countAx, x, ct.ReviewedHighlightCount, 0.72, ...
            'FaceColor', [0.16 0.44 0.56], 'EdgeColor', 'none', 'DisplayName', '复核后代表峰数');
        plot(countAx, x, ct.AutoHighlightCount, 'o--', ...
            'Color', [0.88 0.42 0.14], 'LineWidth', 1.1, 'MarkerSize', 4, 'DisplayName', '自动代表峰数');

        % 标出无有效数据或全零脉冲
        badMask = strcmp(ct.Status, 'no_valid_data') | strcmp(ct.Status, 'zero_signal');
        if any(badMask)
            scatter(countAx, x(badMask), zeros(nnz(badMask), 1), 40, 'rx', ...
                'LineWidth', 1.4, 'DisplayName', '无有效数据/全零');
        end
        hold(countAx, 'off');
        grid(countAx, 'on');
        xlabel(countAx, '脉冲列号 (pin)');
        ylabel(countAx, '代表峰数量');
        title(countAx, sprintf('逐脉冲代表峰数量（共 %d 列 · 零峰 %d 列 · 异常/无数据 %d 列）', ...
            height(ct), nnz(strcmp(ct.Status, 'ok_zero_peaks')), nnz(badMask)));
        legend(countAx, 'Location', 'northeast');
        styleAxes(countAx);
        countSummaryLabel.Text = sprintf('批量范围 %d–%d · 有效代表峰总计 %d 个 · 人工修改 %d 次', ...
            min(x), max(x), sum(ct.ReviewedHighlightCount), numel(rState.edits));
    end

    function updateSummaryTable()
        if isempty(materialized), return; end
        switch tableSwitch.Value
            case '代表峰总表 (highlights)'
                t = materialized.highlightsTable;
            case '全部候选表 (candidates)'
                t = materialized.candidatesTable;
            otherwise
                t = materialized.countsTable;
        end
        summaryTable.ColumnName = t.Properties.VariableNames;
        summaryTable.Data = t;
    end

    function onSummaryRowSelect(~, event)
        if isempty(event.Indices) || isempty(summaryTable.Data), return; end
        r = event.Indices(1, 1);
        t = summaryTable.Data;
        if istable(t) && ismember('PulseIndex', t.Properties.VariableNames)
            p = t.PulseIndex(r);
            curPulseField.Value = p;
            if ismember('CandidateId', t.Properties.VariableNames)
                selectedRowCandId = t.CandidateId(r);
            else
                selectedRowCandId = [];
            end
            tabs.SelectedTab = mainTab;
            onPulseChanged();
            scroll(mainLayout, 'bottom');
        end
    end

%% ==================== 导出（CSV / MAT / PNG+FIG） ====================
    function setExportButtonsEnabled(tf)
        st = matlab.lang.OnOffSwitchState(tf);
        expCsvBtn.Enable = st;
        expMatBtn.Enable = st;
        expHeatBtn.Enable = st;
        expTraceBtn.Enable = st;
        expCountBtn.Enable = st;
        expBundleBtn.Enable = st;
    end

    function meta = buildDatasetMeta()
        meta = rmfield(dataset, 'values');
        meta.acquisitionMode = acqMode.Value;
        meta.activeSignalDesc = activeSignalDesc;
    end

    function doExportCsv(varargin)
        if isempty(rState), return; end
        outDir = uigetdir(pwd, '选择 CSV 导出目录');
        if isequal(outDir, 0), return; end
        try
            eh.exportResults('csv', outDir, rState);
            statusLabel.Text = ['已导出 candidates.csv / highlights.csv / counts.csv 至 ' outDir];
        catch err
            uialert(fig, err.message, '导出 CSV 失败');
        end
    end

    function doExportMat(varargin)
        if isempty(rState), return; end
        defaultName = [dataset.datasetName '_' dataset.channel '_highlights.mat'];
        [fn, fp] = uiputfile('*.mat', '保存工程快照 MAT', defaultName);
        if isequal(fn, 0), return; end
        try
            eh.exportResults('mat', fullfile(fp, fn), rState, buildDatasetMeta(), ...
                struct('heatScale', heatScale));
            statusLabel.Text = ['已保存工程 MAT：' fn];
        catch err
            uialert(fig, err.message, '导出 MAT 失败');
        end
    end

    function doExportSingleFig(ax, label)
        if isempty(dataset), return; end
        captureDraggedScale();
        defaultName = [dataset.datasetName '_' dataset.channel '_' label '.png'];
        [fn, fp] = uiputfile('*.png', '保存同名 PNG 与可编辑 FIG', defaultName);
        if isequal(fn, 0), return; end
        dlg = uiprogressdlg(fig, 'Title', '导出图形', 'Message', '正在排版并导出 PNG + FIG…', 'Indeterminate', 'on');
        c = onCleanup(@() close(dlg));
        try
            [~, stem] = fileparts(fn);
            eh.exportResults('figure', ax, fullfile(fp, stem), exportSizeMenu.Value, '');
            statusLabel.Text = ['已导出 ' stem '.png 与 ' stem '.fig'];
        catch err
            clear c
            uialert(fig, err.message, '导出图形失败');
        end
    end

    function doExportBundle(varargin)
        if isempty(rState), return; end
        captureDraggedScale();
        parent = uigetdir(pwd, '选择导出位置（将新建结果子文件夹）');
        if isequal(parent, 0), return; end
        dest = fullfile(parent, [dataset.datasetName '_' dataset.channel '_Highlights_' ...
            char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'))]);
        dlg = uiprogressdlg(fig, 'Title', '一键导出', 'Message', '正在写入 CSV 与 MAT…', ...
            'Cancelable', 'on', 'CancelText', '取消');
        c = onCleanup(@() close(dlg));
        try
            mkdir(dest);
            updateProgress(dlg, 0.2, '正在写入 CSV 三表…');
            eh.exportResults('csv', dest, rState);
            updateProgress(dlg, 0.45, '正在写入工程 MAT…');
            eh.exportResults('mat', fullfile(dest, 'echo_highlight_session.mat'), ...
                rState, buildDatasetMeta(), struct('heatScale', heatScale));
            updateProgress(dlg, 0.65, '正在导出全组热图 PNG + FIG…');
            eh.exportResults('figure', heatAx, fullfile(dest, '01_全组热图'), exportSizeMenu.Value, '');
            updateProgress(dlg, 0.82, '正在导出单脉冲复核图 PNG + FIG…');
            eh.exportResults('figure', traceAx, fullfile(dest, sprintf('02_单脉冲复核_pin%d', round(curPulseField.Value))), ...
                exportSizeMenu.Value, '');
            updateProgress(dlg, 0.95, '正在导出逐脉冲计数图 PNG + FIG…');
            eh.exportResults('figure', countAx, fullfile(dest, '03_逐脉冲计数'), exportSizeMenu.Value, '');
            statusLabel.Text = ['已一键导出至 ' dest];
        catch err
            if strcmp(err.identifier, 'echoHighlight:Cancelled')
                statusLabel.Text = ['已取消导出，已写入文件位于 ' dest];
                return
            end
            clear c
            uialert(fig, err.message, '一键导出失败');
        end
    end

    function refreshAllViews(varargin)
        if isempty(dataset), return; end
        drawHeatmap();
        drawTrace();
        drawCountChart();
        updateSummaryTable();
        statusLabel.Text = '已刷新全部视图。';
    end

    function updateProgress(dlg, frac, msg)
        dlg.Value = max(0, min(1, frac));
        dlg.Message = msg;
        drawnow limitrate
        if dlg.CancelRequested
            error('echoHighlight:Cancelled', '已取消。');
        end
    end

    function styleAxes(ax)
        ax.Box = 'on';
        ax.TickDir = 'out';
        ax.LineWidth = 0.8;
        ax.XColor = [0.22 0.30 0.34];
        ax.YColor = ax.XColor;
        ax.GridAlpha = 0.14;
        ax.FontUnits = 'points';
        ax.FontSize = 10;
    end
end
