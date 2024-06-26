/*  Copyright (c) MIPoPS. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-3-Clause license that can
 *  be found in the LICENSE.txt file in the root of the source tree.
 */

#import "Common/AvfCtl.h"
#import <AVFoundation/AVFoundation.h>

@implementation AVFCtlFileReceiver
- (void) setLastInput: (NSDate*) toDate
{
    _last_input = toDate;
}

- (NSDate*) lastInput
{
    return _last_input;
}

- (id) initWithOutputFileName:(NSString *)theFileName {
    self = [super init];
    if (self) {
        if ([theFileName isEqualToString: @"-"]) {
            _output_file = [NSFileHandle fileHandleWithStandardOutput];
        } else {
            [[NSFileManager defaultManager] createFileAtPath:theFileName contents:nil attributes:nil];
            _output_file = [NSFileHandle fileHandleForWritingAtPath:theFileName];
        }
        _output_data = [NSMutableData dataWithLength:1000];
    }
    return self;
}

- (void) captureOutput:(AVCaptureOutput *)captureOutput
  didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
         fromConnection:(AVCaptureConnection *)connection
{
    _last_input = [NSDate date];
    if (_output_file != nil) {
        CMBlockBufferRef block_buffer = CMSampleBufferGetDataBuffer(sampleBuffer); // raw, DV data only
        size_t bb_len = CMBlockBufferGetDataLength(block_buffer);
        if (_output_data.length != bb_len) {
            _output_data.length = bb_len;
        }
        CMBlockBufferCopyDataBytes(block_buffer, 0, _output_data.length, _output_data.mutableBytes);
        [_output_file writeData:_output_data];
    }
}

- (void) captureOutput:(AVCaptureOutput *)captureOutput
    didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
         fromConnection:(AVCaptureConnection *)connection
{
    NSLog(@"Frame dropped.");
}
@end

@implementation AVFCtl
+ (NSUInteger) getDeviceCount
{
    return [[AVCaptureDevice devicesWithMediaType:AVMediaTypeMuxed] count];
}

+ (NSString*) getDeviceName:(NSUInteger) index
{
    if (index >= [[AVCaptureDevice devicesWithMediaType:AVMediaTypeMuxed] count])
        return @"";

    AVCaptureDevice* device = [[AVCaptureDevice devicesWithMediaType:AVMediaTypeMuxed] objectAtIndex:index];
    NSMutableString* toReturn = [NSMutableString stringWithString:[device localizedName]];
    NSString* vendor = @"";
    NSString* model = @"";
    CFMutableDictionaryRef properties = NULL;
    io_iterator_t iterator;
    io_object_t service;
    io_name_t location;
    kern_return_t result;

    NSString* uniqueID = [device uniqueID];
    if ([uniqueID length] > 2 && [uniqueID hasPrefix:@"0x"])
        uniqueID = [uniqueID substringFromIndex:2];

    result = IOServiceGetMatchingServices(kIOMasterPortDefault, IOServiceNameMatching("IOFireWireDevice"), &iterator);
    if (result == KERN_SUCCESS)
    {
        while ((service=IOIteratorNext(iterator)) != 0) {
            result = IORegistryEntryGetLocationInPlane(service, kIOServicePlane, location);
            if (result==KERN_SUCCESS && strcmp(location, [uniqueID UTF8String]) == 0) {
                result = IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0);
                if (result==KERN_SUCCESS && properties!=NULL) {
                    NSDictionary* dictionary = (__bridge NSDictionary*)properties;

                    id probedVendor = dictionary[@"FireWire Vendor Name"];
                    if ([probedVendor isKindOfClass:[NSString class]] && [probedVendor length] > 0)
                        vendor = probedVendor;

                    id probedModel = dictionary[@"FireWire Product Name"];
                    if ([probedModel isKindOfClass:[NSString class]] && [probedModel length] > 0)
                        model = probedModel;
                }

                IOObjectRelease(service);
                break;
            }

            IOObjectRelease(service);
        }

        IOObjectRelease(iterator);
    }

    if ([model length] > 0)
    {
        if ([vendor length] > 0)
            [toReturn appendFormat:@" (%@ %@)", vendor, model];
        else
            [toReturn appendFormat:@" (%@)", model];
    }

    if (properties != NULL)
        CFRelease(properties);

    return toReturn;
}

+ (NSString*) getDeviceID:(NSUInteger) index
{
    if (index >= [[AVCaptureDevice devicesWithMediaType:AVMediaTypeMuxed] count])
        return @"";

    return [[[AVCaptureDevice devicesWithMediaType:AVMediaTypeMuxed] objectAtIndex:index] uniqueID];
}

+ (NSInteger) getDeviceIndex:(NSString*) uniqueID
{
    for (NSUInteger i = 0; i < [[AVCaptureDevice devicesWithMediaType:AVMediaTypeMuxed] count]; i++)
    {
        AVCaptureDevice *dev = [[AVCaptureDevice devicesWithMediaType:AVMediaTypeMuxed] objectAtIndex:i];
        if ([[dev uniqueID] isEqualToString:uniqueID])
            return i;
    }

    return -1;
}

+ (BOOL) isTransportControlsSupported:(NSUInteger) index
{
    if (index >= [[AVCaptureDevice devicesWithMediaType:AVMediaTypeMuxed] count])
        return NO;

    return [[[AVCaptureDevice devicesWithMediaType:AVMediaTypeMuxed] objectAtIndex:index] transportControlsSupported];
}

- (id) initWithDeviceIndex:(NSUInteger) index controller:(id) extCtl
{
    if (index >= [[AVCaptureDevice devicesWithMediaType:AVMediaTypeMuxed] count])
        return nil;

    self = [super init];
    if (self) {
        _device = [[AVCaptureDevice devicesWithMediaType:AVMediaTypeMuxed] objectAtIndex:index];
        _old_mode  = [_device transportControlsPlaybackMode];
        _old_speed = [_device transportControlsSpeed];
        _log_changes = NO;

        NSKeyValueObservingOptions options = NSKeyValueObservingOptionNew;
        NSString *keyPath = nil;

        keyPath = NSStringFromSelector(@selector(transportControlsPlaybackMode));
        [_device addObserver:self forKeyPath:keyPath options:options context:nil];

        keyPath = NSStringFromSelector(@selector(transportControlsSpeed));
        [_device addObserver:self forKeyPath:keyPath options:options context:nil];

        externalController = extCtl;
    }
    return self;
}

- (id) initWithDeviceID:(NSString*) uniqueID controller:(id) extCtl
{
    self = [super init];
    if (self) {
        for (NSUInteger i = 0; i < [[AVCaptureDevice devicesWithMediaType:AVMediaTypeMuxed] count]; i++)
        {
            AVCaptureDevice *dev = [[AVCaptureDevice devicesWithMediaType:AVMediaTypeMuxed] objectAtIndex:i];
            if ([[dev uniqueID] isEqualToString:uniqueID])
            {
                _device = dev;
                break;
            }
        }

        if (!_device)
            return nil;

        _old_mode  = [_device transportControlsPlaybackMode];
        _old_speed = [_device transportControlsSpeed];
        _log_changes = NO;

        NSKeyValueObservingOptions options = NSKeyValueObservingOptionNew;
        NSString *keyPath = nil;

        keyPath = NSStringFromSelector(@selector(transportControlsPlaybackMode));
        [_device addObserver:self forKeyPath:keyPath options:options context:nil];

        keyPath = NSStringFromSelector(@selector(transportControlsSpeed));
        [_device addObserver:self forKeyPath:keyPath options:options context:nil];

        externalController = extCtl;
    }
    return self;
}

- (void) dealloc
{
    NSString *keyPath = nil;

    keyPath = NSStringFromSelector(@selector(transportControlsPlaybackMode));
    [_device removeObserver:self forKeyPath:keyPath];

    keyPath = NSStringFromSelector(@selector(transportControlsSpeed));
    [_device removeObserver:self forKeyPath:keyPath];
}

- (void) observeValueForKeyPath:(NSString *)keyPath
                       ofObject:(id)object
                       change:(NSDictionary *)change
                       context:(void *)context
{
    if (context == nil) {
        if ([keyPath isEqualToString:NSStringFromSelector(@selector(transportControlsPlaybackMode))]) {
            AVCaptureDeviceTransportControlsPlaybackMode mode =
                [change[NSKeyValueChangeNewKey] integerValue];

            if (_old_mode != mode) {
                if (_log_changes)
                    NSLog(@"Mode changed: %ld -> %ld", _old_mode, mode);
                if (mode == AVCaptureDeviceTransportControlsNotPlayingMode &&
                    [_session isRunning]) {
                    if (_log_changes)
                        NSLog(@"Stopping capturing.");
                    [self stopCaptureSession];
                }
                _old_mode = mode;
            }
        } else if ([keyPath isEqualToString:NSStringFromSelector(@selector(transportControlsSpeed))]) {
            AVCaptureDeviceTransportControlsSpeed speed =
                [change[NSKeyValueChangeNewKey] floatValue];

            if (_old_speed != speed) {
                if (_log_changes)
                    NSLog(@"Speed changed: %f -> %f", _old_speed, speed);
                _old_speed = speed;
            }
        }
    } else {
        [super observeValueForKeyPath:keyPath
                             ofObject:object
                               change:change
                              context:context];
    }
}

- (NSString*) getStatus
{
    if (externalController)
        return [externalController getStatus];

    NSString *status;

    float speed = [_device transportControlsSpeed];
    if (speed == 0.0f) {
        status = @"stopped";
    } else if (speed == 1.0f) {
        status = @"playing";
    } else if (speed > 1.0f) {
        status = @"fast-forwarding";
    } else if (speed < 0.0f) {
        status = @"rewinding";
    } else {
        status = @"unknown";
    }

    return status;
}

- (void) createCaptureSession:(id) receiver
{
    NSError *error = nil;

    if ([_device isInUseByAnotherApplication]) {
        NSLog(@"Error creating capture session: device already in use");
        return;
    }

    @try {
        _session = [[AVCaptureSession alloc] init];

        // add input to session
        AVCaptureDeviceInput *device_input = [AVCaptureDeviceInput deviceInputWithDevice:_device error:&error];
        if (device_input == nil) {
            NSLog(@"Error creating device input: %@", error);
            return;
        }

        if (![_session canAddInput:device_input]) {
            NSLog(@"Error adding input to session");
            return;
        }

        [_session addInput:device_input];

        // create output for session
        _output = [[AVCaptureVideoDataOutput alloc] init];
        _output.videoSettings = @{ }; // set empty dict to receive raw data
        [_output setAlwaysDiscardsLateVideoFrames:NO];

        // add receiver delegate to output
        dispatch_queue_t queue = dispatch_queue_create("avfctl_queue", NULL);
        [_output setSampleBufferDelegate:(id)receiver queue:queue];
        // not in arc: dispatch_release(queue);

        // add output to session
        if (![_session canAddOutput:_output]) {
            NSLog(@"Error adding output to session");
            return;
        }
        [_session addOutput:_output];
    }
    @catch (NSException *e) {
        NSLog(@"Error creating capture session: %@", e);
        return;
    }

    receiverInstance = receiver;
}

- (void) startCaptureSession
{
    [_session startRunning];

}

- (void) stopCaptureSession
{
    [_session stopRunning];
}

- (void) setPlaybackMode:(AVCaptureDeviceTransportControlsPlaybackMode)theMode speed:(AVCaptureDeviceTransportControlsSpeed) theSpeed
{
    if (externalController)
    {
        [externalController setPlaybackMode:theMode speed:theSpeed];
        return;
    }

    @try {
        NSError *error = nil;
        if ([_device lockForConfiguration:&error] == YES) {
            [_device setTransportControlsPlaybackMode:theMode speed:theSpeed];
            [_device unlockForConfiguration];
        } else {
            NSLog(@"Error: %@", error);
        }
    }
    @catch (NSException *e) {
        NSLog(@"Exception: %@", e);
    }
}

- (AVCaptureDeviceTransportControlsSpeed) getSpeed
{
    if (externalController)
        return [externalController getSpeed];

    return [_device transportControlsSpeed];
}

- (AVCaptureDeviceTransportControlsPlaybackMode) getMode
{
    if (externalController)
        return [externalController getMode];

    return [_device transportControlsPlaybackMode];
}

- (BOOL) waitForSessionEnd:(NSUInteger) timeout
{
    // Initialize reveiver's last input timestamp to current time
    if (receiverInstance)
        [receiverInstance setLastInput: [NSDate date]];

    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"YYYY-MM-dd-HH-mm-ss"];
    // block as long as the capture session is running
    // terminates if playback mode changes to NotPlaying
    while ([self getSpeed] != 0.0f) {
        if (timeout && receiverInstance && [[NSDate dateWithTimeInterval:timeout sinceDate:[receiverInstance lastInput]] compare:[NSDate date]] == NSOrderedAscending)
        {
            [self setPlaybackMode:AVCaptureDeviceTransportControlsNotPlayingMode speed: 0.0f];
            return TRUE;
        }

        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.5f]];
    }

    return FALSE;
}

@end
