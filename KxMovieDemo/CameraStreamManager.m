//
//  X264Manager.m
//  FFmpeg_X264_Codec
//
//  Created by sunminmin on 15/9/7.
//  Copyright (c) 2015年 suntongmian@163.com. All rights reserved.
//

/*
 视频文件的大小除以是视频的时长定义为码率。
 
 码率可以理解为取样率，单位时间内取样率越大，精度就越高，同时体积也越大。
 当视频没有经过编码时，如果分辨率越高，那么视频图像的细节越清晰。
 但如果视频经过编码，被限制在一定码率内，编码器就必须舍弃掉一部分细节。
 所以分辨率和码率都同清晰度有关。
 
 GPU解码就是所谓的硬解码
 CPU解码就是软解码。
 iOS提供的播放器类使用的是硬解码，所以视频播放对CPU不会有很大的压力，但是支持的播放格式比较单一，一般就是MP4、MOV、M4V这几个。
 */

/*
 单独存本地视频成功
 单独存本地声音，只能听见前几秒，修改播放代码后成功播放全部了
 同时存本地视频声音成功
 同时上传视频声音失败
 单独上传视频成功，但有延迟几秒
 单独上传声音能听见但出现重复不断
 */

#import "CameraStreamManager.h"
#import "time.h"
#import <AudioToolbox/AudioConverter.h>

#ifdef __cplusplus
extern "C" {
#endif
    
#include "libavutil/time.h"
#include "libavutil/opt.h"
#include "libavcodec/avcodec.h"
#include "libavformat/avformat.h"
#include "libswscale/swscale.h"
    
#ifdef __cplusplus
};
#endif

const BOOL TestRtmp=NO;
const char* TestRTMPOutputPath = "rtmp://139.129.28.153:1935/myapp/test";
const int TestCameraWidth=640;
const int TestCameraHeight=480;
const enum AVPixelFormat DestPixFmt=AV_PIX_FMT_YUV420P;

@implementation CameraStreamManager
{
    id outputPath_;
    AVFormatContext* outputContext_;
    AVCodecContext* videoCodeContext_;
    AVCodecContext* audioCodeContext_;
    int frameIndex_;
    
    int64_t start_time;
    
    AVRational rframeRate_;//AVStream.r_frame_rate
    
    AudioConverterRef m_converter;
}

-(void)dealloc
{
    avformat_network_deinit();
}

- (id)initWithOutputPath:(id)outputPath
{
    self = [super init];
    if (self)
    {
        outputPath_=outputPath;
        if(TestRtmp)
        {
            outputPath_=[NSString stringWithUTF8String:TestRTMPOutputPath];
        }
        
        rframeRate_.num=30;
        rframeRate_.den=2;
        
        av_register_all();
        avcodec_register_all();
        avformat_network_init();
        
        [self initVideoCodeContext];
        [self initAudioCodeContext];
        if(videoCodeContext_ && audioCodeContext_)
        {
            [self initOutputContext];
        }
    }
    
    return self;
}

-(void)initVideoCodeContext
{
    if(videoCodeContext_)
    {
        return;
    }
    
    /* find the mpeg video encoder */
    AVCodec* codec =avcodec_find_encoder(AV_CODEC_ID_H264);//avcodec_find_encoder_by_name("libx264"); //avcodec_find_encoder(CODEC_ID_H264);//CODEC_ID_H264);
    if (!codec)
    {
        fprintf(stderr, "codec not found\n");
        return;
    }
    
    AVCodecContext* codecCtx = avcodec_alloc_context3(codec);
    codecCtx->pix_fmt = AV_PIX_FMT_YUV420P;
    codecCtx->width = TestCameraWidth;
    codecCtx->height = TestCameraHeight;
    codecCtx->time_base.num = 1;
    codecCtx->time_base.den = 30;
    codecCtx->bit_rate = 800000;
    codecCtx->gop_size = 300;

    //H264 codec param
    //pCodecCtx->me_range = 16;
    //pCodecCtx->max_qdiff = 4;
    //pCodecCtx->qcompress = 0.6;
    codecCtx->qmin = 10;
    codecCtx->qmax = 51;
    //Optional Param
    codecCtx->max_b_frames = 3;
    codecCtx->flags |= CODEC_FLAG_GLOBAL_HEADER;

    // Set H264 preset and tune
    AVDictionary *param = 0;
    av_dict_set(&param, "preset", "ultrafast", 0);
    av_dict_set(&param, "tune", "zerolatency", 0);
    
    if (avcodec_open2(codecCtx, codec, &param) < 0){
        fprintf(stderr, "could not open codec\n");
        return;
    }
    
    videoCodeContext_=codecCtx;
}

-(void)initAudioCodeContext
{
    if(audioCodeContext_)
    {
        return;
    }

    AVCodec* codec =avcodec_find_encoder(AV_CODEC_ID_AAC);
    if (!codec)
    {
        fprintf(stderr, "codec %s not found\n" ,avcodec_get_name(AV_CODEC_ID_AAC));
        return;
    }

    AVCodecContext* codecCtx = avcodec_alloc_context3(codec);
    codecCtx->flags |= CODEC_FLAG_GLOBAL_HEADER ;
    codecCtx->codec_type = AVMEDIA_TYPE_AUDIO;
    /*AV_SAMPLE_FMT_S16 Specified sample format s16 is invalid or not supported*/
    codecCtx->sample_fmt = AV_SAMPLE_FMT_S16;
    codecCtx->sample_rate= 44100;//16000//48000
    codecCtx->channel_layout=AV_CH_LAYOUT_MONO;//AV_CH_LAYOUT_STEREO;
    codecCtx->channels = av_get_channel_layout_nb_channels(codecCtx->channel_layout);
    codecCtx->bit_rate = 64142;//64000;//32000
    codecCtx->strict_std_compliance = FF_COMPLIANCE_EXPERIMENTAL;
    codecCtx->profile=FF_PROFILE_AAC_LOW;
    codecCtx->time_base = (AVRational){1, codecCtx->sample_rate };
    
    //Show some information
    //av_dump_format(pFormatCtx, 0, out_file, 1);
    
    if (avcodec_open2(codecCtx, codec, 0) < 0){
        fprintf(stderr, "could not open codec\n");
        return;
    }
    
    audioCodeContext_=codecCtx;
}

-(void)initOutputContext
{
    if(outputContext_)
    {
        return;
    }
    
    const char* outputPath=[outputPath_ UTF8String];
    
    AVFormatContext* outputCtx=NULL;
    avformat_alloc_output_context2(&outputCtx, NULL, "flv", outputPath); //RTMP
    //avformat_alloc_output_context2(&ofmt_ctx, NULL, "mpegts", out_filename);//UDP
    if (!outputCtx)
    {
        printf("Could not create output context\n");
        return;
    }
    
    /* Some formats want stream headers to be separate. */
    //av_dump_format(outputCtx, 0, out_filename, 1);
    
    //video stream
    AVStream* videoOutputStream = avformat_new_stream(outputCtx, videoCodeContext_->codec);
    if (!videoOutputStream)
    {
        printf( "Failed allocating output stream\n");
        return;
    }
    videoOutputStream->time_base.num = 1;
    videoOutputStream->time_base.den = 30;
    videoOutputStream->codec = videoCodeContext_;
    
    //audio stream
    AVStream* audioOutputStream = avformat_new_stream(outputCtx, audioCodeContext_->codec);
    if (!audioOutputStream)
    {
        return;
    }
    audioOutputStream->codec = audioCodeContext_;
    //audioOutputStream->id=1;

    //打开输出URL（Open output URL）
    if (!(outputCtx->oformat->flags & AVFMT_NOFILE))
    {
        int ret = avio_open(&(outputCtx->pb), outputPath, AVIO_FLAG_WRITE);
        if (ret < 0)
        {
            printf("Could not open output URL '%s'", outputPath);
            return;
        }
    }
    
    outputContext_=outputCtx;
}

-(void)writeHead
{
    //写文件头（Write file header）
    int ret = avformat_write_header(outputContext_, NULL);
    if (ret < 0)
    {
        printf( "Error occurred when opening output URL\n");
    }
    
    start_time = av_gettime();
}

- (void)writeVideoSampleBuffer:(CMSampleBufferRef)sampleBuffer
{
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if(CVPixelBufferLockBaseAddress(imageBuffer, 0) != kCVReturnSuccess)
    {
        return;
    }
    
    UInt8 *rawPixelBase = (UInt8 *)CVPixelBufferGetBaseAddressOfPlane(imageBuffer,0);
    //int imageWidth = CVPixelBufferGetWidth(imageBuffer);
    //int imageHeight = CVPixelBufferGetHeight(imageBuffer);
    
    int bytesNum = avpicture_get_size(DestPixFmt, videoCodeContext_->width, videoCodeContext_->height);
    //create buffer for the output image
    uint8_t* outBuffer = (uint8_t*)av_malloc(bytesNum);
    AVFrame* outFrame = av_frame_alloc();
    avpicture_fill((AVPicture*)outFrame, outBuffer, DestPixFmt, videoCodeContext_->width, videoCodeContext_->height);
    
    /*
     NV21就是 YUV420SP
     NV12就是 YUV420SP格式，Y分量平面格式，UV打包格式
     SP(Semi-Planar)指的是YUV不是分成3个平面而是分成2个平面。Y数据一个平面，UV数据合用一个平面。UV平面的数据格式是UVUVUV..
     NV12和NV21属于YUV420格式，是一种two-plane模式，即Y和UV分为两个Plane，但是UV（CbCr）为交错存储，而不是分为三个plane

     NV12与NV21类似，U 和 V 交错排列,不同在于UV顺序。
     I420: YYYYYYYY UU VV    =>YUV420P
     YV12: YYYYYYYY VV UU    =>YUV420P
     NV12: YYYYYYYY UVUV     =>YUV420SP
     NV21: YYYYYYYY VUVU     =>YUV420SP
     */
    
    //安卓摄像头数据为NV21格式，iPhone为NV12，此处将其转换为YUV420P格式
    int y_length=TestCameraWidth*TestCameraHeight;
    int uv_length=TestCameraWidth*TestCameraHeight/4;
    memcpy(outFrame->data[0], rawPixelBase, y_length);
    for(int i=0;i<uv_length;i++)
    {
        //NV21
        //*(outFrame->data[2]+i)=*(rawPixelBase + y_length+i*2);
        //*(outFrame->data[1]+i)=*(rawPixelBase + y_length+i*2+1);
        
        //NV12
        *(outFrame->data[1]+i)=*(rawPixelBase + y_length + i*2);
        *(outFrame->data[2]+i)=*(rawPixelBase + y_length + i*2+1);
    }
    
    outFrame->format = AV_PIX_FMT_YUV420P;
    outFrame->width = TestCameraWidth;
    outFrame->height = TestCameraHeight;
    
    AVPacket avpkt;
    avpkt.data = NULL;
    avpkt.size = 0;
    av_init_packet(&avpkt);
    
    int got_packet_ptr = 0;
    BOOL ret = avcodec_encode_video2(videoCodeContext_, &avpkt, outFrame, &got_packet_ptr)==0;
    ret=ret && got_packet_ptr>0;
    printf("encoding frame %d , %s , %d\n", frameIndex_, ret?"true":"false", avpkt.size);
    if(ret)
    {
        AVStream* videoStream=[self videoStream];

        frameIndex_++;
        avpkt.stream_index = videoStream->index;
        
        //Write PTS
        AVRational time_base = videoStream->time_base;//{ 1, 1000 };
        AVRational time_base_q = { 1, AV_TIME_BASE };
        //Duration between 2 frames (us)
        int64_t calc_duration = (double)(AV_TIME_BASE)*(1 / av_q2d(rframeRate_));  //内部时间戳
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
            av_usleep((unsigned)(pts_time - now_time));
        
        [self writePacket:&avpkt];
    }
    
    av_free_packet(&avpkt);
    av_free(outBuffer);
    av_frame_free(&outFrame);
    
    /*We unlock the buffer*/
    CVPixelBufferUnlockBaseAddress(imageBuffer, 0);
}

- (void)writeAudioSampleBuffer2:(CMSampleBufferRef)sampleBuffer
{
    char szBuf[4096];
    int  nSize = sizeof(szBuf);
    BOOL success=[self encoderAAC:sampleBuffer aacData:szBuf aacLen:&nSize];
    printf("encoding audio  %s , %d\n", success?"true":"false", nSize);
    if (success)
    {
        AVPacket avpkt;
        avpkt.data = NULL;
        avpkt.size = 0;
        av_init_packet(&avpkt);
        
        avpkt.data=(uint8_t*)szBuf;
        avpkt.size=nSize;

        AVStream* audioStream=[self audioStream];
        avpkt.stream_index = audioStream->index;
        
        /*
        //Write PTS
        AVRational time_base = audioStream->time_base;//{ 1, 1000 };
        AVRational time_base_q = { 1, AV_TIME_BASE };
        //Duration between 2 frames (us)
        int64_t calc_duration = (double)(AV_TIME_BASE)*(1 / av_q2d(rframeRate_));  //内部时间戳
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
            av_usleep((unsigned)(pts_time - now_time));
         */
        
        [self writePacket:&avpkt];
        
        av_free_packet(&avpkt);
    }
}

- (void)writeAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer
{
     AudioBufferList audioBufferList;
     CMBlockBufferRef blockBuffer=NULL;
     NSMutableData* mData = [[NSMutableData alloc] init];
     
     CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, NULL, &audioBufferList, sizeof(audioBufferList), NULL, NULL, 0, &blockBuffer);
     
     UInt32 mNumberBuffers=audioBufferList.mNumberBuffers;
     for (int y = 0; y < mNumberBuffers; y++)
     {
         AudioBuffer audioBuffer = audioBufferList.mBuffers[y];
         Float32 *frame = (Float32 *)audioBuffer.mData;
         [mData appendBytes:frame length:audioBuffer.mDataByteSize];
     }
     
     CFRelease(blockBuffer);
     blockBuffer = NULL;
    
    CMItemCount numSamples = CMSampleBufferGetNumSamples(sampleBuffer);
    const AudioStreamBasicDescription *audioDescription = CMAudioFormatDescriptionGetStreamBasicDescription(CMSampleBufferGetFormatDescription(sampleBuffer));
    
    /*
    CMBlockBufferRef audioBlockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    NSUInteger channelIndex = 0;
    size_t audioBlockBufferOffset = (channelIndex * numSamples * sizeof(SInt16));
    size_t lengthAtOffset = 0;
    size_t totalLength = 0;
    char* samples = NULL;
    CMBlockBufferGetDataPointer(audioBlockBuffer, audioBlockBufferOffset, &lengthAtOffset, &totalLength, (char **)(&samples));
    */
    
    AVFrame* outFrame = av_frame_alloc();
    outFrame->format=audioCodeContext_->sample_fmt;
    outFrame->nb_samples =(int)numSamples;//audioCodeContext_->frame_size;
    outFrame->channels=audioDescription->mChannelsPerFrame;
    outFrame->sample_rate=(int)audioDescription->mSampleRate;
    outFrame->channel_layout = audioCodeContext_->channel_layout;
    
    //int size = av_samples_get_buffer_size(NULL, audioCodeContext_->channels,audioCodeContext_->frame_size,audioCodeContext_->sample_fmt, 1);
    
//    int buf_size=outFrame->nb_samples * av_get_bytes_per_sample(audioCodeContext_->sample_fmt) * outFrame->channels;
//    uint8_t *outbuff=av_malloc(buf_size);
//    memcpy(outbuff, samples, buf_size);
//    outFrame->linesize[0] = buf_size;
//    outFrame->extended_data = outFrame->data[0] = outbuff;
    
    const uint8_t * buf=mData.mutableBytes;
    int buf_size=mData.length;
    
    //my webCamera configured to produce 16bit 16kHz LPCM mono, so sample format hardcoded here, and seems to be correct
    int rett=avcodec_fill_audio_frame(outFrame, audioCodeContext_->channels, audioCodeContext_->sample_fmt, buf, buf_size, 1);
    
    AVPacket avpkt;
    av_init_packet(&avpkt);
    avpkt.data = NULL;
    avpkt.size = 0;
    
    
    //下面两句我加的。编码前一定要给frame时间戳
    //outFrame->pts = 1;
    //lastpts = outFrame->pts + outFrame->nb_samples;

    int got_packet=0;
    int ret = avcodec_encode_audio2(audioCodeContext_, &avpkt, outFrame, &got_packet);
    if (ret>=0)
    {
        if(got_packet>0)
        {
            AVStream* audioStream=[self audioStream];
            avpkt.stream_index = audioStream->index;
            avpkt.pos = -1;
            
            printf("write audio packet: Succeed to encode 1 frame!\tsize:%d\n", avpkt.size);
            
            [self writePacket:&avpkt];
        }
    }
    else
    {
        printf("encode fail %s\n", av_err2str(ret));
    }
    
    ////av_freep(outbuff);
    av_free_packet(&avpkt);
    av_frame_free(&outFrame);
    
    /*
     AVFrame* pFrame = av_frame_alloc();
     pFrame->nb_samples= audioCodeContext_->frame_size;
     pFrame->format= audioCodeContext_->sample_fmt;
     
     int size = av_samples_get_buffer_size(NULL, audioCodeContext_->channels,audioCodeContext_->frame_size,audioCodeContext_->sample_fmt, 1);
     uint8_t* frame_buf = (uint8_t *)av_malloc(size);
     avcodec_fill_audio_frame(pFrame, audioCodeContext_->channels, audioCodeContext_->sample_fmt,(const uint8_t*)frame_buf, size, 1);
     
     AVPacket pkt;
     av_new_packet(&pkt,size);
     
     int framenum=1000;
     for (int i=0; i<framenum; i++)
     {
     //Read PCM
     if (fread(frame_buf, 1, size, in_file) <= 0){
     printf("Failed to read raw data! \n");
     return -1;
     }else if(feof(in_file)){
     break;
     }
     
     pFrame->data[0] = frame_buf;  //PCM Data
     
     pFrame->pts=i*100;
     got_frame=0;
     //Encode
     ret = avcodec_encode_audio2(pCodecCtx, &pkt,pFrame, &got_frame);
     if(ret < 0){
     printf("Failed to encode!\n");
     return -1;
     }
     if (got_frame==1){
     printf("Succeed to encode 1 frame! \tsize:%5d\n",pkt.size);
     pkt.stream_index = audio_st->index;
     ret = av_write_frame(pFormatCtx, &pkt);
     av_free_packet(&pkt);
     }
     }*/
}

-(BOOL)createAudioConvert:(CMSampleBufferRef)sampleBuffer { //根据输入样本初始化一个编码转换器
    if (m_converter != nil)
    {
        return TRUE;
    }
    
    AudioStreamBasicDescription inputFormat = *(CMAudioFormatDescriptionGetStreamBasicDescription(CMSampleBufferGetFormatDescription(sampleBuffer))); // 输入音频格式
    AudioStreamBasicDescription outputFormat; // 这里开始是输出音频格式
    memset(&outputFormat, 0, sizeof(outputFormat));
    outputFormat.mSampleRate       = inputFormat.mSampleRate; // 采样率保持一致
    outputFormat.mFormatID         = kAudioFormatMPEG4AAC;    // AAC编码
    outputFormat.mChannelsPerFrame = 2;
    outputFormat.mFramesPerPacket  = 1024;                    // AAC一帧是1024个字节
    
    AudioClassDescription *desc = [self getAudioClassDescriptionWithType:kAudioFormatMPEG4AAC fromManufacturer:kAppleSoftwareAudioCodecManufacturer];
    if (AudioConverterNewSpecific(&inputFormat, &outputFormat, 1, desc, &m_converter) != noErr)
    {
        //CKPrint(@"AudioConverterNewSpecific failed");
        return NO;
    }
    
    return YES;
}
-(BOOL)encoderAAC:(CMSampleBufferRef)sampleBuffer aacData:(char*)aacData aacLen:(int*)aacLen { // 编码PCM成AAC
    if ([self createAudioConvert:sampleBuffer] != YES)
    {
        return NO;
    }
    
    CMBlockBufferRef blockBuffer = nil;
    AudioBufferList  inBufferList;
    if (CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, NULL, &inBufferList, sizeof(inBufferList), NULL, NULL, 0, &blockBuffer) != noErr)
    {
        //CKPrint(@"CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer failed");
        return NO;
    }
    // 初始化一个输出缓冲列表
    AudioBufferList outBufferList;
    outBufferList.mNumberBuffers              = 1;
    outBufferList.mBuffers[0].mNumberChannels = 2;
    outBufferList.mBuffers[0].mDataByteSize   = *aacLen; // 设置缓冲区大小
    outBufferList.mBuffers[0].mData           = aacData; // 设置AAC缓冲区
    UInt32 outputDataPacketSize               = 1;
    if (AudioConverterFillComplexBuffer(m_converter, inputDataProc, &inBufferList, &outputDataPacketSize, &outBufferList, NULL) != noErr)
    {
        //CKPrint(@"AudioConverterFillComplexBuffer failed");
        return NO;
    }
    
    *aacLen = outBufferList.mBuffers[0].mDataByteSize; //设置编码后的AAC大小
    CFRelease(blockBuffer);
    return YES;
}
-(AudioClassDescription*)getAudioClassDescriptionWithType:(UInt32)type fromManufacturer:(UInt32)manufacturer { // 获得相应的编码器
    static AudioClassDescription audioDesc;
    
    UInt32 encoderSpecifier = type, size = 0;
    OSStatus status;
    
    memset(&audioDesc, 0, sizeof(audioDesc));
    status = AudioFormatGetPropertyInfo(kAudioFormatProperty_Encoders, sizeof(encoderSpecifier), &encoderSpecifier, &size);
    if (status)
    {
        return nil;
    }
    
    uint32_t count = size / sizeof(AudioClassDescription);
    AudioClassDescription descs[count];
    status = AudioFormatGetProperty(kAudioFormatProperty_Encoders, sizeof(encoderSpecifier), &encoderSpecifier, &size, descs);
    for (uint32_t i = 0; i < count; i++)
    {
        if ((type == descs[i].mSubType) && (manufacturer == descs[i].mManufacturer))
        {
            memcpy(&audioDesc, &descs[i], sizeof(audioDesc));
            break;
        }
    }
    return &audioDesc;
}
OSStatus inputDataProc(AudioConverterRef inConverter, UInt32 *ioNumberDataPackets, AudioBufferList *ioData,AudioStreamPacketDescription **outDataPacketDescription, void *inUserData) { //<span style="font-family: Arial, Helvetica, sans-serif;">AudioConverterFillComplexBuffer 编码过程中，会要求这个函数来填充输入数据，也就是原始PCM数据</span>
    AudioBufferList bufferList = *(AudioBufferList*)inUserData;
    ioData->mBuffers[0].mNumberChannels = 1;
    ioData->mBuffers[0].mData           = bufferList.mBuffers[0].mData;
    ioData->mBuffers[0].mDataByteSize   = bufferList.mBuffers[0].mDataByteSize;
    return noErr;
}

- (BOOL)writePacket:(AVPacket*)avpkt
{
    //int ret = av_write_frame(outputContext_, avpkt);
    int ret = av_interleaved_write_frame(outputContext_, avpkt);
    
    if (ret<0)
    {
        printf("Error writePacket packet. %d %s , stream_index %d\n", ret, av_err2str(ret), avpkt->stream_index);
    }

    return ret>=0;
}

- (void)writeEnd
{
    //Flush Encoder
    [self flushVideoStream];
    [self flushAudioStream];
    
    //Write file trailer
    av_write_trailer(outputContext_);
    
    //Clean
    for (int i=0; i<outputContext_->nb_streams; i++)
    {
        avcodec_close(outputContext_->streams[i]->codec);
    }
    avio_close(outputContext_->pb);
    avformat_free_context(outputContext_);
}

-(void)flushVideoStream
{
    AVStream* videoStream=[self videoStream];
    if (!videoStream)
    {
        return;
    }
    
    if (!(videoStream->codec->codec->capabilities & CODEC_CAP_DELAY))
    {
        return;
    }
    
    int ret;
    int got_frame;
    AVPacket enc_pkt;
    
    while (1)
    {
        enc_pkt.data = NULL;
        enc_pkt.size = 0;
        av_init_packet(&enc_pkt);
        ret = avcodec_encode_video2(videoStream->codec, &enc_pkt,
                                    NULL, &got_frame);
        if (ret < 0)
        {
            break;
        }
        
        if (!got_frame)
        {
            ret = 0;
            break;
        }
        
        printf("Flush Encoder: Succeed to encode 1 frame!\tsize:%5d\n", enc_pkt.size);
        
        //Write PTS
        AVRational time_base = videoStream->time_base;//{ 1, 1000 };
        AVRational time_base_q = { 1, AV_TIME_BASE };
        //Duration between 2 frames (us)
        int64_t calc_duration = (double)(AV_TIME_BASE)*(1 / av_q2d(rframeRate_));  //内部时间戳
        //Parameters
        enc_pkt.pts = av_rescale_q(frameIndex_*calc_duration, time_base_q, time_base);
        enc_pkt.dts = enc_pkt.pts;
        enc_pkt.duration = av_rescale_q(calc_duration, time_base_q, time_base);
        
        //转换PTS/DTS（Convert PTS/DTS）
        enc_pkt.pos = -1;
        frameIndex_++;
        outputContext_->duration = enc_pkt.duration * frameIndex_;
        
        BOOL ret=[self writePacket:&enc_pkt];
        if(!ret)
        {
            break;
        }
    }
}

-(void)flushAudioStream
{
    AVStream* audioStream=[self audioStream];
    if (!audioStream)
    {
        return;
    }
    
    if (!(audioStream->codec->codec->capabilities & CODEC_CAP_DELAY))
    {
        return;
    }
    
    int ret;
    int got_frame;
    AVPacket enc_pkt;
    
    while (1)
    {
        enc_pkt.data = NULL;
        enc_pkt.size = 0;
        av_init_packet(&enc_pkt);
        ret = avcodec_encode_audio2(audioCodeContext_, &enc_pkt, NULL, &got_frame);
        if (ret < 0)
        {
            break;
        }
        
        if (!got_frame)
        {
            ret = 0;
            break;
        }
        
        printf("flushAudioStream: Succeed to encode 1 frame!\tsize:%5d\n", enc_pkt.size);
        
        enc_pkt.stream_index=audioStream->index;
        
        BOOL ret=[self writePacket:&enc_pkt];
        if(!ret)
        {
            break;
        }
    }
}

-(AVStream*)videoStream
{
    AVStream* videoStream=nil;
    for (int i=0; i<outputContext_->nb_streams; i++)
    {
        AVStream* stream=outputContext_->streams[i];
        if(stream->codec->codec_type==AVMEDIA_TYPE_VIDEO)
        {
            videoStream=stream;
            break;
        }
    }
    
    return videoStream;
}

-(AVStream*)audioStream
{
    AVStream* audioStream=nil;
    for (int i=0; i<outputContext_->nb_streams; i++)
    {
        AVStream* stream=outputContext_->streams[i];
        if(stream->codec->codec_type==AVMEDIA_TYPE_AUDIO)
        {
            audioStream=stream;
            break;
        }
    }
    
    return audioStream;
}

@end