//
//  X264Manager.h
//  FFmpeg_X264_Codec
//
//  Created by sunminmin on 15/9/7.
//  Copyright (c) 2015年 suntongmian@163.com. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

@interface CameraStreamManager : NSObject

- (id)initWithOutputPath:(id)outputPath;

-(void)writeHead;
-(void)writeSampleBuffer:(CMSampleBufferRef)sampleBuffer;
-(void)writeEnd;

@end