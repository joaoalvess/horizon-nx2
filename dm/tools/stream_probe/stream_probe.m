#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#include <mach/mach_time.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <poll.h>
#include <signal.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include "../../host/stream_proto.h"
#include "../../host/dm_input.h"

enum {
    AUDIO_RATE = 48000,
    AUDIO_CHANNELS = 2,
    AUDIO_FRAME_BYTES = 4,
    AVCC_LENGTH_BYTES = 4,
    ATTACH_REFRESH_HZ = 60,
    POLL_TIMEOUT_MS = 20,
    READ_CHUNK_BYTES = 1 << 20,
    DRAIN_LIMIT_BYTES = 32 << 20,
    PRINTED_DECODE_ERRORS_MAX = 20,
};

static const uint64_t report_interval_ns = 5000000000ull;
static const uint8_t annex_b_start_code[4] = {0, 0, 0, 1};

typedef enum { ACTION_ATTACH, ACTION_DETACH, ACTION_DETACH_PAUSE, ACTION_REFRESH, ACTION_BITRATE, ACTION_STALL, ACTION_CLOSE, ACTION_QUIT, ACTION_CRASH, ACTION_PADS } script_action_kind;

typedef struct {
    double at_seconds, argument;
    script_action_kind kind;
    int done;
    char text[64];
} script_action;

typedef struct { double *values; size_t count, capacity; } sample_list;

typedef struct {
    double at_seconds, hold_seconds;
    uint64_t buttons;
    int16_t axes[4];
    char text[48];
} key_step;

typedef struct {
    sample_list hop_ms, present_to_received_ms;
    uint64_t start_ns, frames, video_bytes, sync_frames, refresh_frames, decode_errors, frame_number_gaps, gap_rule_violations, audio_blocks, audio_gaps, ltr_acks, protocol_errors;
} stream_tally;

typedef struct { uint8_t *bytes; size_t length, capacity; } byte_buffer;

typedef struct {
    int fd;
    pid_t peer_pid;
    byte_buffer incoming, outgoing;
    size_t stamped_bytes;
    uint64_t *receive_stamps;
    size_t stamp_count, stamp_capacity;
    int hello_received, ending, stop_processing, attached, pad_dirty;
    uint64_t pad_sent_ns;
    char end_reason[160];
    uint64_t stall_until_ns;
    int frame_number_known, audio_time_known;
    uint64_t last_frame_number, expected_audio_ns;
} dmhost_connection;

static struct {
    const char *socket_path, *output_prefix;
    int once, verbose, width, height, script_attaches, action_count, key_count, sends_pads;
    uint32_t hello_version, codec, kbps, pads_mask;
    script_action *actions;
    key_step *keys;
} options = {.width = 1920, .height = 1080, .hello_version = DMS_VERSION, .codec = DMS_AVC1, .kbps = 25000, .pads_mask = 1};

static int key_next, key_held;
static double key_release_seconds;
static uint64_t key_buttons;
static int16_t key_axes[4];

static FILE *video_file, *audio_file, *video_rows, *audio_rows;
static uint64_t audio_data_bytes;
static int listener_fd = -1;
static dmhost_connection connection = {.fd = -1};
static stream_tally window_tally, run_tally;
static uint64_t start_ns, first_connection_ns, next_report_ns, connection_count;
static volatile sig_atomic_t stop_signal;
static NSArray<NSData *> *parameter_sets;
static NSData *parameter_set_payload;
static int parameter_sets_due_in_file, printed_decode_errors;
static CMFormatDescriptionRef video_format;
static VTDecompressionSessionRef decoder;
static NSString *last_stats;

#define TALLY(field) (window_tally.field++, run_tally.field++)

static uint64_t now_ns(void) {
    static mach_timebase_info_data_t timebase;
    if (!timebase.denom) mach_timebase_info(&timebase);
    return mach_absolute_time() * timebase.numer / timebase.denom;
}

static double run_seconds(uint64_t at_ns) {
    uint64_t origin = first_connection_ns ? first_connection_ns : start_ns;
    return at_ns > origin ? (at_ns - origin) / 1e9 : 0;
}

static void print_line(const char *prefix, const char *format, va_list arguments) {
    printf("%st=%.2f: ", prefix, run_seconds(now_ns()));
    vprintf(format, arguments);
    putchar('\n');
}

__attribute__((format(printf, 1, 2))) static void note(const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    print_line("[probe] ", format, arguments);
    va_end(arguments);
}

__attribute__((format(printf, 1, 2))) static void warn(const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    print_line("[RED] probe: ", format, arguments);
    va_end(arguments);
}

static void print_usage(FILE *stream) {
    fprintf(stream,
            "usage: stream_probe <socket path> <output prefix> [options]\n"
            "  --once               exit when the connection ends instead of waiting for the next one\n"
            "  --size WxH           size sent in ATTACH (default 1920x1080)\n"
            "  --codec avc1|hvc1    codec sent in ATTACH (default avc1)\n"
            "  --kbps N             starting bitrate sent in ATTACH (default 25000)\n"
            "  --hello-version N    protocol version sent in the probe's HELLO (default %d)\n"
            "  --script \"T:action,...\"  T in seconds since the first connection; actions: attach, detach, detach-pause,\n"
            "                       refresh, bitrate=N, stall=S, close, quit, crash, pads=MASK (the players PADS connects)\n"
            "  --keys \"T:keys[~hold][*count/interval],...\"  player 1's input as DM_KEYS writes it, in seconds since the first\n"
            "                       connection: names joined by +, held 0.15 s by default; sent as PAD on change and every 100 ms\n"
            "  --verbose            print every STATS message, LTR_ACK and skipped message\n",
            DMS_VERSION);
}

__attribute__((format(printf, 1, 2), noreturn)) static void usage_error(const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    fputs("[RED] probe: ", stderr);
    vfprintf(stderr, format, arguments);
    fputc('\n', stderr);
    va_end(arguments);
    print_usage(stderr);
    exit(2);
}

__attribute__((format(printf, 1, 2), noreturn)) static void setup_error(const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    fputs("[RED] probe: ", stderr);
    vfprintf(stderr, format, arguments);
    fputc('\n', stderr);
    va_end(arguments);
    exit(2);
}

static void *grow_or_die(void *pointer, size_t bytes) {
    void *grown = realloc(pointer, bytes);
    if (!grown) {
        fputs("[RED] probe: out of memory\n", stderr);
        _exit(1);
    }
    return grown;
}

static void sample_add(sample_list *list, double value) {
    if (list->count == list->capacity) {
        list->capacity = list->capacity ? list->capacity * 2 : 1024;
        list->values = grow_or_die(list->values, list->capacity * sizeof *list->values);
    }
    list->values[list->count++] = value;
}

static int compare_doubles(const void *left, const void *right) {
    double a = *(const double *)left, b = *(const double *)right;
    return (a > b) - (a < b);
}

static void sample_sort(sample_list *list) { qsort(list->values, list->count, sizeof *list->values, compare_doubles); }

static double sample_at(const sample_list *list, int percent) {
    size_t index = list->count * (size_t)percent / 100;
    return list->values[index < list->count ? index : list->count - 1];
}

static void format_percentile(char *text, size_t size, const sample_list *list, int percent) {
    if (list->count) snprintf(text, size, "%.3f", sample_at(list, percent));
    else snprintf(text, size, "-");
}

static void tally_restart(stream_tally *tally, uint64_t at_ns) {
    sample_list hop = tally->hop_ms, latency = tally->present_to_received_ms;
    hop.count = 0;
    latency.count = 0;
    *tally = (stream_tally){.hop_ms = hop, .present_to_received_ms = latency, .start_ns = at_ns};
}

static void print_tally(const char *label, stream_tally *tally, uint64_t at_ns) {
    double seconds = at_ns > tally->start_ns ? (at_ns - tally->start_ns) / 1e9 : 0;
    sample_sort(&tally->hop_ms);
    sample_sort(&tally->present_to_received_ms);
    char hop_p50[32], hop_p95[32], hop_max[32], latency_p50[32], latency_p95[32];
    format_percentile(hop_p50, sizeof hop_p50, &tally->hop_ms, 50);
    format_percentile(hop_p95, sizeof hop_p95, &tally->hop_ms, 95);
    format_percentile(hop_max, sizeof hop_max, &tally->hop_ms, 100);
    format_percentile(latency_p50, sizeof latency_p50, &tally->present_to_received_ms, 50);
    format_percentile(latency_p95, sizeof latency_p95, &tally->present_to_received_ms, 95);
    printf("[probe] %s: frames %llu (%.1f fps), hop p50 %s / p95 %s / max %s ms, present to received p50 %s / p95 %s ms, %.2f Mbit/s, "
           "sync %llu / refresh %llu frames, decode errors %llu, frame-number gaps %llu, gap rule violations %llu, audio blocks %llu and gaps %llu, "
           "LTR acks %llu, protocol errors %llu\n",
           label, tally->frames, seconds > 0 ? tally->frames / seconds : 0, hop_p50, hop_p95, hop_max, latency_p50, latency_p95,
           seconds > 0 ? tally->video_bytes * 8 / seconds / 1e6 : 0, tally->sync_frames, tally->refresh_frames, tally->decode_errors,
           tally->frame_number_gaps, tally->gap_rule_violations, tally->audio_blocks, tally->audio_gaps, tally->ltr_acks, tally->protocol_errors);
}

static void buffer_reserve(byte_buffer *buffer, size_t extra) {
    if (buffer->capacity - buffer->length >= extra) return;
    size_t capacity = buffer->capacity ? buffer->capacity : 65536;
    while (capacity - buffer->length < extra) capacity *= 2;
    buffer->bytes = grow_or_die(buffer->bytes, capacity);
    buffer->capacity = capacity;
}

static void buffer_append(byte_buffer *buffer, const void *bytes, size_t length) {
    buffer_reserve(buffer, length);
    memcpy(buffer->bytes + buffer->length, bytes, length);
    buffer->length += length;
}

static void buffer_consume(byte_buffer *buffer, size_t length) {
    memmove(buffer->bytes, buffer->bytes + length, buffer->length - length);
    buffer->length -= length;
}

static uint32_t read_big_endian32(const uint8_t *bytes) {
    return (uint32_t)bytes[0] << 24 | (uint32_t)bytes[1] << 16 | (uint32_t)bytes[2] << 8 | bytes[3];
}

static dms_header read_header(const uint8_t *bytes) {
    dms_reader reader = {(uint8_t *)bytes, (uint8_t *)bytes + DMS_HEADER, 0};
    dms_header header;
    header.length = dms_get32(&reader);
    header.type = dms_get16(&reader);
    header.flags = dms_get16(&reader);
    header.sent_ns = dms_get64(&reader);
    return header;
}

static int take_bytes(dms_reader *reader, size_t length, const uint8_t **bytes) {
    if (reader->bad || (size_t)(reader->end - reader->p) < length) {
        reader->bad = 1;
        return 0;
    }
    *bytes = reader->p;
    reader->p += length;
    return 1;
}

static void fourcc_text(uint32_t code, char text[5]) {
    for (int i = 0; i < 4; i++) {
        unsigned char character = (unsigned char)(code >> (24 - 8 * i));
        text[i] = character >= 0x20 && character < 0x7f ? (char)character : '?';
    }
    text[4] = 0;
}

__attribute__((format(printf, 1, 2))) static void end_connection(const char *format, ...) {
    if (connection.ending) return;
    connection.ending = 1;
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(connection.end_reason, sizeof connection.end_reason, format, arguments);
    va_end(arguments);
}

__attribute__((format(printf, 1, 2))) static void protocol_error(const char *format, ...) {
    char message[256];
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(message, sizeof message, format, arguments);
    va_end(arguments);
    warn("protocol error: %s; closing the connection", message);
    TALLY(protocol_errors);
    connection.stop_processing = 1;
    end_connection("protocol error");
}

static void flush_outgoing(void) {
    while (connection.outgoing.length && !connection.ending) {
        ssize_t written = write(connection.fd, connection.outgoing.bytes, connection.outgoing.length);
        if (written > 0) {
            buffer_consume(&connection.outgoing, (size_t)written);
            continue;
        }
        if (written < 0 && errno == EINTR) continue;
        if (written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return;
        end_connection("writing to dmhost failed: %s", written < 0 ? strerror(errno) : "nothing was written");
    }
}

static void send_message(uint16_t type, uint16_t flags, const uint8_t *payload, uint32_t length) {
    if (connection.fd < 0 || connection.ending) return;
    uint8_t header[DMS_HEADER], *cursor = header;
    dms_put32(&cursor, length);
    dms_put16(&cursor, type);
    dms_put16(&cursor, flags);
    dms_put64(&cursor, now_ns());
    buffer_append(&connection.outgoing, header, sizeof header);
    if (length) buffer_append(&connection.outgoing, payload, length);
    flush_outgoing();
}

static const char *codec_name(void) { return options.codec == DMS_HVC1 ? "HEVC" : "H.264"; }

static void send_pads(void) {
    uint8_t pads[12] = {0}, *cursor = pads;
    dms_put32(&cursor, options.pads_mask);
    for (int p = 0; p < 8; p++) dms_put8(&cursor, options.pads_mask >> p & 1 ? DMS_STYLE_PRO : 0);
    send_message(DMS_PADS, 0, pads, sizeof pads);
}

static void send_attach(void) {
    uint8_t attach[16], *cursor = attach;
    dms_put16(&cursor, ATTACH_REFRESH_HZ);
    dms_put16(&cursor, (uint16_t)options.width);
    dms_put16(&cursor, (uint16_t)options.height);
    dms_put16(&cursor, 0);
    dms_put32(&cursor, options.codec);
    dms_put32(&cursor, options.kbps);
    send_message(DMS_ATTACH, 0, attach, (uint32_t)(cursor - attach));
    send_pads();
    connection.frame_number_known = 0;
    connection.audio_time_known = 0;
    connection.attached = 1;
    connection.pad_dirty = 1;
    char codec[5];
    fourcc_text(options.codec, codec);
    note("sent ATTACH %dx%d at %d Hz, %s, %u kbit/s, then PADS with players %#x as Pro Controllers", options.width, options.height, ATTACH_REFRESH_HZ, codec,
         options.kbps, options.pads_mask);
}

static void send_ltr_ack(int64_t token) {
    uint8_t payload[10], *cursor = payload;
    dms_put16(&cursor, 1);
    dms_put64(&cursor, (uint64_t)token);
    send_message(DMS_LTR_ACK, 0, payload, sizeof payload);
    TALLY(ltr_acks);
    if (options.verbose) note("sent LTR_ACK %lld", token);
}

static void warm_up_video_toolbox(void) {
    CMVideoFormatDescriptionRef format = NULL;
    VTDecompressionSessionRef session = NULL;
    if (CMVideoFormatDescriptionCreate(kCFAllocatorDefault, kCMVideoCodecType_H264, 64, 64, NULL, &format)) return;
    if (!VTDecompressionSessionCreate(kCFAllocatorDefault, format, NULL, NULL, NULL, &session)) {
        VTDecompressionSessionInvalidate(session);
        CFRelease(session);
    }
    CFRelease(format);
}

static void release_decoder(void) {
    if (!decoder) return;
    VTDecompressionSessionInvalidate(decoder);
    CFRelease(decoder);
    decoder = NULL;
}

static void replace_video_format(void) {
    release_decoder();
    if (video_format) CFRelease(video_format);
    video_format = NULL;
    size_t count = parameter_sets.count;
    const uint8_t *pointers[count];
    size_t sizes[count];
    for (size_t i = 0; i < count; i++) {
        pointers[i] = parameter_sets[i].bytes;
        sizes[i] = parameter_sets[i].length;
    }
    OSStatus status = options.codec == DMS_HVC1
                          ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(kCFAllocatorDefault, count, pointers, sizes, AVCC_LENGTH_BYTES, NULL, &video_format)
                          : CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault, count, pointers, sizes, AVCC_LENGTH_BYTES, &video_format);
    if (status) {
        video_format = NULL;
        warn("the parameter sets do not make an %s format description (%d)", codec_name(), (int)status);
    }
}

static int decode_access_unit(const uint8_t *bytes, size_t length, uint64_t present_ns, char *failure, size_t failure_size) {
    if (!video_format) {
        snprintf(failure, failure_size, "no usable VIDEO_CONFIG came before it");
        return 0;
    }
    if (!decoder) {
        OSStatus status = VTDecompressionSessionCreate(kCFAllocatorDefault, video_format, NULL, NULL, NULL, &decoder);
        if (status) {
            decoder = NULL;
            snprintf(failure, failure_size, "VTDecompressionSessionCreate failed (%d)", (int)status);
            return 0;
        }
    }
    CMBlockBufferRef block = NULL;
    CMSampleBufferRef sample = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, length, kCFAllocatorDefault, NULL, 0, length, kCMBlockBufferAssureMemoryNowFlag, &block);
    if (!status) status = CMBlockBufferReplaceDataBytes(bytes, block, 0, length);
    CMSampleTimingInfo timing = {kCMTimeInvalid, CMTimeMake((int64_t)present_ns, 1000000000), kCMTimeInvalid};
    if (!status) status = CMSampleBufferCreateReady(kCFAllocatorDefault, block, video_format, 1, 1, &timing, 1, &length, &sample);
    if (status) {
        if (block) CFRelease(block);
        snprintf(failure, failure_size, "its sample buffer could not be made (%d)", (int)status);
        return 0;
    }
    __block OSStatus output_status = noErr;
    __block int pictures = 0;
    VTDecodeInfoFlags info = 0;
    status = VTDecompressionSessionDecodeFrameWithOutputHandler(decoder, sample, 0, &info,
                                                                ^(OSStatus decoded_status, VTDecodeInfoFlags decoded_flags, CVImageBufferRef image, CMTime presentation, CMTime duration) {
                                                                    if (decoded_status) output_status = decoded_status;
                                                                    else if (image && !(decoded_flags & kVTDecodeInfo_FrameDropped)) pictures++;
                                                                });
    if (!status) VTDecompressionSessionWaitForAsynchronousFrames(decoder);
    CFRelease(sample);
    CFRelease(block);
    if (status == kVTInvalidSessionErr) release_decoder();
    if (status) snprintf(failure, failure_size, "VTDecompressionSessionDecodeFrame failed (%d)", (int)status);
    else if (output_status) snprintf(failure, failure_size, "the decoder reported %d", (int)output_status);
    else if (!pictures) snprintf(failure, failure_size, "the decoder gave no picture");
    return !status && !output_status && pictures;
}

static void report_decode_error(uint64_t frame_number, const char *failure) {
    if (printed_decode_errors < PRINTED_DECODE_ERRORS_MAX) warn("frame %llu did not decode: %s", frame_number, failure);
    else if (printed_decode_errors == PRINTED_DECODE_ERRORS_MAX) warn("more frames did not decode; they are counted, not printed");
    printed_decode_errors++;
}

static void write_annex_b(const uint8_t *access_unit, size_t length) {
    if (parameter_sets_due_in_file) {
        for (NSData *set in parameter_sets) {
            fwrite(annex_b_start_code, 1, sizeof annex_b_start_code, video_file);
            fwrite(set.bytes, 1, set.length, video_file);
        }
        parameter_sets_due_in_file = 0;
    }
    for (size_t offset = 0; offset < length;) {
        uint32_t nal_length = read_big_endian32(access_unit + offset);
        offset += AVCC_LENGTH_BYTES;
        fwrite(annex_b_start_code, 1, sizeof annex_b_start_code, video_file);
        fwrite(access_unit + offset, 1, nal_length, video_file);
        offset += nal_length;
    }
}

static void handle_hello(dms_reader *reader) {
    if (connection.hello_received) {
        protocol_error("a second HELLO on the same connection");
        return;
    }
    const uint8_t *start = reader->p;
    uint32_t version = dms_get32(reader);
    uint64_t title_id = dms_get64(reader);
    uint16_t window_width = dms_get16(reader), window_height = dms_get16(reader);
    uint32_t audio_rate = dms_get32(reader);
    uint8_t channels = dms_get8(reader), codec_count = dms_get8(reader);
    dms_get16(reader);
    char codecs[256 * 5 + 1] = "";
    int lists_chosen_codec = 0;
    for (int i = 0; i < codec_count; i++) {
        uint32_t codec = dms_get32(reader);
        char text[5];
        fourcc_text(codec, text);
        if (i) strlcat(codecs, " ", sizeof codecs);
        strlcat(codecs, text, sizeof codecs);
        lists_chosen_codec |= codec == options.codec;
    }
    if (reader->bad) {
        protocol_error("HELLO is malformed: %u codecs announced in a %ld-byte payload", codec_count, (long)(reader->end - start));
        return;
    }
    connection.hello_received = 1;
    note("HELLO: version %u, title %016llX, window %ux%u, audio %u Hz, %u channels, codecs %s, build \"%.*s\"", version, title_id, window_width, window_height,
         audio_rate, channels, codec_count ? codecs : "none", (int)(reader->end - reader->p), (const char *)reader->p);
    if (version != DMS_VERSION) warn("dmhost speaks protocol version %u, the probe speaks %d", version, DMS_VERSION);
    if (audio_rate != AUDIO_RATE || channels != AUDIO_CHANNELS) warn("dmhost announces %u Hz with %u channels; AUDIO is %d Hz stereo", audio_rate, channels, AUDIO_RATE);
    char chosen[5];
    fourcc_text(options.codec, chosen);
    if (!lists_chosen_codec) warn("dmhost does not list %s; the probe attaches with it anyway", chosen);
    uint8_t payload[4], *cursor = payload;
    dms_put32(&cursor, options.hello_version);
    send_message(DMS_HELLO, 0, payload, sizeof payload);
    note("sent HELLO version %u", options.hello_version);
    if (!options.script_attaches) send_attach();
}

static void handle_video_config(dms_reader *reader) {
    const uint8_t *start = reader->p;
    NSMutableArray<NSData *> *sets = [NSMutableArray array];
    NSMutableString *sizes = [NSMutableString string];
    while (reader->p < reader->end) {
        uint16_t length = dms_get16(reader);
        const uint8_t *bytes = NULL;
        if (!length || !take_bytes(reader, length, &bytes)) {
            protocol_error("VIDEO_CONFIG is malformed after %lu parameter sets", (unsigned long)sets.count);
            return;
        }
        [sets addObject:[NSData dataWithBytes:bytes length:length]];
        [sizes appendFormat:@"%s%u", sets.count > 1 ? ", " : "", length];
    }
    if (!sets.count) {
        protocol_error("VIDEO_CONFIG has no parameter sets");
        return;
    }
    NSData *payload = [NSData dataWithBytes:start length:(NSUInteger)(reader->end - start)];
    parameter_sets = sets;
    parameter_sets_due_in_file = 1;
    if ([payload isEqualToData:parameter_set_payload]) {
        if (options.verbose) note("VIDEO_CONFIG unchanged");
        return;
    }
    parameter_set_payload = payload;
    replace_video_format();
    note("VIDEO_CONFIG: %lu parameter sets of %s bytes; the %s decoder is recreated", (unsigned long)sets.count, sizes.UTF8String, codec_name());
}

static void handle_video_frame(dms_reader *reader, dms_header header, uint64_t received_ns) {
    uint64_t present_ns = dms_get64(reader), frame_number = dms_get64(reader);
    int64_t ltr_token = (int64_t)dms_get64(reader);
    if (reader->bad) {
        protocol_error("VIDEO_FRAME is %u bytes, under its 24-byte fixed part", header.length);
        return;
    }
    const uint8_t *access_unit = reader->p;
    size_t access_unit_length = (size_t)(reader->end - reader->p), nal_count = 0;
    for (size_t offset = 0; offset < access_unit_length; nal_count++) {
        if (access_unit_length - offset < AVCC_LENGTH_BYTES) {
            protocol_error("frame %llu ends inside the length of NAL unit %zu", frame_number, nal_count);
            return;
        }
        uint32_t nal_length = read_big_endian32(access_unit + offset);
        offset += AVCC_LENGTH_BYTES;
        if (!nal_length || nal_length > access_unit_length - offset) {
            protocol_error("frame %llu: NAL unit %zu claims %u bytes, %zu are left", frame_number, nal_count, nal_length, access_unit_length - offset);
            return;
        }
        offset += nal_length;
    }
    if (!nal_count) {
        protocol_error("frame %llu has no NAL units", frame_number);
        return;
    }
    write_annex_b(access_unit, access_unit_length);
    int sync = (header.flags & DMS_FRAME_SYNC) != 0, refresh = (header.flags & DMS_FRAME_REFRESH) != 0;
    if (connection.frame_number_known && frame_number != connection.last_frame_number + 1) {
        TALLY(frame_number_gaps);
        if (sync || refresh) note("frame %llu follows frame %llu, a gap, with the %s flag", frame_number, connection.last_frame_number, sync ? "sync" : "refresh");
        else {
            TALLY(gap_rule_violations);
            warn("frame %llu follows frame %llu, a gap, without the sync or refresh flag", frame_number, connection.last_frame_number);
        }
    }
    connection.frame_number_known = 1;
    connection.last_frame_number = frame_number;
    char failure[128] = "";
    int decoded = decode_access_unit(access_unit, access_unit_length, present_ns, failure, sizeof failure);
    if (!decoded) {
        TALLY(decode_errors);
        report_decode_error(frame_number, failure);
    }
    if (decoded && ltr_token >= 0) send_ltr_ack(ltr_token);
    double hop_ms = (int64_t)(received_ns - header.sent_ns) / 1e6, present_to_received_ms = (int64_t)(received_ns - present_ns) / 1e6;
    fprintf(video_rows, "%llu\t%llu\t%llu\t%llu\t%.3f\t%.3f\t%zu\t%u\t%lld\t%d\n", frame_number, present_ns, header.sent_ns, received_ns, hop_ms, present_to_received_ms,
            access_unit_length, header.flags, ltr_token, decoded);
    TALLY(frames);
    window_tally.video_bytes += access_unit_length;
    run_tally.video_bytes += access_unit_length;
    if (sync) TALLY(sync_frames);
    if (refresh) TALLY(refresh_frames);
    sample_add(&window_tally.hop_ms, hop_ms);
    sample_add(&run_tally.hop_ms, hop_ms);
    sample_add(&window_tally.present_to_received_ms, present_to_received_ms);
    sample_add(&run_tally.present_to_received_ms, present_to_received_ms);
}

static void handle_audio(dms_reader *reader, dms_header header, uint64_t received_ns) {
    uint64_t block_ns = dms_get64(reader);
    uint32_t frame_count = dms_get32(reader);
    if (reader->bad || (uint64_t)(reader->end - reader->p) != (uint64_t)frame_count * AUDIO_FRAME_BYTES) {
        protocol_error("AUDIO is %u bytes, which does not hold its 12-byte fixed part and %u frames", header.length, frame_count);
        return;
    }
    size_t sample_bytes = (size_t)frame_count * AUDIO_FRAME_BYTES;
    fwrite(reader->p, 1, sample_bytes, audio_file);
    audio_data_bytes += sample_bytes;
    uint64_t block_duration_ns = (uint64_t)frame_count * 1000000000ull / AUDIO_RATE;
    if (connection.audio_time_known && block_ns > connection.expected_audio_ns + block_duration_ns) {
        TALLY(audio_gaps);
        note("audio gap: the block at %llu ns starts %.2f ms after the previous block ended", block_ns, (block_ns - connection.expected_audio_ns) / 1e6);
    }
    connection.audio_time_known = 1;
    connection.expected_audio_ns = block_ns + block_duration_ns;
    fprintf(audio_rows, "%llu\t%llu\t%llu\t%.3f\t%u\n", block_ns, header.sent_ns, received_ns, (int64_t)(received_ns - header.sent_ns) / 1e6, frame_count);
    TALLY(audio_blocks);
}

static void handle_stats(dms_reader *reader) {
    last_stats = [[NSString alloc] initWithBytes:reader->p length:(NSUInteger)(reader->end - reader->p) encoding:NSUTF8StringEncoding] ?: @"(not UTF-8)";
    if (options.verbose) note("STATS %s", last_stats.UTF8String);
}

static void handle_message(dms_header header, uint8_t *payload, uint64_t received_ns) {
    dms_reader reader = {payload, payload + header.length, 0};
    if (!connection.hello_received && header.type != DMS_HELLO) {
        protocol_error("the first message is of type %u, not HELLO", header.type);
        return;
    }
    switch (header.type) {
    case DMS_HELLO: handle_hello(&reader); break;
    case DMS_VIDEO_CONFIG: handle_video_config(&reader); break;
    case DMS_VIDEO_FRAME: handle_video_frame(&reader, header, received_ns); break;
    case DMS_AUDIO: handle_audio(&reader, header, received_ns); break;
    case DMS_STATS: handle_stats(&reader); break;
    default:
        if (options.verbose) note("skipped a message of type %u (%u bytes)", header.type, header.length);
        break;
    }
}

static void stamp_complete_messages(uint64_t received_ns) {
    for (;;) {
        size_t available = connection.incoming.length - connection.stamped_bytes;
        if (available < DMS_HEADER) return;
        dms_header header = read_header(connection.incoming.bytes + connection.stamped_bytes);
        if (header.length > DMS_MAX_PAYLOAD || available - DMS_HEADER < header.length) return;
        if (connection.stamp_count == connection.stamp_capacity) {
            connection.stamp_capacity = connection.stamp_capacity ? connection.stamp_capacity * 2 : 1024;
            connection.receive_stamps = grow_or_die(connection.receive_stamps, connection.stamp_capacity * sizeof *connection.receive_stamps);
        }
        connection.receive_stamps[connection.stamp_count++] = received_ns;
        connection.stamped_bytes += DMS_HEADER + header.length;
    }
}

static void read_available(void) {
    for (size_t drained = 0; drained < DRAIN_LIMIT_BYTES;) {
        buffer_reserve(&connection.incoming, READ_CHUNK_BYTES);
        ssize_t received = read(connection.fd, connection.incoming.bytes + connection.incoming.length, connection.incoming.capacity - connection.incoming.length);
        if (received > 0) {
            connection.incoming.length += (size_t)received;
            drained += (size_t)received;
            stamp_complete_messages(now_ns());
            continue;
        }
        if (received == 0) {
            end_connection("dmhost closed the socket");
            return;
        }
        if (errno == EINTR) continue;
        if (errno != EAGAIN && errno != EWOULDBLOCK) end_connection("reading from dmhost failed: %s", strerror(errno));
        return;
    }
}

static void process_incoming(void) {
    size_t offset = 0, stamp_index = 0;
    while (!connection.stop_processing) {
        size_t available = connection.incoming.length - offset;
        if (available < DMS_HEADER) break;
        dms_header header = read_header(connection.incoming.bytes + offset);
        if (header.length > DMS_MAX_PAYLOAD) {
            protocol_error("a message of type %u announces a %u-byte payload, over the %d-byte limit", header.type, header.length, DMS_MAX_PAYLOAD);
            break;
        }
        if (available - DMS_HEADER < header.length) break;
        uint64_t received_ns = stamp_index < connection.stamp_count ? connection.receive_stamps[stamp_index] : now_ns();
        stamp_index++;
        handle_message(header, connection.incoming.bytes + offset + DMS_HEADER, received_ns);
        offset += DMS_HEADER + header.length;
    }
    if (connection.stop_processing) return;
    buffer_consume(&connection.incoming, offset);
    connection.stamped_bytes -= offset;
    if (stamp_index > connection.stamp_count) stamp_index = connection.stamp_count;
    memmove(connection.receive_stamps, connection.receive_stamps + stamp_index, (connection.stamp_count - stamp_index) * sizeof *connection.receive_stamps);
    connection.stamp_count -= stamp_index;
}

static int exit_status(void) { return run_tally.decode_errors || run_tally.protocol_errors || run_tally.gap_rule_violations ? 1 : 0; }

static void write_wav_header(void) {
    uint32_t data_bytes = audio_data_bytes > UINT32_MAX - 36 ? UINT32_MAX - 36 : (uint32_t)audio_data_bytes;
    uint8_t header[44], *cursor = header;
    dms_put(&cursor, "RIFF", 4);
    dms_put32(&cursor, 36 + data_bytes);
    dms_put(&cursor, "WAVE", 4);
    dms_put(&cursor, "fmt ", 4);
    dms_put32(&cursor, 16);
    dms_put16(&cursor, 1);
    dms_put16(&cursor, AUDIO_CHANNELS);
    dms_put32(&cursor, AUDIO_RATE);
    dms_put32(&cursor, AUDIO_RATE * AUDIO_FRAME_BYTES);
    dms_put16(&cursor, AUDIO_FRAME_BYTES);
    dms_put16(&cursor, 16);
    dms_put(&cursor, "data", 4);
    dms_put32(&cursor, data_bytes);
    fseek(audio_file, 0, SEEK_SET);
    fwrite(header, 1, sizeof header, audio_file);
}

__attribute__((noreturn)) static void finish_run(void) {
    uint64_t now = now_ns();
    close(listener_fd);
    unlink(options.socket_path);
    if (connection.fd >= 0) close(connection.fd);
    release_decoder();
    char label[64];
    snprintf(label, sizeof label, "whole run, %.1f s", run_seconds(now));
    print_tally(label, &run_tally, now);
    if (last_stats) printf("[probe] last STATS: %s\n", last_stats.UTF8String);
    if (!run_tally.hop_ms.count) printf("[RED] probe: hop p95: no video frames were received\n");
    else if (sample_at(&run_tally.hop_ms, 95) < 1) printf("[probe] hop p95 %.3f ms: under 1 ms\n", sample_at(&run_tally.hop_ms, 95));
    else printf("[RED] probe: hop p95 %.3f ms: over 1 ms\n", sample_at(&run_tally.hop_ms, 95));
    write_wav_header();
    fclose(video_file);
    fclose(audio_file);
    fclose(video_rows);
    fclose(audio_rows);
    printf("[probe] connections %llu, %llu bytes of audio; exit status %d\n", connection_count, audio_data_bytes, exit_status());
    exit(exit_status());
}

static void close_connection(const char *reason) {
    if (connection.incoming.length) note("connection %llu closed: %s (%zu received bytes left unprocessed)", connection_count, reason, connection.incoming.length);
    else note("connection %llu closed: %s", connection_count, reason);
    close(connection.fd);
    byte_buffer incoming = connection.incoming, outgoing = connection.outgoing;
    uint64_t *receive_stamps = connection.receive_stamps;
    size_t stamp_capacity = connection.stamp_capacity;
    incoming.length = 0;
    outgoing.length = 0;
    connection = (dmhost_connection){.fd = -1, .incoming = incoming, .outgoing = outgoing, .receive_stamps = receive_stamps, .stamp_capacity = stamp_capacity};
    if (options.once) finish_run();
    note("waiting for dmhost's next connection");
}

static void accept_connection(void) {
    int fd = accept(listener_fd, NULL, NULL);
    if (fd < 0) {
        if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR && errno != ECONNABORTED) warn("accept failed: %s", strerror(errno));
        return;
    }
    int enabled = 1, file_flags = fcntl(fd, F_GETFL);
    if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof enabled) || file_flags < 0 || fcntl(fd, F_SETFL, file_flags | O_NONBLOCK) < 0) {
        warn("cannot set up the accepted socket: %s", strerror(errno));
        close(fd);
        return;
    }
    pid_t peer_pid = 0;
    socklen_t peer_pid_size = sizeof peer_pid;
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer_pid, &peer_pid_size)) peer_pid = 0;
    uint64_t now = now_ns();
    if (!first_connection_ns) {
        first_connection_ns = now;
        tally_restart(&window_tally, now);
        tally_restart(&run_tally, now);
        next_report_ns = now + report_interval_ns;
    }
    connection.fd = fd;
    connection.peer_pid = peer_pid;
    connection_count++;
    note("dmhost connected (pid %d, connection %llu)", peer_pid, connection_count);
}

static void perform_action(script_action *action, uint64_t now) {
    if (action->kind == ACTION_QUIT) {
        note("script %s: quitting", action->text);
        finish_run();
    }
    if (action->kind == ACTION_CRASH) {
        note("script %s: exiting at once with status 3", action->text);
        _exit(3);
    }
    int connected = connection.fd >= 0 && !connection.ending;
    int needs_hello = action->kind != ACTION_STALL && action->kind != ACTION_CLOSE;
    if (!connected || (needs_hello && !connection.hello_received)) {
        note("script %s: skipped, %s", action->text, connected ? "dmhost has not sent HELLO yet" : "no dmhost is connected");
        return;
    }
    switch (action->kind) {
    case ACTION_ATTACH:
        note("script %s", action->text);
        send_attach();
        break;
    case ACTION_DETACH:
    case ACTION_DETACH_PAUSE:
        send_message(DMS_DETACH, action->kind == ACTION_DETACH_PAUSE ? DMS_DETACH_PAUSE : 0, NULL, 0);
        connection.attached = 0;
        note("script %s: sent DETACH%s", action->text, action->kind == ACTION_DETACH_PAUSE ? " with pause" : "");
        break;
    case ACTION_REFRESH:
        send_message(DMS_REFRESH, 0, NULL, 0);
        note("script %s: sent REFRESH", action->text);
        break;
    case ACTION_BITRATE: {
        uint8_t payload[4], *cursor = payload;
        dms_put32(&cursor, (uint32_t)action->argument);
        send_message(DMS_BITRATE, 0, payload, sizeof payload);
        note("script %s: sent BITRATE %u kbit/s", action->text, (uint32_t)action->argument);
        break;
    }
    case ACTION_STALL:
        connection.stall_until_ns = now + (uint64_t)(action->argument * 1e9);
        note("script %s: not reading the socket for %.2f s", action->text, action->argument);
        break;
    case ACTION_CLOSE:
        note("script %s", action->text);
        close_connection("closed by the script");
        break;
    case ACTION_PADS:
        options.pads_mask = (uint32_t)action->argument;
        send_pads();
        connection.pad_dirty = 1;
        note("script %s: sent PADS with players %#x", action->text, options.pads_mask);
        break;
    case ACTION_QUIT:
    case ACTION_CRASH: break;
    }
}

static void keys_tick(uint64_t now) {
    if (!first_connection_ns || key_next >= options.key_count) return;
    double elapsed = run_seconds(now);
    const key_step *step = &options.keys[key_next];
    if (!key_held) {
        if (elapsed < step->at_seconds) return;
        key_buttons = step->buttons;
        memcpy(key_axes, step->axes, sizeof key_axes);
        key_held = 1;
        key_release_seconds = elapsed + step->hold_seconds;
        connection.pad_dirty = 1;
        note("keys %s: pressed at %.2f s for %.2f s", step->text, elapsed, step->hold_seconds);
    } else if (elapsed >= key_release_seconds) {
        key_buttons = 0;
        memset(key_axes, 0, sizeof key_axes);
        key_held = 0;
        key_next++;
        connection.pad_dirty = 1;
    }
}

static void pads_tick(uint64_t now) {
    if (!options.sends_pads || connection.fd < 0 || connection.ending || !connection.attached || !connection.hello_received) return;
    if (!connection.pad_dirty && now - connection.pad_sent_ns < 80000000ull) return;
    for (int p = 0; p < 8; p++) {
        if (!(options.pads_mask >> p & 1)) continue;
        uint8_t pad[24] = {0}, *cursor = pad;
        dms_put8(&cursor, (uint8_t)p);
        cursor += 7;
        dms_put64(&cursor, p ? 0 : key_buttons);
        for (int i = 0; i < 4; i++) dms_put16(&cursor, (uint16_t)(p ? 0 : key_axes[i]));
        send_message(DMS_PAD, 0, pad, sizeof pad);
    }
    connection.pad_sent_ns = now;
    connection.pad_dirty = 0;
}

static void run_due_actions(uint64_t now) {
    if (!first_connection_ns) return;
    double elapsed = run_seconds(now);
    for (int i = 0; i < options.action_count; i++) {
        script_action *action = &options.actions[i];
        if (action->at_seconds > elapsed) break;
        if (action->done) continue;
        action->done = 1;
        perform_action(action, now);
    }
}

static unsigned long long parse_unsigned(const char *text, const char *what, unsigned long long minimum, unsigned long long maximum) {
    char *end = NULL;
    errno = 0;
    unsigned long long value = strtoull(text, &end, 10);
    if (!*text || *text == '-' || *end || errno || value < minimum || value > maximum) usage_error("%s takes a number from %llu to %llu, not \"%s\"", what, minimum, maximum, text);
    return value;
}

static void parse_script(const char *text) {
    char *copy = strdup(text), *cursor = NULL;
    for (char *item = strtok_r(copy, ",", &cursor); item; item = strtok_r(NULL, ",", &cursor)) {
        char *colon = strchr(item, ':');
        if (!colon) usage_error("the script item \"%s\" is not T:action", item);
        *colon = 0;
        const char *name = colon + 1;
        char *end = NULL;
        double at_seconds = strtod(item, &end);
        if (end == item || *end || !isfinite(at_seconds) || at_seconds < 0) usage_error("the script time \"%s\" is not a number of seconds", item);
        script_action action = {.at_seconds = at_seconds};
        snprintf(action.text, sizeof action.text, "%s:%s", item, name);
        if (!strcmp(name, "attach")) action.kind = ACTION_ATTACH;
        else if (!strcmp(name, "detach")) action.kind = ACTION_DETACH;
        else if (!strcmp(name, "detach-pause")) action.kind = ACTION_DETACH_PAUSE;
        else if (!strcmp(name, "refresh")) action.kind = ACTION_REFRESH;
        else if (!strcmp(name, "close")) action.kind = ACTION_CLOSE;
        else if (!strcmp(name, "quit")) action.kind = ACTION_QUIT;
        else if (!strcmp(name, "crash")) action.kind = ACTION_CRASH;
        else if (!strncmp(name, "bitrate=", 8)) {
            action.kind = ACTION_BITRATE;
            action.argument = (double)parse_unsigned(name + 8, "bitrate=", 1, UINT32_MAX);
        } else if (!strncmp(name, "stall=", 6)) {
            action.kind = ACTION_STALL;
            action.argument = strtod(name + 6, &end);
            if (end == name + 6 || *end || !isfinite(action.argument) || action.argument < 0) usage_error("stall= takes a number of seconds, not \"%s\"", name + 6);
        } else if (!strncmp(name, "pads=", 5)) {
            action.kind = ACTION_PADS;
            action.argument = (double)parse_unsigned(name + 5, "pads=", 0, 255);
            options.sends_pads = 1;
        } else usage_error("unknown script action \"%s\"", name);
        options.script_attaches |= action.kind == ACTION_ATTACH;
        options.actions = grow_or_die(options.actions, (size_t)(options.action_count + 1) * sizeof *options.actions);
        int slot = options.action_count++;
        while (slot > 0 && options.actions[slot - 1].at_seconds > action.at_seconds) {
            options.actions[slot] = options.actions[slot - 1];
            slot--;
        }
        options.actions[slot] = action;
    }
    free(copy);
}

static const struct { const char *name; uint64_t button; int axis, sign; } key_names[] = {
    {"A", DM_BTN_A, -1, 0}, {"B", DM_BTN_B, -1, 0}, {"X", DM_BTN_X, -1, 0}, {"Y", DM_BTN_Y, -1, 0},
    {"LS", DM_BTN_LS, -1, 0}, {"RS", DM_BTN_RS, -1, 0}, {"L", DM_BTN_L, -1, 0}, {"R", DM_BTN_R, -1, 0},
    {"ZL", DM_BTN_ZL, -1, 0}, {"ZR", DM_BTN_ZR, -1, 0}, {"Plus", DM_BTN_PLUS, -1, 0}, {"Minus", DM_BTN_MINUS, -1, 0},
    {"Left", DM_BTN_LEFT, -1, 0}, {"Up", DM_BTN_UP, -1, 0}, {"Right", DM_BTN_RIGHT, -1, 0}, {"Down", DM_BTN_DOWN, -1, 0},
    {"Shake", DM_BTN_SHAKE, -1, 0},
    {"LLeft", 0, 0, -1}, {"LRight", 0, 0, 1}, {"LUp", 0, 1, 1}, {"LDown", 0, 1, -1},
    {"RLeft", 0, 2, -1}, {"RRight", 0, 2, 1}, {"RUp", 0, 3, 1}, {"RDown", 0, 3, -1},
};

static void add_key_step(const key_step *step) {
    options.keys = grow_or_die(options.keys, (size_t)(options.key_count + 1) * sizeof *options.keys);
    int slot = options.key_count++;
    while (slot > 0 && options.keys[slot - 1].at_seconds > step->at_seconds) {
        options.keys[slot] = options.keys[slot - 1];
        slot--;
    }
    options.keys[slot] = *step;
}

static void parse_keys(const char *text) {
    char *copy = strdup(text), *cursor = NULL;
    for (char *item = strtok_r(copy, ", \t\n", &cursor); item; item = strtok_r(NULL, ", \t\n", &cursor)) {
        key_step step = {.hold_seconds = 0.15};
        snprintf(step.text, sizeof step.text, "%s", item);
        char *colon = strchr(item, ':');
        if (!colon) usage_error("the keys item \"%s\" is not T:keys", item);
        *colon = 0;
        char *end = NULL;
        step.at_seconds = strtod(item, &end);
        if (end == item || *end || !isfinite(step.at_seconds) || step.at_seconds < 0) usage_error("the keys time \"%s\" is not a number of seconds", item);
        char *names = colon + 1, *repeat = strchr(names, '*'), *hold = strchr(names, '~');
        int count = 1;
        double interval = 0;
        if (repeat) {
            *repeat = 0;
            if (sscanf(repeat + 1, "%d/%lf", &count, &interval) != 2 || count < 1 || interval <= 0) usage_error("the keys repeat \"%s\" is not *count/interval", repeat + 1);
        }
        if (hold) {
            *hold = 0;
            step.hold_seconds = strtod(hold + 1, &end);
            if (end == hold + 1 || *end || !isfinite(step.hold_seconds) || step.hold_seconds < 0) usage_error("the keys hold \"%s\" is not a number of seconds", hold + 1);
        }
        char *name_cursor = NULL;
        for (char *name = strtok_r(names, "+", &name_cursor); name; name = strtok_r(NULL, "+", &name_cursor)) {
            size_t k = 0;
            while (k < sizeof key_names / sizeof *key_names && strcmp(key_names[k].name, name)) k++;
            if (k == sizeof key_names / sizeof *key_names) usage_error("unknown key \"%s\" (A B X Y LS RS L R ZL ZR Plus Minus Left Up Right Down Shake, LLeft LUp LRight LDown, RLeft RUp RRight RDown)", name);
            step.buttons |= key_names[k].button;
            if (key_names[k].axis >= 0) step.axes[key_names[k].axis] = (int16_t)(key_names[k].sign * DM_STICK_MAX);
        }
        double first = step.at_seconds;
        for (int r = 0; r < count; r++) {
            step.at_seconds = first + r * interval;
            add_key_step(&step);
        }
    }
    free(copy);
    options.sends_pads |= options.key_count > 0;
}

static const char *next_value(int argc, char **argv, int *index) {
    if (*index + 1 >= argc) usage_error("%s needs a value", argv[*index]);
    return argv[++*index];
}

static void parse_options(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        const char *argument = argv[i];
        if (!strcmp(argument, "--once")) options.once = 1;
        else if (!strcmp(argument, "--verbose")) options.verbose = 1;
        else if (!strcmp(argument, "--help") || !strcmp(argument, "-h")) {
            print_usage(stdout);
            exit(0);
        } else if (!strcmp(argument, "--hello-version")) options.hello_version = (uint32_t)parse_unsigned(next_value(argc, argv, &i), "--hello-version", 0, UINT32_MAX);
        else if (!strcmp(argument, "--kbps")) options.kbps = (uint32_t)parse_unsigned(next_value(argc, argv, &i), "--kbps", 1, UINT32_MAX);
        else if (!strcmp(argument, "--size")) {
            const char *size = next_value(argc, argv, &i);
            int consumed = 0;
            if (sscanf(size, "%dx%d%n", &options.width, &options.height, &consumed) != 2 || size[consumed] || options.width < 1 || options.height < 1 ||
                options.width > UINT16_MAX || options.height > UINT16_MAX)
                usage_error("--size takes WxH, each from 1 to %d, not \"%s\"", UINT16_MAX, size);
        } else if (!strcmp(argument, "--codec")) {
            const char *codec = next_value(argc, argv, &i);
            if (!strcmp(codec, "avc1")) options.codec = DMS_AVC1;
            else if (!strcmp(codec, "hvc1")) options.codec = DMS_HVC1;
            else usage_error("--codec takes avc1 or hvc1, not \"%s\"", codec);
        } else if (!strcmp(argument, "--script")) parse_script(next_value(argc, argv, &i));
        else if (!strcmp(argument, "--keys")) parse_keys(next_value(argc, argv, &i));
        else if (argument[0] == '-' && argument[1]) usage_error("unknown option %s", argument);
        else if (!options.socket_path) options.socket_path = argument;
        else if (!options.output_prefix) options.output_prefix = argument;
        else usage_error("unexpected argument \"%s\"", argument);
    }
    if (!options.socket_path || !options.output_prefix || !*options.socket_path || !*options.output_prefix) usage_error("the socket path and the output prefix are required");
    if (strlen(options.socket_path) > DMS_SUN_PATH_MAX)
        usage_error("the socket path is %zu bytes, over the %d-byte sun_path limit: %s", strlen(options.socket_path), DMS_SUN_PATH_MAX, options.socket_path);
}

static FILE *open_output(const char *suffix) {
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s%s", options.output_prefix, suffix);
    FILE *file = fopen(path, "wb");
    if (!file) setup_error("cannot create %s: %s", path, strerror(errno));
    return file;
}

static void open_outputs(void) {
    video_file = open_output(options.codec == DMS_HVC1 ? ".h265" : ".h264");
    audio_file = open_output(".wav");
    video_rows = open_output(".tsv");
    audio_rows = open_output(".audio.tsv");
    write_wav_header();
    fputs("frame\tpresent_ns\tsent_ns\trecv_ns\thop_ms\tpresent_to_recv_ms\tbytes\tflags\tltr_token\tdecoded\n", video_rows);
    fputs("time_ns\tsent_ns\trecv_ns\thop_ms\tframes\n", audio_rows);
}

static void open_listener(void) {
    struct stat existing;
    if (!lstat(options.socket_path, &existing) && !S_ISSOCK(existing.st_mode)) setup_error("%s exists and is not a socket; the probe does not remove it", options.socket_path);
    if (unlink(options.socket_path) && errno != ENOENT) setup_error("cannot remove the old socket %s: %s", options.socket_path, strerror(errno));
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    strlcpy(address.sun_path, options.socket_path, sizeof address.sun_path);
    address.sun_len = (unsigned char)SUN_LEN(&address);
    int enabled = 1;
    listener_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (listener_fd < 0) setup_error("cannot create a Unix socket: %s", strerror(errno));
    setsockopt(listener_fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof enabled);
    if (bind(listener_fd, (struct sockaddr *)&address, address.sun_len)) setup_error("cannot bind %s: %s", options.socket_path, strerror(errno));
    if (listen(listener_fd, 1)) setup_error("cannot listen on %s: %s", options.socket_path, strerror(errno));
    int file_flags = fcntl(listener_fd, F_GETFL);
    if (file_flags < 0 || fcntl(listener_fd, F_SETFL, file_flags | O_NONBLOCK) < 0) setup_error("cannot make the listening socket non-blocking: %s", strerror(errno));
}

static void request_stop(int signal_number) { stop_signal = signal_number; }

static void flush_outputs(void) {
    fflush(video_file);
    fflush(audio_file);
    fflush(video_rows);
    fflush(audio_rows);
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    parse_options(argc, argv);
    open_outputs();
    warm_up_video_toolbox();
    open_listener();
    struct sigaction stop_action = {.sa_handler = request_stop};
    sigemptyset(&stop_action.sa_mask);
    sigaction(SIGINT, &stop_action, NULL);
    sigaction(SIGTERM, &stop_action, NULL);
    start_ns = now_ns();
    tally_restart(&window_tally, start_ns);
    tally_restart(&run_tally, start_ns);
    char codec[5];
    fourcc_text(options.codec, codec);
    note("listening on %s; ATTACH %dx%d %s %u kbit/s%s; writing %s.%s, .wav, .tsv and .audio.tsv", options.socket_path, options.width, options.height, codec, options.kbps,
         options.script_attaches ? " only when the script says" : " on each HELLO", options.output_prefix, options.codec == DMS_HVC1 ? "h265" : "h264");
    for (;;) {
        @autoreleasepool {
            if (stop_signal) {
                note("stopping on signal %d", (int)stop_signal);
                finish_run();
            }
            uint64_t now = now_ns();
            run_due_actions(now);
            keys_tick(now);
            pads_tick(now);
            if (first_connection_ns && now >= next_report_ns) {
                char label[32];
                snprintf(label, sizeof label, "t=%.1f", run_seconds(now));
                print_tally(label, &window_tally, now);
                tally_restart(&window_tally, now);
                next_report_ns += report_interval_ns;
                if (next_report_ns <= now) next_report_ns = now + report_interval_ns;
                flush_outputs();
            }
            if (connection.fd >= 0 && connection.stall_until_ns && now >= connection.stall_until_ns) {
                connection.stall_until_ns = 0;
                note("stall over: reading the socket again");
            }
            if (connection.fd >= 0 && connection.outgoing.length) flush_outgoing();
            if (connection.fd >= 0 && connection.ending) {
                close_connection(connection.end_reason);
                continue;
            }
            struct pollfd descriptor = {-1, 0, 0};
            nfds_t descriptor_count = 0;
            if (connection.fd < 0) {
                descriptor = (struct pollfd){listener_fd, POLLIN, 0};
                descriptor_count = 1;
            } else if (!connection.stall_until_ns) {
                descriptor = (struct pollfd){connection.fd, (short)(POLLIN | (connection.outgoing.length ? POLLOUT : 0)), 0};
                descriptor_count = 1;
            }
            if (poll(&descriptor, descriptor_count, POLL_TIMEOUT_MS) <= 0 || !descriptor_count) continue;
            if (connection.fd < 0) {
                accept_connection();
                continue;
            }
            if (descriptor.revents & (POLLIN | POLLHUP | POLLERR)) {
                read_available();
                process_incoming();
            }
            if (descriptor.revents & POLLOUT) flush_outgoing();
        }
    }
}
