/*
 * Author: Landon Fuller <landonf@plausiblelabs.com>
 *
 * Copyright (c) 2008-2013 Plausible Labs Cooperative, Inc.
 * All rights reserved.
 *
 * Permission is hereby granted, free of charge, to any person
 * obtaining a copy of this software and associated documentation
 * files (the "Software"), to deal in the Software without
 * restriction, including without limitation the rights to use,
 * copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following
 * conditions:
 *
 * The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
 * OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 * NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 * HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
 * WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
 * OTHER DEALINGS IN THE SOFTWARE.
 */

#import "PLCrashReport.h"
#import "CrashReporter.h"

#import "crash_report.pb-c.h"

struct _PLCrashReportDecoder {
    Plcrash__CrashReport *crashReport;
};

#define IMAGE_UUID_DIGEST_LEN 16

@interface PLCrashReport (PrivateMethods)

- (Plcrash__CrashReport *) decodeCrashData: (NSData *) data error: (NSError **) outError;
- (PLCrashReportSystemInfo *) extractSystemInfo: (Plcrash__CrashReport__SystemInfo *) systemInfo error: (NSError **) outError;
- (PLCrashReportProcessorInfo *) extractProcessorInfo: (Plcrash__CrashReport__Processor *) processorInfo error: (NSError **) outError;
- (PLCrashReportMachineInfo *) extractMachineInfo: (Plcrash__CrashReport__MachineInfo *) machineInfo error: (NSError **) outError;
- (PLCrashReportApplicationInfo *) extractApplicationInfo: (Plcrash__CrashReport__ApplicationInfo *) applicationInfo error: (NSError **) outError;
- (PLCrashReportProcessInfo *) extractProcessInfo: (Plcrash__CrashReport__ProcessInfo *) processInfo error: (NSError **) outError;
- (NSArray *) extractThreadInfo: (Plcrash__CrashReport *) crashReport error: (NSError **) outError;
- (NSArray *) extractImageInfo: (Plcrash__CrashReport *) crashReport error: (NSError **) outError;
- (PLCrashReportExceptionInfo *) extractExceptionInfo: (Plcrash__CrashReport__Exception *) exceptionInfo error: (NSError **) outError;
- (PLCrashReportSignalInfo *) extractSignalInfo: (Plcrash__CrashReport__Signal *) signalInfo error: (NSError **) outError;

@end


static void populate_nserror (NSError **error, PLCrashReporterError code, NSString *description);

/**
 * Provides decoding of crash logs generated by the PLCrashReporter framework.
 *
 * @warning This API should be considered in-development and subject to change.
 */
@implementation PLCrashReport

/**
 * Initialize with the provided crash log data. On error, nil will be returned, and
 * an NSError instance will be provided via @a error, if non-NULL.
 *
 * @param encodedData Encoded plcrash crash log.
 * @param outError If an error occurs, this pointer will contain an NSError object
 * indicating why the crash log could not be parsed. If no error occurs, this parameter
 * will be left unmodified. You may specify NULL for this parameter, and no error information
 * will be provided.
 *
 * @par Designated Initializer
 * This method is the designated initializer for the PLCrashReport class.
 */
- (id) initWithData: (NSData *) encodedData error: (NSError **) outError {
    if ((self = [super init]) == nil) {
        // This shouldn't happen, but we have to fufill our API contract
        populate_nserror(outError, PLCrashReporterErrorUnknown, @"Could not initialize superclass");
        return nil;
    }


    /* Allocate the struct and attempt to parse */
    _decoder = malloc(sizeof(_PLCrashReportDecoder));
    _decoder->crashReport = [self decodeCrashData: encodedData error: outError];

    /* Check if decoding failed. If so, outError has already been populated. */
    if (_decoder->crashReport == NULL) {
        goto error;
    }

    /* Report info (optional) */
    _uuid = NULL;
    if (_decoder->crashReport->report_info != NULL) {
        /* Report UUID (optional)
         * If our minimum supported target is bumped to (10.8+, iOS 6.0+), NSUUID should
         * be used instead. */
        if (_decoder->crashReport->report_info->has_uuid) {
            /* Validate the UUID length */
            if (_decoder->crashReport->report_info->uuid.len != sizeof(uuid_t)) {
                populate_nserror(outError, PLCrashReporterErrorCrashReportInvalid , @"Report UUID value is not a standard 16 bytes");
                goto error;
            }

            CFUUIDBytes uuid_bytes;
            memcpy(&uuid_bytes, _decoder->crashReport->report_info->uuid.data, _decoder->crashReport->report_info->uuid.len);
            _uuid = CFUUIDCreateFromUUIDBytes(NULL, uuid_bytes);
        }
    }

    /* System info */
    _systemInfo = [[self extractSystemInfo: _decoder->crashReport->system_info error: outError] retain];
    if (!_systemInfo)
        goto error;
    
    /* Machine info */
    if (_decoder->crashReport->machine_info != NULL) {
        _machineInfo = [[self extractMachineInfo: _decoder->crashReport->machine_info error: outError] retain];
        if (!_machineInfo)
            goto error;
    }

    /* Application info */
    _applicationInfo = [[self extractApplicationInfo: _decoder->crashReport->application_info error: outError] retain];
    if (!_applicationInfo)
        goto error;
    
    /* Process info. Handle missing info gracefully -- it is only included in v1.1+ crash reports. */
    if (_decoder->crashReport->process_info != NULL) {
        _processInfo = [[self extractProcessInfo: _decoder->crashReport->process_info error:outError] retain];
        if (!_processInfo)
            goto error;
    }

    /* Signal info */
    _signalInfo = [[self extractSignalInfo: _decoder->crashReport->signal error: outError] retain];
    if (!_signalInfo)
        goto error;

    /* Thread info */
    _threads = [[self extractThreadInfo: _decoder->crashReport error: outError] retain];
    if (!_threads)
        goto error;

    /* Image info */
    _images = [[self extractImageInfo: _decoder->crashReport error: outError] retain];
    if (!_images)
        goto error;

    /* Exception info, if it is available */
    if (_decoder->crashReport->exception != NULL) {
        _exceptionInfo = [[self extractExceptionInfo: _decoder->crashReport->exception error: outError] retain];
        if (!_exceptionInfo)
            goto error;
    }

    return self;

error:
    [self release];
    return nil;
}

- (void) dealloc {
    /* Free the data objects */
    [_systemInfo release];
    [_machineInfo release];
    [_applicationInfo release];
    [_processInfo release];
    [_signalInfo release];
    [_threads release];
    [_images release];
    [_exceptionInfo release];
    
    if (_uuid != NULL)
        CFRelease(_uuid);

    /* Free the decoder state */
    if (_decoder != NULL) {
        if (_decoder->crashReport != NULL) {
            protobuf_c_message_free_unpacked((ProtobufCMessage *) _decoder->crashReport, &protobuf_c_system_allocator);
        }

        free(_decoder);
        _decoder = NULL;
    }

    [super dealloc];
}

/**
 * Return the binary image containing the given address, or nil if no binary image
 * is found.
 *
 * @param address The address to search for.
 */
- (PLCrashReportBinaryImageInfo *) imageForAddress: (uint64_t) address {
    for (PLCrashReportBinaryImageInfo *imageInfo in self.images) {
        if (imageInfo.imageBaseAddress <= address && address < (imageInfo.imageBaseAddress + imageInfo.imageSize))
            return imageInfo;
    }

    /* Not found */
    return nil;
}

// property getter. Returns YES if machine information is available.
- (BOOL) hasMachineInfo {
    if (_machineInfo != nil)
        return YES;
    return NO;
}

// property getter. Returns YES if process information is available.
- (BOOL) hasProcessInfo {
    if (_processInfo != nil)
        return YES;
    return NO;
}

// property getter. Returns YES if exception information is available.
- (BOOL) hasExceptionInfo {
    if (_exceptionInfo != nil)
        return YES;
    return NO;
}

@synthesize systemInfo = _systemInfo;
@synthesize machineInfo = _machineInfo;
@synthesize applicationInfo = _applicationInfo;
@synthesize processInfo = _processInfo;
@synthesize signalInfo = _signalInfo;
@synthesize threads = _threads;
@synthesize images = _images;
@synthesize exceptionInfo = _exceptionInfo;
@synthesize uuidRef = _uuid;

@end


/**
 * @internal
 * Private Methods
 */
@implementation PLCrashReport (PrivateMethods)

/**
 * Decode the crash log message.
 *
 * @warning MEMORY WARNING. The caller is responsible for deallocating th ePlcrash__CrashReport instance
 * returned by this method via protobuf_c_message_free_unpacked().
 */
- (Plcrash__CrashReport *) decodeCrashData: (NSData *) data error: (NSError **) outError {
    const struct PLCrashReportFileHeader *header;
    const void *bytes;

    bytes = [data bytes];
    header = bytes;

    /* Verify that the crash log is sufficently large */
    if (sizeof(struct PLCrashReportFileHeader) >= [data length]) {
        populate_nserror(outError, PLCrashReporterErrorCrashReportInvalid, NSLocalizedString(@"Could not decode truncated crash log",
                                                                                             @"Crash log decoding error message"));
        return NULL;
    }

    /* Check the file magic */
    if (memcmp(header->magic, PLCRASH_REPORT_FILE_MAGIC, strlen(PLCRASH_REPORT_FILE_MAGIC)) != 0) {
        populate_nserror(outError, PLCrashReporterErrorCrashReportInvalid,NSLocalizedString(@"Could not decode invalid crash log header",
                                                                                            @"Crash log decoding error message"));
        return NULL;
    }

    /* Check the version */
    if(header->version != PLCRASH_REPORT_FILE_VERSION) {
        populate_nserror(outError, PLCrashReporterErrorCrashReportInvalid, [NSString stringWithFormat: NSLocalizedString(@"Could not decode unsupported crash report version: %d", 
                                                                                                                         @"Crash log decoding message"), header->version]);
        return NULL;
    }

    Plcrash__CrashReport *crashReport = plcrash__crash_report__unpack(&protobuf_c_system_allocator, [data length] - sizeof(struct PLCrashReportFileHeader), header->data);
    if (crashReport == NULL) {
        populate_nserror(outError, PLCrashReporterErrorCrashReportInvalid, NSLocalizedString(@"An unknown error occured decoding the crash report", 
                                                                                             @"Crash log decoding error message"));
        return NULL;
    }

    return crashReport;
}


/**
 * Extract system information from the crash log. Returns nil on error.
 */
- (PLCrashReportSystemInfo *) extractSystemInfo: (Plcrash__CrashReport__SystemInfo *) systemInfo error: (NSError **) outError {
    NSDate *timestamp = nil;
    NSString *osBuild = nil;
    
    /* Validate */
    if (systemInfo == NULL) {
        populate_nserror(outError, PLCrashReporterErrorCrashReportInvalid, 
                         NSLocalizedString(@"Crash report is missing System Information section", 
                                           @"Missing sysinfo in crash report"));
        return nil;
    }
    
    if (systemInfo->os_version == NULL) {
        populate_nserror(outError, PLCrashReporterErrorCrashReportInvalid, 
                         NSLocalizedString(@"Crash report is missing System Information OS version field", 
                                           @"Missing sysinfo operating system in crash report"));
        return nil;
    }

    /* Set up the build, if available */
    if (systemInfo->os_build != NULL)
        osBuild = [NSString stringWithUTF8String: systemInfo->os_build];
    
    /* Set up the timestamp, if available */
    if (systemInfo->timestamp != 0)
        timestamp = [NSDate dateWithTimeIntervalSince1970: systemInfo->timestamp];
    
    /* Done */
    return [[[PLCrashReportSystemInfo alloc] initWithOperatingSystem: (PLCrashReportOperatingSystem) systemInfo->operating_system
                                              operatingSystemVersion: [NSString stringWithUTF8String: systemInfo->os_version]
                                                operatingSystemBuild: osBuild
                                                        architecture: (PLCrashReportArchitecture) systemInfo->architecture
                                                           timestamp: timestamp] autorelease];
}

/**
 * Extract processor information from the crash log. Returns nil on error.
 */
- (PLCrashReportProcessorInfo *) extractProcessorInfo: (Plcrash__CrashReport__Processor *) processorInfo error: (NSError **) outError {   
    /* Validate */
    if (processorInfo == NULL) {
        populate_nserror(outError, PLCrashReporterErrorCrashReportInvalid, 
                         NSLocalizedString(@"Crash report is missing processor info section", 
                                           @"Missing processor info in crash report"));
        return nil;
    }

    return [[[PLCrashReportProcessorInfo alloc] initWithTypeEncoding: (PLCrashReportProcessorTypeEncoding) processorInfo->encoding
                                                                type: processorInfo->type
                                                             subtype: processorInfo->subtype] autorelease];
}

/**
 * Extract machine information from the crash log. Returns nil on error.
 */
- (PLCrashReportMachineInfo *) extractMachineInfo: (Plcrash__CrashReport__MachineInfo *) machineInfo error: (NSError **) outError {
    NSString *model = nil;
    PLCrashReportProcessorInfo *processorInfo = nil;

    /* Validate */
    if (machineInfo == NULL) {
        populate_nserror(outError, PLCrashReporterErrorCrashReportInvalid, 
                         NSLocalizedString(@"Crash report is missing Machine Information section", 
                                           @"Missing machine_info in crash report"));
        return nil;
    }

    /* Set up the model, if available */
    if (machineInfo->model != NULL)
        model = [NSString stringWithUTF8String: machineInfo->model];

    /* Set up the processor info. */
    if (machineInfo->processor != NULL) {
        processorInfo = [self extractProcessorInfo: machineInfo->processor error: outError];
        if (processorInfo == nil)
            return nil;
    }

    /* Done */
    return [[[PLCrashReportMachineInfo alloc] initWithModelName: model
                                                  processorInfo: processorInfo
                                                 processorCount: machineInfo->processor_count
                                          logicalProcessorCount: machineInfo->logical_processor_count] autorelease];
}

/**
 * Extract application information from the crash log. Returns nil on error.
 */
- (PLCrashReportApplicationInfo *) extractApplicationInfo: (Plcrash__CrashReport__ApplicationInfo *) applicationInfo 
                                                    error: (NSError **) outError
{    
    /* Validate */
    if (applicationInfo == NULL) {
        populate_nserror(outError, PLCrashReporterErrorCrashReportInvalid, 
                         NSLocalizedString(@"Crash report is missing Application Information section", 
                                           @"Missing app info in crash report"));
        return nil;
    }

    /* Identifier available? */
    if (applicationInfo->identifier == NULL) {
        populate_nserror(outError, PLCrashReporterErrorCrashReportInvalid, 
                         NSLocalizedString(@"Crash report is missing Application Information app identifier field", 
                                           @"Missing app identifier in crash report"));
        return nil;
    }

    /* Version available? */
    if (applicationInfo->version == NULL) {
        populate_nserror(outError, PLCrashReporterErrorCrashReportInvalid, 
                         NSLocalizedString(@"Crash report is missing Application Information app version field", 
                                           @"Missing app version in crash report"));
        return nil;
    }
    
    /* Done */
    NSString *identifier = [NSString stringWithUTF8String: applicationInfo->identifier];
    NSString *version = [NSString stringWithUTF8String: applicationInfo->version];

    return [[[PLCrashReportApplicationInfo alloc] initWithApplicationIdentifier: identifier
                                                          applicationVersion: version] autorelease];
}


/**
 * Extract process information from the crash log. Returns nil on error.
 */
- (PLCrashReportProcessInfo *) extractProcessInfo: (Plcrash__CrashReport__ProcessInfo *) processInfo 
                                            error: (NSError **) outError
{    
    /* Validate */
    if (processInfo == NULL) {
        populate_nserror(outError, PLCrashReporterErrorCrashReportInvalid, 
                         NSLocalizedString(@"Crash report is missing Process Information section", 
                                           @"Missing process info in crash report"));
        return nil;
    }
    
    /* Name available? */
    NSString *processName = nil;
    if (processInfo->process_name != NULL)
        processName = [NSString stringWithUTF8String: processInfo->process_name];
    
    /* Path available? */
    NSString *processPath = nil;
    if (processInfo->process_path != NULL)
        processPath = [NSString stringWithUTF8String: processInfo->process_path];

    /* Start time available? */
    NSDate *startTime = nil;
    if (processInfo->has_start_time)
        startTime = [NSDate dateWithTimeIntervalSince1970: processInfo->start_time];
    
    /* Parent Name available? */
    NSString *parentProcessName = nil;
    if (processInfo->parent_process_name != NULL)
        parentProcessName = [NSString stringWithUTF8String: processInfo->parent_process_name];

    /* Required elements */
    NSUInteger processID = processInfo->process_id;
    NSUInteger parentProcessID = processInfo->parent_process_id;

    /* Done */
    return [[[PLCrashReportProcessInfo alloc] initWithProcessName: processName
                                                        processID: processID
                                                      processPath: processPath
                                                 processStartTime: startTime
                                                parentProcessName: parentProcessName
                                                  parentProcessID: parentProcessID
                                                           native: processInfo->native] autorelease];
}

/**
 * Extract symbol information from the crash log. Returns nil on error, or a PLCrashReportSymbolInfo
 * instance on success.
 */
- (PLCrashReportSymbolInfo *) extractSymbolInfo: (Plcrash__CrashReport__Symbol *) symbol error: (NSError **) outError {
    if (symbol == NULL) {
        populate_nserror(outError, PLCrashReporterErrorCrashReportInvalid,
                         NSLocalizedString(@"Crash report is missing symbol information",
                                           @"Missing symbol info in crash report"));
        return nil;
    }
    
    NSString *name = [NSString stringWithUTF8String: symbol->name];
    return [[[PLCrashReportSymbolInfo alloc] initWithSymbolName: name
                                                   startAddress: symbol->start_address
                                                     endAddress: symbol->has_end_address ? symbol->end_address : 0] autorelease];
}

/**
 * Extract stack frame information from the crash log. Returns nil on error, or a PLCrashReportStackFrameInfo
 * instance on success.
 */
- (PLCrashReportStackFrameInfo *) extractStackFrameInfo: (Plcrash__CrashReport__Thread__StackFrame *) stackFrame error: (NSError **) outError {
    /* There should be at least one thread */
    if (stackFrame == NULL) {
        populate_nserror(outError, PLCrashReporterErrorCrashReportInvalid,
                         NSLocalizedString(@"Crash report is missing stack frame information",
                                           @"Missing stack frame info in crash report"));
        return nil;
    }
    
    PLCrashReportSymbolInfo *symbolInfo = nil;
    if (stackFrame->symbol != NULL) {
        if ((symbolInfo = [self extractSymbolInfo: stackFrame->symbol error: outError]) == NULL)
            return NULL;
    }

    return [[[PLCrashReportStackFrameInfo alloc] initWithInstructionPointer: stackFrame->pc
                                                                 symbolInfo: symbolInfo] autorelease];
}

/**
 * Extract thread information from the crash log. Returns nil on error, or an array of PLCrashLogThreadInfo
 * instances on success.
 */
- (NSArray *) extractThreadInfo: (Plcrash__CrashReport *) crashReport error: (NSError **) outError {
    /* There should be at least one thread */
    if (crashReport->n_threads == 0) {
        populate_nserror(outError, PLCrashReporterErrorCrashReportInvalid,
                         NSLocalizedString(@"Crash report is missing thread state information",
                                           @"Missing thread info in crash report"));
        return nil;
    }

    /* Handle all threads */
    NSMutableArray *threadResult = [NSMutableArray arrayWithCapacity: crashReport->n_threads];
    for (size_t thr_idx = 0; thr_idx < crashReport->n_threads; thr_idx++) {
        Plcrash__CrashReport__Thread *thread = crashReport->threads[thr_idx];
        
        /* Fetch stack frames for this thread */
        NSMutableArray *frames = [NSMutableArray arrayWithCapacity: thread->n_frames];
        for (size_t frame_idx = 0; frame_idx < thread->n_frames; frame_idx++) {
            Plcrash__CrashReport__Thread__StackFrame *frame = thread->frames[frame_idx];
            PLCrashReportStackFrameInfo *frameInfo = [self extractStackFrameInfo: frame error: outError];
            if (frameInfo == nil)
                return nil;

            [frames addObject: frameInfo];
        }

        /* Fetch registers for this thread */
        NSMutableArray *registers = [NSMutableArray arrayWithCapacity: thread->n_registers];
        for (size_t reg_idx = 0; reg_idx < thread->n_registers; reg_idx++) {
            Plcrash__CrashReport__Thread__RegisterValue *reg = thread->registers[reg_idx];
            PLCrashReportRegisterInfo *regInfo;

            /* Handle missing register name (should not occur!) */
            if (reg->name == NULL) {
                populate_nserror(outError, PLCrashReporterErrorCrashReportInvalid, @"Missing register name in register value");
                return nil;
            }

            regInfo = [[[PLCrashReportRegisterInfo alloc] initWithRegisterName: [NSString stringWithUTF8String: reg->name]
                                                              registerValue: reg->value] autorelease];
            [registers addObject: regInfo];
        }

        /* Create the thread info instance */
        PLCrashReportThreadInfo *threadInfo = [[[PLCrashReportThreadInfo alloc] initWithThreadNumber: thread->thread_number
                                                                                   stackFrames: frames 
                                                                                       crashed: thread->crashed 
                                                                                     registers: registers] autorelease];
        [threadResult addObject: threadInfo];
    }
    
    return threadResult;
}


/**
 * Extract binary image information from the crash log. Returns nil on error.
 */
- (NSArray *) extractImageInfo: (Plcrash__CrashReport *) crashReport error: (NSError **) outError {
    /* There should be at least one image */
    if (crashReport->n_binary_images == 0) {
        populate_nserror(outError, PLCrashReporterErrorCrashReportInvalid,
                         NSLocalizedString(@"Crash report is missing binary image information",
                                           @"Missing image info in crash report"));
        return nil;
    }

    /* Handle all records */
    NSMutableArray *images = [NSMutableArray arrayWithCapacity: crashReport->n_binary_images];
    for (size_t i = 0; i < crashReport->n_binary_images; i++) {
        Plcrash__CrashReport__BinaryImage *image = crashReport->binary_images[i];
        PLCrashReportBinaryImageInfo *imageInfo;

        /* Validate */
        if (image->name == NULL) {
            populate_nserror(outError, PLCrashReporterErrorCrashReportInvalid, @"Missing image name in image record");
            return nil;
        }

        /* Extract UUID value */
        NSData *uuid = nil;
        if (image->uuid.len == 0) {
            /* No UUID */
            uuid = nil;
        } else {
            uuid = [NSData dataWithBytes: image->uuid.data length: image->uuid.len];
        }
        assert(image->uuid.len == 0 || uuid != nil);
        
        /* Extract code type (if available). */
        PLCrashReportProcessorInfo *codeType = nil;
        if (image->code_type != NULL) {
            if ((codeType = [self extractProcessorInfo: image->code_type error: outError]) == nil)
                return nil;
        }


        imageInfo = [[[PLCrashReportBinaryImageInfo alloc] initWithCodeType: codeType
                                                                baseAddress: image->base_address
                                                                       size: image->size
                                                                       name: [NSString stringWithUTF8String: image->name]
                                                                       uuid: uuid] autorelease];
        [images addObject: imageInfo];
    }

    return images;
}

/**
 * Extract  exception information from the crash log. Returns nil on error.
 */
- (PLCrashReportExceptionInfo *) extractExceptionInfo: (Plcrash__CrashReport__Exception *) exceptionInfo
                                               error: (NSError **) outError
{
    /* Validate */
    if (exceptionInfo == NULL) {
        populate_nserror(outError, PLCrashReporterErrorCrashReportInvalid, 
                         NSLocalizedString(@"Crash report is missing Exception Information section", 
                                           @"Missing appinfo in crash report"));
        return nil;
    }
    
    /* Name available? */
    if (exceptionInfo->name == NULL) {
        populate_nserror(outError, PLCrashReporterErrorCrashReportInvalid, 
                         NSLocalizedString(@"Crash report is missing exception name field", 
                                           @"Missing appinfo operating system in crash report"));
        return nil;
    }
    
    /* Reason available? */
    if (exceptionInfo->reason == NULL) {
        populate_nserror(outError, PLCrashReporterErrorCrashReportInvalid, 
                         NSLocalizedString(@"Crash report is missing exception reason field", 
                                           @"Missing appinfo operating system in crash report"));
        return nil;
    }
    
    /* Done */
    NSString *name = [NSString stringWithUTF8String: exceptionInfo->name];
    NSString *reason = [NSString stringWithUTF8String: exceptionInfo->reason];
    
    /* Fetch stack frames for this thread */
    NSMutableArray *frames = nil;
    if (exceptionInfo->n_frames > 0) {
        frames = [NSMutableArray arrayWithCapacity: exceptionInfo->n_frames];
        for (size_t frame_idx = 0; frame_idx < exceptionInfo->n_frames; frame_idx++) {
            Plcrash__CrashReport__Thread__StackFrame *frame = exceptionInfo->frames[frame_idx];
            PLCrashReportStackFrameInfo *frameInfo = [self extractStackFrameInfo: frame error: outError];
            if (frameInfo == nil)
                return nil;
            
            [frames addObject: frameInfo];
        }
    }

    if (frames == nil) {
        return [[[PLCrashReportExceptionInfo alloc] initWithExceptionName: name reason: reason] autorelease];
    } else {
        return [[[PLCrashReportExceptionInfo alloc] initWithExceptionName: name
                                                                   reason: reason 
                                                              stackFrames: frames] autorelease];
    }
}

/**
 * Extract signal information from the crash log. Returns nil on error.
 */
- (PLCrashReportSignalInfo *) extractSignalInfo: (Plcrash__CrashReport__Signal *) signalInfo
                                       error: (NSError **) outError
{
    /* Validate */
    if (signalInfo == NULL) {
        populate_nserror(outError, PLCrashReporterErrorCrashReportInvalid, 
                         NSLocalizedString(@"Crash report is missing Signal Information section", 
                                           @"Missing appinfo in crash report"));
        return nil;
    }
    
    /* Name available? */
    if (signalInfo->name == NULL) {
        populate_nserror(outError, PLCrashReporterErrorCrashReportInvalid, 
                         NSLocalizedString(@"Crash report is missing signal name field", 
                                           @"Missing appinfo operating system in crash report"));
        return nil;
    }
    
    /* Code available? */
    if (signalInfo->code == NULL) {
        populate_nserror(outError, PLCrashReporterErrorCrashReportInvalid, 
                         NSLocalizedString(@"Crash report is missing signal code field", 
                                           @"Missing appinfo operating system in crash report"));
        return nil;
    }
    
    /* Done */
    NSString *name = [NSString stringWithUTF8String: signalInfo->name];
    NSString *code = [NSString stringWithUTF8String: signalInfo->code];
    
    return [[[PLCrashReportSignalInfo alloc] initWithSignalName: name code: code address: signalInfo->address] autorelease];
}

@end

/**
 * @internal
 
 * Populate an NSError instance with the provided information.
 *
 * @param error Error instance to populate. If NULL, this method returns
 * and nothing is modified.
 * @param code The error code corresponding to this error.
 * @param description A localized error description.
 * @param cause The underlying cause, if any. May be nil.
 */
static void populate_nserror (NSError **error, PLCrashReporterError code, NSString *description) {
    NSMutableDictionary *userInfo;
    
    if (error == NULL)
        return;
    
    /* Create the userInfo dictionary */
    userInfo = [NSDictionary dictionaryWithObjectsAndKeys:
                description, NSLocalizedDescriptionKey,
                nil
                ];
    
    *error = [NSError errorWithDomain: PLCrashReporterErrorDomain code: code userInfo: userInfo];
}
