// SZError.h —— SevenZipKit 统一错误域（HRESULT → NSError）。
// 公开头：仅 Foundation，不暴露任何 7-Zip C++ 类型（01-architecture.md §2.2 桥接边界单一）。
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const SZErrorDomain;

/// code：业务级失败码；原始 HRESULT 放 userInfo[@"SZUnderlyingHRESULT"]。详见 02-core-bridge.md §4.0。
typedef NS_ERROR_ENUM(SZErrorDomain, SZErrorCode) {
    SZErrorUnknown        = 1,
    SZErrorCannotOpenFile = 2,   // CInFileStream::Open 失败
    SZErrorNotArchive     = 3,   // OpenFolderFile S_FALSE 且无错误信息
    SZErrorWrongPassword  = 4,
    SZErrorCancelled      = 5,   // E_ABORT
    SZErrorHResult        = 100, // 其它原始 HRESULT，userInfo[@"SZUnderlyingHRESULT"]=@(hr)
};

NS_ASSUME_NONNULL_END
