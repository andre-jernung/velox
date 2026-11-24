"""Lossy WebP through libwebp's C API (ctypes), for the encoder settings
PIL does not offer: the filter type (0 simple, 1 normal), its strength
and sharpness."""
import ctypes as C
import ctypes.util

lib = C.CDLL(ctypes.util.find_library("webp") or "libwebp.so.7")
I = C.c_int
class Config(C.Structure):
    _fields_ = [(n, t) for n, t in [("lossless", I), ("quality", C.c_float), ("method", I), ("image_hint", I),
        ("target_size", I), ("target_PSNR", C.c_float), ("segments", I), ("sns_strength", I),
        ("filter_strength", I), ("filter_sharpness", I), ("filter_type", I), ("autofilter", I),
        ("alpha_compression", I), ("alpha_filtering", I), ("alpha_quality", I), ("pass_", I),
        ("show_compressed", I), ("preprocessing", I), ("partitions", I), ("partition_limit", I),
        ("emulate_jpeg_size", I), ("thread_level", I), ("low_memory", I), ("near_lossless", I),
        ("exact", I), ("use_delta_palette", I), ("use_sharp_yuv", I), ("qmin", I), ("qmax", I),
        ("pad", C.c_uint32 * 16)]]
W = C.CFUNCTYPE(I, C.c_void_p, C.c_size_t, C.c_void_p)
class Pic(C.Structure):
    _fields_ = [("use_argb", I), ("colorspace", I), ("width", I), ("height", I),
        ("y", C.c_void_p), ("u", C.c_void_p), ("v", C.c_void_p), ("y_stride", I), ("uv_stride", I),
        ("a", C.c_void_p), ("a_stride", I), ("pad1", C.c_uint32 * 2), ("argb", C.c_void_p),
        ("argb_stride", I), ("pad2", C.c_uint32 * 3), ("writer", C.c_void_p), ("custom_ptr", C.c_void_p),
        ("rest", C.c_uint8 * 512)]
class Mem(C.Structure):
    _fields_ = [("mem", C.c_void_p), ("size", C.c_size_t), ("max_size", C.c_size_t), ("pad", C.c_uint32 * 4)]
ABI = 0x020f
def encode(im, path, filter_type, strength, sharp=0, quality=75):
    cfg = Config()
    assert lib.WebPConfigInitInternal(C.byref(cfg), 0, C.c_float(quality), ABI)
    cfg.filter_type = filter_type; cfg.filter_strength = strength; cfg.filter_sharpness = sharp
    cfg.autofilter = 0
    assert lib.WebPValidateConfig(C.byref(cfg))
    pic = Pic()
    assert lib.WebPPictureInitInternal(C.byref(pic), ABI)
    pic.width, pic.height = im.size
    rgb = im.convert("RGB").tobytes()
    assert lib.WebPPictureImportRGB(C.byref(pic), rgb, im.size[0] * 3)
    mem = Mem()
    lib.WebPMemoryWriterInit(C.byref(mem))
    pic.writer = C.cast(lib.WebPMemoryWrite, C.c_void_p).value
    pic.custom_ptr = C.addressof(mem)
    assert lib.WebPEncode(C.byref(cfg), C.byref(pic))
    open(path, "wb").write(C.string_at(mem.mem, mem.size))
    lib.WebPPictureFree(C.byref(pic))
    lib.WebPMemoryWriterClear(C.byref(mem))
