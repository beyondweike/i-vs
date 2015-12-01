//
//  X264Manager.m
//  FFmpeg_X264_Codec
//
//  Created by sunminmin on 15/9/7.
//  Copyright (c) 2015年 suntongmian@163.com. All rights reserved.
//

#import "CameraStreamManager.h"
#import "time.h"

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

const char* TestRTMPOutputPath = "rtmp://139.129.28.153:1935/myapp/test";
const int TestCameraWidth=640;
const int TestCameraHeight=480;
const enum AVPixelFormat DestPixFmt=AV_PIX_FMT_YUV420P;

@implementation CameraStreamManager
{
    id outputPath_;
    AVFormatContext* outputContext_;
    AVCodecContext* codeContext_;
    int frameIndex_;
    
    int64_t start_time;
}

-(void)dealloc
{
}

- (id)initWithOutputPath:(id)outputPath
{
    self = [super init];
    if (self)
    {
        outputPath_=outputPath;
        if(!outputPath_)
        {
            outputPath_=[NSString stringWithUTF8String:TestRTMPOutputPath];
        }
        
        av_register_all();
        avcodec_register_all();
        avformat_network_init();
        
        [self initCodeContext];
        if(codeContext_)
        {
            [self initOutputContext];
        }
    }
    
    return self;
}

-(void)initCodeContext
{
    if(codeContext_)
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
    // Set H264 preset and tune
    AVDictionary *param = 0;
    av_dict_set(&param, "preset", "ultrafast", 0);
    av_dict_set(&param, "tune", "zerolatency", 0);
    
    if (avcodec_open2(codecCtx, codec, &param) < 0){
        fprintf(stderr, "could not open codec\n");
        return;
    }
    
    codeContext_=codecCtx;
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
    //if (outputCtx->oformat->flags & AVFMT_GLOBALHEADER)
    //    codeContext_->flags |= CODEC_FLAG_GLOBAL_HEADER;
    //av_dump_format(outputCtx, 0, out_filename, 1);
    
    AVStream *out_stream = avformat_new_stream(outputCtx, codeContext_->codec);
    if (!out_stream)
    {
        printf( "Failed allocating output stream\n");
        return;
    }
    
    //    int ret = avcodec_copy_context(out_stream->codec, codeContext_);
    //    if (ret < 0)
    //    {
    //        printf( "Failed to copy context from input to output stream codec context\n");
    //        return;
    //    }
    
    //    out_stream->codec->codec_tag = 0;
    //    if (outputCtx->oformat->flags & AVFMT_GLOBALHEADER)
    //    {
    //        out_stream->codec->flags |= CODEC_FLAG_GLOBAL_HEADER;
    //    }
    //
    out_stream->time_base.num = 1;
    out_stream->time_base.den = 30;
    out_stream->codec = codeContext_;
    
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

- (void)writeSampleBuffer:(CMSampleBufferRef)sampleBuffer
{
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if(CVPixelBufferLockBaseAddress(imageBuffer, 0) != kCVReturnSuccess)
    {
        return;
    }
    
    UInt8 *rawPixelBase = (UInt8 *)CVPixelBufferGetBaseAddressOfPlane(imageBuffer,0);
    //int imageWidth = CVPixelBufferGetWidth(imageBuffer);
    //int imageHeight = CVPixelBufferGetHeight(imageBuffer);
    
    int bytesNum = avpicture_get_size(DestPixFmt, codeContext_->width, codeContext_->height);
    //create buffer for the output image
    uint8_t* outBuffer = (uint8_t*)av_malloc(bytesNum);
    AVFrame* outFrame = av_frame_alloc();
    avpicture_fill((AVPicture*)outFrame, outBuffer, DestPixFmt, codeContext_->width, codeContext_->height);
    
    //安卓摄像头数据为NV21格式，此处将其转换为YUV420P格式
    int y_length=TestCameraWidth*TestCameraHeight;
    int uv_length=TestCameraWidth*TestCameraHeight/4;
    memcpy(outFrame->data[0], rawPixelBase, y_length);
    for(int i=0;i<uv_length;i++)
    {
        *(outFrame->data[2]+i)=*(rawPixelBase + y_length+i*2);
        *(outFrame->data[1]+i)=*(rawPixelBase + y_length+i*2+1);
    }
    
    outFrame->format = AV_PIX_FMT_YUV420P;
    outFrame->width = TestCameraWidth;
    outFrame->height = TestCameraHeight;
    
    /* encode the image */
    int got_packet_ptr = 0;
    AVPacket avpkt;
    
    avpkt.data = NULL;    // packet data will be allocated by the encoder
    avpkt.size = 0;
    av_init_packet(&avpkt);
    
    BOOL ret = avcodec_encode_video2(codeContext_, &avpkt, outFrame, &got_packet_ptr)==0;
    ret=ret && got_packet_ptr>0;
    if(ret)
    {
        printf("encoding frame %d , %s , %d\n", frameIndex_, ret?"true":"false", avpkt.size);
        
        frameIndex_++;
        avpkt.stream_index = outputContext_->streams[0]->index;
        
        //Write PTS
        AVRational time_base = outputContext_->streams[0]->time_base;//{ 1, 1000 };
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
        
        [self writePacket:&avpkt];
    }
    
    av_free_packet(&avpkt);
    av_free(outBuffer);
    av_frame_free(&outFrame);
    
    /*We unlock the buffer*/
    CVPixelBufferUnlockBaseAddress(imageBuffer, 0);
}

- (BOOL)writePacket:(AVPacket*)avpkt
{
    //int ret = av_write_frame(outputContext_, avpkt);
    int ret = av_interleaved_write_frame(outputContext_, avpkt);
    
    if (ret<0)
    {
        printf("Error push packet\n");
    }
    
    return ret>=0;
}

- (void)writeEnd
{
    return;
    
    //Flush Encoder
//    int ret = [self flushEncoder:outputContext_ streamIndex:0];
//    if (ret < 0) {
//        printf("Flushing encoder failed\n");
//    }
    
    //Write file trailer
    av_write_trailer(outputContext_);
    
    //Clean
    if (outputContext_->streams[0])
    {
        avcodec_close(outputContext_->streams[0]->codec);
    }
    avio_close(outputContext_->pb);
    avformat_free_context(outputContext_);
}

-(int)flushEncoder:(AVFormatContext *)ofmt_ctx streamIndex:(unsigned int)stream_index
{
    int ret;
    int got_frame;
    AVPacket enc_pkt;
    if (!(ofmt_ctx->streams[stream_index]->codec->codec->capabilities & CODEC_CAP_DELAY))
        return 0;
    
    while (1)
    {
        enc_pkt.data = NULL;
        enc_pkt.size = 0;
        av_init_packet(&enc_pkt);
        ret = avcodec_encode_video2(ofmt_ctx->streams[stream_index]->codec, &enc_pkt,
                                    NULL, &got_frame);
        if (ret < 0)
            break;
        if (!got_frame)
        {
            ret = 0;
            break;
        }
        printf("Flush Encoder: Succeed to encode 1 frame!\tsize:%5d\n", enc_pkt.size);
        
        //Write PTS
        AVRational time_base = ofmt_ctx->streams[stream_index]->time_base;//{ 1, 1000 };
        AVRational r_framerate1 = { 60, 2 };
        AVRational time_base_q = { 1, AV_TIME_BASE };
        //Duration between 2 frames (us)
        int64_t calc_duration = (double)(AV_TIME_BASE)*(1 / av_q2d(r_framerate1));  //内部时间戳
        //Parameters
        enc_pkt.pts = av_rescale_q(frameIndex_*calc_duration, time_base_q, time_base);
        enc_pkt.dts = enc_pkt.pts;
        enc_pkt.duration = av_rescale_q(calc_duration, time_base_q, time_base);
        
        //转换PTS/DTS（Convert PTS/DTS）
        enc_pkt.pos = -1;
        frameIndex_++;
        ofmt_ctx->duration = enc_pkt.duration * frameIndex_;
        
        BOOL ret=[self writePacket:&enc_pkt];
        if(!ret)
        {
            break;
        }
    }
    
    return 0;
}

@end