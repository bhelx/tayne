
; bring some needed syscalls
declare i8* @malloc(i32)
declare void @free(i8*)
declare i8* @memcpy(i8*, i8*, i32)
declare i32 @sleep(i32)
declare i32 @usleep(i32)
declare float @clock()
; Function Attrs: nounwind
declare i32 @printf(i8* nocapture, ...) #0
; Function Attrs: nounwind
declare i32 @puts(i8* nocapture) #0

attributes #0 = { nounwind }
