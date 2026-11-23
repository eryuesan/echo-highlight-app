function exportResults(action, varargin)
%EXPORTRESULTS 导出 CSV 表、MAT 工程快照以及 8×6 / 16×12 cm 的 PNG + 可编辑 FIG。
%   action:
%     'csv'    : eh.exportResults('csv', outDir, reviewState)
%     'mat'    : eh.exportResults('mat', matPath, reviewState, datasetMeta, extraMeta)
%     'figure' : eh.exportResults('figure', sourceAx, outBase, widthCM, titleText)

switch lower(action)
    case 'csv'
        outDir = varargin{1};
        rState = varargin{2};
        if ~isfolder(outDir)
            [ok, msg] = mkdir(outDir);
            assert(ok, '%s', msg);
        end
        mat = eh.reviewState('materialize', rState);
        writetable(mat.candidatesTable, fullfile(outDir, 'candidates.csv'));
        writetable(mat.highlightsTable, fullfile(outDir, 'highlights.csv'));
        writetable(mat.countsTable, fullfile(outDir, 'counts.csv'));

    case 'mat'
        matPath = varargin{1};
        rState = varargin{2};
        datasetMeta = varargin{3};
        extraMeta = struct();
        if numel(varargin) >= 4, extraMeta = varargin{4}; end

        mat = eh.reviewState('materialize', rState);
        session = struct();
        session.exportedAt = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));
        session.datasetMeta = datasetMeta;
        session.extraMeta = extraMeta;
        session.timeSeconds = rState.autoBatch.timeSeconds;
        session.time_ms = rState.autoBatch.time_ms;
        session.fs = rState.autoBatch.fs;
        session.smoothedEnvelope = rState.autoBatch.smoothedEnvelope;
        session.pulseIndices = rState.autoBatch.pulseIndices;
        session.recordNumbers = rState.autoBatch.recordNumbers;
        session.recordFiles = rState.autoBatch.recordFiles;
        session.angles_deg = rState.autoBatch.angles_deg;
        session.searchWindows_ms = rState.autoBatch.searchWindows_ms;
        session.maskZones_ms = rState.autoBatch.maskZones_ms;
        session.params = rState.autoBatch.params;
        session.normMode = rState.autoBatch.normMode;
        session.normScope = rState.autoBatch.normScope;
        session.normRefPerCol = rState.autoBatch.normRefPerCol;
        session.normDescription = rState.autoBatch.normDescription;
        session.signalSource = rState.signalSource;
        session.originalScaleUnknown = rState.originalScaleUnknown;
        session.autoBatch = rState.autoBatch;
        session.manualEdits = rState.edits;
        session.archivedReviews = rState.archivedReviews;
        session.candidatesTable = mat.candidatesTable;
        session.highlightsTable = mat.highlightsTable;
        session.countsTable = mat.countsTable;

        [parent, ~] = fileparts(matPath);
        if ~isempty(parent) && ~isfolder(parent)
            mkdir(parent);
        end
        save(matPath, 'session', '-v7.3');

    case 'figure'
        sourceAx = varargin{1};
        outBase = varargin{2};
        widthCM = double(varargin{3});
        titleText = '';
        if numel(varargin) >= 4, titleText = char(varargin{4}); end
        exportFigurePair(sourceAx, outBase, widthCM, titleText);

    otherwise
        error('echoHighlight:UnknownExportAction', '不支持的导出操作：%s', action);
end
end

function exportFigurePair(sourceAx, outBase, widthCM, titleText)
heightCM = widthCM * 3 / 4;
if widthCM <= 10
    fontPt = 8;
else
    fontPt = 11;
end

paper = figure('Visible', 'off', 'WindowStyle', 'normal', 'Color', 'w', ...
    'Units', 'centimeters', 'Position', [2 2 widthCM heightCM], ...
    'PaperUnits', 'centimeters', 'PaperSize', [widthCM heightCM], ...
    'PaperPosition', [0 0 widthCM heightCM], 'NumberTitle', 'off', 'Name', titleText);
closePaper = onCleanup(@() close(paper));

tiles = tiledlayout(paper, 1, 1, 'Padding', 'tight', 'TileSpacing', 'tight');
ax = nexttile(tiles);

copyobj(flipud(sourceAx.Children), ax);
xlabel(ax, sourceAx.XLabel.String);
ylabel(ax, sourceAx.YLabel.String);
if ~isempty(titleText)
    title(ax, titleText);
else
    title(ax, sourceAx.Title.String);
end
ax.XGrid = sourceAx.XGrid;
ax.YGrid = sourceAx.YGrid;
ax.XDir = sourceAx.XDir;
ax.YDir = sourceAx.YDir;
xlim(ax, sourceAx.XLim);
ylim(ax, sourceAx.YLim);
ax.Box = 'on';
ax.TickDir = 'out';
ax.LineWidth = 0.7;
ax.FontUnits = 'points';
ax.FontSize = fontPt;
ax.LabelFontSizeMultiplier = 1;
ax.TitleFontSizeMultiplier = 1;

if ~isempty(findobj(sourceAx, 'Type', 'image'))
    colormap(ax, colormap(sourceAx));
    clim(ax, sourceAx.CLim);
    cb = colorbar(ax);
    cb.FontSize = fontPt;
    srcCb = getappdata(sourceAx, 'scaleBarHandle');
    if isscalar(srcCb) && isgraphics(srcCb, 'colorbar')
        cb.Ticks = srcCb.Ticks;
    end
end

srcLg = sourceAx.Legend;
if ~isempty(srcLg) && isvalid(srcLg) && strcmp(srcLg.Visible, 'on')
    lg = legend(ax, srcLg.String, 'Location', 'southoutside');
    lg.FontUnits = 'points';
    lg.FontSize = fontPt;
    lg.Box = 'off';
    lg.ItemTokenSize(1) = 1.5 * fontPt;
    lg.Units = 'centimeters';
    for cols = numel(lg.String):-1:1
        lg.NumColumns = cols;
        drawnow;
        if lg.Position(3) <= widthCM - 0.1
            break
        end
    end
    lg.Layout.Tile = 'south';
end

for lbl = reshape(findall(paper, 'Type', 'text'), 1, [])
    lbl.FontUnits = 'points';
    lbl.FontSize = fontPt;
end

% 测量墨迹外缘并自动微调安全边距
tiles.Units = 'normalized';
for pass = 1:3
    drawnow;
    raster = print(paper, '-RGBImage', '-r300');
    ink = min(raster, [], 3) < 225;
    x = find(any(ink, 1));
    y = find(any(ink, 2));
    if isempty(x) || isempty(y), break; end
    h = size(ink, 1);
    w = size(ink, 2);
    margins = [x(1) - 1, h - y(end), w - x(end), y(1) - 1];
    delta = (margins - 6) ./ [w h w h];
    if max(abs(margins - 6)) <= 3, break; end
    pos = tiles.OuterPosition;
    tiles.OuterPosition = pos + [-delta(1:2), delta(1) + delta(3), delta(2) + delta(4)];
end

drawnow;
print(paper, [outBase '.png'], '-dpng', '-r300');
paper.Visible = 'on';
savefig(paper, [outBase '.fig']);
end
