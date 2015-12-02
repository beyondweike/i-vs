//
//  MoreViewController.m
//

#import "CameraViewController.h"
#import <QuartzCore/QuartzCore.h>

#import <AVFoundation/AVCaptureDevice.h>
#import <AVFoundation/AVCaptureSession.h>
#import <AVFoundation/AVMediaFormat.h>
#import <AVFoundation/AVCaptureInput.h>
#import <AVFoundation/AVCaptureOutput.h>
#import <AVFoundation/AVCaptureVideoPreviewLayer.h>
#import <AVFoundation/AVMetadataObject.h>
#import <AVFoundation/AVAssetWriter.h>
#import <AVFoundation/AVVideoSettings.h>
#import <AVFoundation/AVAssetWriterInput.h>
#import <AVFoundation/AVAudioSettings.h>
#import <AVFoundation/AVFoundation.h>
#import <AssetsLibrary/AssetsLibrary.h>

extern "C"
{
#include "libavformat/avformat.h"
#include "libswscale/swscale.h"
#include "libswresample/swresample.h"
#include "libavutil/pixdesc.h"
#include "libavutil/mathematics.h"
#include "libavutil/time.h"
#include "libavdevice/avdevice.h"
}

#import "CameraStreamManager.h"


@interface CameraViewController() <AVCaptureFileOutputRecordingDelegate,AVCaptureVideoDataOutputSampleBufferDelegate,AVCaptureAudioDataOutputSampleBufferDelegate>
{
}

@property (strong,nonatomic) AVCaptureSession *captureSession;//负责输入和输出设置之间的数据传递
//@property (strong,nonatomic) AVCaptureDeviceInput *captureDeviceInput;//负责从AVCaptureDevice获得输入数据
@property (strong,nonatomic) AVCaptureMovieFileOutput *captureMovieFileOutput;//视频输出流
@property (strong,nonatomic) AVCaptureVideoPreviewLayer *captureVideoPreviewLayer;//相机拍摄预览图层
@property (assign,nonatomic) UIBackgroundTaskIdentifier backgroundTaskIdentifier;//后台任务标识

@end

//http://ios.jobbole.com/82051/
@implementation CameraViewController
{
    
    //AVCaptureSession* session_;
    //AVAssetWriter* assetWriter_;
    AVCaptureVideoDataOutput* videoDataOutput_;
    AVCaptureAudioDataOutput* audioDataOutput_;
    //AVAssetWriterInput* videoWriterInput_;
    //AVAssetWriterInput* audioWriterInput_;
    
    int frameWith_;
    int frameHeight_;
    AVPixelFormat pixelFormat_;
    
    AVFormatContext* inContext_;
    AVFormatContext* outContext_;
    BOOL outReady_;
    
    
    AVCodecContext* encodeContext_;
    int frameIndex_;
    
    CameraStreamManager* cameraStreamManager_;
    BOOL h264ManagerReady_;
    
    int64_t start_time;
}

- (void)dealloc
{
}

- (void)loadView
{
    [super loadView];
  
    UIButton* button=[[UIButton alloc] initWithFrame:CGRectMake(0, 0, 100, 40)];
    [button setTitle:@"开始录制" forState:UIControlStateNormal];
    [button setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    [button addTarget:self action:@selector(onButtonClick:) forControlEvents:UIControlEventTouchUpInside];
    UIBarButtonItem* item=[[UIBarButtonItem alloc] initWithCustomView:button];
    self.navigationItem.rightBarButtonItem=item;
 
    //初始化会话
    _captureSession=[[AVCaptureSession alloc]init];
    if ([_captureSession canSetSessionPreset:AVCaptureSessionPreset640x480])
    {
        //设置分辨率
        _captureSession.sessionPreset=AVCaptureSessionPreset640x480;
    }
    
    //获得输入设备
    AVCaptureDevice *captureDevice=[self getCameraDeviceWithPosition:AVCaptureDevicePositionBack];//取得后置摄像头
    if (!captureDevice)
    {
        NSLog(@"取得后置摄像头时出现问题.");
        return;
    }
    NSError *error=nil;
    //根据输入设备初始化设备输入对象，用于获得输入数据
    AVCaptureDeviceInput* captureDeviceInput=[[AVCaptureDeviceInput alloc] initWithDevice:captureDevice error:&error];
    if (error)
    {
        NSLog(@"取得设备输入对象时出错，错误原因：%@",error.localizedDescription);
        return;
    }
    
    //添加一个音频输入设备
    AVCaptureDevice *audioCaptureDevice=[[AVCaptureDevice devicesWithMediaType:AVMediaTypeAudio] firstObject];
    AVCaptureDeviceInput *audioCaptureDeviceInput=[[AVCaptureDeviceInput alloc]initWithDevice:audioCaptureDevice error:&error];
    if (error)
    {
        NSLog(@"取得设备输入对象时出错，错误原因：%@",error.localizedDescription);
        return;
    }
    
    //将设备输入添加到会话中
    if ([_captureSession canAddInput:captureDeviceInput])
    {
        [_captureSession addInput:captureDeviceInput];
        [_captureSession addInput:audioCaptureDeviceInput];
    }
    
    BOOL useFileOutput=NO;
    BOOL useDataOutput=YES;
    if(useFileOutput)
    {
        //初始化设备输出对象，用于获得输出数据
        AVCaptureMovieFileOutput* captureMovieFileOutput=[[AVCaptureMovieFileOutput alloc] init];
        self.captureMovieFileOutput=captureMovieFileOutput;
        
        AVCaptureConnection *captureConnection=[captureMovieFileOutput connectionWithMediaType:AVMediaTypeVideo];
        if ([captureConnection isVideoStabilizationSupported ]) {
            captureConnection.preferredVideoStabilizationMode=AVCaptureVideoStabilizationModeAuto;
        }
        
        //将设备输出添加到会话中
        if ([_captureSession canAddOutput:captureMovieFileOutput]) {
            [_captureSession addOutput:captureMovieFileOutput];
        }
    }
    else if(useDataOutput)
    {
        // 创建一个VideoDataOutput对象，将其添加到session
        AVCaptureVideoDataOutput* captureVideoDataOutput = [[AVCaptureVideoDataOutput alloc] init];
        dispatch_queue_t queue = dispatch_queue_create("myQueue", NULL);
        [captureVideoDataOutput setSampleBufferDelegate:self queue:queue];
        
        /*
         On iOS, the only supported key is kCVPixelBufferPixelFormatTypeKey. Supported pixel formats are
         kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
         kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
         kCVPixelFormatType_32BGRA
         
         [AVCaptureVideoDataOutput setVideoSettings:] - videoSettings dictionary contains one or more unsupported (ignored) keys: (
         Height,
         Width
         )*/
        captureVideoDataOutput.videoSettings =@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)};
        
        captureVideoDataOutput.minFrameDuration = CMTimeMake(1, 15);
        videoDataOutput_=captureVideoDataOutput;
        
        if ([_captureSession canAddOutput:captureVideoDataOutput]) {
            [_captureSession addOutput:captureVideoDataOutput];
        }
        
        // 创建一个AVCaptureAudioDataOutput对象，将其添加到session
        AVCaptureAudioDataOutput* captureAudioDataOutput = [[AVCaptureAudioDataOutput alloc] init];
        queue = dispatch_queue_create("MyAudioQueue", NULL);
        [captureAudioDataOutput setSampleBufferDelegate:self queue:queue];
        audioDataOutput_=captureAudioDataOutput;
        
        if ([_captureSession canAddOutput:captureAudioDataOutput]) {
            [_captureSession addOutput:captureAudioDataOutput];
        }
    }
    
    //创建视频预览层，用于实时展示摄像头状态
    AVCaptureVideoPreviewLayer* captureVideoPreviewLayer=[[AVCaptureVideoPreviewLayer alloc]initWithSession:self.captureSession];
    CALayer *layer=self.view.layer;
    layer.masksToBounds=YES;
    captureVideoPreviewLayer.frame=layer.bounds;
    captureVideoPreviewLayer.videoGravity=AVLayerVideoGravityResizeAspectFill;//填充模式
    [layer addSublayer:captureVideoPreviewLayer];
    self.captureVideoPreviewLayer=captureVideoPreviewLayer;
}

-(void)initH264Manager
{
    if(h264ManagerReady_)
    {
        return;
    }
    
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask,YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    
    NSString *date = nil;
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"YYYY-MM-dd";// hh:mm:ss
    date = [formatter stringFromDate:[NSDate date]];
    NSString *fileName = [date stringByAppendingString:@".flv"];//.h264
    NSString *writablePath = [documentsDirectory stringByAppendingPathComponent:fileName];
    [[NSFileManager defaultManager] removeItemAtPath:writablePath error:nil];
    
    cameraStreamManager_=[[CameraStreamManager alloc] initWithOutputPath:writablePath];
    [cameraStreamManager_ writeHead];
    
    h264ManagerReady_=YES;
}

-(void)pushStream:(id)pushFilePath
{
    AVDictionary* options = NULL;
    AVInputFormat *iformat=NULL;
    
    AVOutputFormat *ofmt = NULL;
    //输入对应一个AVFormatContext，输出对应一个AVFormatContext
    //（Input AVFormatContext and Output AVFormatContext）
    AVFormatContext *ifmt_ctx = NULL, *ofmt_ctx = NULL;
    AVPacket pkt;
    const char *in_filename, *out_filename;
    int ret, i;
    int videoindex=-1;
    int frame_index=0;
    int64_t start_time=0;
    //in_filename  = "cuc_ieschool.mov";
    //in_filename  = "cuc_ieschool.mkv";
    //in_filename  = "cuc_ieschool.ts";
    //in_filename  = "cuc_ieschool.mp4";
    //in_filename  = "cuc_ieschool.h264";
    in_filename  = "cuc_ieschool.flv";//输入URL（Input file URL）
    //in_filename  = "shanghai03_p.h264";
    
    in_filename=[pushFilePath UTF8String];
    
    out_filename = "rtmp://139.129.28.153:1935/myapp/test";//输出 URL（Output URL）[RTMP]
    //out_filename = "rtp://233.233.233.233:6666";//输出 URL（Output URL）[UDP]
    
    av_register_all();
    //Network
    avformat_network_init();
    //输入（Input）
    
    //from file
    /*
     if ((ret = avformat_open_input(&ifmt_ctx, in_filename, 0, 0)) < 0) {
     printf( "Could not open input file.");
     goto end;
     }*/
    
    //from device
    avdevice_register_all();
    ifmt_ctx = avformat_alloc_context();
    av_dict_set(&options,"list_devices","true",0);
    iformat = av_find_input_format("avfoundation");
    printf("Device Info=============\n");
    avformat_open_input(&ifmt_ctx,"video=dummy",iformat,&options);
    iformat = av_find_input_format("avfoundation");
    if ((ret = avformat_open_input(&ifmt_ctx,"0",iformat,NULL)) < 0) {
        printf( "Could not open input file.");
        goto end;
    }
    
    if ((ret = avformat_find_stream_info(ifmt_ctx, 0)) < 0) {
        printf( "Failed to retrieve input stream information");
        goto end;
    }
    
    for(i=0; i<ifmt_ctx->nb_streams; i++)
        if(ifmt_ctx->streams[i]->codec->codec_type==AVMEDIA_TYPE_VIDEO){
            videoindex=i;
            break;
        }
    
    av_dump_format(ifmt_ctx, 0, in_filename, 0);
    
    //输出（Output）
    
    avformat_alloc_output_context2(&ofmt_ctx, NULL, "flv", out_filename); //RTMP
    //avformat_alloc_output_context2(&ofmt_ctx, NULL, "mpegts", out_filename);//UDP
    
    if (!ofmt_ctx) {
        printf( "Could not create output context\n");
        ret = AVERROR_UNKNOWN;
        goto end;
    }
    ofmt = ofmt_ctx->oformat;
    for (i = 0; i < ifmt_ctx->nb_streams; i++) {
        //根据输入流创建输出流（Create output AVStream according to input AVStream）
        AVStream *in_stream = ifmt_ctx->streams[i];
        AVStream *out_stream = avformat_new_stream(ofmt_ctx, in_stream->codec->codec);
        if (!out_stream) {
            printf( "Failed allocating output stream\n");
            ret = AVERROR_UNKNOWN;
            goto end;
        }
        //复制AVCodecContext的设置（Copy the settings of AVCodecContext）
        ret = avcodec_copy_context(out_stream->codec, in_stream->codec);
        if (ret < 0) {
            printf( "Failed to copy context from input to output stream codec context\n");
            goto end;
        }
        out_stream->codec->codec_tag = 0;
        if (ofmt_ctx->oformat->flags & AVFMT_GLOBALHEADER)
            out_stream->codec->flags |= CODEC_FLAG_GLOBAL_HEADER;
    }
    //Dump Format------------------
    av_dump_format(ofmt_ctx, 0, out_filename, 1);
    //打开输出URL（Open output URL）
    if (!(ofmt->flags & AVFMT_NOFILE)) {
        ret = avio_open(&ofmt_ctx->pb, out_filename, AVIO_FLAG_WRITE);
        if (ret < 0) {
            printf( "Could not open output URL '%s'", out_filename);
            goto end;
        }
    }
    //写文件头（Write file header）
    ret = avformat_write_header(ofmt_ctx, NULL);
    if (ret < 0) {
        printf( "Error occurred when opening output URL\n");
        goto end;
    }
    
    start_time=av_gettime();
    while (1) {
        AVStream *in_stream, *out_stream;
        //获取一个AVPacket（Get an AVPacket）
        ret = av_read_frame(ifmt_ctx, &pkt);
        if (ret < 0)
            break;
        //FIX：No PTS (Example: Raw H.264)
        //Simple Write PTS
        if(pkt.pts==AV_NOPTS_VALUE){
            //Write PTS
            AVRational time_base1=ifmt_ctx->streams[videoindex]->time_base;
            //Duration between 2 frames (us)
            int64_t calc_duration=(double)AV_TIME_BASE/av_q2d(ifmt_ctx->streams[videoindex]->r_frame_rate);
            //Parameters
            pkt.pts=(double)(frame_index*calc_duration)/(double)(av_q2d(time_base1)*AV_TIME_BASE);
            pkt.dts=pkt.pts;
            pkt.duration=(double)calc_duration/(double)(av_q2d(time_base1)*AV_TIME_BASE);
        }
        //Important:Delay
        if(pkt.stream_index==videoindex){
            AVRational time_base=ifmt_ctx->streams[videoindex]->time_base;
            AVRational time_base_q={1,AV_TIME_BASE};
            int64_t pts_time = av_rescale_q(pkt.dts, time_base, time_base_q);
            int64_t now_time = av_gettime() - start_time;
            if (pts_time > now_time)
                av_usleep(pts_time - now_time);
            
        }
        
        in_stream  = ifmt_ctx->streams[pkt.stream_index];
        out_stream = ofmt_ctx->streams[pkt.stream_index];
        /* copy packet */
        //转换PTS/DTS（Convert PTS/DTS）
        pkt.pts = av_rescale_q_rnd(pkt.pts, in_stream->time_base, out_stream->time_base, (AVRounding)(AV_ROUND_NEAR_INF|AV_ROUND_PASS_MINMAX));
        pkt.dts = av_rescale_q_rnd(pkt.dts, in_stream->time_base, out_stream->time_base, (AVRounding)(AV_ROUND_NEAR_INF|AV_ROUND_PASS_MINMAX));
        pkt.duration = av_rescale_q(pkt.duration, in_stream->time_base, out_stream->time_base);
        pkt.pos = -1;
        //Print to Screen
        if(pkt.stream_index==videoindex){
            printf("Send %8d video frames to output URL\n",frame_index);
            frame_index++;
        }
        //ret = av_write_frame(ofmt_ctx, &pkt);
        ret = av_interleaved_write_frame(ofmt_ctx, &pkt);
        
        if (ret < 0) {
            printf( "Error muxing packet\n");
            break;
        }
        
        av_free_packet(&pkt);
        
    }
    //写文件尾（Write file trailer）
    av_write_trailer(ofmt_ctx);
end:
    avformat_close_input(&ifmt_ctx);
    /* close output */
    if (ofmt_ctx && !(ofmt->flags & AVFMT_NOFILE))
        avio_close(ofmt_ctx->pb);
    avformat_free_context(ofmt_ctx);
    if (ret < 0 && ret != AVERROR_EOF) {
        printf( "Error occurred.\n");
    }
}

-(void)pushDeviceStream
{
    unsigned int nb_streams=0;
    AVDictionary* options = NULL;
    AVInputFormat *iformat=NULL;
    
    AVOutputFormat *ofmt = NULL;
    //输入对应一个AVFormatContext，输出对应一个AVFormatContext
    //（Input AVFormatContext and Output AVFormatContext）
    AVFormatContext *ifmt_ctx = NULL, *ofmt_ctx = NULL;
    AVPacket pkt;
    const char *in_filename, *out_filename;
    int ret, i;
    int videoindex=-1;
    int frame_index=0;
    int64_t start_time=0;
    //in_filename  = "cuc_ieschool.mov";
    //in_filename  = "cuc_ieschool.mkv";
    //in_filename  = "cuc_ieschool.ts";
    //in_filename  = "cuc_ieschool.mp4";
    //in_filename  = "cuc_ieschool.h264";
    in_filename  = "cuc_ieschool.flv";//输入URL（Input file URL）
    //in_filename  = "shanghai03_p.h264";
    
    out_filename = "rtmp://139.129.28.153:1935/myapp/test";//输出 URL（Output URL）[RTMP]
    //out_filename = "rtp://233.233.233.233:6666";//输出 URL（Output URL）[UDP]
    
    av_register_all();
    //Network
    avformat_network_init();
    //输入（Input）
    
    //from file
    /*
     if ((ret = avformat_open_input(&ifmt_ctx, in_filename, 0, 0)) < 0) {
     printf( "Could not open input file.");
     goto end;
     }*/
    
    //from device
    avdevice_register_all();
    ifmt_ctx = avformat_alloc_context();
    av_dict_set(&options,"list_devices","true",0);
    iformat = av_find_input_format("avfoundation");
    printf("Device Info=============\n");
    avformat_open_input(&ifmt_ctx,"video=dummy",iformat,&options);
    iformat = av_find_input_format("avfoundation");
    //av_dict_set(&options, "rtsp_transport", "tcp", 0);
    
    options = NULL;
    av_dict_set(&options, "video_size", "192x144", 0);
    av_dict_set(&options, "framerate", "30", 0);
    
    in_filename="0";
    if ((ret = avformat_open_input(&ifmt_ctx,in_filename,iformat, &options)) < 0) {
        printf( "Could not open input file.");
        goto end;
    }
    
    if ((ret = avformat_find_stream_info(ifmt_ctx, 0)) < 0) {
        printf( "Failed to retrieve input stream information");
        goto end;
    }
    
    nb_streams=ifmt_ctx->nb_streams;
    for(i=0; i<nb_streams; i++)
        if(ifmt_ctx->streams[i]->codec->codec_type==AVMEDIA_TYPE_VIDEO){
            videoindex=i;
            break;
        }
    
    av_dump_format(ifmt_ctx, 0, in_filename, 0);
    
    //输出（Output）
    
    avformat_alloc_output_context2(&ofmt_ctx, NULL, "flv", out_filename); //RTMP
    //avformat_alloc_output_context2(&ofmt_ctx, NULL, "mpegts", out_filename);//UDP
    
    if (!ofmt_ctx) {
        printf( "Could not create output context\n");
        ret = AVERROR_UNKNOWN;
        goto end;
    }
    ofmt = ofmt_ctx->oformat;
    for (i = 0; i < nb_streams; i++) {
        //根据输入流创建输出流（Create output AVStream according to input AVStream）
        AVStream *in_stream = ifmt_ctx->streams[i];
        AVStream *out_stream = avformat_new_stream(ofmt_ctx, in_stream->codec->codec);
        if (!out_stream) {
            printf( "Failed allocating output stream\n");
            ret = AVERROR_UNKNOWN;
            goto end;
        }
        //复制AVCodecContext的设置（Copy the settings of AVCodecContext）
        ret = avcodec_copy_context(out_stream->codec, in_stream->codec);
        if (ret < 0) {
            printf( "Failed to copy context from input to output stream codec context\n");
            goto end;
        }
        out_stream->codec->codec_tag = 0;
        if (ofmt_ctx->oformat->flags & AVFMT_GLOBALHEADER)
            out_stream->codec->flags |= CODEC_FLAG_GLOBAL_HEADER;
    }
    //Dump Format------------------
    av_dump_format(ofmt_ctx, 0, out_filename, 1);
    //打开输出URL（Open output URL）
    if (!(ofmt->flags & AVFMT_NOFILE)) {
        ret = avio_open(&ofmt_ctx->pb, out_filename, AVIO_FLAG_WRITE);
        if (ret < 0) {
            printf( "Could not open output URL '%s'", out_filename);
            goto end;
        }
    }
    //    //写文件头（Write file header）
    //    ret = avformat_write_header(ofmt_ctx, NULL);
    //    if (ret < 0) {
    //        printf( "Error occurred when opening output URL\n");
    //        goto end;
    //    }
    
    start_time=av_gettime();
    while (1) {
        AVStream *in_stream, *out_stream;
        //获取一个AVPacket（Get an AVPacket）
        ret = av_read_frame(ifmt_ctx, &pkt);
        if (ret < 0)
            break;
        //FIX：No PTS (Example: Raw H.264)
        //Simple Write PTS
        if(pkt.pts==AV_NOPTS_VALUE){
            //Write PTS
            AVRational time_base1=ifmt_ctx->streams[videoindex]->time_base;
            //Duration between 2 frames (us)
            int64_t calc_duration=(double)AV_TIME_BASE/av_q2d(ifmt_ctx->streams[videoindex]->r_frame_rate);
            //Parameters
            pkt.pts=(double)(frame_index*calc_duration)/(double)(av_q2d(time_base1)*AV_TIME_BASE);
            pkt.dts=pkt.pts;
            pkt.duration=(double)calc_duration/(double)(av_q2d(time_base1)*AV_TIME_BASE);
        }
        //Important:Delay
        if(pkt.stream_index==videoindex){
            AVRational time_base=ifmt_ctx->streams[videoindex]->time_base;
            AVRational time_base_q={1,AV_TIME_BASE};
            int64_t pts_time = av_rescale_q(pkt.dts, time_base, time_base_q);
            int64_t now_time = av_gettime() - start_time;
            if (pts_time > now_time)
                av_usleep(pts_time - now_time);
        }
        
        in_stream  = ifmt_ctx->streams[pkt.stream_index];
        out_stream = ofmt_ctx->streams[pkt.stream_index];
        /* copy packet */
        //转换PTS/DTS（Convert PTS/DTS）
        pkt.pts = av_rescale_q_rnd(pkt.pts, in_stream->time_base, out_stream->time_base, (AVRounding)(AV_ROUND_NEAR_INF|AV_ROUND_PASS_MINMAX));
        pkt.dts = av_rescale_q_rnd(pkt.dts, in_stream->time_base, out_stream->time_base, (AVRounding)(AV_ROUND_NEAR_INF|AV_ROUND_PASS_MINMAX));
        pkt.duration = av_rescale_q(pkt.duration, in_stream->time_base, out_stream->time_base);
        pkt.pos = -1;
        //pkt.pts=10;
       // pkt.dts=10;
       // pkt.duration=10;
        //Print to Screen
        if(pkt.stream_index==videoindex){
            printf("Send %8d video frames to output URL\n",frame_index);
            frame_index++;
        }
        //ret = av_write_frame(ofmt_ctx, &pkt);
        ret = av_interleaved_write_frame(ofmt_ctx, &pkt);
        
        if (ret < 0) {
            printf( "Error muxing packet\n");
            break;
        }
        
        av_free_packet(&pkt);
        
    }
    //写文件尾（Write file trailer）
    //av_write_trailer(ofmt_ctx);
end:
    avformat_close_input(&ifmt_ctx);
    /* close output */
    if (ofmt_ctx && !(ofmt->flags & AVFMT_NOFILE))
        avio_close(ofmt_ctx->pb);
    avformat_free_context(ofmt_ctx);
    if (ret < 0 && ret != AVERROR_EOF) {
        printf( "Error occurred.\n");
    }
}


-(void)initAVContext
{
    unsigned int nb_streams=0;
    AVDictionary* options = NULL;
    AVInputFormat *iformat=NULL;
    
    AVOutputFormat *ofmt = NULL;
    
    AVPacket pkt;
    const char *in_filename, *out_filename;
    int ret, i;
    int videoindex=-1;
    int frame_index=0;
    int64_t start_time=0;
    
    out_filename = "rtmp://139.129.28.153:1935/myapp/test";//输出 URL（Output URL）[RTMP]
    av_register_all();
    avformat_network_init();
    avdevice_register_all();
    inContext_ = avformat_alloc_context();
    av_dict_set(&options,"list_devices","true",0);
    iformat = av_find_input_format("avfoundation");
    printf("Device Info=============\n");
    avformat_open_input(&inContext_,"video=dummy",iformat,&options);
    iformat = av_find_input_format("avfoundation");
    //av_dict_set(&options, "rtsp_transport", "tcp", 0);
    
    options = NULL;
    av_dict_set(&options, "video_size", "1280x720", 0);
    av_dict_set(&options, "framerate", "30", 0);
    
    if ((ret = avformat_open_input(&inContext_,"0",iformat, &options)) < 0) {
        return;
    }
    
    if ((ret = avformat_find_stream_info(inContext_, 0)) < 0) {
        return;
    }
    
    nb_streams=inContext_->nb_streams;
    for(i=0; i<nb_streams; i++)
        if(inContext_->streams[i]->codec->codec_type==AVMEDIA_TYPE_VIDEO){
            videoindex=i;
            break;
        }
    
    av_dump_format(inContext_, 0, "0", 0);
    
    //输出（Output）
    
    avformat_alloc_output_context2(&outContext_, NULL, "flv", out_filename); //RTMP
    //avformat_alloc_output_context2(&ofmt_ctx, NULL, "mpegts", out_filename);//UDP
    
    if (!outContext_)
    {
        return;
    }
    
    ofmt = outContext_->oformat;
    for (i = 0; i < nb_streams; i++)
    {
        //根据输入流创建输出流（Create output AVStream according to input AVStream）
        AVStream *in_stream = inContext_->streams[i];
        AVStream *out_stream = avformat_new_stream(outContext_, in_stream->codec->codec);
        if (!out_stream) {
            return;
        }
        //复制AVCodecContext的设置（Copy the settings of AVCodecContext）
        ret = avcodec_copy_context(out_stream->codec, in_stream->codec);
        if (ret < 0) {
            return;
        }
        out_stream->codec->codec_tag = 0;
        if (outContext_->oformat->flags & AVFMT_GLOBALHEADER)
            out_stream->codec->flags |= CODEC_FLAG_GLOBAL_HEADER;
    }
    //Dump Format------------------
    av_dump_format(outContext_, 0, out_filename, 1);
    //打开输出URL（Open output URL）
    if (!(ofmt->flags & AVFMT_NOFILE)) {
        ret = avio_open(&outContext_->pb, out_filename, AVIO_FLAG_WRITE);
        if (ret < 0) {
            return;
        }
    }
    
    outReady_=YES;
    //    //写文件头（Write file header）
    //    ret = avformat_write_header(ofmt_ctx, NULL);
    //    if (ret < 0) {
    //        printf( "Error occurred when opening output URL\n");
    //        goto end;
    //    }
    
     /*
    start_time=av_gettime();
    while (1) {
        AVStream *in_stream, *out_stream;
        //获取一个AVPacket（Get an AVPacket）
        ret = av_read_frame(ifmt_ctx, &pkt);
        if (ret < 0)
            break;
        //FIX：No PTS (Example: Raw H.264)
        //Simple Write PTS
        if(pkt.pts==AV_NOPTS_VALUE){
            //Write PTS
            AVRational time_base1=ifmt_ctx->streams[videoindex]->time_base;
            //Duration between 2 frames (us)
            int64_t calc_duration=(double)AV_TIME_BASE/av_q2d(ifmt_ctx->streams[videoindex]->r_frame_rate);
            //Parameters
            pkt.pts=(double)(frame_index*calc_duration)/(double)(av_q2d(time_base1)*AV_TIME_BASE);
            pkt.dts=pkt.pts;
            pkt.duration=(double)calc_duration/(double)(av_q2d(time_base1)*AV_TIME_BASE);
        }
        //Important:Delay
        if(pkt.stream_index==videoindex){
            AVRational time_base=ifmt_ctx->streams[videoindex]->time_base;
            AVRational time_base_q={1,AV_TIME_BASE};
            int64_t pts_time = av_rescale_q(pkt.dts, time_base, time_base_q);
            int64_t now_time = av_gettime() - start_time;
            if (pts_time > now_time)
                // av_usleep(pts_time - now_time);
                av_usleep(1000);
            
        }
        
        in_stream  = ifmt_ctx->streams[pkt.stream_index];
        out_stream = ofmt_ctx->streams[pkt.stream_index];
        // copy packet
        //转换PTS/DTS（Convert PTS/DTS）
        pkt.pts = av_rescale_q_rnd(pkt.pts, in_stream->time_base, out_stream->time_base, (AVRounding)(AV_ROUND_NEAR_INF|AV_ROUND_PASS_MINMAX));
        pkt.dts = av_rescale_q_rnd(pkt.dts, in_stream->time_base, out_stream->time_base, (AVRounding)(AV_ROUND_NEAR_INF|AV_ROUND_PASS_MINMAX));
        pkt.duration = av_rescale_q(pkt.duration, in_stream->time_base, out_stream->time_base);
        pkt.pos = -1;
        //pkt.pts=10;
        // pkt.dts=10;
        // pkt.duration=10;
        //Print to Screen
        if(pkt.stream_index==videoindex){
            printf("Send %8d video frames to output URL\n",frame_index);
            frame_index++;
        }
        //ret = av_write_frame(ofmt_ctx, &pkt);
        ret = av_interleaved_write_frame(ofmt_ctx, &pkt);
        
        if (ret < 0) {
            printf( "Error muxing packet\n");
            break;
        }
        
        av_free_packet(&pkt);
        
    }
    */
}


- (void)viewDidLoad
{
    [super viewDidLoad];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
}

-(void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    
    [self.captureSession startRunning];
    
}

-(void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    
    [self.captureSession stopRunning];
}

-(BOOL)shouldAutorotate
{
    return NO;
}

-(AVCaptureDevice *)getCameraDeviceWithPosition:(AVCaptureDevicePosition )position
{
    NSArray *cameras= [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
    for (AVCaptureDevice *camera in cameras)
    {
        if ([camera position]==position)
        {
            return camera;
        }
    }
    return nil;
}

-(void)onButtonClick:(UIButton*)button
{
    //if (![self.captureMovieFileOutput isRecording])
    if(button.tag==0)
    {
        [self startRecordVideo];
        
        [button setTitle:@"停止录制" forState:UIControlStateNormal];
        button.tag=1;
    }
    else
    {
        [self stopRecordVideo];
        
        [button setTitle:@"开始录制" forState:UIControlStateNormal];
        button.tag=0;
    }
}

- (void)startRecordVideo
{
    if(self.captureMovieFileOutput)
    {
        //根据设备输出获得连接
        AVCaptureConnection *captureConnection=[self.captureMovieFileOutput connectionWithMediaType:AVMediaTypeVideo];
        //根据连接取得设备输出的数据
        if (![self.captureMovieFileOutput isRecording])
        {
            //如果支持多任务则则开始多任务
            if ([[UIDevice currentDevice] isMultitaskingSupported])
            {
                self.backgroundTaskIdentifier=[[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:nil];
            }
            //预览图层和视频方向保持一致
            captureConnection.videoOrientation=[self.captureVideoPreviewLayer connection].videoOrientation;
            
            NSString *outputFielPath=[NSTemporaryDirectory() stringByAppendingString:@"myMovie.mov"];
            NSString *folder = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,  NSUserDomainMask, YES) lastObject];
            outputFielPath=[folder stringByAppendingString:@"/myMovie.mov"];
            NSLog(@"save path is :%@",outputFielPath);
            NSURL *fileUrl=[NSURL fileURLWithPath:outputFielPath];
            NSLog(@"fileUrl:%@",fileUrl);
            
            [self.captureMovieFileOutput startRecordingToOutputFileURL:fileUrl recordingDelegate:self];
        }
        else
        {
            [self.captureMovieFileOutput stopRecording];//停止录制
        }
    }
    else
    {
        [self initH264Manager];
    }
}

-(void)stopRecordVideo
{
    if(self.captureMovieFileOutput)
    {
        [self.captureMovieFileOutput stopRecording];//停止录制
    }
    else
    {
        h264ManagerReady_=NO;
        
        [self performSelector:@selector(writeEnd) withObject:nil afterDelay:1.0];
    }
}

-(void)writeEnd
{
    //[manager264_ freeX264Resource];
    //manager264_=nil;
    
    [cameraStreamManager_ writeEnd];
    cameraStreamManager_ = nil;
}

//http://blog.sina.com.cn/s/blog_5ec985eb0101t684.html
- (void)encode2_H264:(CMSampleBufferRef)sampleBuffer
{
    CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    
    // access the data
    int width = CVPixelBufferGetWidth(pixelBuffer);
    int height = CVPixelBufferGetHeight(pixelBuffer);
    unsigned char *rawPixelBase = (unsigned char *)CVPixelBufferGetBaseAddress(pixelBuffer);
    
    AVFrame *pFrame = av_frame_alloc();
    pFrame->quality = 0;
    AVFrame* outpic = av_frame_alloc();
    
    avpicture_fill((AVPicture*)pFrame, rawPixelBase, AV_PIX_FMT_BGR32, width, height);//PIX_FMT_RGB32//PIX_FMT_RGB8
    
    avcodec_register_all();
    av_register_all();
    
    AVCodec *codec;
    AVCodecContext *c= NULL;
    int  out_size, size, outbuf_size;
    //FILE *f;
    uint8_t *outbuf;
    
    codec =avcodec_find_encoder(AV_CODEC_ID_H264);//avcodec_find_encoder_by_name("libx264"); //avcodec_find_encoder(CODEC_ID_H264);//CODEC_ID_H264);
    
    if (!codec) {
        fprintf(stderr, "codec not foundn");
        exit(1);
    }
    
    c= avcodec_alloc_context3(codec);
    
    
    c->bit_rate = 400000;
    //    c->bit_rate_tolerance = 10;
    //    c->me_method = 2;
    
    c->width = 192;//width;//352;
    c->height = 144;//height;//288;
    
    c->time_base= (AVRational){1,25};
    c->gop_size = 10;//25;
    c->max_b_frames=1;
    c->pix_fmt = AV_PIX_FMT_YUV420P;
    c->thread_count = 1;
    
    //    c ->me_range = 16;
    //    c ->max_qdiff = 4;
    //    c ->qmin = 10;
    //    c ->qmax = 51;
    //    c ->qcompress = 0.6f;
    
    
    if (avcodec_open2(c, codec,NULL) < 0) {
        fprintf(stderr, "could not open codecn");
        exit(1);
    }
    
    
    outbuf_size = 100000;
    outbuf = (uint8_t *)malloc(outbuf_size);
    size = c->width * c->height;
    AVPacket avpkt;
    
    int nbytes = avpicture_get_size(AV_PIX_FMT_YUV420P, c->width, c->height);
    //create buffer for the output image
    uint8_t* outbuffer = (uint8_t*)av_malloc(nbytes);
    
    fflush(stdout);
    for (int i=0;i<15;++i)
    {
        avpicture_fill((AVPicture*)outpic, outbuffer, AV_PIX_FMT_YUV420P, c->width, c->height);
        
        struct SwsContext* fooContext = sws_getContext(c->width, c->height,
                                                       AV_PIX_FMT_BGR32,
                                                       c->width, c->height,
                                                       AV_PIX_FMT_YUV420P,
                                                       SWS_POINT, NULL, NULL, NULL);
        
        //perform the conversion
        
        pFrame->data[0]  += pFrame->linesize[0] * (height - 1);
        pFrame->linesize[0] *= -1;
        pFrame->data[1]  += pFrame->linesize[1] * (height / 2 - 1);
        pFrame->linesize[1] *= -1;
        pFrame->data[2]  += pFrame->linesize[2] * (height / 2 - 1);
        pFrame->linesize[2] *= -1;
        
        int xx = sws_scale(fooContext,(const uint8_t**)pFrame->data, pFrame->linesize, 0, c->height, outpic->data, outpic->linesize);
        // Here is where I try to convert to YUV
        NSLog(@"xxxxx=====%d",xx);
        
        
        int got_packet_ptr = 0;
        av_init_packet(&avpkt);
        avpkt.size = outbuf_size;
        avpkt.data = outbuf;
        
        outpic->format=AV_SAMPLE_FMT_S32;
        outpic->width=c->width;
        outpic->height=c->height;
        outpic->pts=i;
        
        out_size = avcodec_encode_video2(c, &avpkt, outpic, &got_packet_ptr);
        
        printf("encoding frame (size=])n", out_size);
        printf("encoding frame %sn", avpkt.data);
        printf("encoding frame %sn", avpkt.data);
        
        ////fwrite(avpkt.data,1,avpkt.size ,fp);
    }
    
    free(outbuf);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    
    avcodec_close(c);
    av_free(c);
    av_free(pFrame);
    av_free(outpic);
}

//http://blog.csdn.net/nonmarking/article/details/48601317
//http://www.cocoachina.com/bbs/read.php?tid-202850-page-1.html
- (void)encodeH264:(CMSampleBufferRef)sampleBuffer
{
    CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if(CVPixelBufferLockBaseAddress(pixelBuffer, 0) != kCVReturnSuccess)
    {
        return;
    }
    
    
    AVPixelFormat dest_pix_fmt=AV_PIX_FMT_YUV420P;
    AVPixelFormat pix_fmt=AV_PIX_FMT_NV12;
    int width = CVPixelBufferGetWidth(pixelBuffer);
    int height = CVPixelBufferGetHeight(pixelBuffer);
    
    if(!outContext_)
    {
        av_register_all();
        avcodec_register_all();
        avformat_network_init();
        
        if(!outContext_)
        {
            /* find the mpeg video encoder */
            AVCodec * codec =avcodec_find_encoder(AV_CODEC_ID_H264);//avcodec_find_encoder_by_name("libx264"); //avcodec_find_encoder(CODEC_ID_H264);//CODEC_ID_H264);
            
            if (!codec)
            {
                fprintf(stderr, "codec not found\n");
                exit(1);
            }
            
            /*
            AVCodecContext *c= avcodec_alloc_context3(codec);
            
            // put sample parameters
            c->bit_rate = 240000;
            //    c->bit_rate_tolerance = 10;
            //    c->me_method = 2;
            // resolution must be a multiple of two
            c->width = width;//352;
            c->height = height;//288;
            // frames per second
            c->time_base= (AVRational){1,25};
            c->gop_size = 10;//25;  emit one intra frame every ten frames
            c->max_b_frames=1;
            c->pix_fmt = dest_pix_fmt;
            c->thread_count = 1;
            
            av_opt_set(c->priv_data, "preset", "ultrafast", 0);
            av_opt_set(c->priv_data, "tune","stillimage,fastdecode,zerolatency",0);
            av_opt_set(c->priv_data, "x264opts","crf=26:vbv-maxrate=728:vbv-bufsize=364:keyint=25",0);
            
            //    c ->me_range = 16;
            //    c ->max_qdiff = 4;
            //    c ->qmin = 10;
            //    c ->qmax = 51;
            //    c ->qcompress = 0.6f;
            
            // open it
            if (avcodec_open2(c, codec,NULL) < 0) {
                fprintf(stderr, "could not open codec\n");
                exit(1);
            }*/
            
            
            AVCodecContext* pCodecCtx = avcodec_alloc_context3(codec);
            pCodecCtx->pix_fmt = AV_PIX_FMT_YUV420P;
            pCodecCtx->width = width;
            pCodecCtx->height = height;
            pCodecCtx->time_base.num = 1;
            pCodecCtx->time_base.den = 30;
            pCodecCtx->bit_rate = 800000;
            pCodecCtx->gop_size = 300;
            
            //H264 codec param
            //pCodecCtx->me_range = 16;
            //pCodecCtx->max_qdiff = 4;
            //pCodecCtx->qcompress = 0.6;
            pCodecCtx->qmin = 10;
            pCodecCtx->qmax = 51;
            //Optional Param
            pCodecCtx->max_b_frames = 3;
            // Set H264 preset and tune
            AVDictionary *param = 0;
            av_dict_set(&param, "preset", "ultrafast", 0);
            av_dict_set(&param, "tune", "zerolatency", 0);
            
            if (avcodec_open2(pCodecCtx, codec, &param) < 0){
                fprintf(stderr, "could not open codec\n");
                return;
            }
            encodeContext_=pCodecCtx;
            
            AVFormatContext *ofmt_ctx = NULL;//outContext_
            
            const char *out_filename = "rtmp://139.129.28.153:1935/myapp/test";
            
            avformat_alloc_output_context2(&ofmt_ctx, NULL, "flv", out_filename); //RTMP
            //avformat_alloc_output_context2(&ofmt_ctx, NULL, "mpegts", out_filename);//UDP
            
            if (!ofmt_ctx)
            {
                printf( "Could not create output context\n");
                return;
            }
            
            /* Some formats want stream headers to be separate. */
            if (ofmt_ctx->oformat->flags & AVFMT_GLOBALHEADER)
                encodeContext_->flags |= CODEC_FLAG_GLOBAL_HEADER;
            
            av_dump_format(ofmt_ctx, 0, out_filename, 1);
            
            //打开输出URL（Open output URL）
            if (!(ofmt_ctx->oformat->flags & AVFMT_NOFILE))
            {
                int ret = avio_open(&(ofmt_ctx->pb), out_filename, AVIO_FLAG_WRITE);
                if (ret < 0)
                {
                    printf( "Could not open output URL '%s'", out_filename);
                    return;
                }
            }
            
            AVStream *out_stream = avformat_new_stream(ofmt_ctx, codec);
            if (!out_stream)
            {
                printf( "Failed allocating output stream\n");
                return;
            }
            
            int ret = avcodec_copy_context(out_stream->codec, encodeContext_);
            if (ret < 0)
            {
                printf( "Failed to copy context from input to output stream codec context\n");
                return;
            }
            
            out_stream->codec->codec_tag = 0;
            if (ofmt_ctx->oformat->flags & AVFMT_GLOBALHEADER)
            {
                out_stream->codec->flags |= CODEC_FLAG_GLOBAL_HEADER;
            }
            
            out_stream->time_base.num = 1;
            out_stream->time_base.den = 30;
            out_stream->codec = pCodecCtx;
            
            //写文件头（Write file header）
            ret = avformat_write_header(ofmt_ctx, NULL);
            if (ret < 0)
            {
                printf( "Error occurred when opening output URL\n");
                return;
            }
            
            outContext_=ofmt_ctx;
            
            start_time = av_gettime(); 
        }

    }
    
//    int pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
//    AVPixelFormat pix_fmt;
//    if (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
//        pix_fmt = AV_PIX_FMT_NV12;
//    else
//        pix_fmt = AV_PIX_FMT_BGR32;
    
    //unsigned char *rawPixelBase = (unsigned char *)CVPixelBufferGetBaseAddress(pixelBuffer);
    UInt8 *rawPixelBase = (UInt8 *)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer,0);

    //size_t pixelBufferSize = CVPixelBufferGetDataSize(pixelBuffer);
 
    AVFrame *pFrame = av_frame_alloc();
    pFrame->quality = 0;
    
    avpicture_fill((AVPicture*)pFrame, rawPixelBase, pix_fmt, width, height);//PIX_FMT_RGB32//PIX_FMT_RGB8
    
    /* alloc image and output buffer */
    //int outbuf_size = pixelBufferSize;
    //uint8_t * outbuf = (uint8_t *)malloc(outbuf_size);
    
    int nbytes = avpicture_get_size(dest_pix_fmt, encodeContext_->width, encodeContext_->height);
    //create buffer for the output image
    uint8_t* outbuffer = (uint8_t*)av_malloc(nbytes);
    //fflush(stdout);
    AVFrame* outFrame = av_frame_alloc();
    avpicture_fill((AVPicture*)outFrame, outbuffer, dest_pix_fmt, encodeContext_->width, encodeContext_->height);
    
    /*
    struct SwsContext* fooContext = sws_getContext(width, height, pix_fmt,  encodeContext_->width, encodeContext_->height, dest_pix_fmt, SWS_POINT, NULL, NULL, NULL);
    
//    //perform the conversion
//    pFrame->data[0]  += pFrame->linesize[0] * (height - 1);
//    pFrame->linesize[0] *= -1;
//    pFrame->data[1]  += pFrame->linesize[1] * (height / 2 - 1);
//    pFrame->linesize[1] *= -1;
//    pFrame->data[2]  += pFrame->linesize[2] * (height / 2 - 1);
//    pFrame->linesize[2] *= -1;
    
    int xx = sws_scale(fooContext,(const uint8_t**)pFrame->data, pFrame->linesize, 0, height, outFrame->data, outFrame->linesize);
    // Here is where I try to convert to YUV
    NSLog(@"xxxxx=====%d",xx);*/
    
    
    //安卓摄像头数据为NV21格式，此处将其转换为YUV420P格式
    int size1=width*height;
    int size2=width*height/4;
    memcpy(outFrame->data[0],rawPixelBase,size1);
    for(int i=0;i<size2;i++)
    {
        *(outFrame->data[2]+i)=*(rawPixelBase+size1+i*2);
        *(outFrame->data[1]+i)=*(rawPixelBase+size1+i*2+1);
    }
    
    outFrame->format = AV_PIX_FMT_YUV420P;
    outFrame->width = width;
    outFrame->height = height;
    
    
    
    
    /* encode the image */
    int got_packet_ptr = 0;
    AVPacket avpkt;
    av_init_packet(&avpkt);
    avpkt.data = NULL;    // packet data will be allocated by the encoder
    avpkt.size = 0;
    avpkt.pts = AV_NOPTS_VALUE;
    avpkt.dts =AV_NOPTS_VALUE;
 
    
    //fill_yuv_image((AVPicture *)outFrame, outContext_->streams[0]->codec->frame_number,width, height);
    
    BOOL ret = avcodec_encode_video2(encodeContext_, &avpkt, outFrame, &got_packet_ptr)==0;
    ret=ret && got_packet_ptr>0;
    if(ret)
    {
        printf("encoding frame %d , %s , %d\n", frameIndex_, ret?"true":"false", avpkt.size);
        frameIndex_++;
        
//
//        outFrame->pts = frameIndex_++;           //这边的pts值要不停增加
//        outFrame->width=encodeContext_->width;
//        outFrame->height=encodeContext_->height;
//        outFrame->format=encodeContext_->pix_fmt;
        //avpkt.duration=23;
        
        //Write PTS
        AVRational time_base = outContext_->streams[0]->time_base;//{ 1, 1000 };
        AVRational r_framerate1 = {60, 2 };//{ 50, 2 };
        AVRational time_base_q = { 1, AV_TIME_BASE };
        //Duration between 2 frames (us)
        int64_t calc_duration = (double)(AV_TIME_BASE)*(1 / av_q2d(r_framerate1));  //内部时间戳
        //Parameters
        //enc_pkt.pts = (double)(framecnt*calc_duration)*(double)(av_q2d(time_base_q)) / (double)(av_q2d(time_base));
        avpkt.pts = av_rescale_q(frameIndex_*calc_duration, time_base_q, time_base);
        avpkt.dts = avpkt.pts;
        avpkt.duration = av_rescale_q(calc_duration, time_base_q, time_base); //(double)(calc_duration)*(double)(av_q2d(time_base_q)) / (double)(av_q2d(time_base));
        avpkt.pos = -1;
        
        //Delay
        int64_t pts_time = av_rescale_q(avpkt.dts, time_base, time_base_q);
        int64_t now_time = av_gettime() - start_time;
        if (pts_time > now_time)
            av_usleep(pts_time - now_time);
        
        
        [self pushH264Packet:&avpkt];
    }
    
    av_free(outbuffer);
    av_free(pFrame);
    av_free(outFrame);
    
    /*We unlock the buffer*/
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
}

-(void)pushH264Packet:(AVPacket*)pkt
{
//    if (pkt->pts != AV_NOPTS_VALUE )
//    {
//        pkt->pts = av_rescale_q(pkt->pts,outContext_->streams[0]->codec->time_base, outContext_->streams[0]->time_base);
//    }
//    if(pkt->dts !=AV_NOPTS_VALUE )
//    {
//        pkt->dts = av_rescale_q(pkt->dts,outContext_->streams[0]->codec->time_base, outContext_->streams[0]->time_base);
//    }

    pkt->stream_index = outContext_->streams[0]->index;
    int ret = av_write_frame(outContext_, pkt);
    //int ret = av_interleaved_write_frame(outContext_, pkt);
    
    if (ret < 0)
    {
        printf( "Error push packet\n");
    }
}

#pragma mark - AVCaptureFileOutputRecordingDelegate 视频输出代理
-(void)captureOutput:(AVCaptureFileOutput *)captureOutput didStartRecordingToOutputFileAtURL:(NSURL *)fileURL fromConnections:(NSArray *)connections
{
    NSLog(@"开始录制...");
}

-(void)captureOutput:(AVCaptureFileOutput *)captureOutput didFinishRecordingToOutputFileAtURL:(NSURL *)outputFileURL fromConnections:(NSArray *)connections error:(NSError *)error
{
    NSLog(@"视频录制完成.");
    
    /*
     //视频录入完成之后在后台将视频存储到相簿
     UIBackgroundTaskIdentifier lastBackgroundTaskIdentifier=self.backgroundTaskIdentifier;
     self.backgroundTaskIdentifier=UIBackgroundTaskInvalid;
     ALAssetsLibrary *assetsLibrary=[[ALAssetsLibrary alloc]init];
     [assetsLibrary writeVideoAtPathToSavedPhotosAlbum:outputFileURL completionBlock:^(NSURL *assetURL, NSError *error)
     {
     if (error)
     {
     NSLog(@"保存视频到相簿过程中发生错误，错误信息：%@",error.localizedDescription);
     }
     NSLog(@"outputUrl:%@",outputFileURL);
     [[NSFileManager defaultManager] removeItemAtURL:outputFileURL error:nil];
     if (lastBackgroundTaskIdentifier!=UIBackgroundTaskInvalid)
     {
     [[UIApplication sharedApplication] endBackgroundTask:lastBackgroundTaskIdentifier];
     }
     NSLog(@"成功保存视频到相簿.");
     }];
     */
}

#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate
- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{
    if(captureOutput==videoDataOutput_)
    {
        if(h264ManagerReady_)
        {
            [cameraStreamManager_ writeVideoSampleBuffer:sampleBuffer];
        }
    }
    else if(captureOutput==audioDataOutput_)
    {
        if(h264ManagerReady_)
        {
            [cameraStreamManager_ writeAudioSampleBuffer:sampleBuffer];
        }
    }
}

@end
