function os_train(varargin)
opts.writeResults = 0;
%global imdb train
[opts, imdb] = os_setup(varargin{:}) ;

if strcmp(opts.dataset,'dtd')
    for s = 1:3
        list = textread(fullfile('data\dtd', 'labels', ...
            sprintf('%s%d.txt', imdb.sets{s}, 1)),'%s') ;
        list = strrep(list, '/', '\');
        ok = ismember(imdb.images.name, list) ;
        imdb.images.set(find(ok)) = s ;
    end
    imdb.segments.set = imdb.images.set;
end

if strcmp(opts.dataset,'mit')
    imdb.images.set = zeros(1,size(imdb.images.name,2));
    for s = [1 3]
        %   disp(fullfile(datasetDir, 'meta', ...
        %     sprintf('%s.txt', imdb.sets{s})));
        list = textread(fullfile('data\mit_indoor', 'meta', ...
            sprintf('%s.txt', imdb.sets{s})),'%s') ;
        list = strrep(list, '/', '\');
        imdb.images.set(find(ismember(imdb.images.name, list))) = s ;
    end
    imdb.images.set(find(imdb.images.set==0)) = 1;
    % hack
    sel_train = find(imdb.images.set == 1);
    imdb.images.set(sel_train(1 : 4 : end)) = 2;
    imdb.segments.set = imdb.images.set;
end


% -------------------------------------------------------------------------
%                                          Train encoders and compute codes
% -------------------------------------------------------------------------

if ~exist(opts.resultPath)
  psi = {} ;
  psit = {};
  for i = 1:numel(opts.encoders)
      if exist(opts.encoders{i}.path)
        encoder = load(opts.encoders{i}.path) ;
        if isfield(encoder, 'net')
            if opts.useGpu
              encoder.net = vl_simplenn_move(encoder.net, 'gpu') ;
              encoder.net.useGpu = true ;
            else
              encoder.net = vl_simplenn_move(encoder.net, 'cpu') ;
              encoder.net.useGpu = false ;
            end
        end
      else
        train = find(ismember(imdb.segments.set, [1 2])) ;
        train = vl_colsubset(train, 1000, 'uniform') ;
        encoder = encoder_train_from_segments(...
          imdb, imdb.segments.id(train), ...
          opts.encoders{i}.opts{:}, ...
          'useGpu', opts.useGpu) ;
        encoder_save(encoder, opts.encoders{i}.path) ;
      end

      if exist(opts.encoders{i}.codePath)
          load(opts.encoders{i}.codePath, 'code', 'area') ;
      else
        [code, area] = encoder_extract_for_segments(encoder, imdb, imdb.segments.id) ;
        savefast(opts.encoders{i}.codePath, 'code', 'area');
      end
      psi{i} = code;
      clear code;
  end
  psi = cat(1, psi{:}) ;
  imdb.segments.area = area;
end

% -------------------------------------------------------------------------
function info = traintest(opts, imdb, psi)
% -------------------------------------------------------------------------

multiLabel = (size(imdb.segments.label,1) > 1) ;

% print some data statistics
% figure(4) ; clf;
% s=~imdb.segments.difficult ;
% subplot(1,2,1);title('size') ;
% [h,x]=hist(imdb.segments.area(s), 100);
% semilogy(h/sum(h),x,'r--') ; hold on ;
% [h,x]=hist(imdb.segments.area, 100);
% semilogy(h/sum(h),x,'b') ;
% legend('easy', 'all') ;
% title('easy vs other segment areas') ;
% 
% subplot(1,2,2) ;
% classes = find(imdb.meta.inUse) ;
% n = length(classes) ;
% if ~multiLabel
%   [~,a]=ismember(imdb.segments.label, classes) ;
%   h1=hist(a(s),n) ;
%   h2=hist(a,n) ;
% else
%   h1 = sum(imdb.segments.label, 2) ;
%   h2 = sum(imdb.segments.label(:,s), 2) ;
% end
% bar([h1(:), h2(:)]) ;
% legend('easy', 'all') ;
% title('class distribution easy vs other segments') ;

if opts.excludeDifficult
  imdb.segments.set(imdb.segments.difficult) = 0 ;
end
train = ismember(imdb.segments.set, 1) ;
test = ismember(imdb.segments.set, 3) ;

info.classes = find(imdb.meta.inUse) ;
C = 1 ;
w = {} ;
b = {} ;



for c=1:numel(info.classes)
  if ~multiLabel
    y = 2*(imdb.segments.label == info.classes(c)) - 1 ;
  else
    y = imdb.segments.label(c,:) ;
  end
  np = sum(y(train) > 0) ;
  nn = sum(y(train) < 0) ;
  n = np + nn ;
  
  [w{c},b{c}] = vl_svmtrain(psi(:,train & y ~= 0), y(train & y ~= 0), 1/(n* C), ...
    'epsilon', 0.001, 'verbose', 'biasMultiplier', 1, ...
    'maxNumIterations', n * 200) ;

  pred = w{c}'*psi + b{c} ;

  % try cheap calibration
  mp = median(pred(train & y > 0)) ;
  mn = median(pred(train & y < 0)) ;
  b{c} = (b{c} - mn) / (mp - mn) ;
  w{c} = w{c} / (mp - mn) ;
  pred = w{c}'*psi + b{c} ;

  scores{c} = pred ;

  [~,~,i]= vl_pr(y(train), pred(train)) ; ap(c) = i.ap ; ap11(c) = i.ap_interp_11 ;
  [~,~,i]= vl_pr(y(test), pred(test)) ; tap(c) = i.ap ; tap11(c) = i.ap_interp_11 ;
  [~,~,i]= vl_pr(y(train), pred(train), 'normalizeprior', 0.01) ; nap(c) = i.ap ;
  [~,~,i]= vl_pr(y(test), pred(test), 'normalizeprior', 0.01) ; tnap(c) = i.ap ;
end
info.w = cat(2,w{:}) ;
info.b = cat(2,b{:}) ;
info.scores = cat(1, scores{:}) ;
info.train.ap = ap ;
info.train.ap11 = ap11 ;
info.train.nap = nap ;
info.train.map = mean(ap) ;
info.train.map11 = mean(ap11) ;
info.train.mnap = mean(nap) ;
info.test.ap = tap ;
info.test.ap11 = tap11 ;
info.test.nap = tnap ;
info.test.map = mean(tap) ;
info.test.map11 = mean(tap11) ;
info.test.mnap = mean(tnap) ;
clear ap nap tap tnap scores ;
fprintf('mAP train: %.1f, test: %.1f\n', ...
  mean(info.train.ap)*100, ...
  mean(info.test.ap)*100);

figure(1) ; clf ;
subplot(3,2,1) ;
bar([info.train.ap; info.test.ap]')
xlabel('class') ;
ylabel('AP') ;
legend(...
  sprintf('train (%.1f)', info.train.map*100), ...
  sprintf('test (%.1f)', info.test.map*100));
title('average precision') ;

subplot(3,2,2) ;
bar([info.train.nap; info.test.nap]')
xlabel('class') ;
ylabel('AP') ;
legend(...
  sprintf('train (%.1f)', info.train.mnap*100), ...
  sprintf('test (%.1f)', info.test.mnap*100));
title('normalized average precision') ;

if ~multiLabel
  [~,preds] = max(info.scores,[],1) ;
  [~,gts] = ismember(imdb.segments.label, info.classes) ;

  % per pixel
  [info.train.msrcConfusion, info.train.msrcAcc] = compute_confusion(numel(info.classes), gts(train), preds(train), imdb.segments.area(train), true) ;
  [info.test.msrcConfusion, info.test.msrcAcc] = compute_confusion(numel(info.classes), gts(test), preds(test), imdb.segments.area(test), true) ;

  % per pixel per class
  [info.train.confusion, info.train.acc] = compute_confusion(numel(info.classes), gts(train), preds(train), imdb.segments.area(train)) ;
  [info.test.confusion, info.test.acc] = compute_confusion(numel(info.classes), gts(test), preds(test), imdb.segments.area(test)) ;

  % per segment per class
  [info.train.psConfusion, info.train.psAcc] = compute_confusion(numel(info.classes), gts(train), preds(train)) ;
  [info.test.psConfusion, info.test.psAcc] = compute_confusion(numel(info.classes), gts(test), preds(test)) ;

  subplot(3,2,3) ;
  imagesc(info.train.confusion) ;
  title(sprintf('train confusion per pixel (acc: %.1f, msrc acc: %.1f)', ...
    info.train.acc*100, info.train.msrcAcc*100)) ;

  subplot(3,2,4) ;
  imagesc(info.test.confusion) ;
  title(sprintf('test confusion per pixel (acc: %.1f, msrc acc: %.1f)', ...
    info.test.acc*100, info.test.msrcAcc*100)) ;

  subplot(3,2,5) ;
  imagesc(info.train.psConfusion) ;
  title(sprintf('train confusion per segment (acc: %.1f)', info.train.psAcc*100)) ;

  subplot(3,2,6) ;
  imagesc(info.test.psConfusion) ;
  title(sprintf('test confusion per segment (acc: %.1f)', info.test.psAcc*100)) ;
end

% -------------------------------------------------------------------------
function [code, area] = encoder_extract_for_segments(encoder, imdb, segmentIds, varargin)
% -------------------------------------------------------------------------
opts.batchSize = 128 ;
opts.maxNumLocalDescriptorsReturned = 500 ;
opts = vl_argparse(opts, varargin) ;

[~,segmentSel] = ismember(segmentIds, imdb.segments.id) ;
imageIds = unique(imdb.segments.imageId(segmentSel)) ;
n = numel(imageIds) ;

% prepare batches
n = ceil(numel(imageIds)/opts.batchSize) ;
batches = mat2cell(1:numel(imageIds), 1, [opts.batchSize * ones(1, n-1), numel(imageIds) - opts.batchSize*(n-1)]) ;
batchResults = cell(1, numel(batches)) ;

% just use as many workers as are already available
delete(gcp('nocreate'));
poolobj = parpool;
if isempty(poolobj)
    numWorkers = 0;
else
    numWorkers = poolobj.NumWorkers -1
end
%numWorkers = matlabpool('size') ;
parfor (b = 1:numel(batches), numWorkers)
%for b = 1:numel(batches)
  batchResults{b} = get_batch_results(imdb, imageIds, batches{b}, ...
    encoder, opts.maxNumLocalDescriptorsReturned) ;
end

area = zeros(size(segmentIds)) ;
code = cell(size(segmentIds)) ;
for b = 1:numel(batches)
  m = numel(batches{b}) ;
  for j = 1:m
    for q = 1:numel(batchResults{b}.segmentIndex{j})
      k = batchResults{b}.segmentIndex{j}(q) ;
      code{k} = batchResults{b}.code{j}(:, q) ;
      area(k) = batchResults{b}.area{j}(q) ;
    end
  end
end
code = cat(2, code{:}) ;

% code is either:
% - a cell array, each cell containing an array of local features for a
%   segment
% - an array of FV descriptors, one per segment

% -------------------------------------------------------------------------
function result = get_batch_results(imdb, imageIds, batch, encoder, maxn)
% -------------------------------------------------------------------------

m = numel(batch) ;
im = cell(1, m) ;
regions = cell(1, m) ;
task = getCurrentTask() ;
if ~isempty(task), tid = task.ID ; else tid = 1 ; end
for i = 1:m
  fprintf('Task: %03d: encoder: extract features: image %d of %d\n', tid, batch(i), numel(imageIds)) ;
  [im{i}, regions{i}] = os_get_gt_regions(imdb, imageIds(batch(i)));
end
if ~isfield(encoder, 'numSpatialSubdivisions')
  encoder.numSpatialSubdivisions = 1 ;
end
switch encoder.type
  case 'rcnn'
    code_ = get_rcnn_features(encoder.net, ...
      im, regions, ...
      'regionBorder', encoder.regionBorder) ;
  case 'dcnn'
    gmm = [] ;
    if isfield(encoder, 'covariances'), gmm = encoder ; end
    if isfield(encoder, 'kdtree'), gmm = encoder ; end
    code_ = get_dcnn_features(encoder.net, ...
      im, regions, ...
      'encoder', gmm, ...
      'numSpatialSubdivisions', encoder.numSpatialSubdivisions, ...
      'maxNumLocalDescriptorsReturned', maxn) ;
  case 'dsift'
    gmm = [] ;
    if isfield(encoder, 'covariances'), gmm = encoder ; end
    if isfield(encoder, 'kdtree'), gmm = encoder ; end
    code_ = get_dcnn_features([], im, regions, ...
      'useSIFT', true, ...
      'encoder', gmm, ...
      'numSpatialSubdivisions', encoder.numSpatialSubdivisions, ...
      'maxNumLocalDescriptorsReturned', maxn) ;
end
result.code = code_ ;
for j = 1:m
 result.segmentIndex{j} = regions{j}.segmentIndex ;
 result.area{j} = regions{j}.area ;
end

% -------------------------------------------------------------------------
function encoder = encoder_train_from_segments(imdb, segmentIds, varargin)
% -------------------------------------------------------------------------
opts.type = 'rcnn' ;
opts.model = '' ;
opts.layer = 0 ;
opts.useGpu = true ;
opts.regionBorder = 0.05 ;
opts.numPcaDimensions = +inf ;
opts.numSamplesPerWord = 1000 ;
opts.whitening = false ;
opts.whiteningRegul = 0 ;
opts.renormalize = false ;
opts.numWords = 64 ;
opts.numSpatialSubdivisions = 1 ;
opts.encoderType = 'fv';
opts = vl_argparse(opts, varargin) ;

%initialize ?!
encoder.projection = 1 ;
encoder.projectionCenter = 0 ;

encoder.encoderType = opts.encoderType;

encoder.type = opts.type ;
encoder.regionBorder = opts.regionBorder ;
switch opts.type
  case {'dcnn', 'dsift'}
    encoder.numWords = opts.numWords ;
    encoder.renormalize = opts.renormalize ;
    encoder.numSpatialSubdivisions = opts.numSpatialSubdivisions ;
end

switch opts.type
  case {'rcnn', 'dcnn'}
    encoder.net = load(opts.model) ;
    encoder.net = vl_simplenn_tidy(encoder.net);
    encoder.net.layers = encoder.net.layers(1:opts.layer) ;
    if opts.useGpu
      encoder.net = vl_simplenn_move(encoder.net, 'gpu') ;
      encoder.net.useGpu = true ;
    else
      encoder.net = vl_simplenn_move(encoder.net, 'cpu') ;
      encoder.net.useGpu = false ;
    end
end

switch opts.type
  case 'rcnn'
    return ;
end

% Step 0: sample descriptors
fprintf('%s: getting local descriptors to train GMM\n', mfilename) ;
code = encoder_extract_for_segments(encoder, imdb, segmentIds) ;
descrs = cell(1, numel(code)) ;
numImages = numel(code);
numDescrsPerImage = floor(encoder.numWords * opts.numSamplesPerWord / numImages);
for i=1:numel(code)
  descrs{i} = vl_colsubset(code{i}, numDescrsPerImage) ;
end
descrs = cat(2, descrs{:}) ;
fprintf('%s: obtained %d local descriptors to train GMM\n', ...
  mfilename, size(descrs,2)) ;


% Step 1 (optional): learn PCA projection
if opts.numPcaDimensions < inf || opts.whitening
  fprintf('%s: learning PCA rotation/projection\n', mfilename) ;
  encoder.projectionCenter = mean(descrs,2) ;
  x = bsxfun(@minus, descrs, encoder.projectionCenter) ;
  X = x*x' / size(x,2) ;
  [V,D] = eig(X) ;
  d = diag(D) ;
  [d,perm] = sort(d,'descend') ;
  d = d + opts.whiteningRegul * max(d) ;
  m = min(opts.numPcaDimensions, size(descrs,1)) ;
  V = V(:,perm) ;
  if opts.whitening
    encoder.projection = diag(1./sqrt(d(1:m))) * V(:,1:m)' ;
  else
    encoder.projection = V(:,1:m)' ;
  end
  clear X V D d ;
else
  encoder.projection = 1 ;
  encoder.projectionCenter = 0 ;
end
descrs = encoder.projection * bsxfun(@minus, descrs, encoder.projectionCenter) ;
if encoder.renormalize
  descrs = bsxfun(@times, descrs, 1./max(1e-12, sqrt(sum(descrs.^2)))) ;
end

encoder.encoderType = opts.encoderType;

% Step 2: train Encoder

switch (opts.encoderType)
    case {'bovw', 'vlad', 'llc'}
    encoder.words = vl_kmeans(descrs, opts.numWords, 'verbose', 'algorithm', 'ann') ;
    encoder.kdtree = vl_kdtreebuild(encoder.words, 'numTrees', 2) ;

    case {'fv'}

    v = var(descrs')' ;
    [encoder.means, encoder.covariances, encoder.priors] = ...
        vl_gmm(descrs, opts.numWords, 'verbose', ...
            'Initialization', 'kmeans', ...
            'CovarianceBound', double(max(v)*0.0001), ...
            'NumRepetitions', 1);

end
