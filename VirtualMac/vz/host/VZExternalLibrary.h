#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// External Drive Library
//
// iPadOS mounts every external volume that the Files app can show below one
// fixed directory that the userfsd file-system daemon owns. The host app runs
// without a sandbox (see VirtualMac.entitlements), so it can read and write
// those mount points directly. This module keeps every external-storage
// decision in one place:
//
//   - discovering mounted volumes and proving that a folder is a live mount,
//   - probing a chosen volume for writability and sparse-file support,
//   - moving a complete VM bundle between libraries with verification.
//
// Nothing here ever runs as root and nothing here is reachable from the
// setuid install helper. Installation always targets the internal library.

// Settings key. Value: absolute path of the external library folder
// (a "VirtualMac" folder directly below a mounted volume). Absent = off.
FOUNDATION_EXPORT NSString * const VZExternalLibraryPathKey;

// Name of the folder created directly below the chosen volume.
FOUNDATION_EXPORT NSString * const VZExternalLibraryFolderName;

// Fixed parent of every userfsd mount point on iPadOS 13 and later.
FOUNDATION_EXPORT NSString * const VZExternalVolumesRoot;

typedef NS_ENUM(NSInteger, VZExternalLibraryState) {
    VZExternalLibraryStateOff = 0,
    VZExternalLibraryStateMounted,
    VZExternalLibraryStateNotConnected,
};

// Mounted external volumes as {"name": display name, "path": mount point}.
NSArray<NSDictionary<NSString *, NSString *> *> *VZExternalVolumes(void);

// YES only when `path` is a mount point below VZExternalVolumesRoot that is
// currently backed by its own file system (a left-over empty folder from an
// unplugged drive is NOT live).
BOOL VZExternalVolumeIsLive(NSString *volumePath);

// Configured external library folder, or nil when the feature is off.
NSString * _Nullable VZExternalLibraryPath(void);

// Volume mount point that owns the configured library, or nil when off.
NSString * _Nullable VZExternalLibraryVolumePath(void);

// Display name of the configured volume, or nil when off.
NSString * _Nullable VZExternalLibraryVolumeName(void);

VZExternalLibraryState VZExternalLibraryCurrentState(void);

// YES when a bundle path lives below any external volume mount point.
BOOL VZBundlePathIsExternal(NSString *bundlePath);

// YES when the bundle's volume is live (internal bundles are always live).
BOOL VZBundleVolumeIsAvailable(NSString *bundlePath);

// Library folder that owns `bundlePath` (its parent directory).
NSString *VZLibraryPathForBundle(NSString *bundlePath);

// Probe results for a candidate library folder. Creates the folder if
// needed. `supportsSparseFiles` is informational: a volume that cannot keep
// holes still works but allocates each disk image at its full size.
BOOL VZProbeExternalLibraryFolder(NSString *folder, BOOL *supportsSparseFiles,
                                  NSError **error);

// Bytes of free space on the volume owning `path` (0 when unknown).
uint64_t VZFreeSpaceForPath(NSString *path);

// Logical and allocated sizes of every regular file below `path`.
void VZMeasureBundle(NSString *path, uint64_t *logicalBytes,
                     uint64_t *allocatedBytes);

FOUNDATION_EXPORT NSString * const VZExternalLibraryErrorDomain;
typedef NS_ENUM(NSInteger, VZExternalLibraryError) {
    VZExternalLibraryErrorNotMounted = 1,
    VZExternalLibraryErrorNotWritable,
    VZExternalLibraryErrorNotEnoughSpace,
    VZExternalLibraryErrorDestinationExists,
    VZExternalLibraryErrorInvalidBundle,
    VZExternalLibraryErrorUnsupportedItem,
    VZExternalLibraryErrorVerificationFailed,
    VZExternalLibraryErrorCancelled,
    VZExternalLibraryErrorIO,
};

typedef NS_ENUM(NSInteger, VZBundleMovePhase) {
    VZBundleMovePhaseCopying = 0,
    VZBundleMovePhaseVerifying,
    VZBundleMovePhaseFinishing,
};

// Moves one VM bundle directory into another library folder.
//
// Sequence (each step must succeed before the next starts):
//   1. pre-flight: source valid, destination library live and writable,
//      destination name free, enough free space;
//   2. copy every file into "<name>.bundle.moving" with zero blocks written
//      as holes and a SHA-256 taken of the logical contents;
//   3. re-read every copied file and compare size and SHA-256;
//   4. rename "<name>.bundle.moving" to "<name>.bundle";
//   5. delete the source. A failure here is reported through
//      `sourceRetained` and is not treated as a failed move.
// Cancellation or any failure before step 4 removes the partial copy and
// leaves the source untouched.
@interface VZBundleMover : NSObject
@property(nonatomic, readonly, copy) NSString *sourcePath;
@property(nonatomic, readonly, copy) NSString *destinationPath;
- (instancetype)initWithSourcePath:(NSString *)sourcePath
                destinationLibrary:(NSString *)destinationLibrary;
- (void)startWithProgress:(void (^)(VZBundleMovePhase phase,
                                    NSString *itemName,
                                    double fraction))progress
               completion:(void (^)(BOOL success,
                                    NSError * _Nullable error,
                                    BOOL sourceRetained))completion;
- (void)cancel;
@end

NS_ASSUME_NONNULL_END
