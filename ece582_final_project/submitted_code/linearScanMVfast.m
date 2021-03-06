function [rf_out, x, z, rf_steer] = linearScanMVfast(rf_in,acq_params,bf_params,lines,flag,Mp)
% [rf_out, x, z] = linearScanMVfast(rf,acq_params,bf_params,[],0,32);
%
% Linear Scan MV beamforming code - Will Long. Latest revision: 4/23/15
% Inputs: 
% rf_in - element array data [array signal x array element x Tx event]
% acq_params - parameters include rx_pos, c, t0
% bf_params - parameters include x (tx_pos or A line lateral location)
% lines - A-lines to beamform (corresponding to bf_params.x)
% flag - '1' for pre-steered rf input and '0' raw rf input
% Mp - subarray length for covariance matrix estimation

if nargin < 4 || isempty(lines)
    lines = 1:length(bf_params.x); % beamform all a-lines (all tx events)
end
if nargin < 5
    flag = 0;
end
if nargin < 6 || isempty(Mp)
    M = size(rf_in,2); % total number of array elements
    Mp = floor(M/4); % # of subarray elements for subarray avg (Mp <= M/2)
end
    
% intialize parameters for steering
x = bf_params.x(lines);
z_ref = ((acq_params.t0+1:acq_params.t0+size(rf_in,1))/acq_params.fs)*acq_params.c;
z = z_ref/2;
n_depth = length(z);

% define incremental distances for estimation of echo propagation time
dz = repmat(z',1,M);
dx = repmat(acq_params.rx_pos,n_depth,1);
dr = sqrt(dz.^2+dx.^2);
t_samp = (dr+dz)./acq_params.c;

% perform pre-steering (DR delay)
rf_steer = zeros(length(z),M,length(lines));
switch flag
    case 0 
        idx = 0;
        fprintf('Performing pre-steering... \n');
        for l = lines
            idx = idx+1;
            % linear interpolation to extract response at focal point
            % (apply focal delay)
            rf_steer(:,:,idx) = linearInterp(z_ref'/acq_params.c,squeeze(rf_in(:,:,l)),t_samp);
        end
    case 1
        fprintf('Pre-steering skipped. \n');
        rf_steer = rf_in;
end
rf_steer(isnan(rf_steer)) = 0;

% initialize MV beamformer parameters
e = ones(Mp,1); % steering vector (all ones for planar wavefront)
fprintf('# elements for subarray avg: %d \n',Mp)

Nwin = 128; % fft window size (should be larger than 2 way conv of pulse)
if Nwin > length(z)
    error('Specified fft window size greater than available data'); 
end

% matrix of overlapping short time windows pre-defined for each desired focal depth
tmp = buffer(1:length(z),Nwin,Nwin-1); 
izwin = tmp(:,Nwin:end); clear tmp;
iz0 = izwin(Nwin/2,:);

% memory pre-allocation for speed
Bl = zeros(1,Nwin);
rf_out = zeros(length(iz0),length(lines));
    
% minimum variance beamform at each depth and for each freq band
idx = 0;
for l = lines
    fprintf('Beamforming %d/%d A-line... \n',l,length(bf_params.x))
    tic
    idx = idx+1;

    % minimum variance beamform at each depth and for each subband
    Yl_mat = zeros(Nwin,length(iz0),size(rf_steer,2));
    for rcv = 1:size(rf_steer,2)
        tmp = rf_steer(izwin(:),rcv,l);
        rcv_mat = reshape(tmp,size(izwin)); 
        % take DFT of each window representing a different focal depth
        % (window values x depths x array element number)
        Yl_mat(:,:,rcv) = fft(rcv_mat,Nwin,1);
    end
    
    for zi = 1:length(iz0)
        % extract DFT of window at specfic depth for all array signals
        Yl = squeeze(Yl_mat(:,zi,:)).';
        
        % solve MV problem for each frequency band k
        for k = 1:Nwin
            Rl = zeros(Mp,Mp);
            Gav = zeros(Mp,1);
            for p = 1:M-Mp+1
                G = Yl(p:p+Mp-1,k); % subband values in subarray p
                Rl = G*G'+Rl; % calculate subarray covariance matrix
                Gav = G+Gav;
            end
            Rl = 1/Mp*Rl; % spatial smoothing of covariance matrix
            Gav = 1/Mp*Gav; % subarray average of subband values
            wl = (Rl\e)/(e'*(Rl\e)); % solution of MV problem
            Bl(k) = wl'*Gav; % beamform in Fourier domain
        end
        % IDFT to extract beamformed signal
        bl = ifft(Bl);
        % extract beamformed signal at focal point
        rf_out(zi,idx) = bl(floor(Nwin/2));  
    end
    toc
end
z = z(iz0);