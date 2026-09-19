#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const VZVMConfigurationFileName;
FOUNDATION_EXPORT NSString * const VZApplePencilPressureTiltEnabledKey;
FOUNDATION_EXPORT NSString * const VZVirtualMacGuestToolsEnabledKey;
FOUNDATION_EXPORT NSString * const VZMetalBCSupportEnabledKey;
FOUNDATION_EXPORT NSString * const VZOpenGLAccelerationEnabledKey;
FOUNDATION_EXPORT NSString * const VZGuestToolsRemovalPendingKey;

NSDictionary *VZVMDefaultOptions(void);
NSDictionary *VZVMOptionsForBundle(NSString *bundlePath);
BOOL VZRestoreImageUsesMontereyProfile(NSString *path);
BOOL VZWriteVMOptions(NSDictionary *options, NSString *bundlePath,
                      NSError **error);
BOOL VZIsValidVMBundle(NSString *path);
NSString *_Nullable VZVMStableIdentifier(NSString *path);
NSArray<NSDictionary *> *VZDiscoverVirtualMachines(void);
NSArray<NSString *> *VZInstallationArtifactPaths(void);
NSArray<NSString *> *VZCachedRestoreImagePaths(void);
void VZRemovePaths(NSArray<NSString *> *paths);
// The virtual machines in the internal library, and a removal that takes each
// one's leftover installation files with it.
NSArray<NSString *> *VZInternalVirtualMachinePaths(void);
void VZRemoveVirtualMachines(NSArray<NSString *> *bundlePaths);
// Everything Virtual Mac stores: the machines themselves, restore images,
// installation staging and settings. It is also the default library, as
// opposed to an external drive a machine has been moved to. The path is
// fixed, because the setuid installer and the keyboard tweak both depend on
// it being constant, and it is inside the jailbreak prefix, so removing the
// package or the jailbreak takes it with them.
NSString *VZVMLibraryPath(void);
NSString *VZRestoreImagesPath(void);
NSString *VZInstallationsPath(void);
// Moves a bundle into another library on the same volume by renaming it.
// Returns the new path, or nil with an error when the two are not on one
// volume or the rename fails.
NSString * _Nullable VZMoveBundleWithinVolume(NSString *bundlePath,
                                              NSString *destinationLibrary,
                                              NSError **error);
// Repoints the auto-boot and last-selected settings after a bundle moves.
void VZUpdateSavedBundlePath(NSString *oldPath, NSString *newPath);

@class VZVMLibraryViewController;

@protocol VZVMLibraryViewControllerDelegate <NSObject>
- (void)vmLibrary:(VZVMLibraryViewController *)library
    bootBundleAtPath:(NSString *)path
             options:(NSDictionary *)options;
- (void)vmLibrary:(VZVMLibraryViewController *)library
    installRestoreImageAtURL:(NSURL *)url
                        name:(NSString *)name
                     options:(NSDictionary *)options;
@optional
- (nullable NSString *)activeVMBundlePathForLibrary:
    (VZVMLibraryViewController *)library;
- (void)vmLibraryResumeActiveVM:(VZVMLibraryViewController *)library;
- (void)vmLibraryForceShutdownActiveVM:
    (VZVMLibraryViewController *)library;
@end

@interface VZVMLibraryViewController : UIViewController
    <UIDocumentPickerDelegate>
@property(nonatomic, assign) id<VZVMLibraryViewControllerDelegate> delegate;
- (void)reloadLibrary;
- (void)presentNewVMFlow;
- (void)presentSettings;
@end

NS_ASSUME_NONNULL_END
