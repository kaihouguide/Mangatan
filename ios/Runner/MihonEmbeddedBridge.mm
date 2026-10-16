#import "MihonEmbeddedBridge.h"

#include <jni.h>

#include <cstdio>
#include <cstdint>
#include <dlfcn.h>
#include <os/lock.h>
#include <string>
#include <vector>

@interface MangatanEmbeddedMihonThread : NSThread {
  NSCondition *_condition;
  NSMutableArray *_pendingBlocks;
}

- (void)enqueueBlock:(dispatch_block_t)block;

@end

@implementation MangatanEmbeddedMihonThread

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _condition = [[NSCondition alloc] init];
    _pendingBlocks = [[NSMutableArray alloc] init];
    self.name = @"com.selxo.mangatan.embedded-mihon";
    // The Zero interpreter divides the current native stack between its
    // Java operand stack and C/C++ calls. iOS dispatch workers only provide
    // a small implementation-defined stack, which can exhaust during
    // java.lang bootstrap. Give the embedded VM a stable, JVM-sized stack.
    self.stackSize = 8 * 1024 * 1024;
  }
  return self;
}

- (void)enqueueBlock:(dispatch_block_t)block {
  [_condition lock];
  [_pendingBlocks addObject:[block copy]];
  [_condition signal];
  [_condition unlock];
}

- (void)main {
  while (!self.cancelled) {
    dispatch_block_t block = nil;
    [_condition lock];
    while (_pendingBlocks.count == 0 && !self.cancelled) {
      [_condition wait];
    }
    if (_pendingBlocks.count > 0) {
      block = _pendingBlocks.firstObject;
      [_pendingBlocks removeObjectAtIndex:0];
    }
    [_condition unlock];

    if (block != nil) {
      @autoreleasepool {
        block();
      }
    }
  }
}

@end

namespace {

NSString *const kEmbeddedMihonErrorDomain =
    @"com.selxo.mangatan.embedded_mihon";
const char *const kEmbeddedBridgeClassName =
    "mextensionserver/EmbeddedBridge";
const char *const kOpenJDKFrameworkRelativePath =
    "Frameworks/OpenJDKRuntime.framework/OpenJDKRuntime";

using LoadFunctions = void (*)(void);
using CreateJavaVM = jint (*)(JavaVM **, void **, void *);

JavaVM *gJavaVM = nullptr;
jclass gEmbeddedBridgeClass = nullptr;
jmethodID gStartMethod = nullptr;
jmethodID gPauseMethod = nullptr;
jmethodID gStopMethod = nullptr;
jmethodID gIsRunningMethod = nullptr;
void *gOpenJDKHandle = nullptr;
LoadFunctions gLoadFunctions = nullptr;
CreateJavaVM gCreateJavaVM = nullptr;
os_unfair_lock gJavaVMLock = OS_UNFAIR_LOCK_INIT;

class JavaVMLockGuard {
 public:
  JavaVMLockGuard() {
    os_unfair_lock_lock(&gJavaVMLock);
  }

  ~JavaVMLockGuard() {
    os_unfair_lock_unlock(&gJavaVMLock);
  }

  JavaVMLockGuard(const JavaVMLockGuard &) = delete;
  JavaVMLockGuard &operator=(const JavaVMLockGuard &) = delete;
};

void TraceEmbeddedMihon(NSString *message) {
  const char *utf8 = message.UTF8String;
  fprintf(
      stderr,
      "Mangatan EmbeddedMihon: %s\n",
      utf8 == nullptr ? "(null)" : utf8);
  fflush(stderr);
}

MangatanEmbeddedMihonThread *EmbeddedMihonThread() {
  static MangatanEmbeddedMihonThread *thread;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    thread = [[MangatanEmbeddedMihonThread alloc] init];
    [thread start];
  });
  return thread;
}

NSError *EmbeddedMihonError(NSInteger code, NSString *message) {
  // A nil value in the dictionary literal would raise and terminate the app
  // instead of reporting the startup failure to Flutter.
  return [NSError errorWithDomain:kEmbeddedMihonErrorDomain
                             code:code
                         userInfo:@{
                           NSLocalizedDescriptionKey :
                               message ?: @"The embedded Mihon bridge failed."
                         }];
}

NSString *OpenJDKRuntimePath() {
  NSString *relativePath =
      [NSString stringWithUTF8String:kOpenJDKFrameworkRelativePath];
  return [NSBundle.mainBundle.bundlePath
      stringByAppendingPathComponent:relativePath];
}

NSString *OpenJDKRuntimeHome() {
  return [[OpenJDKRuntimePath() stringByDeletingLastPathComponent]
      stringByAppendingPathComponent:@"lib"];
}

bool LoadOpenJDKRuntime(NSError **error) {
  if (gOpenJDKHandle != nullptr &&
      gLoadFunctions != nullptr &&
      gCreateJavaVM != nullptr) {
    return true;
  }

  NSString *runtimePath = OpenJDKRuntimePath();
  dlerror();
  // The static OpenJDK build resolves its bundled JIMAGE and JDK native
  // functions through dlsym(RTLD_DEFAULT, ...). RTLD_GLOBAL is therefore
  // required even though the framework itself is loaded lazily.
  void *handle = dlopen(runtimePath.UTF8String, RTLD_NOW | RTLD_GLOBAL);
  if (handle == nullptr) {
    const char *details = dlerror();
    if (error != nullptr) {
      *error = EmbeddedMihonError(
          12,
          [NSString stringWithFormat:
              @"The on-device Mihon runtime could not be loaded: %s",
              details == nullptr ? "unknown dynamic loader error" : details]);
    }
    return false;
  }

  const char *const requiredGlobalSymbols[] = {
      "JDK_Canonicalize",
      "JIMAGE_Open",
      "JIMAGE_Close",
      "JIMAGE_FindResource",
      "JIMAGE_GetResource",
      "VerifyClassForMajorVersion",
  };
  for (const char *symbol : requiredGlobalSymbols) {
    dlerror();
    if (dlsym(RTLD_DEFAULT, symbol) == nullptr) {
      if (error != nullptr) {
        *error = EmbeddedMihonError(
            14,
            [NSString stringWithFormat:
                @"The on-device Mihon runtime cannot expose %s.", symbol]);
      }
      dlclose(handle);
      return false;
    }
  }

  dlerror();
  auto loadFunctions =
      reinterpret_cast<LoadFunctions>(
          dlsym(handle, "MangatanOpenJDKLoadFunctions"));
  const char *loadFunctionsError = dlerror();
  dlerror();
  auto createJavaVM =
      reinterpret_cast<CreateJavaVM>(dlsym(handle, "JNI_CreateJavaVM"));
  const char *createJavaVMError = dlerror();
  if (loadFunctions == nullptr ||
      createJavaVM == nullptr ||
      loadFunctionsError != nullptr ||
      createJavaVMError != nullptr) {
    if (error != nullptr) {
      *error = EmbeddedMihonError(
          13,
          @"The on-device Mihon runtime is missing its JNI entry points.");
    }
    dlclose(handle);
    return false;
  }

  gOpenJDKHandle = handle;
  gLoadFunctions = loadFunctions;
  gCreateJavaVM = createJavaVM;
  return true;
}

NSString *JavaExceptionMessage(JNIEnv *env, NSString *fallback) {
  jthrowable exception = env->ExceptionOccurred();
  if (exception == nullptr) {
    return fallback;
  }
  env->ExceptionClear();

  NSString *message = fallback;
  jclass throwableClass = env->FindClass("java/lang/Throwable");
  if (throwableClass != nullptr) {
    jmethodID toStringMethod =
        env->GetMethodID(throwableClass, "toString", "()Ljava/lang/String;");
    if (toStringMethod != nullptr) {
      auto text =
          static_cast<jstring>(env->CallObjectMethod(exception, toStringMethod));
      if (!env->ExceptionCheck() && text != nullptr) {
        const char *utf8 = env->GetStringUTFChars(text, nullptr);
        if (utf8 != nullptr) {
          // JNI returns modified UTF-8, which Foundation rejects for
          // characters outside the BMP. Keep the fallback in that case.
          NSString *decoded = [NSString stringWithUTF8String:utf8];
          if (decoded != nil) {
            message = decoded;
          }
          env->ReleaseStringUTFChars(text, utf8);
        }
        env->DeleteLocalRef(text);
      } else {
        env->ExceptionClear();
        if (text != nullptr) {
          env->DeleteLocalRef(text);
        }
      }
    }
    env->DeleteLocalRef(throwableClass);
  } else {
    env->ExceptionClear();
  }
  env->DeleteLocalRef(exception);
  return message;
}

bool VerifyRuntimeFiles(
    NSString *resourcePath,
    NSString *runtimeHome,
    NSError **error) {
  NSArray<NSString *> *requiredFiles = @[
    @"lib/security/cacerts",
    @"MExtensionServer.jar",
    @"java-logging-shim.jar",
  ];
  NSFileManager *fileManager = NSFileManager.defaultManager;
  for (NSString *relativePath in requiredFiles) {
    NSString *path = [resourcePath stringByAppendingPathComponent:relativePath];
    if (![fileManager fileExistsAtPath:path]) {
      if (error != nullptr) {
        *error = EmbeddedMihonError(
            1,
            [NSString stringWithFormat:
                @"The embedded Mihon runtime is incomplete: %@ is missing.",
                relativePath]);
      }
      return false;
    }
  }
  NSString *bootModules =
      [runtimeHome stringByAppendingPathComponent:@"lib/modules"];
  if (![fileManager fileExistsAtPath:bootModules]) {
    if (error != nullptr) {
      *error = EmbeddedMihonError(
          1,
          @"The embedded Mihon runtime is incomplete: the framework-local "
          @"OpenJDK module image is missing.");
    }
    return false;
  }
  NSString *securityConfiguration =
      [runtimeHome stringByAppendingPathComponent:@"conf/security/java.security"];
  if (![fileManager fileExistsAtPath:securityConfiguration]) {
    if (error != nullptr) {
      *error = EmbeddedMihonError(
          1,
          @"The embedded Mihon runtime is incomplete: the framework-local "
          @"OpenJDK security configuration is missing.");
    }
    return false;
  }
  NSString *timezoneDatabase =
      [runtimeHome stringByAppendingPathComponent:@"lib/tzdb.dat"];
  if (![fileManager fileExistsAtPath:timezoneDatabase]) {
    if (error != nullptr) {
      *error = EmbeddedMihonError(
          1,
          @"The embedded Mihon runtime is incomplete: the framework-local "
          @"OpenJDK timezone database is missing.");
    }
    return false;
  }
  return true;
}

NSString *CreateApplicationDirectory(NSError **error) {
  NSFileManager *fileManager = NSFileManager.defaultManager;
  NSURL *supportURL = [fileManager URLForDirectory:NSApplicationSupportDirectory
                                          inDomain:NSUserDomainMask
                                 appropriateForURL:nil
                                            create:YES
                                             error:error];
  if (supportURL == nil) {
    return nil;
  }
  NSURL *appURL = [supportURL URLByAppendingPathComponent:@"MihonExtensions"
                                             isDirectory:YES];
  if (![fileManager createDirectoryAtURL:appURL
             withIntermediateDirectories:YES
                              attributes:nil
                                   error:error]) {
    return nil;
  }
  return appURL.path;
}

bool CacheBridgeEntryPoints(JNIEnv *env, NSError **error) {
  TraceEmbeddedMihon(@"looking up mextensionserver/EmbeddedBridge");
  jclass localClass = env->FindClass(kEmbeddedBridgeClassName);
  if (localClass == nullptr) {
    TraceEmbeddedMihon(
        [NSString stringWithFormat:
            @"EmbeddedBridge lookup failed (exception=%@)",
            env->ExceptionCheck() ? @"yes" : @"no"]);
    if (error != nullptr) {
      *error = EmbeddedMihonError(
          3,
          JavaExceptionMessage(
              env, @"The embedded Mihon bridge class could not be loaded."));
    }
    return false;
  }
  TraceEmbeddedMihon(@"EmbeddedBridge class lookup succeeded");

  gEmbeddedBridgeClass =
      static_cast<jclass>(env->NewGlobalRef(localClass));
  env->DeleteLocalRef(localClass);
  if (gEmbeddedBridgeClass == nullptr) {
    if (error != nullptr) {
      *error = EmbeddedMihonError(
          4, @"The embedded Mihon bridge class could not be retained.");
    }
    return false;
  }
  TraceEmbeddedMihon(@"EmbeddedBridge global reference retained");

  gStartMethod = env->GetStaticMethodID(
      gEmbeddedBridgeClass, "start", "(ILjava/lang/String;)I");
  gPauseMethod =
      env->GetStaticMethodID(gEmbeddedBridgeClass, "pause", "()V");
  gStopMethod =
      env->GetStaticMethodID(gEmbeddedBridgeClass, "stop", "()V");
  gIsRunningMethod =
      env->GetStaticMethodID(gEmbeddedBridgeClass, "isRunning", "()Z");
  if (gStartMethod == nullptr ||
      gPauseMethod == nullptr ||
      gStopMethod == nullptr ||
      gIsRunningMethod == nullptr ||
      env->ExceptionCheck()) {
    if (error != nullptr) {
      *error = EmbeddedMihonError(
          5,
          JavaExceptionMessage(
              env, @"The embedded Mihon bridge entry points are invalid."));
    }
    return false;
  }
  TraceEmbeddedMihon(@"EmbeddedBridge JNI entry points cached");
  return true;
}

bool CreateJavaVMIfNeeded(JNIEnv **environment, NSError **error) {
  JavaVMLockGuard guard;
  if (gJavaVM != nullptr) {
    if (gEmbeddedBridgeClass == nullptr ||
        gStartMethod == nullptr ||
        gPauseMethod == nullptr ||
        gStopMethod == nullptr ||
        gIsRunningMethod == nullptr) {
      if (error != nullptr) {
        *error = EmbeddedMihonError(
            2, @"The embedded Java runtime did not initialize completely.");
      }
      return false;
    }
    jint result = gJavaVM->AttachCurrentThread(
        reinterpret_cast<void **>(environment), nullptr);
    if (result != JNI_OK) {
      if (error != nullptr) {
        *error = EmbeddedMihonError(
            6, @"The embedded Java runtime could not attach its worker.");
      }
      return false;
    }
    return true;
  }

  NSString *resourcePath = NSBundle.mainBundle.resourcePath;
  NSString *runtimeHome = OpenJDKRuntimeHome();
  if (!VerifyRuntimeFiles(resourcePath, runtimeHome, error)) {
    return false;
  }
  if (!LoadOpenJDKRuntime(error)) {
    return false;
  }

  NSString *applicationDirectory = CreateApplicationDirectory(error);
  if (applicationDirectory == nil) {
    return false;
  }
  NSString *temporaryDirectory =
      [NSTemporaryDirectory() stringByAppendingPathComponent:@"MihonExtensions"];
  if (![NSFileManager.defaultManager
          createDirectoryAtPath:temporaryDirectory
    withIntermediateDirectories:YES
                     attributes:nil
                          error:error]) {
    return false;
  }

  NSString *serverJar =
      [resourcePath stringByAppendingPathComponent:@"MExtensionServer.jar"];
  NSString *loggingShim =
      [resourcePath stringByAppendingPathComponent:@"java-logging-shim.jar"];
  NSString *trustStore =
      [resourcePath stringByAppendingPathComponent:@"lib/security/cacerts"];

  std::vector<std::string> optionStrings = {
      std::string("-Djava.class.path=") + serverJar.UTF8String,
      std::string("-Xbootclasspath/a:") + loggingShim.UTF8String,
      std::string("-Djava.home=") + runtimeHome.UTF8String,
      std::string("-Djava.io.tmpdir=") + temporaryDirectory.UTF8String,
      std::string("-Duser.home=") + applicationDirectory.UTF8String,
      std::string("-Djavax.net.ssl.trustStore=") + trustStore.UTF8String,
      "-Djavax.net.ssl.trustStorePassword=changeit",
      "-Djava.awt.headless=true",
      "-Dfile.encoding=UTF-8",
      "-Djava.net.preferIPv4Stack=true",
      "-Dorg.slf4j.simpleLogger.defaultLogLevel=warn",
      // OpenJDK Zero uses Serial GC on iOS. Runtime v7 links java.lang.Class
      // before the first Java bytecode, so ordinary balanced generation
      // ceilings are sufficient without reserving an oversized heap.
      "-XX:+UseSerialGC",
        "-Xms128m",
        "-Xmx512m",
        "-XX:NewSize=64m",
        "-XX:MaxNewSize=256m",
      // The dedicated JNI bootstrap thread above has an 8 MiB stack, but
      // NanoHTTPD and the Android compatibility layer create ordinary Java
      // threads. BSD Zero otherwise gives those threads only 1536 KiB and its
      // stack-overflow signal path is not implemented, turning a deep request
      // into a process-fatal ShouldNotCall instead of StackOverflowError.
      "-Xss8m",
  };
  std::vector<JavaVMOption> options(optionStrings.size());
  for (size_t index = 0; index < optionStrings.size(); index++) {
    options[index].optionString =
        const_cast<char *>(optionStrings[index].c_str());
    options[index].extraInfo = nullptr;
  }

  JavaVMInitArgs arguments = {};
  arguments.version = JNI_VERSION_1_8;
  arguments.nOptions = static_cast<jint>(options.size());
  arguments.options = options.data();
  arguments.ignoreUnrecognized = JNI_FALSE;

  TraceEmbeddedMihon(@"calling JNI_CreateJavaVM");
  gLoadFunctions();
  // HotSpot must own SIGSEGV/SIGBUS while the VM is running. OpenJDK Zero
  // uses those signals internally on iOS, so an app-level handler here would
  // turn a recoverable VM signal into an app termination.
  jint result = gCreateJavaVM(
      &gJavaVM, reinterpret_cast<void **>(environment), &arguments);
  TraceEmbeddedMihon(
      [NSString stringWithFormat:
          @"JNI_CreateJavaVM returned %d (vm=%@, env=%@)",
          result,
          gJavaVM == nullptr ? @"null" : @"set",
          *environment == nullptr ? @"null" : @"set"]);
  if (result != JNI_OK || gJavaVM == nullptr || *environment == nullptr) {
    gJavaVM = nullptr;
    if (error != nullptr) {
      *error = EmbeddedMihonError(
          7,
          [NSString stringWithFormat:
              @"The embedded Java runtime could not start (JNI %d).",
              result]);
    }
    return false;
  }
  TraceEmbeddedMihon(@"JNI_CreateJavaVM succeeded");
  if (!CacheBridgeEntryPoints(*environment, error)) {
    TraceEmbeddedMihon(@"EmbeddedBridge JNI cache failed");
    return false;
  }
  TraceEmbeddedMihon(@"embedded Java runtime initialization completed");
  return true;
}

void DetachCurrentWorker() {
  if (gJavaVM != nullptr) {
    gJavaVM->DetachCurrentThread();
  }
}

}  // namespace

void MangatanEmbeddedMihonStart(
    int32_t port,
    MangatanEmbeddedMihonStartCompletion completion) {
  // Loading the framework and starting the VM are intentionally kept off the
  // app launch path and the UI thread. The framework remains loaded for the
  // lifetime of the process after the first Mihon request.
  [EmbeddedMihonThread() enqueueBlock:^{
    @autoreleasepool {
      NSError *error = nil;
      JNIEnv *environment = nullptr;
      int32_t startedPort = 0;
      TraceEmbeddedMihon(
          [NSString stringWithFormat:@"start requested on port %d", port]);
      if (CreateJavaVMIfNeeded(&environment, &error)) {
        NSString *applicationDirectory = CreateApplicationDirectory(&error);
        if (applicationDirectory != nil) {
          jstring appDirectory =
              environment->NewStringUTF(applicationDirectory.UTF8String);
          // JNI forbids calling into Java with the OutOfMemoryError that a
          // failed NewStringUTF leaves pending.
          jint result = 0;
          if (appDirectory != nullptr) {
            TraceEmbeddedMihon(@"calling EmbeddedBridge.start");
            result = environment->CallStaticIntMethod(
                gEmbeddedBridgeClass, gStartMethod, port, appDirectory);
          }
          TraceEmbeddedMihon(
              [NSString stringWithFormat:
                  @"EmbeddedBridge.start returned %d (exception=%@)",
                  result,
                  environment->ExceptionCheck() ? @"yes" : @"no"]);
          if (environment->ExceptionCheck()) {
            error = EmbeddedMihonError(
                8,
                JavaExceptionMessage(
                    environment, @"The embedded Mihon bridge failed to start."));
          } else if (result <= 0 || result > UINT16_MAX) {
            error = EmbeddedMihonError(
                9, @"The embedded Mihon bridge returned an invalid port.");
          } else {
            startedPort = result;
          }
          if (appDirectory != nullptr) {
            environment->DeleteLocalRef(appDirectory);
          }
        }
        DetachCurrentWorker();
      }
      if (error != nil) {
        TraceEmbeddedMihon(
            [NSString stringWithFormat:@"start failed: %@",
                                       error.localizedDescription]);
      } else {
        TraceEmbeddedMihon(
            [NSString stringWithFormat:@"start completed on port %d",
                                       startedPort]);
      }
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(startedPort, error);
      });
    }
  }];
}

void MangatanEmbeddedMihonStop(
    MangatanEmbeddedMihonCompletion completion) {
  [EmbeddedMihonThread() enqueueBlock:^{
    @autoreleasepool {
      NSError *error = nil;
      JNIEnv *environment = nullptr;
      if (gJavaVM != nullptr &&
          CreateJavaVMIfNeeded(&environment, &error)) {
        environment->CallStaticVoidMethod(
            gEmbeddedBridgeClass, gStopMethod);
        if (environment->ExceptionCheck()) {
          error = EmbeddedMihonError(
              10,
              JavaExceptionMessage(
                  environment, @"The embedded Mihon bridge failed to stop."));
        }
        DetachCurrentWorker();
      }
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(error);
      });
    }
  }];
}

void MangatanEmbeddedMihonPause(
    MangatanEmbeddedMihonCompletion completion) {
  [EmbeddedMihonThread() enqueueBlock:^{
    @autoreleasepool {
      NSError *error = nil;
      JNIEnv *environment = nullptr;
      if (gJavaVM != nullptr &&
          CreateJavaVMIfNeeded(&environment, &error)) {
        environment->CallStaticVoidMethod(
            gEmbeddedBridgeClass, gPauseMethod);
        if (environment->ExceptionCheck()) {
          error = EmbeddedMihonError(
              12,
              JavaExceptionMessage(
                  environment, @"The embedded Mihon bridge failed to pause."));
        }
        DetachCurrentWorker();
      }
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(error);
      });
    }
  }];
}

void MangatanEmbeddedMihonIsRunning(
    MangatanEmbeddedMihonStatusCompletion completion) {
  [EmbeddedMihonThread() enqueueBlock:^{
    @autoreleasepool {
      NSError *error = nil;
      JNIEnv *environment = nullptr;
      BOOL isRunning = NO;
      if (gJavaVM != nullptr &&
          CreateJavaVMIfNeeded(&environment, &error)) {
        jboolean result = environment->CallStaticBooleanMethod(
            gEmbeddedBridgeClass, gIsRunningMethod);
        if (environment->ExceptionCheck()) {
          error = EmbeddedMihonError(
              11,
              JavaExceptionMessage(
                  environment,
                  @"The embedded Mihon bridge status could not be read."));
        } else {
          isRunning = result == JNI_TRUE;
        }
        DetachCurrentWorker();
      }
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(isRunning, error);
      });
    }
  }];
}
