//
//  KSYViewController.m
//  KSYAirStreamer
//
//  Created by pengbins on 04/11/2017.
//  Copyright (c) 2017 pengbins. All rights reserved.
//
#import "KSYAirStreamKit.h"

@implementation KSYAudioCap
+ (BOOL) isHeadsetPluggedIn {
    return NO;
}

@end


@interface KSYAirStreamKit () <KSYAirDelegate>{
    int            _autoRetryCnt;
    BOOL           _bRetry;
    int            _maxAutoRetry;
}

@end

@implementation KSYAirStreamKit

- (id) initWithTokeID:(NSString *)tokenID
            onSuccess:(void (^)(void))completeSuccess
            onFailure:(void (^)(AuthorizeError iErrorCode))completeFailure{
    self = [super init];
    if (self == nil) {
        return nil;
    }
    
    _airTunesServer = [[KMCAirTunesServer alloc] init];
    [_airTunesServer authorizeWithTokeID:tokenID onSuccess:^{
        
        _streamerBase   = [[KSYStreamerBase alloc] init];
        _aMixer         = [[KSYAudioMixer alloc] init];
        _aMixer.mainTrack = 0;
        [_aMixer setTrack:0 enable:YES];
        _airTunesServer.delegate = self;
        __weak typeof(self) weakSelf = self;
        _airTunesServer.videoProcessingCallback = ^(CVPixelBufferRef pixelBuffer, CMTime timeInfo) {
            [weakSelf.streamerBase processVideoPixelBuffer:pixelBuffer timeInfo:timeInfo];
        };
        _streamerBase.videoCodec = KSYVideoCodec_AUTO;
        _streamerBase.videoEncodePerf = KSYVideoEncodePer_HighPerformance;
        _streamerBase.audioCodec = KSYAudioCodec_AT_AAC;
        _streamerBase.audiokBPS  = 64;
        _streamerBase.streamStateChange = ^(KSYStreamState state) {
            [weakSelf onStreamStateChange:state];
        };
        
        _autoRetryCnt    = 0;
        _maxAutoRetry    = 5;
        _bRetry          = NO;
        NSNotificationCenter* dc = [NSNotificationCenter defaultCenter];
        [dc addObserver:self
               selector:@selector(onNetStateEvent)
                   name:KSYNetStateEventNotification
                 object:nil];
        
        if(completeSuccess)
            completeSuccess();
    } onFailure:^(AuthorizeError iErrorCode) {
        if(iErrorCode ==AUTHORIZE_NETWORK_ERROR){
            NSString * errorMessage = [[NSString alloc]initWithFormat:@"网络异常，请打开网络"];
            dispatch_async(dispatch_get_main_queue(), ^{
                UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"错误提示" message:errorMessage delegate:nil cancelButtonTitle:@"好的" otherButtonTitles:nil, nil];
                [alert show];
            });
        }else{
            NSString * errorMessage = [[NSString alloc]initWithFormat:@"鉴权失败,错误码:%lu",(unsigned long)iErrorCode];
            dispatch_async(dispatch_get_main_queue(), ^{
                UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"错误提示" message:errorMessage delegate:nil cancelButtonTitle:@"好的" otherButtonTitles:nil, nil];
                [alert show];
            });
        }
        if(completeFailure)
            completeFailure(iErrorCode);
    }];

    return self;
}

- (void) dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void) startService {
    __weak typeof(self) weakSelf = self;
    _aMixer.pcmProcessingCallback = ^(uint8_t **pData, int nbSample, CMTime pts) {
        [weakSelf.streamerBase processAudioData:pData
                                       nbSample:nbSample
                                     withFormat:weakSelf.aMixer.outFmtDes
                                       timeinfo:&pts];
    };
    [_airTunesServer startServerWithCfg:_airCfg];
}
- (void) stopService {
    [_streamerBase stopStream];
    [_airTunesServer stopServer];
}

#pragma mark - KSYAirDelegate
- (void) didStartMirroring:(KSYAirTunesServer *)server {
    NSLog(@"开始镜像");
    _streamerBase.videoFPS = _airCfg.framerate;
    _streamerBase.videoMaxBitrate  = _videoBitrate;
    _streamerBase.videoInitBitrate = _videoBitrate*6/10;
    _streamerBase.videoMinBitrate  = 0;
    [_streamerBase startStream:[NSURL URLWithString:_streamUrl]];
    if (_delegate && [_delegate respondsToSelector:@selector(didStartMirroring:)]) {
        dispatch_async(dispatch_get_main_queue(), ^() {
            [_delegate didStartMirroring:server];
        });
    }
    __weak typeof(self) weakSelf = self;
    _aCapDev        = [[KSYAudioCap alloc] init];
    // 关闭降噪处理, 减少CPU占用
    _aCapDev.noiseSuppressionLevel = KSYAudioNoiseSuppress_OFF;
    _aCapDev.pcmProcessingCallback = ^(uint8_t **pData, int len, const AudioStreamBasicDescription *fmt, CMTime timeInfo) {
        [weakSelf.aMixer processAudioData:pData
                                 nbSample:len
                               withFormat:fmt
                                 timeinfo:timeInfo
                                       of:0];
    };
    [_aCapDev startCapture];
}
- (void)mirroringErrorDidOcccur:(KSYAirTunesServer *)server  withError:(NSError *)error {
    if (_delegate && [_delegate respondsToSelector:@selector(mirroringErrorDidOcccur:withError:)]) {
        dispatch_async(dispatch_get_main_queue(), ^() {
            [_delegate mirroringErrorDidOcccur:server withError:error];
        });
    }
}
- (void)didStopMirroring:(KSYAirTunesServer *)server {
    if (_delegate && [_delegate respondsToSelector:@selector(didStartMirroring:)]) {
        dispatch_async(dispatch_get_main_queue(), ^() {
            [_delegate didStopMirroring:server ];
        });
    }
    [_streamerBase stopStream];
    [_aCapDev stopCapture];
    _aCapDev = nil;
}

#pragma mark - stream state

- (void) onStreamStateChange: (KSYStreamState) state {
    if (!_streamerBase){
        return;
    }
    if (state == KSYStreamStateError){
        [self onStreamError:_streamerBase.streamErrorCode];
    }
    else if (state == KSYStreamStateConnected){
        _autoRetryCnt = _maxAutoRetry;
        _bRetry = NO;
    }
}
- (void) onNetStateEvent {
    KSYNetStateCode code = [_streamerBase netStateCode];
    if (code == KSYNetStateCode_REACHABLE) {
        if ( _streamerBase.streamState == KSYStreamStateError) {
            [self tryRtmpReconnect:1];
        }
    }
}
    
- (void) onStreamError: (KSYStreamErrorCode) errCode {
    NSString * name = [_streamerBase getCurKSYStreamErrorCodeName];
    NSLog(@"stream Error: %@", [name substringFromIndex:19]);
    if (errCode == KSYStreamErrorCode_CONNECT_BREAK ||
        errCode == KSYStreamErrorCode_AV_SYNC_ERROR ||
        errCode == KSYStreamErrorCode_Connect_Server_failed ||
        errCode == KSYStreamErrorCode_DNS_Parse_failed) {
        if (_bRetry == NO){
            [self tryRtmpReconnect:2];
        }
    }
    else if (errCode == KSYStreamErrorCode_RTMP_Publish_failed ||
             errCode == KSYStreamErrorCode_RTMP_AlreadyExistStreamName||
             errCode == KSYStreamErrorCode_RTMP_InternalError){
        if (_bRetry == NO){
            [self tryRtmpReconnect:5];
        }
    }
    else if (errCode == KSYStreamErrorCode_CODEC_OPEN_FAILED) {
        _streamerBase.videoCodec = KSYVideoCodec_X264;
        _autoRetryCnt = _maxAutoRetry;
        if (_bRetry == NO){
            [self tryRtmpReconnect:1];
        }
    }
    // 其他一些错误码跟地址有关, 需要重新获取地址再重连, 否则不起作用
}
    
- (void) tryRtmpReconnect:(double) delay {
    _bRetry = YES;
    int64_t delaySec = (int64_t)(delay * NSEC_PER_SEC);
    dispatch_time_t delayT = dispatch_time(DISPATCH_TIME_NOW, delaySec);
    dispatch_after(delayT, dispatch_get_main_queue(), ^{
        _bRetry = NO;
        if (_autoRetryCnt <= 0 || _streamerBase.netReachState == KSYNetReachState_Bad) {
            return;
        }
        if (!_streamerBase.isStreaming) {
            NSLog(@"retry connect %d/%d", _autoRetryCnt, _maxAutoRetry);
            _autoRetryCnt--;
            [_streamerBase startStream:_streamerBase.hostURL];
        }
    });
}
@end
