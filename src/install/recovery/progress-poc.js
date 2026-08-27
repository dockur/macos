ObjC.import('Foundation')
ObjC.import('/usr/lib/libIASUnifiedProgress.dylib')

var stateFile = '/Volumes/installstate/started'
var fm = $.NSFileManager.defaultManager
var client = $.IASUnifiedProgressClient.alloc.initWithPhaseName($('macOSInstall'))

client.showProgressUI
client.setStatus($('Preparing macOS installation...'))
client.setProgressAnimate(0, false)

while (fm.fileExistsAtPath($(stateFile))) {
  for (var progress = 0; progress <= 100; progress += 2) {
    if (!fm.fileExistsAtPath($(stateFile))) {
      break
    }
    client.setProgressAnimate(progress, true)
    $.NSThread.sleepForTimeInterval(0.5)
  }
}

client.hideProgressUI
