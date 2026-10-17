#!/usr/bin/env bash
# AudioKit - LEAN FFmpeg (Android arm64) -> JNI shared library: libffmpeg.so
#   Purpose: ONLY audio/video decode + encode, quality first, smallest size.
#   * --disable-everything, then only the components listed below are enabled
#   * NO subtitles/text (libass, freetype, harfbuzz, fribidi removed), NO network, NO webp, NO ffprobe/ffplay
#   * Hardware codecs through MediaCodec (JNI_OnLoad sets the JavaVM)
#   * Software codecs for best quality: x264, x265, libopus, libmp3lame, soxr (resampler), dav1d (AV1 decode)
#   * Audio processing filters kept: volume, loudnorm, alimiter, acompressor, afade, pan, amix ...
#   * Every optional library is skipped (not fatal) if it fails to build.
#   * 16 KB page-size aligned (required for Android 15+/Play Store)
# Output: build_mt/out/libffmpeg.so
set -euo pipefail

ENABLE_GPL=1        # 1 = x264 + x265 + GPL filters (app becomes GPL). 0 = LGPL only (no x264/x265)
# ---- what to include (1 = yes, 0 = no). Turn things OFF to make the .so smaller.
WITH_X264=1         # H.264 software encoder (needs ENABLE_GPL=1)
WITH_X265=1         # HEVC software encoder  (needs ENABLE_GPL=1)
WITH_VPX=1          # VP8/VP9 encode+decode via libvpx (webm). Set 0 to drop it (native vp8/vp9 decode stays)
WITH_LAME=1         # MP3 encoder
WITH_OPUS=1         # Opus encoder/decoder
WITH_VORBIS=0       # libvorbis encoder (native vorbis decoder is always included)
WITH_DAV1D=1        # AV1 software decoder
WITH_SOXR=1         # high quality audio resampler
API=28
FFMPEG_VER=9.0
TARGET=aarch64-linux-android
# JNI class in slash format: package/class. Must match FFmpegNative.java in AudioKitProject.
# This output is wired for app/src/main/java/com/audiokit/app/FFmpegNative.java.
# For another app, include the same class/package or build with a matching JNI_CLASS.
JNI_CLASS="${JNI_CLASS:-com/audiokit/app/FFmpegNative}"

export API TARGET FFMPEG_VER ENABLE_GPL
set -a
NDK="${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to your NDK path}"
WORK="$PWD/build_mt"; PREFIX="$WORK/prefix"; SRC="$WORK/src"
TC="$NDK/toolchains/llvm/prebuilt/linux-x86_64"; SYSROOT="$TC/sysroot"
JOBS="$(nproc)"
PATH="$TC/bin:$PATH"
CC="$TC/bin/${TARGET}${API}-clang"; CXX="$TC/bin/${TARGET}${API}-clang++"
AR="$TC/bin/llvm-ar"; RANLIB="$TC/bin/llvm-ranlib"; STRIP="$TC/bin/llvm-strip"; NM="$TC/bin/llvm-nm"
CFLAGS="-O3 -fPIC -I$PREFIX/include"; CXXFLAGS="-O3 -fPIC -I$PREFIX/include"; LDFLAGS="-L$PREFIX/lib"
PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"; PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
CXXLIBS="-lc++_static -lc++abi"
set +a
mkdir -p "$WORK/out" "$SRC" "$PREFIX/lib/pkgconfig" "$PREFIX/include"

echo "==> [0] host tools"
SUDO=""; [ "$(id -u)" != "0" ] && SUDO="sudo"
$SUDO apt-get update -y >/dev/null
for p in cmake ninja-build pkg-config python3 git curl xz-utils make meson perl; do
  $SUDO apt-get install -y "$p" >/dev/null || echo "WARNING: could not install $p"
done

# ---------- helpers ----------
fetch() {  # fetch <url> <dir>
  [ -d "$SRC/$2" ] && return 0
  mkdir -p "$SRC/$2"
  curl -fL --retry 3 "$1" -o "$SRC/$2.tar"
  tar -xf "$SRC/$2.tar" -C "$SRC/$2" --strip-components=1
}
cmk() {    # cmk <srcdir> [extra cmake args]
  local s="$1"; shift
  cmake -S "$s" -B "$s/_b" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-$API -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_PREFIX_PATH="$PREFIX" -DCMAKE_FIND_ROOT_PATH="$PREFIX" \
    -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_POLICY_VERSION_MINIMUM=3.5 "$@" \
  && cmake --build "$s/_b" -j"$JOBS" \
  && cmake --install "$s/_b"
}
acfg() {   # autotools cross configure + build + install
  ./configure --host="$TARGET" --prefix="$PREFIX" --disable-shared --enable-static --with-pic "$@" \
  && make -j"$JOBS" && make install
}

# ---------- libraries ----------
lib_ogg()    { fetch https://downloads.xiph.org/releases/ogg/libogg-1.3.5.tar.xz ogg; cd "$SRC/ogg"; acfg; }
lib_vorbis() { fetch https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.xz vorbis; cd "$SRC/vorbis"; acfg --with-ogg="$PREFIX" --disable-oggtest; }
lib_opus()   { fetch https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz opus; cd "$SRC/opus"; acfg --disable-doc --disable-extra-programs; }
lib_lame()   { fetch https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz lame; cd "$SRC/lame"; acfg --disable-frontend; }
lib_x264()   {
  if [ ! -d "$SRC/x264" ]; then git clone --depth 1 https://code.videolan.org/videolan/x264.git "$SRC/x264"; fi
  cd "$SRC/x264"
  AS="$CC" ./configure --host="$TARGET" --cross-prefix="$TC/bin/llvm-" --prefix="$PREFIX" \
    --enable-static --enable-pic --disable-cli --disable-opencl
  make -j"$JOBS"; make install
}
lib_x265()   {
  if [ ! -d "$SRC/x265" ]; then git clone --depth 1 --branch 4.1 https://bitbucket.org/multicoreware/x265_git.git "$SRC/x265"; fi
  local common=(-DENABLE_SHARED=OFF -DENABLE_CLI=OFF -DENABLE_PIC=ON -DENABLE_LIBNUMA=OFF)
  rm -rf "$SRC/x265/source/_b"
  if ! cmk "$SRC/x265/source" "${common[@]}" -DCROSS_COMPILE_ARM64=ON -DENABLE_ASSEMBLY=ON; then
    echo "x265 with NEON asm failed, retrying without asm (slower)"
    rm -rf "$SRC/x265/source/_b"
    cmk "$SRC/x265/source" "${common[@]}" -DENABLE_ASSEMBLY=OFF
  fi
}
lib_vpx()    {
  if [ ! -d "$SRC/vpx" ]; then git clone --depth 1 --branch v1.15.0 https://chromium.googlesource.com/webm/libvpx "$SRC/vpx"; fi
  cd "$SRC/vpx"
  CROSS= CC="$CC" CXX="$CXX" AR="$AR" LD="$CC" AS="$CC" STRIP="$STRIP" NM="$NM" \
  ./configure --target=arm64-linux-gcc --prefix="$PREFIX" --disable-examples --disable-tools --disable-docs \
    --disable-unit-tests --disable-install-docs --enable-pic --enable-vp9-highbitdepth --enable-runtime-cpu-detect
  make -j"$JOBS"; make install
}
lib_freetype() {
  fetch https://download.savannah.gnu.org/releases/freetype/freetype-2.13.3.tar.xz freetype
  cmk "$SRC/freetype" -DFT_DISABLE_ZLIB=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_PNG=ON -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON
}
lib_fribidi() { fetch https://github.com/fribidi/fribidi/releases/download/v1.0.16/fribidi-1.0.16.tar.xz fribidi; cd "$SRC/fribidi"; acfg --disable-docs; }
lib_harfbuzz() {
  fetch https://github.com/harfbuzz/harfbuzz/releases/download/10.1.0/harfbuzz-10.1.0.tar.xz harfbuzz
  cmk "$SRC/harfbuzz" -DHB_HAVE_FREETYPE=ON -DHB_BUILD_UTILS=OFF \
    -DFREETYPE_LIBRARY="$PREFIX/lib/libfreetype.a" \
    -DFREETYPE_INCLUDE_DIR_freetype2="$PREFIX/include/freetype2" -DFREETYPE_INCLUDE_DIR_ft2build="$PREFIX/include/freetype2"
}
lib_libass() {
  fetch https://github.com/libass/libass/releases/download/0.17.3/libass-0.17.3.tar.xz libass
  cd "$SRC/libass"
  LIBS="$CXXLIBS" acfg --disable-fontconfig --disable-require-system-font-provider --disable-asm
}
lib_webp() {
  fetch https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.4.0.tar.gz webp
  cmk "$SRC/webp" -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF -DWEBP_BUILD_GIF2WEBP=OFF \
    -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF
}
lib_dav1d() {
  fetch https://downloads.videolan.org/pub/videolan/dav1d/1.5.0/dav1d-1.5.0.tar.xz dav1d
  cat > "$SRC/cross.txt" <<EOX
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
strip = '$STRIP'
[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8-a'
endian = 'little'
EOX
  cd "$SRC/dav1d"
  meson setup _b --cross-file "$SRC/cross.txt" --prefix="$PREFIX" --libdir=lib --default-library=static \
    --buildtype=release -Denable_tools=false -Denable_tests=false
  ninja -C _b install
}
lib_soxr() {
  fetch https://downloads.sourceforge.net/project/soxr/soxr-0.1.3-Source.tar.xz soxr
  cmk "$SRC/soxr" -DBUILD_TESTS=OFF -DBUILD_EXAMPLES=OFF -DWITH_OPENMP=OFF -DWITH_LSR_BINDINGS=OFF
}
export -f fetch cmk acfg lib_ogg lib_vorbis lib_opus lib_lame lib_x264 lib_x265 lib_vpx lib_freetype lib_fribidi lib_harfbuzz lib_libass lib_webp lib_dav1d lib_soxr

FF_ENABLES=()
EXTRA_LIBS="-lm $CXXLIBS"
build() {  # build <name> <function>  (own bash so one failure does not stop the rest)
  echo "==> [lib] $1"
  if bash -euo pipefail -c "$2" > "$WORK/log_$1.txt" 2>&1; then
    echo "    OK      $1"; return 0
  else
    echo "    FAILED  $1 (skipped). Last log lines:"; tail -n 25 "$WORK/log_$1.txt" | sed 's/^/      /'; return 1
  fi
}

if [ "$WITH_VORBIS" = "1" ]; then
  build ogg lib_ogg || true
  if build ogg_check "test -f $PREFIX/lib/libogg.a"; then
    build vorbis lib_vorbis && FF_ENABLES+=(--enable-libvorbis)
  fi
fi
[ "$WITH_OPUS" = "1" ] && { build opus lib_opus && FF_ENABLES+=(--enable-libopus); } || true
[ "$WITH_LAME" = "1" ] && { build lame lib_lame && FF_ENABLES+=(--enable-libmp3lame); } || true
if [ "$ENABLE_GPL" = "1" ]; then
  [ "$WITH_X264" = "1" ] && { build x264 lib_x264 && FF_ENABLES+=(--enable-libx264); } || true
  [ "$WITH_X265" = "1" ] && { build x265 lib_x265 && FF_ENABLES+=(--enable-libx265); } || true
fi
[ "$WITH_VPX" = "1" ]   && { build vpx lib_vpx && FF_ENABLES+=(--enable-libvpx); } || true
[ "$WITH_DAV1D" = "1" ] && { build dav1d lib_dav1d && FF_ENABLES+=(--enable-libdav1d); } || true
[ "$WITH_SOXR" = "1" ]  && { build soxr lib_soxr && FF_ENABLES+=(--enable-libsoxr); } || true

# Android has no libstdc++/libpthread/librt .so; the C++ runtime is linked statically via $EXTRA_LIBS
for pc in "$PREFIX"/lib/pkgconfig/*.pc; do
  [ -f "$pc" ] && sed -i -E 's/-l(stdc\+\+|c\+\+|pthread|rt|gcc_s|gcc)( |$)/\2/g' "$pc"
done

echo "==> FFmpeg $FFMPEG_VER source"
cd "$WORK"
if [ ! -d ffmpeg ]; then
  if curl -fL "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VER.tar.xz" -o ffmpeg.tar.xz; then
    mkdir ffmpeg && tar -xf ffmpeg.tar.xz -C ffmpeg --strip-components=1
  else
    git clone --depth 1 -b "release/$FFMPEG_VER" https://git.ffmpeg.org/ffmpeg.git ffmpeg
  fi
fi
cd ffmpeg

echo "==> Patch fftools so the ffmpeg CLI can run inside a shared library (main -> ffmpeg_main, exit -> ffw_exit)"
CANCEL_DEF=""
if [ ! -f .mt_patched ]; then
  if ! grep -q '^int main(int argc, char \*\*argv)' fftools/ffmpeg.c; then
    echo "ERROR: 'int main(int argc, char **argv)' not found in fftools/ffmpeg.c (fftools layout changed)"; exit 1
  fi
  sed -i 's/^int main(int argc, char \*\*argv)/int ffmpeg_main(int argc, char **argv)/' fftools/ffmpeg.c
  # FFmpeg builds with -Werror=missing-prototypes, so ffmpeg_main needs a prototype before its definition
  sed -i '1i int ffmpeg_main(int argc, char **argv);' fftools/ffmpeg.c
  for f in fftools/*.c fftools/*/*.c; do
    [ -f "$f" ] || continue
    case "$f" in *ffprobe*|*ffplay*) continue;; esac
    sed -i -E 's/\bexit\(/ffw_exit(/g' "$f"
    sed -i '1i void ffw_exit(int code) __attribute__((noreturn));' "$f"
  done
  # make the signal flags visible so the wrapper can cancel a running job gracefully
  sed -i -E 's/^static volatile (sig_atomic_t|int) received_sigterm/volatile \1 received_sigterm/' fftools/ffmpeg.c
  sed -i -E 's/^static volatile (sig_atomic_t|int) received_nb_signals/volatile \1 received_nb_signals/' fftools/ffmpeg.c
  touch .mt_patched
fi
if grep -qE '^volatile (sig_atomic_t|int) received_sigterm' fftools/ffmpeg.c && \
   grep -qE '^volatile (sig_atomic_t|int) received_nb_signals' fftools/ffmpeg.c; then
  CANCEL_DEF="-DHAVE_CANCEL"; echo "    cancel support: yes"
else
  echo "    cancel support: no (signal flags not found, cancel() will return -1)"
fi

GPL_FLAG="--disable-gpl"; [ "$ENABLE_GPL" = "1" ] && GPL_FLAG="--enable-gpl"
has() {  # has <libname> : was this optional lib built and still enabled?
  local x; for x in ${FF_ENABLES[@]+"${FF_ENABLES[@]}"}; do [ "$x" = "--enable-$1" ] && return 0; done; return 1
}
run_configure() {
  # ---- component whitelists (edit freely). Names that do not exist are simply ignored by configure.
  local ENC="aac,flac,alac,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,h264_mediacodec,hevc_mediacodec,mjpeg,png,rawvideo,wrapped_avframe"
  local DEC="h264,hevc,vp8,vp9,mpeg4,mpeg2video,mpeg1video,h263,mjpeg,png,prores,rawvideo,wrapped_avframe"
  DEC+=",aac,aac_latm,mp3,mp3float,mp2,ac3,eac3,flac,alac,opus,vorbis,amrnb,amrwb,wmav1,wmav2,adpcm_ima_wav,adpcm_ms"
  DEC+=",pcm_s16le,pcm_s16be,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f64le,pcm_u8,pcm_alaw,pcm_mulaw"
  DEC+=",h264_mediacodec,hevc_mediacodec,vp8_mediacodec,vp9_mediacodec,av1_mediacodec,mpeg2_mediacodec,mpeg4_mediacodec"
  has libx264   && ENC+=",libx264"
  has libx265   && ENC+=",libx265"
  has libvpx    && { ENC+=",libvpx_vp8,libvpx_vp9"; DEC+=",libvpx_vp8,libvpx_vp9"; }
  has libmp3lame && ENC+=",libmp3lame"
  has libopus   && { ENC+=",libopus"; DEC+=",libopus"; }
  has libvorbis && ENC+=",libvorbis"
  has libdav1d  && DEC+=",libdav1d"
  local MUX="mp4,mov,ipod,matroska,webm,mp3,adts,flac,ogg,opus,wav,mpegts,image2,null"
  local DEMUX="mov,matroska,mp3,aac,flac,ogg,wav,mpegts,avi,flv,ac3,eac3,amr,concat,image2,pcm_s16le,pcm_s24le,pcm_f32le"
  # audio/video processing filters an editor needs (auto-inserted helpers like scale/aresample/format are included)
  local FLT="null,anull,format,aformat,scale,aresample,fps,xfade,tonemap,setpts,asetpts,trim,atrim,crop,pad,transpose,hflip,vflip,rotate,setsar,setdar,overlay,fade,eq,split,asplit,fifo,afifo,concat,select,aselect"
  FLT+=",volume,loudnorm,alimiter,acompressor,dynaudnorm,equalizer,highpass,lowpass,afade,acrossfade,pan,channelmap,channelsplit,join,amerge,amix,adelay,apad,atempo,aresample,anullsrc,aevalsrc,sine,volumedetect,ebur128,astats"
  ./configure \
    --prefix="$PREFIX" \
    --target-os=android --arch=aarch64 --cpu=armv8-a --enable-cross-compile \
    --cc="$CC" --cxx="$CXX" --ar="$AR" --nm="$NM" --ranlib="$RANLIB" --strip="$STRIP" \
    --sysroot="$SYSROOT" \
    --pkg-config=pkg-config --pkg-config-flags="--static" \
    $GPL_FLAG --disable-nonfree \
    --enable-static --disable-shared --enable-pic \
    --disable-autodetect --disable-doc --disable-debug --disable-symver \
    --disable-everything \
    --disable-ffplay --disable-ffprobe --enable-ffmpeg --disable-avdevice \
    --disable-vulkan --disable-opencl --disable-network --disable-iconv \
    --enable-zlib \
    --enable-gray --enable-swscale-alpha --enable-runtime-cpudetect \
    --enable-jni --enable-mediacodec \
    --enable-avcodec --enable-avformat --enable-avutil --enable-avfilter --enable-swscale --enable-swresample \
    --enable-protocol=file,pipe,fd \
    --enable-parser='*' --enable-bsf='*' \
    --enable-demuxer="$DEMUX" --enable-muxer="$MUX" \
    --enable-decoder="$DEC" --enable-encoder="$ENC" \
    --enable-filter="$FLT" \
    ${FF_ENABLES[@]+"${FF_ENABLES[@]}"} \
    --extra-cflags="-O3 -fpic -ffunction-sections -fdata-sections -I$PREFIX/include" \
    --extra-ldflags="-L$PREFIX/lib" \
    --extra-libs="$EXTRA_LIBS"
}
# If an optional library cannot be linked, drop it and retry instead of failing the whole build.
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  echo "==> FFmpeg configure (attempt $attempt). Extra libs: ${FF_ENABLES[*]:-none}"
  if run_configure > "$WORK/log_configure.txt" 2>&1; then echo "    configure OK"; break; fi
  bad="$(grep -oE 'ERROR: [A-Za-z0-9_+.-]+' "$WORK/log_configure.txt" | head -n1 | awk '{print $2}')"
  echo "    configure failed on: ${bad:-unknown}"
  NEW=(); removed=0
  for x in ${FF_ENABLES[@]+"${FF_ENABLES[@]}"}; do
    if [ -n "$bad" ] && { [[ "$x" == *"$bad"* ]] || [[ "$x" == *"${bad%2}"* ]]; }; then removed=1; echo "    dropping $x"; else NEW+=("$x"); fi
  done
  if [ "$removed" = "0" ]; then
    echo "ERROR: configure failed for a reason that is not an optional library:"
    tail -n 40 "$WORK/log_configure.txt"; echo "---- config.log tail ----"; tail -n 60 ffbuild/config.log || true
    exit 1
  fi
  FF_ENABLES=(${NEW[@]+"${NEW[@]}"})
done
[ -f config.h ] || { echo "ERROR: configure never succeeded"; tail -n 40 "$WORK/log_configure.txt"; exit 1; }

echo "---- configured features ----"
for k in JNI MEDIACODEC LIBX264 LIBX265 LIBVPX LIBMP3LAME LIBOPUS LIBVORBIS LIBDAV1D LIBSOXR; do
  if grep -qE "^#define CONFIG_${k} 1" config.h; then echo "ON   $k"; else echo "OFF  $k"; fi
done
for k in JNI MEDIACODEC; do
  grep -qE "^#define CONFIG_${k} 1" config.h || { echo "ERROR: $k is OFF, hardware codecs would not work"; exit 1; }
done

# The ffmpeg executable itself will fail to link (no main() any more) - that is expected, we only need the objects.
make -j"$JOBS" -k > "$WORK/log_ffmpeg_make.txt" 2>&1 || true
for a in libavcodec/libavcodec.a libavformat/libavformat.a libavfilter/libavfilter.a libavutil/libavutil.a \
         libswscale/libswscale.a libswresample/libswresample.a fftools/ffmpeg.o; do
  [ -f "$a" ] || {
    echo "ERROR: $a was not built."
    echo "==================== REAL COMPILE ERRORS (first 60) ===================="
    grep -n -B2 -A6 -E 'error:|undefined reference|\*\*\* \[|fatal error|No such file' "$WORK/log_ffmpeg_make.txt" | head -n 120 || true
    echo "==================== END OF ERRORS ===================="
    exit 1
  }
done
make install-libs install-headers > "$WORK/log_ffmpeg_install.txt" 2>&1

echo "==> JNI wrapper (class $JNI_CLASS)"
mkdir -p "$WORK/jni"
cat > "$WORK/jni/ffmpeg_jni.c" <<'EOC'
#include <jni.h>
#include <setjmp.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <android/log.h>
#include "libavcodec/jni.h"
#include "libavformat/avformat.h"
#include "libavutil/avutil.h"
#include "libavutil/bprint.h"
#include "libavutil/log.h"
#include "libavutil/pixdesc.h"
#include "libavutil/samplefmt.h"

#define JNI_CLASS_NAME "@JNI_CLASS@"
#define LOG_CAP (256 * 1024)

int ffmpeg_main(int argc, char **argv);
/* declared in different headers across FFmpeg versions, so declare it ourselves (same signature) */
const char *avcodec_configuration(void);
#ifdef HAVE_CANCEL
extern volatile int received_sigterm;
extern volatile int received_nb_signals;
#endif

static pthread_mutex_t g_run_mx = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_log_mx = PTHREAD_MUTEX_INITIALIZER;
static char g_log[LOG_CAP];
static size_t g_log_len = 0;
static int g_print_prefix = 1;

static __thread jmp_buf *t_jmp = NULL;
static __thread int t_code = 0;

/* called by patched fftools instead of exit() */
void ffw_exit(int code) {
    if (t_jmp) { t_code = code; longjmp(*t_jmp, 1); }
    pthread_exit(NULL);
}

static void log_cb(void *ptr, int level, const char *fmt, va_list vl) {
    if (level > av_log_get_level()) return;
    char line[2048];
    pthread_mutex_lock(&g_log_mx);
    av_log_format_line(ptr, level, fmt, vl, line, sizeof(line), &g_print_prefix);
    int prio = level <= AV_LOG_ERROR ? ANDROID_LOG_ERROR : level <= AV_LOG_WARNING ? ANDROID_LOG_WARN
             : level <= AV_LOG_INFO ? ANDROID_LOG_INFO : ANDROID_LOG_DEBUG;
    __android_log_write(prio, "ffmpeg", line);
    size_t n = strlen(line);
    if (n >= LOG_CAP) n = LOG_CAP - 1;
    if (g_log_len + n >= LOG_CAP) {            /* drop the oldest half */
        size_t keep = g_log_len / 2;
        memmove(g_log, g_log + (g_log_len - keep), keep);
        g_log_len = keep;
        if (g_log_len + n >= LOG_CAP) g_log_len = 0;
    }
    memcpy(g_log + g_log_len, line, n);
    g_log_len += n;
    g_log[g_log_len] = 0;
    pthread_mutex_unlock(&g_log_mx);
}

static jint n_run(JNIEnv *e, jclass c, jobjectArray arr) {
    pthread_mutex_lock(&g_run_mx);
    int n = (*e)->GetArrayLength(e, arr);
    char **argv = calloc((size_t)n + 2, sizeof(char *));
    argv[0] = strdup("ffmpeg");
    for (int i = 0; i < n; i++) {
        jstring s = (jstring)(*e)->GetObjectArrayElement(e, arr, i);
        const char *u = (*e)->GetStringUTFChars(e, s, NULL);
        argv[i + 1] = strdup(u);
        (*e)->ReleaseStringUTFChars(e, s, u);
        (*e)->DeleteLocalRef(e, s);
    }
    pthread_mutex_lock(&g_log_mx); g_log_len = 0; g_log[0] = 0; g_print_prefix = 1; pthread_mutex_unlock(&g_log_mx);
#ifdef HAVE_CANCEL
    received_sigterm = 0; received_nb_signals = 0;
#endif
    jmp_buf jb;
    volatile int ret = 0;
    t_jmp = &jb;
    if (setjmp(jb) == 0) ret = ffmpeg_main(n + 1, argv);
    else ret = t_code;
    t_jmp = NULL;
    for (int i = 0; i <= n; i++) free(argv[i]);
    free(argv);
    pthread_mutex_unlock(&g_run_mx);
    return ret;
}

static jstring n_log(JNIEnv *e, jclass c) {
    pthread_mutex_lock(&g_log_mx);
    jstring r = (*e)->NewStringUTF(e, g_log);
    pthread_mutex_unlock(&g_log_mx);
    return r;
}

static jint n_cancel(JNIEnv *e, jclass c) {
#ifdef HAVE_CANCEL
    received_sigterm = 15;
    received_nb_signals++;
    return 0;
#else
    return -1;
#endif
}

static jstring n_version(JNIEnv *e, jclass c) {
    char buf[512];
    snprintf(buf, sizeof(buf), "FFmpeg %s | %s", av_version_info(), avcodec_configuration());
    return (*e)->NewStringUTF(e, buf);
}

static void jstr(AVBPrint *b, const char *s) {
    av_bprint_chars(b, '"', 1);
    for (; s && *s; s++) {
        unsigned char ch = (unsigned char)*s;
        if (ch == '"' || ch == '\\') { av_bprint_chars(b, '\\', 1); av_bprint_chars(b, ch, 1); }
        else if (ch < 0x20) av_bprintf(b, "\\u%04x", ch);
        else av_bprint_chars(b, ch, 1);
    }
    av_bprint_chars(b, '"', 1);
}

/* returns JSON: {format,duration,bit_rate,streams:[{index,type,codec,width,height,fps,pix_fmt,sample_rate,channels,sample_fmt,bit_rate}]} */
static jstring n_probe(JNIEnv *e, jclass c, jstring jpath) {
    const char *p = (*e)->GetStringUTFChars(e, jpath, NULL);
    AVFormatContext *f = NULL;
    AVBPrint b;
    av_bprint_init(&b, 0, AV_BPRINT_SIZE_UNLIMITED);
    int r = avformat_open_input(&f, p, NULL, NULL);
    if (r >= 0) r = avformat_find_stream_info(f, NULL);
    if (r < 0) {
        char err[128]; av_strerror(r, err, sizeof(err));
        av_bprintf(&b, "{\"error\":"); jstr(&b, err); av_bprintf(&b, "}");
    } else {
        av_bprintf(&b, "{\"format\":"); jstr(&b, f->iformat ? f->iformat->name : "");
        av_bprintf(&b, ",\"duration\":%.3f", f->duration != AV_NOPTS_VALUE ? f->duration / (double)AV_TIME_BASE : -1.0);
        av_bprintf(&b, ",\"bit_rate\":%lld,\"streams\":[", (long long)f->bit_rate);
        for (unsigned i = 0; i < f->nb_streams; i++) {
            AVStream *st = f->streams[i];
            AVCodecParameters *par = st->codecpar;
            if (i) av_bprintf(&b, ",");
            av_bprintf(&b, "{\"index\":%u,\"type\":", i);
            jstr(&b, av_get_media_type_string(par->codec_type) ? av_get_media_type_string(par->codec_type) : "unknown");
            av_bprintf(&b, ",\"codec\":"); jstr(&b, avcodec_get_name(par->codec_id));
            av_bprintf(&b, ",\"bit_rate\":%lld", (long long)par->bit_rate);
            if (par->codec_type == AVMEDIA_TYPE_VIDEO) {
                const char *pf = par->format >= 0 ? av_get_pix_fmt_name((enum AVPixelFormat)par->format) : NULL;
                av_bprintf(&b, ",\"width\":%d,\"height\":%d,\"fps\":%.3f,\"pix_fmt\":", par->width, par->height,
                           st->avg_frame_rate.den ? av_q2d(st->avg_frame_rate) : 0.0);
                jstr(&b, pf ? pf : "");
            } else if (par->codec_type == AVMEDIA_TYPE_AUDIO) {
                const char *sf = par->format >= 0 ? av_get_sample_fmt_name((enum AVSampleFormat)par->format) : NULL;
                av_bprintf(&b, ",\"sample_rate\":%d,\"channels\":%d,\"sample_fmt\":", par->sample_rate, par->ch_layout.nb_channels);
                jstr(&b, sf ? sf : "");
            }
            av_bprintf(&b, "}");
        }
        av_bprintf(&b, "]}");
    }
    if (f) avformat_close_input(&f);
    (*e)->ReleaseStringUTFChars(e, jpath, p);
    jstring out = (*e)->NewStringUTF(e, b.str ? b.str : "{}");
    av_bprint_finalize(&b, NULL);
    return out;
}

static const JNINativeMethod METHODS[] = {
    {"nativeRun",     "([Ljava/lang/String;)I",               (void *)n_run},
    {"nativeLog",     "()Ljava/lang/String;",                 (void *)n_log},
    {"nativeCancel",  "()I",                                  (void *)n_cancel},
    {"nativeVersion", "()Ljava/lang/String;",                 (void *)n_version},
    {"nativeProbe",   "(Ljava/lang/String;)Ljava/lang/String;", (void *)n_probe},
};

JNIEXPORT jint JNI_OnLoad(JavaVM *vm, void *reserved) {
    JNIEnv *env = NULL;
    if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) return -1;
    av_jni_set_java_vm(vm, NULL);          /* <- this enables h264_mediacodec etc. */
    av_log_set_callback(log_cb);
    jclass cls = (*env)->FindClass(env, JNI_CLASS_NAME);
    if (!cls) { __android_log_print(ANDROID_LOG_ERROR, "ffmpeg", "class %s not found", JNI_CLASS_NAME); return -1; }
    if ((*env)->RegisterNatives(env, cls, METHODS, sizeof(METHODS) / sizeof(METHODS[0])) != 0) return -1;
    return JNI_VERSION_1_6;
}
EOC
sed -i "s#@JNI_CLASS@#$JNI_CLASS#" "$WORK/jni/ffmpeg_jni.c"

"$CC" -O2 -fPIC -Wall $CANCEL_DEF -I"$PREFIX/include" -c "$WORK/jni/ffmpeg_jni.c" -o "$WORK/jni/ffmpeg_jni.o"

echo "==> Link libffmpeg.so"
FFT_OBJS="$(find fftools -name '*.o' ! -name 'ffprobe*.o' ! -name 'ffplay*.o' | sort)"
PKGS="libavfilter libavformat libavcodec libswresample libswscale libavutil"
# shellcheck disable=SC2046
"$CC" -shared -o "$WORK/out/libffmpeg.so" "$WORK/jni/ffmpeg_jni.o" $FFT_OBJS \
  -L"$PREFIX/lib" $(pkg-config --static --libs $PKGS) $EXTRA_LIBS -lmediandk -landroid -llog -lz -lm \
  -Wl,-soname,libffmpeg.so -Wl,--exclude-libs,ALL -Wl,-Bsymbolic -Wl,--gc-sections \
  -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384 -Wl,-z,noexecstack -Wl,--build-id=none
"$STRIP" --strip-unneeded "$WORK/out/libffmpeg.so"

echo "==> Verify"
readelf -d "$WORK/out/libffmpeg.so" | grep NEEDED || true
echo "LOAD segment alignment (want 0x4000):"; readelf -lW "$WORK/out/libffmpeg.so" | awk '/LOAD/{print "  "$NF}'
nm -D --defined-only "$WORK/out/libffmpeg.so" 2>/dev/null | grep -E 'JNI_OnLoad' || echo "WARNING: JNI_OnLoad not exported"
strings -a "$WORK/out/libffmpeg.so" > "$WORK/strings.txt"
for f in h264_mediacodec hevc_mediacodec vp9_mediacodec av1_mediacodec ndk_codec \
         libx264 libx265 libopus libmp3lame libdav1d aac flac alac \
         loudnorm alimiter acompressor afade volume atrim aresample scale; do
  if grep -qx "$f" "$WORK/strings.txt"; then echo "OK      $f"; else echo "MISSING $f"; fi
done
echo "Tip: from the app run  nativeRun([\"-encoders\"])  /  [\"-filters\"]  /  [\"-decoders\"]  and read nativeLog() to see the exact lists."
if grep -q 'vulkan' "$WORK/strings.txt" && grep -qx 'scale_vulkan' "$WORK/strings.txt"; then echo "WARNING: Vulkan filters present"; else echo "OK      no vulkan"; fi
ls -lh "$WORK/out"
echo "Copy build_mt/out/libffmpeg.so to app/src/main/jniLibs/arm64-v8a/"
