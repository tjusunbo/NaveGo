function [ins_est] = ins(imu, gps, ref, precision)
% ins: integrates IMU and GPS measurements using an Extended Kalman filter
%
%   Copyright (C) 2014, Rodrigo Gonzalez, all rights reserved.
%
%   This file is part of NaveGo, an open-source MATLAB toolbox for
%   simulation of integrated navigation systems.
%
%   NaveGo is free software: you can redistribute it and/or modify
%   it under the terms of the GNU Lesser General Public License (LGPL)
%   version 3 as published by the Free Software Foundation.
%
%   This program is distributed in the hope that it will be useful,
%   but WITHOUT ANY WARRANTY; without even the implied warranty of
%   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%   GNU Lesser General Public License for more details.
%
%   You should have received a copy of the GNU Lesser General Public
%   License along with this program. If not, see
%   <http://www.gnu.org/licenses/>.
%
% Reference:
%   R. Gonzalez, J. Giribet, and H. Patiño. NaveGo: a
% simulation framework for low-cost integrated navigation systems,
% Journal of Control Engineering and Applied Informatics, vol. 17,
% issue 2, pp. 110-120, 2015. Alg. 2.
%
% Version: 003
% Date:    2016/04/26
% Author:  Rodrigo Gonzalez <rodralez@frm.utn.edu.ar>
% URL:     https://github.com/rodralez/navego

if nargin < 4, precision = 'double'; end

tins = imu.t;
tgps = gps.t;

tti = (max(size(tins)));
ttg = (max(size(tgps)));

if strcmp(precision, 'single')  % single precision
    
    % Preallocate memory for estimates
    roll_e  =  single(zeros (tti,1));
    pitch_e =  single(zeros (tti,1));
    yaw_e   =  single(zeros (tti,1));
    vel_e   =  single(zeros (tti,3));
    h_e     =  single(zeros (tti,1));
    x = single(zeros(21,1));
    
    % Constant matrices
    I =  single(eye(3));
    Z =  single(zeros(3));
    
    % Matrices for later analysis
    Y_inno =  single(zeros(ttg,6));     % Kalman filter innovations
    P_diag = single(zeros(ttg,21));     % Diagonal from matrix P
    X =  single(zeros(ttg,21));         % Evolution of Kalman filter states
    Bias_comp =  single(zeros(ttg,12)); % Biases compensantions after Kalman filter correction
    
    % Initialize biases variables
    gb_drift = single(imu.gb_drift');
    ab_drift = single(imu.ab_drift');
    gb_fix = single(imu.gb_fix');
    ab_fix = single(imu.ab_fix');
    vel_e(1,:) = single(zeros(1,3));

    % Initialize estimates at tti=1
    roll_e (1) = single(ref.roll(1));
    pitch_e(1) = single(ref.pitch(1));
    yaw_e(1)   = single(ref.yaw(1));
    vel_e(1,:) = single(gps.vel(1,:));    
    h_e(1)     = single(gps.h(1));
    vel_e(1,:) = single(zeros(1,3)); 
    
else % double precision
    
    % Preallocate memory for estimates
    roll_e  =  (zeros (tti,1));
    pitch_e =  (zeros (tti,1));
    yaw_e   =  (zeros (tti,1));
    vel_e   =  (zeros (tti,3));
    h_e     =  (zeros (tti,1));
    x = (zeros(21,1));  
    
    % Constant matrices
    I =  (eye(3));
    Z =  (zeros(3));
    
    % Matrices for later analysis
    Y_inno =  (zeros(ttg,6));       % Kalman filter innovations
    P_diag = (zeros(ttg,21));       % Diagonal from matrix P
    X =  (zeros(ttg,21));           % Evolution of Kalman filter states
    Bias_comp =  (zeros(ttg,12));   % Biases compensantions after Kalman filter correction
    
    % Initialize biases variables
    gb_drift = imu.gb_drift';
    ab_drift = imu.ab_drift';
    gb_fix = imu.gb_fix';
    ab_fix = imu.ab_fix';
    
    % Initialize estimates at tti = 1
    roll_e (1) = ref.roll(1);
    pitch_e(1) = ref.pitch(1);
    yaw_e(1)   = ref.yaw(1);
    vel_e(1,:) = gps.vel(1,:);    
    h_e(1)     = gps.h(1);
    vel_e(1,:) = zeros(1,3);        
end

% Lat and lon cannot be set in single precision. They need full precision.
lat_e   =  zeros (tti,1);
lon_e   =  zeros (tti,1);
lat_e(1) =   double(gps.lat(1));
lon_e(1) =   double(gps.lon(1));

DCMnb_old = euler2dcm([roll_e(1); pitch_e(1); yaw_e(1);]);
DCMbn_old = DCMnb_old';
quaold = euler2qua([roll_e(1) pitch_e(1) yaw_e(1)]);

% Kalman filter matrices
R = diag([gps.stdv, gps.stdm].^2);
Q = (diag([imu.arw, imu.vrw, imu.gpsd, imu.apsd].^2));
P = diag([imu.att_init, gps.stdv, gps.std, imu.gstd, imu.astd, imu.gb_drift, imu.ab_drift].^2);

% Initialize matrices for INS performance analysis
P_diag(1,:) = diag(P)';
Bias_comp(1,:)  = [gb_fix', ab_fix', gb_drift', ab_drift'];

% SINS index
i = 2;

% GPS clock is the master clock
for j = 2:ttg
    
    while (tins(i) <= tgps(j))
        
        % Print a dot on console every 10,000 SINS executions
        if (mod(i,10000) == 0), fprintf('. '); end
        % Print a return on console every 100,000 SINS executions
        if (mod(i,100000) == 0), fprintf('\n'); end
        
        % SINS period
        dti = tins(i) - tins(i-1);
        
        % Correct inertial sensors
        wb_fix = (imu.wb(i,:)' - gb_drift - gb_fix);
        fb_fix = (imu.fb(i,:)' - ab_drift - ab_fix);
        
        % Attitude computer
        omega_ie_N = earthrate(lat_e(i-1), precision);
        omega_en_N = transportrate(lat_e(i-1), vel_e(i-1,1), vel_e(i-1,2), h_e(i-1));
        
        [quanew, DCMbn_new, ang_v] = att_update(wb_fix, DCMbn_old, quaold, ...
            omega_ie_N, omega_en_N, dti);
        roll_e(i) = ang_v(1);
        pitch_e(i)= ang_v(2);
        yaw_e(i)  = ang_v(3);
        DCMbn_old = DCMbn_new;
        quaold = quanew;
        
        % Gravity computer
        g = gravity(lat_e(i-1), h_e(i-1));
        
        % Velocity computer
        fn = DCMbn_new * (fb_fix);
        vel_upd = vel_update(fn, vel_e(i-1,:)', omega_ie_N, omega_en_N, g', dti); %
        vel_e (i,:) = vel_upd';
        
        % Position computer
        pos = pos_update([lat_e(i-1) lon_e(i-1) double(h_e(i-1))], double(vel_e(i,:)), double(dti) );
        lat_e(i)=pos(1); lon_e(i)=pos(2); h_e(i)=single(pos(3));
        
        % Magnetic heading computer
        %  yawm_e(i) = hd_update (imu.mb(i,:), roll_e(i),  pitch_e(i), D);
        
        % Index for SINS navigation update
        i = i + 1;
        
    end
    
    %% Innovation update section
    
    [RM,RN] = radius(lat_e(i-1), precision);
    Tpr = diag([(RM+h_e(i-1)), (RN+h_e(i-1))*cos(lat_e(i-1)), -1]);  % rad-to-meters
    
    % Innovations
    yp = Tpr * ([lat_e(i-1); lon_e(i-1); h_e(i-1);] ...
        - [gps.lat(j); gps.lon(j); gps.h(j);]) + (DCMbn_new * gps.larm);
    
    yv = (vel_e (i-1,:) - gps.vel(j,:))';
    y = [ yv' yp' ]';
    
    %% Kalman filter update section
    
    % GPS period
    dtg = tgps(j) - tgps(j-1);
    
    % Vector to update matrix F
    upd = [vel_e(i-1,:) lat_e(i-1) h_e(i-1) fn'];
    
    % Update matrices F and G
    [F, G] = F_update(upd, DCMbn_new, imu);
    
    % Update matrix H
    H = [Z I Z Z Z Z Z;
        Z Z Tpr Z Z Z Z; ];
    
    % Execute the extended Kalman filter
    [xu, P] = kalman(x, y, F, H, G, P, Q, R, dtg); % 
    
    %% Corrections section
    
    % DCM correction
    E = skewm(xu(1:3));
    DCMbn_old = (eye(3) + E) * DCMbn_new;
    
    % Quaternion correction
    antm = [0 quanew(3) -quanew(2); -quanew(3) 0 quanew(1); quanew(2) -quanew(1) 0];
    quaold = quanew + 0.5 .* [quanew(4)*eye(3) + antm; -1.*[quanew(1) quanew(2) quanew(3)]] * xu(1:3);
    quaold = quaold/norm(quaold);       % Brute force normalization
    
    % Attitude correction
    roll_e(i-1)  = roll_e(i-1)  - xu(1);
    pitch_e(i-1) = pitch_e(i-1) - xu(2);
    yaw_e(i-1)   = yaw_e(i-1)   - xu(3);
    % Velocity correction
    vel_e (i-1,1) = vel_e (i-1,1) - xu(4);
    vel_e (i-1,2) = vel_e (i-1,2) - xu(5);
    vel_e (i-1,3) = vel_e (i-1,3) - xu(6);
    % Position correction
    lat_e(i-1) = lat_e(i-1) - double(xu(7));
    lon_e(i-1) = lon_e(i-1) - double(xu(8));
    h_e(i-1)   = h_e(i-1)   - xu(9);
    
    % Biases correction
    gb_fix = gb_fix - xu(10:12);
    ab_fix = ab_fix - xu(13:15);
    gb_drift = gb_drift - xu(16:18);
    ab_drift = ab_drift - xu(19:21);
    
    % Matrices for later INS/GPS performance analysis
    X(j,:) = xu';
    P_diag(j,:) = diag(P)';
    Y_inno(j,:) = y';
    Bias_comp(j,:) = [gb_fix', ab_fix', gb_drift', ab_drift'];
end

% Estimates from INS/GPS procedure
ins_est.t     = tins(1:i-1, :);     % IMU time
ins_est.roll  = roll_e(1:i-1, :);   % Roll
ins_est.pitch = pitch_e(1:i-1, :);  % Pitch      
ins_est.yaw = yaw_e(1:i-1, :);      % Yaw
ins_est.vel = vel_e(1:i-1, :);      % NED velocities
ins_est.lat = lat_e(1:i-1, :);      % Latitude
ins_est.lon = lon_e(1:i-1, :);      % Longitude
ins_est.h   = h_e(1:i-1, :);        % Altitude
ins_est.P_diag = P_diag;            % P matrix diagonals
ins_est.Bias_comp = Bias_comp;      % Kalman filter biases compensations
ins_est.Y_inno = Y_inno;            % Kalman filter innovations
ins_est.X = X;                      % Kalman filter states evolution
end
