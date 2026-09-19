#import "VZExternalLibrary.h"
#import "VZAppSettings.h"

#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <unistd.h>

NSString * const VZExternalLibraryPathKey = @"ExternalLibraryPath";
NSString * const VZExternalLibraryFolderName = @"VirtualMac";
NSString * const VZExternalVolumesRoot =
    @"/private/var/mobile/Library/LiveFiles/com.apple.filesystems.userfsd";
NSString * const VZExternalLibraryErrorDomain = @"VirtualMacExternalLibrary";

// Copy granularity. Zero-filled runs of this size are written as holes so a
// sparse Disk.img stays sparse on any destination that supports holes.
enum {
    kHoleBlockSize = 64 * 1024,
    kReadBufferSize = 8 * 1024 * 1024,
    kSparseProbeSize = 256 * 1024 * 1024,
    kSparseProbeAllocationLimit = 64 * 1024 * 1024,
};

static const uint64_t kMoveHeadroomBytes = 512ULL * 1024 * 1024;

static void ExternalLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void ExternalLog(NSString *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format
                                              arguments:arguments];
    va_end(arguments);
    printf("[VirtualMac] external library: %s\n", message.UTF8String);
    [message release];
}

static NSError *ExternalError(VZExternalLibraryError code, NSString *format,
                              ...) NS_FORMAT_FUNCTION(2, 3);
static NSError *ExternalError(VZExternalLibraryError code, NSString *format,
                              ...)
{
    va_list arguments;
    va_start(arguments, format);
    NSString *description = [[[NSString alloc] initWithFormat:format
                                                    arguments:arguments]
        autorelease];
    va_end(arguments);
    return [NSError errorWithDomain:VZExternalLibraryErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

static NSError *POSIXError(NSString *operation, NSString *path, int code)
{
    NSString *description = [NSString stringWithFormat:@"%@ failed for %@: %s",
        operation, path, strerror(code)];
    return [NSError errorWithDomain:VZExternalLibraryErrorDomain
                               code:VZExternalLibraryErrorIO
                           userInfo:@{NSLocalizedDescriptionKey: description,
                                      NSUnderlyingErrorKey: [NSError
                                          errorWithDomain:NSPOSIXErrorDomain
                                          code:code userInfo:nil]}];
}

static NSString *CanonicalPath(NSString *path)
{
    char resolved[PATH_MAX];
    if (!path.length || !realpath(path.fileSystemRepresentation, resolved))
        return path.stringByStandardizingPath;
    return [NSString stringWithUTF8String:resolved];
}

static NSString *CanonicalVolumesRoot(void)
{
    return CanonicalPath(VZExternalVolumesRoot);
}

static BOOL PathIsBelow(NSString *path, NSString *parent)
{
    NSString *prefix = [parent stringByAppendingString:@"/"];
    return [path hasPrefix:prefix];
}

BOOL VZExternalVolumeIsLive(NSString *volumePath)
{
    if (!volumePath.length)
        return NO;
    NSString *canonical = CanonicalPath(volumePath);
    if (!PathIsBelow(canonical, CanonicalVolumesRoot()))
        return NO;
    struct statfs volume, parent;
    if (statfs(canonical.fileSystemRepresentation, &volume) != 0)
        return NO;
    if (statfs(CanonicalVolumesRoot().fileSystemRepresentation, &parent) != 0)
        return NO;
    struct stat volumeInfo, parentInfo;
    if (stat(canonical.fileSystemRepresentation, &volumeInfo) != 0 ||
        stat(CanonicalVolumesRoot().fileSystemRepresentation, &parentInfo) != 0)
        return NO;
    // A live volume is its own mount point, so its device differs from the
    // directory that holds it. A stale folder left behind by an unplugged
    // drive belongs to the data volume and shares both device and fsid.
    // Device numbers are compared rather than mount-point strings so Unicode
    // normalization of the volume name cannot cause a false negative.
    BOOL ownMount = S_ISDIR(volumeInfo.st_mode) &&
        volumeInfo.st_dev != parentInfo.st_dev;
    BOOL distinctFileSystem = volume.f_fsid.val[0] != parent.f_fsid.val[0] ||
        volume.f_fsid.val[1] != parent.f_fsid.val[1];
    return ownMount && distinctFileSystem;
}

NSArray<NSDictionary<NSString *, NSString *> *> *VZExternalVolumes(void)
{
    NSMutableArray *volumes = [NSMutableArray array];
    NSFileManager *manager = NSFileManager.defaultManager;
    NSArray *names = [manager contentsOfDirectoryAtPath:VZExternalVolumesRoot
                                                  error:nil];
    for (NSString *name in [names sortedArrayUsingSelector:
            @selector(localizedStandardCompare:)]) {
        if ([name hasPrefix:@"."])
            continue;
        NSString *path = [VZExternalVolumesRoot
            stringByAppendingPathComponent:name];
        if (!VZExternalVolumeIsLive(path))
            continue;
        [volumes addObject:@{@"name": name, @"path": path}];
    }
    return volumes;
}

NSString *VZExternalLibraryPath(void)
{
    NSString *path = [VZAppSettings.sharedSettings
        stringForKey:VZExternalLibraryPathKey];
    if (!path.length)
        return nil;
    // Accept only the exact shape this module writes: a library folder
    // directly below a volume that is directly below the userfsd root.
    NSString *volume = path.stringByDeletingLastPathComponent;
    if (![path.lastPathComponent isEqualToString:VZExternalLibraryFolderName] ||
        ![volume.stringByDeletingLastPathComponent
            isEqualToString:VZExternalVolumesRoot] ||
        [volume.lastPathComponent hasPrefix:@"."] ||
        [path rangeOfString:@"/../"].location != NSNotFound)
        return nil;
    return path;
}

NSString *VZExternalLibraryVolumePath(void)
{
    return VZExternalLibraryPath().stringByDeletingLastPathComponent;
}

NSString *VZExternalLibraryVolumeName(void)
{
    return VZExternalLibraryVolumePath().lastPathComponent;
}

VZExternalLibraryState VZExternalLibraryCurrentState(void)
{
    NSString *volume = VZExternalLibraryVolumePath();
    if (!volume)
        return VZExternalLibraryStateOff;
    return VZExternalVolumeIsLive(volume) ? VZExternalLibraryStateMounted
                                          : VZExternalLibraryStateNotConnected;
}

// Mount point (in VZExternalVolumesRoot form) that owns `path`, or nil for
// any internal path. Foundation strips a leading "/private" when it
// standardizes an existing path and realpath adds it back, so every spelling
// of the userfsd root is accepted.
static NSString *VolumeForPath(NSString *path)
{
    if (!path.length)
        return nil;
    NSArray<NSString *> *roots = @[VZExternalVolumesRoot,
        VZExternalVolumesRoot.stringByStandardizingPath,
        CanonicalVolumesRoot()];
    NSArray<NSString *> *candidates = @[path, path.stringByStandardizingPath];
    for (NSString *candidate in candidates) {
        for (NSString *root in roots) {
            if (!PathIsBelow(candidate, root))
                continue;
            NSString *remainder = [candidate substringFromIndex:root.length + 1];
            NSString *name = remainder.pathComponents.firstObject;
            if (!name.length || [name isEqualToString:@"/"] ||
                [name isEqualToString:@".."])
                return nil;
            return [VZExternalVolumesRoot stringByAppendingPathComponent:name];
        }
    }
    return nil;
}

BOOL VZBundlePathIsExternal(NSString *bundlePath)
{
    return VolumeForPath(bundlePath) != nil;
}

BOOL VZBundleVolumeIsAvailable(NSString *bundlePath)
{
    NSString *volume = VolumeForPath(bundlePath);
    return volume ? VZExternalVolumeIsLive(volume) : YES;
}

NSString *VZLibraryPathForBundle(NSString *bundlePath)
{
    return bundlePath.stringByStandardizingPath.stringByDeletingLastPathComponent;
}

uint64_t VZFreeSpaceForPath(NSString *path)
{
    struct statfs info;
    if (statfs(path.fileSystemRepresentation, &info) != 0)
        return 0;
    return (uint64_t)info.f_bavail * (uint64_t)info.f_bsize;
}

static BOOL WalkDirectory(NSString *root, NSString *relative,
                          NSMutableArray<NSString *> *directories,
                          NSMutableArray<NSDictionary *> *files,
                          NSError **error)
{
    NSString *directory = relative.length
        ? [root stringByAppendingPathComponent:relative] : root;
    NSError *listError = nil;
    NSArray *names = [NSFileManager.defaultManager
        contentsOfDirectoryAtPath:directory error:&listError];
    if (!names) {
        if (error) *error = listError;
        return NO;
    }
    for (NSString *name in [names sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *childRelative = relative.length
            ? [relative stringByAppendingPathComponent:name] : name;
        NSString *child = [root stringByAppendingPathComponent:childRelative];
        struct stat info;
        if (lstat(child.fileSystemRepresentation, &info) != 0) {
            if (error) *error = POSIXError(@"lstat", child, errno);
            return NO;
        }
        if (S_ISDIR(info.st_mode)) {
            [directories addObject:childRelative];
            if (!WalkDirectory(root, childRelative, directories, files, error))
                return NO;
        } else if (S_ISREG(info.st_mode)) {
            [files addObject:@{@"relative": childRelative,
                               @"size": @((uint64_t)info.st_size),
                               @"allocated": @((uint64_t)info.st_blocks * 512)}];
        } else {
            if (error) *error = ExternalError(
                VZExternalLibraryErrorUnsupportedItem,
                @"%@ is not a regular file or folder and cannot be moved.",
                child);
            return NO;
        }
    }
    return YES;
}

void VZMeasureBundle(NSString *path, uint64_t *logicalBytes,
                     uint64_t *allocatedBytes)
{
    NSMutableArray *directories = [NSMutableArray array];
    NSMutableArray *files = [NSMutableArray array];
    uint64_t logical = 0, allocated = 0;
    if (WalkDirectory(path, @"", directories, files, NULL)) {
        for (NSDictionary *file in files) {
            logical += [file[@"size"] unsignedLongLongValue];
            allocated += [file[@"allocated"] unsignedLongLongValue];
        }
    }
    if (logicalBytes) *logicalBytes = logical;
    if (allocatedBytes) *allocatedBytes = allocated;
}

BOOL VZProbeExternalLibraryFolder(NSString *folder, BOOL *supportsSparseFiles,
                                  NSError **error)
{
    if (supportsSparseFiles)
        *supportsSparseFiles = NO;
    NSError *createError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:folder
            withIntermediateDirectories:YES attributes:nil
            error:&createError]) {
        if (error) *error = createError;
        return NO;
    }
    NSString *probe = [folder stringByAppendingPathComponent:
        [NSString stringWithFormat:@".sparse-probe-%@",
            NSUUID.UUID.UUIDString]];
    int descriptor = open(probe.fileSystemRepresentation,
                          O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (descriptor < 0) {
        if (error) *error = POSIXError(@"open", probe, errno);
        return NO;
    }
    BOOL sparse = NO;
    BOOL writable = YES;
    uint8_t marker = 1;
    if (ftruncate(descriptor, kSparseProbeSize) == 0 &&
        pwrite(descriptor, &marker, 1, kSparseProbeSize - 1) == 1) {
        fsync(descriptor);
        struct stat info;
        if (fstat(descriptor, &info) == 0 &&
            (uint64_t)info.st_size == kSparseProbeSize)
            sparse = (uint64_t)info.st_blocks * 512 <
                kSparseProbeAllocationLimit;
    } else {
        // Some file-system plug-ins refuse to extend a file past its end.
        // A plain write must still succeed for the folder to be usable.
        writable = pwrite(descriptor, &marker, 1, 0) == 1;
        if (!writable && error)
            *error = POSIXError(@"write", probe, errno);
    }
    close(descriptor);
    unlink(probe.fileSystemRepresentation);
    ExternalLog(@"probe folder=%@ writable=%d sparse=%d", folder, writable,
                sparse);
    if (supportsSparseFiles)
        *supportsSparseFiles = sparse;
    return writable;
}

// MARK: - Sparse copy

static BOOL BlockIsZero(const uint8_t *bytes, size_t length)
{
    const uint64_t *words = (const uint64_t *)bytes;
    size_t wordCount = length / sizeof(uint64_t);
    for (size_t index = 0; index < wordCount; index++)
        if (words[index])
            return NO;
    for (size_t index = wordCount * sizeof(uint64_t); index < length; index++)
        if (bytes[index])
            return NO;
    return YES;
}

static BOOL WriteFully(int descriptor, const uint8_t *bytes, size_t length,
                       off_t offset)
{
    while (length) {
        ssize_t written = pwrite(descriptor, bytes, length, offset);
        if (written < 0) {
            if (errno == EINTR)
                continue;
            return NO;
        }
        bytes += written;
        length -= (size_t)written;
        offset += written;
    }
    return YES;
}

@interface VZBundleMover ()
@property(nonatomic, copy) NSString *sourcePath;
@property(nonatomic, copy) NSString *destinationPath;
@property(nonatomic, copy) NSString *destinationLibrary;
@property(nonatomic, copy) NSString *stagingPath;
@property(nonatomic, copy) void (^progress)(VZBundleMovePhase, NSString *,
                                            double);
@property(nonatomic, assign) uint64_t totalBytes;
@property(nonatomic, assign) uint64_t processedBytes;
@property(nonatomic, assign) CFAbsoluteTime lastProgressReport;
@property(nonatomic, assign) BOOL started;
@end

@implementation VZBundleMover {
    atomic_bool _cancelled;
}

- (instancetype)initWithSourcePath:(NSString *)sourcePath
                destinationLibrary:(NSString *)destinationLibrary
{
    if ((self = [super init])) {
        self.sourcePath = sourcePath.stringByStandardizingPath;
        self.destinationLibrary =
            destinationLibrary.stringByStandardizingPath;
        self.destinationPath = [self.destinationLibrary
            stringByAppendingPathComponent:self.sourcePath.lastPathComponent];
        self.stagingPath =
            [self.destinationPath stringByAppendingPathExtension:@"moving"];
        atomic_init(&_cancelled, false);
    }
    return self;
}

- (void)dealloc
{
    [_sourcePath release];
    [_destinationPath release];
    [_destinationLibrary release];
    [_stagingPath release];
    [_progress release];
    [super dealloc];
}

- (void)cancel
{
    atomic_store(&_cancelled, true);
}

- (BOOL)isCancelled
{
    return atomic_load(&_cancelled);
}

- (void)reportPhase:(VZBundleMovePhase)phase item:(NSString *)item
              force:(BOOL)force
{
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!force && now - self.lastProgressReport < 0.2)
        return;
    self.lastProgressReport = now;
    double fraction = self.totalBytes
        ? (double)self.processedBytes / (double)self.totalBytes : 0.0;
    // Copying and verifying each cover half of the reported progress.
    if (phase == VZBundleMovePhaseCopying)
        fraction *= 0.5;
    else if (phase == VZBundleMovePhaseVerifying)
        fraction = 0.5 + fraction * 0.5;
    else
        fraction = 1.0;
    void (^progress)(VZBundleMovePhase, NSString *, double) = self.progress;
    if (!progress)
        return;
    NSString *name = [[item copy] autorelease];
    dispatch_async(dispatch_get_main_queue(), ^{
        progress(phase, name, MIN(1.0, MAX(0.0, fraction)));
    });
}

- (BOOL)copyFileAtPath:(NSString *)source toPath:(NSString *)destination
                  size:(uint64_t)expectedSize
                digest:(unsigned char *)digest
                 error:(NSError **)error
{
    int input = open(source.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (input < 0) {
        if (error) *error = POSIXError(@"open", source, errno);
        return NO;
    }
    int output = open(destination.fileSystemRepresentation,
                      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
    if (output < 0) {
        if (error) *error = POSIXError(@"create", destination, errno);
        close(input);
        return NO;
    }
    // Disk images are read once and never again by this process. Keep the
    // 8 GB host from evicting the guest's working set for a copy.
    fcntl(input, F_NOCACHE, 1);
    fcntl(output, F_NOCACHE, 1);

    uint8_t *buffer = malloc(kReadBufferSize);
    if (!buffer) {
        close(input);
        close(output);
        if (error) *error = POSIXError(@"malloc", source, ENOMEM);
        return NO;
    }
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    BOOL ok = YES;
    off_t offset = 0;
    NSString *name = source.lastPathComponent;
    while (ok) {
        if ([self isCancelled]) {
            ok = NO;
            if (error) *error = ExternalError(VZExternalLibraryErrorCancelled,
                @"The move was cancelled.");
            break;
        }
        ssize_t count = read(input, buffer, kReadBufferSize);
        if (count < 0) {
            if (errno == EINTR)
                continue;
            ok = NO;
            if (error) *error = POSIXError(@"read", source, errno);
            break;
        }
        if (count == 0)
            break;
        CC_SHA256_Update(&context, buffer, (CC_LONG)count);
        for (ssize_t chunkStart = 0; chunkStart < count;
             chunkStart += kHoleBlockSize) {
            size_t length = (size_t)MIN((ssize_t)kHoleBlockSize,
                                        count - chunkStart);
            if (BlockIsZero(buffer + chunkStart, length))
                continue; // becomes a hole on file systems that keep them
            if (!WriteFully(output, buffer + chunkStart, length,
                            offset + chunkStart)) {
                ok = NO;
                if (error) *error = POSIXError(@"write", destination, errno);
                break;
            }
        }
        offset += count;
        self.processedBytes += (uint64_t)count;
        [self reportPhase:VZBundleMovePhaseCopying item:name force:NO];
    }
    if (ok && (uint64_t)offset != expectedSize) {
        ok = NO;
        if (error) *error = ExternalError(VZExternalLibraryErrorIO,
            @"%@ changed size while it was being copied (expected %llu bytes, read %llu).",
            source, expectedSize, (unsigned long long)offset);
    }
    // Establish the logical length even when the file ends in zeros.
    if (ok && ftruncate(output, offset) != 0) {
        ok = NO;
        if (error) *error = POSIXError(@"truncate", destination, errno);
    }
    if (ok && fsync(output) != 0 && errno != ENOTSUP && errno != EINVAL)
        ExternalLog(@"fsync %@ failed: %s", destination, strerror(errno));
    CC_SHA256_Final(digest, &context);
    free(buffer);
    close(input);
    if (close(output) != 0 && ok) {
        ok = NO;
        if (error) *error = POSIXError(@"close", destination, errno);
    }
    return ok;
}

- (BOOL)verifyFileAtPath:(NSString *)path size:(uint64_t)expectedSize
                  digest:(const unsigned char *)expectedDigest
                   error:(NSError **)error
{
    int input = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (input < 0) {
        if (error) *error = POSIXError(@"open", path, errno);
        return NO;
    }
    fcntl(input, F_NOCACHE, 1);
    struct stat info;
    if (fstat(input, &info) != 0 || (uint64_t)info.st_size != expectedSize) {
        close(input);
        if (error) *error = ExternalError(
            VZExternalLibraryErrorVerificationFailed,
            @"%@ has %llu bytes after copying but %llu were expected.",
            path, (unsigned long long)info.st_size,
            (unsigned long long)expectedSize);
        return NO;
    }
    uint8_t *buffer = malloc(kReadBufferSize);
    if (!buffer) {
        close(input);
        if (error) *error = POSIXError(@"malloc", path, ENOMEM);
        return NO;
    }
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    BOOL ok = YES;
    uint64_t total = 0;
    NSString *name = path.lastPathComponent;
    while (ok) {
        if ([self isCancelled]) {
            ok = NO;
            if (error) *error = ExternalError(VZExternalLibraryErrorCancelled,
                @"The move was cancelled.");
            break;
        }
        ssize_t count = read(input, buffer, kReadBufferSize);
        if (count < 0) {
            if (errno == EINTR)
                continue;
            ok = NO;
            if (error) *error = POSIXError(@"read", path, errno);
            break;
        }
        if (count == 0)
            break;
        CC_SHA256_Update(&context, buffer, (CC_LONG)count);
        total += (uint64_t)count;
        self.processedBytes += (uint64_t)count;
        [self reportPhase:VZBundleMovePhaseVerifying item:name force:NO];
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    free(buffer);
    close(input);
    if (ok && (total != expectedSize ||
               memcmp(digest, expectedDigest, sizeof(digest)) != 0)) {
        ok = NO;
        if (error) *error = ExternalError(
            VZExternalLibraryErrorVerificationFailed,
            @"%@ does not match the original after copying.", path);
    }
    return ok;
}

- (void)removeStaging
{
    NSError *error = nil;
    if ([NSFileManager.defaultManager fileExistsAtPath:self.stagingPath] &&
        ![NSFileManager.defaultManager removeItemAtPath:self.stagingPath
                                                  error:&error])
        ExternalLog(@"could not remove partial copy %@: %@", self.stagingPath,
                    error);
}

- (BOOL)preflight:(NSError **)error
{
    NSFileManager *manager = NSFileManager.defaultManager;
    BOOL isDirectory = NO;
    if (![manager fileExistsAtPath:self.sourcePath isDirectory:&isDirectory] ||
        !isDirectory) {
        if (error) *error = ExternalError(VZExternalLibraryErrorInvalidBundle,
            @"%@ is not a folder.", self.sourcePath);
        return NO;
    }
    if (![self.sourcePath.pathExtension.lowercaseString
            isEqualToString:@"bundle"]) {
        if (error) *error = ExternalError(VZExternalLibraryErrorInvalidBundle,
            @"%@ is not a Virtual Mac bundle.", self.sourcePath);
        return NO;
    }
    if (!VZBundleVolumeIsAvailable(self.sourcePath)) {
        if (error) *error = ExternalError(VZExternalLibraryErrorNotMounted,
            @"The drive containing %@ is not connected.", self.sourcePath);
        return NO;
    }
    if (VZBundlePathIsExternal(self.destinationLibrary) &&
        !VZBundleVolumeIsAvailable(self.destinationLibrary)) {
        if (error) *error = ExternalError(VZExternalLibraryErrorNotMounted,
            @"The destination drive is not connected.");
        return NO;
    }
    if ([self.destinationLibrary isEqualToString:
            VZLibraryPathForBundle(self.sourcePath)]) {
        if (error) *error = ExternalError(
            VZExternalLibraryErrorDestinationExists,
            @"%@ is already stored in %@.", self.sourcePath.lastPathComponent,
            self.destinationLibrary);
        return NO;
    }
    if ([manager fileExistsAtPath:self.destinationPath] ||
        [manager fileExistsAtPath:self.stagingPath]) {
        if (error) *error = ExternalError(
            VZExternalLibraryErrorDestinationExists,
            @"%@ already exists in %@.", self.sourcePath.lastPathComponent,
            self.destinationLibrary);
        return NO;
    }
    BOOL sparse = NO;
    NSError *probeError = nil;
    if (!VZProbeExternalLibraryFolder(self.destinationLibrary, &sparse,
                                      &probeError)) {
        if (error) *error = probeError ?: ExternalError(
            VZExternalLibraryErrorNotWritable,
            @"%@ cannot be written to.", self.destinationLibrary);
        return NO;
    }
    uint64_t logical = 0, allocated = 0;
    VZMeasureBundle(self.sourcePath, &logical, &allocated);
    uint64_t required = (sparse ? MIN(allocated, logical) : logical) +
        kMoveHeadroomBytes;
    uint64_t available = VZFreeSpaceForPath(self.destinationLibrary);
    ExternalLog(@"preflight source=%@ destination=%@ logical=%llu allocated=%llu sparse=%d required=%llu available=%llu",
                self.sourcePath, self.destinationLibrary,
                (unsigned long long)logical, (unsigned long long)allocated,
                sparse, (unsigned long long)required,
                (unsigned long long)available);
    if (available < required) {
        NSByteCountFormatter *formatter =
            [[[NSByteCountFormatter alloc] init] autorelease];
        if (error) *error = [NSError errorWithDomain:VZExternalLibraryErrorDomain
            code:VZExternalLibraryErrorNotEnoughSpace
            userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:
                @"Moving needs %@ free on the destination, but only %@ is available.",
                [formatter stringFromByteCount:(long long)required],
                [formatter stringFromByteCount:(long long)available]],
                @"RequiredBytes": @(required),
                @"AvailableBytes": @(available)}];
        return NO;
    }
    return YES;
}

- (void)runWithCompletion:(void (^)(BOOL, NSError *, BOOL))completion
{
    NSError *error = nil;
    BOOL sourceRetained = NO;
    BOOL success = [self performMove:&error sourceRetained:&sourceRetained];
    if (!success) {
        [self removeStaging];
        ExternalLog(@"move failed source=%@ error=%@", self.sourcePath, error);
    } else {
        ExternalLog(@"move complete destination=%@ sourceRetained=%d",
                    self.destinationPath, sourceRetained);
    }
    [error retain];
    dispatch_async(dispatch_get_main_queue(), ^{
        completion(success, [error autorelease], sourceRetained);
    });
}

- (BOOL)performMove:(NSError **)error sourceRetained:(BOOL *)sourceRetained
{
    NSFileManager *manager = NSFileManager.defaultManager;
    if (![self preflight:error])
        return NO;
    NSMutableArray<NSString *> *directories = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *files = [NSMutableArray array];
    if (!WalkDirectory(self.sourcePath, @"", directories, files, error))
        return NO;
    uint64_t total = 0;
    for (NSDictionary *file in files)
        total += [file[@"size"] unsignedLongLongValue];
    // Copying and verifying each read every byte once.
    self.totalBytes = total;
    self.processedBytes = 0;

    NSError *createError = nil;
    if (![manager createDirectoryAtPath:self.stagingPath
            withIntermediateDirectories:NO
            attributes:@{NSFilePosixPermissions: @0755}
            error:&createError]) {
        if (error) *error = createError;
        return NO;
    }
    for (NSString *relative in directories) {
        NSString *path = [self.stagingPath
            stringByAppendingPathComponent:relative];
        if (![manager createDirectoryAtPath:path
                withIntermediateDirectories:NO
                attributes:@{NSFilePosixPermissions: @0755}
                error:&createError]) {
            if (error) *error = createError;
            return NO;
        }
    }
    NSMutableArray<NSData *> *digests = [NSMutableArray array];
    for (NSDictionary *file in files) {
        NSString *relative = file[@"relative"];
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        [self reportPhase:VZBundleMovePhaseCopying
                     item:relative.lastPathComponent force:YES];
        if (![self copyFileAtPath:[self.sourcePath
                    stringByAppendingPathComponent:relative]
                toPath:[self.stagingPath stringByAppendingPathComponent:relative]
                  size:[file[@"size"] unsignedLongLongValue]
                digest:digest error:error])
            return NO;
        [digests addObject:[NSData dataWithBytes:digest length:sizeof(digest)]];
    }
    self.processedBytes = 0;
    for (NSUInteger index = 0; index < files.count; index++) {
        NSDictionary *file = files[index];
        NSString *relative = file[@"relative"];
        [self reportPhase:VZBundleMovePhaseVerifying
                     item:relative.lastPathComponent force:YES];
        if (![self verifyFileAtPath:[self.stagingPath
                    stringByAppendingPathComponent:relative]
                  size:[file[@"size"] unsignedLongLongValue]
                digest:digests[index].bytes error:error])
            return NO;
    }
    [self reportPhase:VZBundleMovePhaseFinishing item:@"" force:YES];
    if ([manager fileExistsAtPath:self.destinationPath]) {
        if (error) *error = ExternalError(
            VZExternalLibraryErrorDestinationExists,
            @"%@ appeared in %@ while the move was running.",
            self.destinationPath.lastPathComponent, self.destinationLibrary);
        return NO;
    }
    if (rename(self.stagingPath.fileSystemRepresentation,
               self.destinationPath.fileSystemRepresentation) != 0) {
        if (error) *error = POSIXError(@"rename", self.stagingPath, errno);
        return NO;
    }
    // From here on the copy is complete and valid. Deleting the original is
    // best effort: a failure leaves two good copies rather than none.
    NSError *removeError = nil;
    if (![manager removeItemAtPath:self.sourcePath error:&removeError]) {
        ExternalLog(@"original %@ kept: %@", self.sourcePath, removeError);
        *sourceRetained = YES;
    }
    return YES;
}

- (void)startWithProgress:(void (^)(VZBundleMovePhase, NSString *, double))progress
               completion:(void (^)(BOOL, NSError *, BOOL))completion
{
    if (self.started)
        return;
    self.started = YES;
    self.progress = progress;
    void (^finish)(BOOL, NSError *, BOOL) = [[completion copy] autorelease];
    [finish retain];
    [self retain];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self runWithCompletion:^(BOOL success, NSError *error,
                                  BOOL sourceRetained) {
            finish(success, error, sourceRetained);
            [finish release];
            [self release];
        }];
    });
}

@end
