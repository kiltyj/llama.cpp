#import "ggml-metal.h"

#import "ggml.h"

#import <Foundation/Foundation.h>

#import <Metal/Metal.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>

#ifdef GGML_METAL_NDEBUG
#define metal_printf(...)
#else
#define metal_printf(...) fprintf(stderr, __VA_ARGS__)
#endif

#define UNUSED(x) (void)(x)

struct ggml_metal_buffer {
    const char * name;

    void   * data;
    size_t   size;

    NSMutableArray *sys_buffers;
    NSMutableArray *sys_buffer_logical_sizes;
    id<MTLBuffer> arg_buffer;
};

struct ggml_metal_context {
    float * logits;

    id<MTLDevice>       device;
    id<MTLCommandQueue> queue;
    id<MTLLibrary>      library;

    int n_buffers;
    struct ggml_metal_buffer buffers[GGML_METAL_MAX_BUFFERS];

    // custom kernels
#define GGML_METAL_DECL_KERNEL(name) \
    id<MTLFunction>             function_##name; \
    id<MTLComputePipelineState> pipeline_##name

    id<MTLArgumentEncoder> buffer_arg_encoder;
    GGML_METAL_DECL_KERNEL(add);
    GGML_METAL_DECL_KERNEL(mul);
    GGML_METAL_DECL_KERNEL(mul_row); // TODO: avoid this extra kernel, instead extend the "mul" kernel to support broadcast
    GGML_METAL_DECL_KERNEL(scale);
    GGML_METAL_DECL_KERNEL(silu);
    GGML_METAL_DECL_KERNEL(relu);
    GGML_METAL_DECL_KERNEL(gelu);
    GGML_METAL_DECL_KERNEL(soft_max);
    GGML_METAL_DECL_KERNEL(diag_mask_inf);
    GGML_METAL_DECL_KERNEL(get_rows_f16);
    GGML_METAL_DECL_KERNEL(get_rows_q4_0);
    GGML_METAL_DECL_KERNEL(get_rows_q4_1);
    GGML_METAL_DECL_KERNEL(get_rows_q2_k);
    GGML_METAL_DECL_KERNEL(get_rows_q3_k);
    GGML_METAL_DECL_KERNEL(get_rows_q4_k);
    GGML_METAL_DECL_KERNEL(get_rows_q5_k);
    GGML_METAL_DECL_KERNEL(get_rows_q6_k);
    GGML_METAL_DECL_KERNEL(rms_norm);
    GGML_METAL_DECL_KERNEL(mul_mat_f16_f32);
    GGML_METAL_DECL_KERNEL(mul_mat_q4_0_f32);
    GGML_METAL_DECL_KERNEL(mul_mat_q4_1_f32);
    GGML_METAL_DECL_KERNEL(mul_mat_q2_k_f32);
    GGML_METAL_DECL_KERNEL(mul_mat_q3_k_f32);
    GGML_METAL_DECL_KERNEL(mul_mat_q4_k_f32);
    GGML_METAL_DECL_KERNEL(mul_mat_q5_k_f32);
    GGML_METAL_DECL_KERNEL(mul_mat_q6_k_f32);
    GGML_METAL_DECL_KERNEL(rope);
    GGML_METAL_DECL_KERNEL(cpy_f32_f16);
    GGML_METAL_DECL_KERNEL(cpy_f32_f32);

#undef GGML_METAL_DECL_KERNEL
};

// MSL code
// TODO: move the contents here when ready
//       for now it is easier to work in a separate file
static NSString * const msl_library_source = @"see metal.metal";

// Here to assist with NSBundle Path Hack
@interface GGMLMetalClass : NSObject
@end
@implementation GGMLMetalClass
@end

struct ggml_metal_context * ggml_metal_init(void) {
    fprintf(stderr, "%s: allocating\n", __func__);

    struct ggml_metal_context * ctx = malloc(sizeof(struct ggml_metal_context));

    ctx->device = MTLCreateSystemDefaultDevice();
    ctx->queue  = [ctx->device newCommandQueue];

    // determine if we can use MPS
    if (MPSSupportsMTLDevice(ctx->device)) {
        fprintf(stderr, "%s: using MPS\n", __func__);
    } else {
        fprintf(stderr, "%s: not using MPS\n", __func__);
        GGML_ASSERT(false && "MPS not supported");
    }

#if 0
    // compile from source string and show compile log
    {
        NSError * error = nil;

        ctx->library = [ctx->device newLibraryWithSource:msl_library_source options:nil error:&error];
        if (error) {
            fprintf(stderr, "%s: error: %s\n", __func__, [[error description] UTF8String]);
            exit(1);
        }
    }
#else
    UNUSED(msl_library_source);

    // read the source from "ggml-metal.metal" into a string and use newLibraryWithSource
    {
        NSError * error = nil;

        //NSString * path = [[NSBundle mainBundle] pathForResource:@"../../examples/metal/metal" ofType:@"metal"];
        NSBundle * bundle = [NSBundle bundleForClass:[GGMLMetalClass class]];
        NSString * path = [bundle pathForResource:@"ggml-metal" ofType:@"metal"];
        fprintf(stderr, "%s: loading '%s'\n", __func__, [path UTF8String]);

        NSString * src  = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
        if (error) {
            fprintf(stderr, "%s: error: %s\n", __func__, [[error description] UTF8String]);
            exit(1);
        }

        ctx->library = [ctx->device newLibraryWithSource:src options:nil error:&error];
        if (error) {
            fprintf(stderr, "%s: error: %s\n", __func__, [[error description] UTF8String]);
            exit(1);
        }
    }
#endif

    // load kernels
    {
#define GGML_METAL_ADD_KERNEL(name) \
        ctx->function_##name = [ctx->library newFunctionWithName:@"kernel_"#name]; \
        ctx->pipeline_##name = [ctx->device newComputePipelineStateWithFunction:ctx->function_##name error:nil]; \
        fprintf(stderr, "%s: loaded %-32s %16p\n", __func__, "kernel_"#name, (void *) ctx->pipeline_##name);

        GGML_METAL_ADD_KERNEL(add);
        GGML_METAL_ADD_KERNEL(mul);
        GGML_METAL_ADD_KERNEL(mul_row);
        GGML_METAL_ADD_KERNEL(scale);
        GGML_METAL_ADD_KERNEL(silu);
        GGML_METAL_ADD_KERNEL(relu);
        GGML_METAL_ADD_KERNEL(gelu);
        GGML_METAL_ADD_KERNEL(soft_max);
        GGML_METAL_ADD_KERNEL(diag_mask_inf);
        GGML_METAL_ADD_KERNEL(get_rows_f16);
        GGML_METAL_ADD_KERNEL(get_rows_q4_0);
        GGML_METAL_ADD_KERNEL(get_rows_q4_1);
        GGML_METAL_ADD_KERNEL(get_rows_q2_k);
        GGML_METAL_ADD_KERNEL(get_rows_q3_k);
        GGML_METAL_ADD_KERNEL(get_rows_q4_k);
        GGML_METAL_ADD_KERNEL(get_rows_q5_k);
        GGML_METAL_ADD_KERNEL(get_rows_q6_k);
        GGML_METAL_ADD_KERNEL(rms_norm);
        GGML_METAL_ADD_KERNEL(mul_mat_f16_f32);
        GGML_METAL_ADD_KERNEL(mul_mat_q4_0_f32);
        GGML_METAL_ADD_KERNEL(mul_mat_q4_1_f32);
        GGML_METAL_ADD_KERNEL(mul_mat_q2_k_f32);
        GGML_METAL_ADD_KERNEL(mul_mat_q3_k_f32);
        GGML_METAL_ADD_KERNEL(mul_mat_q4_k_f32);
        GGML_METAL_ADD_KERNEL(mul_mat_q5_k_f32);
        GGML_METAL_ADD_KERNEL(mul_mat_q6_k_f32);
        GGML_METAL_ADD_KERNEL(rope);
        GGML_METAL_ADD_KERNEL(cpy_f32_f16);
        GGML_METAL_ADD_KERNEL(cpy_f32_f32);
        ctx->buffer_arg_encoder = [[ctx->library newFunctionWithName:@"kernel_add"] newArgumentEncoderWithBufferIndex:0];

#undef GGML_METAL_ADD_KERNEL
    }

    return ctx;
}

void ggml_metal_free(struct ggml_metal_context * ctx) {
    fprintf(stderr, "%s: deallocating\n", __func__);

    free(ctx);
}

// finds the Metal buffer that contains the tensor data on the GPU device
// the assumption is that there is 1-to-1 mapping between the host and device memory buffers, so we can find the
// Metal buffer based on the host memory pointer
//
static struct ggml_metal_buffer *ggml_metal_get_buffer(struct ggml_metal_context * ctx, struct ggml_tensor * t, size_t * offs) {
    //fprintf(stderr, "%s: data tensor '%16s', offs_data = %8ld, offs_eval = %8ld, offs_cach = %8ld\n", __func__, t->name, offs_data, offs_eval, offs_cach);

    for (int i = 0; i < ctx->n_buffers; ++i) {
        const int64_t ioffs = (int64_t) t->data - (int64_t) ctx->buffers[i].data;

        if (ioffs >= 0 && ioffs < (int64_t) ctx->buffers[i].size) {
            *offs = (size_t) ioffs;

            //fprintf(stderr, "%s: '%s' tensor '%16s', offs = %8ld\n", __func__, ctx->buffers[i].name, t->name, *offs);

            return &ctx->buffers[i];
        }
    }

    fprintf(stderr, "%s: error: buffer is nil\n", __func__);

    return nil;
}

static id<MTLBuffer> ggml_metal_create_arg_buffer(struct ggml_metal_context * ctx, struct ggml_metal_buffer *buffer) {
    NSUInteger buffer_count = buffer->sys_buffers.count;
    id<MTLArgumentEncoder> arg_encoder = ctx->buffer_arg_encoder;
    NSUInteger arg_buffer_length = buffer_count * arg_encoder.encodedLength;
    id<MTLBuffer> arg_buffer = [ctx->device newBufferWithLength:arg_buffer_length options:MTLResourceStorageModeShared];

    for (NSUInteger i = 0; i < buffer_count; i++) {
        [arg_encoder setArgumentBuffer:arg_buffer offset:arg_encoder.encodedLength * i];
        id<MTLBuffer> sys_buffer = [buffer->sys_buffers objectAtIndex:i];
        [arg_encoder setBuffer:sys_buffer offset: 0 atIndex:0];
        uint64_t *length_addr = [arg_encoder constantDataAtIndex:1];
        *length_addr = [[buffer->sys_buffer_logical_sizes objectAtIndex:i] unsignedLongLongValue];
    }

    return arg_buffer;
}

bool ggml_metal_add_buffer(
        struct ggml_metal_context * ctx,
                     const char * name,
                           void * data,
                         size_t   size) {
    if (ctx->n_buffers >= GGML_METAL_MAX_BUFFERS) {
        fprintf(stderr, "%s: too many buffers\n", __func__);
        return false;
    }

    if (data) {
        // verify that the buffer does not overlap with any of the existing buffers
        for (int i = 0; i < ctx->n_buffers; ++i) {
            const int64_t ioffs = (int64_t) data - (int64_t) ctx->buffers[i].data;

            if (ioffs >= 0 && ioffs < (int64_t) ctx->buffers[i].size) {
                fprintf(stderr, "%s: error: buffer '%s' overlaps with '%s'\n", __func__, name, ctx->buffers[i].name);
                return false;
            }
        }

        size_t page_size = getpagesize();
        size_t sys_max_buffer_size = ctx->device.maxBufferLength;

        // Make sure total size is page-aligned
        size_t total_aligned_size = size;
        if ((total_aligned_size % page_size) != 0) {
            total_aligned_size += (page_size - (total_aligned_size % page_size));
        }

        // Make sure chunk size is page-aligned
        size_t max_chunk_size = sys_max_buffer_size / 2;
        if ((max_chunk_size % page_size) != 0) {
            max_chunk_size += (page_size - (max_chunk_size % page_size));
        }

        size_t chunk_offset = 0;

        struct ggml_metal_buffer *buffer = &ctx->buffers[ctx->n_buffers];
        buffer->name = name;
        buffer->data = data;
        buffer->size = size;
        buffer->sys_buffers = [[NSMutableArray alloc] init];
        buffer->sys_buffer_logical_sizes = [[NSMutableArray alloc] init];

        while (total_aligned_size > 0) {
            size_t chunk_logical_size = (max_chunk_size > total_aligned_size) ? total_aligned_size : max_chunk_size;
            size_t sys_buffer_size = (sys_max_buffer_size > total_aligned_size) ? total_aligned_size : sys_max_buffer_size;
            void *chunk = (uint8_t *) data + chunk_offset;
            id<MTLBuffer> sys_buffer = [ctx->device newBufferWithBytesNoCopy:chunk length:sys_buffer_size options:MTLResourceStorageModeShared deallocator:nil];

            if (sys_buffer == nil) {
                fprintf(stderr, "%s: failed to allocate '%-16s' buffer, size = %8.2f MB\n", __func__, name,
                        sys_buffer_size / 1024.0 / 1024.0);
                return false;
            } else {
                fprintf(stderr, "%s: allocated '%-16s' buffer, sys size = %8.2f MB, logical size = %8.2f MB, max: %zu\n", __func__, name,
                        sys_buffer_size / 1024.0 / 1024.0, chunk_logical_size / 1024.0 / 1024.0, sys_max_buffer_size);
            }
            [buffer->sys_buffers addObject:sys_buffer];
            [buffer->sys_buffer_logical_sizes addObject:[NSNumber numberWithUnsignedLongLong:chunk_logical_size]];
            total_aligned_size -= chunk_logical_size;
            chunk_offset += chunk_logical_size;
        }

        buffer->arg_buffer = ggml_metal_create_arg_buffer(ctx, buffer);
        ++ctx->n_buffers;
    }

    return true;
}

static void ggml_metal_encode_arg_buffer(
        struct ggml_metal_buffer * buffer,
        uint64_t offset,
        id<MTLComputeCommandEncoder> encoder,
        NSUInteger *bind_point_addr,
        MTLResourceUsage usage) {
    NSUInteger buffer_count = buffer->sys_buffers.count;
    [encoder setBuffer:buffer->arg_buffer offset: 0 atIndex: *bind_point_addr];
    *bind_point_addr = *bind_point_addr + 1;
    for (NSUInteger i = 0; i < buffer_count; i++) {
        [encoder useResource:[buffer->sys_buffers objectAtIndex:i] usage:usage];
    }
    [encoder setBytes:&offset length:sizeof(offset) atIndex:*bind_point_addr];
    *bind_point_addr = *bind_point_addr + 1;
}

void ggml_metal_graph_compute(
        struct ggml_metal_context * ctx,
             struct ggml_cgraph * gf) {
    metal_printf("%s: evaluating graph\n", __func__);

    size_t offs_src0 = 0;
    size_t offs_src1 = 0;
    size_t offs_dst  = 0;

    id<MTLCommandBuffer> command_buffer  = [ctx->queue commandBuffer];
    id<MTLComputeCommandEncoder> encoder = nil;

    for (int i = 0; i < gf->n_nodes; ++i) {
        //metal_printf("%s: encoding node %3d, op = %8s\n", __func__, i, ggml_op_name(gf->nodes[i]->op));

        struct ggml_tensor * src0 = gf->nodes[i]->src0;
        struct ggml_tensor * src1 = gf->nodes[i]->src1;
        struct ggml_tensor * dst  = gf->nodes[i];

        const int64_t  ne00 = src0 ? src0->ne[0] : 0;
        const int64_t  ne01 = src0 ? src0->ne[1] : 0;
        const int64_t  ne02 = src0 ? src0->ne[2] : 0;
        const int64_t  ne03 = src0 ? src0->ne[3] : 0;

        const uint64_t nb00 = src0 ? src0->nb[0] : 0;
        const uint64_t nb01 = src0 ? src0->nb[1] : 0;
        const uint64_t nb02 = src0 ? src0->nb[2] : 0;
        const uint64_t nb03 = src0 ? src0->nb[3] : 0;

        const int64_t  ne10 = src1 ? src1->ne[0] : 0;
        const int64_t  ne11 = src1 ? src1->ne[1] : 0;
        const int64_t  ne12 = src1 ? src1->ne[2] : 0;
        const int64_t  ne13 = src1 ? src1->ne[3] : 0; UNUSED(ne13);

        const uint64_t nb10 = src1 ? src1->nb[0] : 0;
        const uint64_t nb11 = src1 ? src1->nb[1] : 0;
        const uint64_t nb12 = src1 ? src1->nb[2] : 0;
        const uint64_t nb13 = src1 ? src1->nb[3] : 0; UNUSED(nb13);

        const int64_t  ne0  = dst ? dst->ne[0] : 0;
        const int64_t  ne1  = dst ? dst->ne[1] : 0;
        const int64_t  ne2  = dst ? dst->ne[2] : 0;
        const int64_t  ne3  = dst ? dst->ne[3] : 0;

        const uint64_t nb0  = dst ? dst->nb[0] : 0;
        const uint64_t nb1  = dst ? dst->nb[1] : 0;
        const uint64_t nb2  = dst ? dst->nb[2] : 0;
        const uint64_t nb3  = dst ? dst->nb[3] : 0;

        const enum ggml_type src0t = src0 ? src0->type : GGML_TYPE_COUNT;
        const enum ggml_type src1t = src1 ? src1->type : GGML_TYPE_COUNT;
        const enum ggml_type dstt  = dst  ? dst->type  : GGML_TYPE_COUNT;

        struct ggml_metal_buffer *buffer_src0 = src0 ? ggml_metal_get_buffer(ctx, src0, &offs_src0) : nil;
        struct ggml_metal_buffer *buffer_src1 = src1 ? ggml_metal_get_buffer(ctx, src1, &offs_src1) : nil;
        struct ggml_metal_buffer *buffer_dst  = dst  ? ggml_metal_get_buffer(ctx, dst,  &offs_dst)  : nil;

        //metal_printf("%s: op - %s\n", __func__, ggml_op_name(dst->op));
        //if (src0) {
        //    metal_printf("%s: src0 - %4s [%5lld, %5lld, %5lld], %d, %s\n", __func__, ggml_type_name(src0t), ne00, ne01, ne02,
        //            ggml_is_contiguous(src0), src0->name);
        //}
        //if (src1) {
        //    metal_printf("%s: src1 - %4s [%5lld, %5lld, %5lld], %d, %s\n", __func__, ggml_type_name(src1t), ne10, ne11, ne12,
        //            ggml_is_contiguous(src1), src1->name);
        //}
        //if (dst) {
        //    metal_printf("%s: dst  - %4s [%5lld, %5lld, %5lld], 1, %s\n",  __func__, ggml_type_name(dstt),  ne0,  ne1,  ne2,
        //            dst->name);
        //}

        NSUInteger next_bind_point = 0;
#define ENCODE_BUFFER(name, usage) \
    ggml_metal_encode_arg_buffer(buffer_##name, offs_##name, encoder, &next_bind_point, MTLResourceUsage##usage)

        switch (dst->op) {
            case GGML_OP_RESHAPE:
            case GGML_OP_VIEW:
            case GGML_OP_TRANSPOSE:
            case GGML_OP_PERMUTE:
                {
                    // noop
                } break;
            case GGML_OP_ADD:
                {
                    if (encoder == nil) {
                        encoder = [command_buffer computeCommandEncoder];
                    }

                    [encoder setComputePipelineState:ctx->pipeline_add];
                    ENCODE_BUFFER(src0, Read);
                    ENCODE_BUFFER(src1, Read);
                    ENCODE_BUFFER(dst, Write);

                    const int64_t n = ggml_nelements(dst);

                    [encoder dispatchThreadgroups:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
                } break;
            case GGML_OP_MUL:
                {
                    if (encoder == nil) {
                        encoder = [command_buffer computeCommandEncoder];
                    }

                    if (ggml_nelements(src1) == ne10) {
                        // src1 is a row
                        [encoder setComputePipelineState:ctx->pipeline_mul_row];
                    } else {
                        [encoder setComputePipelineState:ctx->pipeline_mul];
                    }
                    ENCODE_BUFFER(src0, Read);
                    ENCODE_BUFFER(src1, Read);
                    ENCODE_BUFFER(dst, Write);
                    [encoder setBytes:&ne00 length:sizeof(ne00) atIndex:next_bind_point++];

                    const int64_t n = ggml_nelements(dst);

                    [encoder dispatchThreadgroups:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
                } break;
            case GGML_OP_SCALE:
                {
                    if (encoder == nil) {
                        encoder = [command_buffer computeCommandEncoder];
                    }

                    const float scale = *(const float *) src1->data;

                    [encoder setComputePipelineState:ctx->pipeline_scale];
                    ENCODE_BUFFER(src0, Read);
                    ENCODE_BUFFER(dst, Write);
                    [encoder setBytes:&scale length:sizeof(scale) atIndex:next_bind_point++];

                    const int64_t n = ggml_nelements(dst);

                    [encoder dispatchThreadgroups:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
                } break;
            case GGML_OP_SILU:
                {
                    if (encoder == nil) {
                        encoder = [command_buffer computeCommandEncoder];
                    }

                    [encoder setComputePipelineState:ctx->pipeline_silu];
                    ENCODE_BUFFER(src0, Read);
                    ENCODE_BUFFER(dst, Write);

                    const int64_t n = ggml_nelements(dst);

                    [encoder dispatchThreadgroups:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
                } break;
            case GGML_OP_RELU:
                {
                    if (encoder == nil) {
                        encoder = [command_buffer computeCommandEncoder];
                    }

                    [encoder setComputePipelineState:ctx->pipeline_relu];
                    ENCODE_BUFFER(src0, Read);
                    ENCODE_BUFFER(dst, Write);

                    const int64_t n = ggml_nelements(dst);

                    [encoder dispatchThreadgroups:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
                } break;
            case GGML_OP_GELU:
            {
                    if (encoder == nil) {
                        encoder = [command_buffer computeCommandEncoder];
                    }

                    [encoder setComputePipelineState:ctx->pipeline_gelu];
                    ENCODE_BUFFER(src0, Read);
                    ENCODE_BUFFER(dst, Write);

                    const int64_t n = ggml_nelements(dst);

                    [encoder dispatchThreadgroups:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
            } break;
            case GGML_OP_SOFT_MAX:
                {
                    if (encoder == nil) {
                        encoder = [command_buffer computeCommandEncoder];
                    }

                    const int nth = 32;

                    [encoder setComputePipelineState:ctx->pipeline_soft_max];
                    ENCODE_BUFFER(src0, Read);
                    ENCODE_BUFFER(dst, Write);
                    [encoder setBytes:&ne00 length:sizeof(ne00) atIndex:next_bind_point++];
                    [encoder setBytes:&ne01 length:sizeof(ne01) atIndex:next_bind_point++];
                    [encoder setBytes:&ne02 length:sizeof(ne02) atIndex:next_bind_point++];
                    [encoder setThreadgroupMemoryLength:nth*sizeof(float) atIndex:0];

                    [encoder dispatchThreadgroups:MTLSizeMake(ne01, ne02, ne03) threadsPerThreadgroup:MTLSizeMake(nth, 1, 1)];
                } break;
            case GGML_OP_DIAG_MASK_INF:
                {
                    if (encoder == nil) {
                        encoder = [command_buffer computeCommandEncoder];
                    }

                    const int n_past = ((int32_t *)(src1->data))[0];

                    [encoder setComputePipelineState:ctx->pipeline_diag_mask_inf];
                    ENCODE_BUFFER(src0, Read);
                    ENCODE_BUFFER(dst, Write);
                    [encoder setBytes:&ne00   length:sizeof(ne00) atIndex:next_bind_point++];
                    [encoder setBytes:&ne01   length:sizeof(ne01) atIndex:next_bind_point++];
                    [encoder setBytes:&n_past length:sizeof(int)  atIndex:next_bind_point++];

                    [encoder dispatchThreadgroups:MTLSizeMake(ne00, ne01, ne02) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
                } break;
            case GGML_OP_MUL_MAT:
                {
                    // TODO: needs to be updated after PR: https://github.com/ggerganov/ggml/pull/224

                    GGML_ASSERT(ne00 == ne10);
                    GGML_ASSERT(ne02 == ne12);

                    if (ggml_is_contiguous(src0) &&
                        ggml_is_contiguous(src1) &&
                        (src0t == GGML_TYPE_F32 || src0t == GGML_TYPE_F16) && ne11 > 1) {

                        // TODO: only works for buffers which fit within system limit
                        id<MTLBuffer> id_src0 = buffer_src0 ? [buffer_src0->sys_buffers objectAtIndex:0] : nil;
                        id<MTLBuffer> id_src1 = buffer_src1 ? [buffer_src1->sys_buffers objectAtIndex:0] : nil;
                        id<MTLBuffer> id_dst  = buffer_dst ? [buffer_dst->sys_buffers objectAtIndex:0] : nil;

                        if (encoder != nil) {
                            [encoder endEncoding];
                            encoder = nil;
                        }

                        MPSDataType src0dt = src0t == GGML_TYPE_F32 ? MPSDataTypeFloat32 : MPSDataTypeFloat16;
                        MPSDataType src1dt = src1t == GGML_TYPE_F32 ? MPSDataTypeFloat32 : MPSDataTypeFloat16;

                        // for F32 x F32 we use MPS
                        MPSMatrixDescriptor * desc0 = [MPSMatrixDescriptor
                            matrixDescriptorWithRows:ne01 columns:ne00 rowBytes:src0->nb[1] dataType:src0dt];

                        MPSMatrixDescriptor * desc1 = [MPSMatrixDescriptor
                            matrixDescriptorWithRows:ne11 columns:ne10 rowBytes:src1->nb[1] dataType:src1dt];

                        MPSMatrixDescriptor * desc  = [MPSMatrixDescriptor
                            matrixDescriptorWithRows:ne1 columns:ne0 rowBytes:dst->nb[1] dataType:MPSDataTypeFloat32];

                        MPSMatrixMultiplication * mul = [[MPSMatrixMultiplication alloc]
                            initWithDevice:ctx->device transposeLeft:false transposeRight:true
                                resultRows:ne11 resultColumns:ne01 interiorColumns:ne00 alpha:1.0 beta:0.0];

                        // we need to do ne02 multiplications
                        // TODO: is there a way to do this in parallel - currently very slow ..
                        // TODO: might be possible to offload part of the computation to ANE using Accelerate's CBLAS
                        for (int64_t i02 = 0; i02 < ne02; ++i02) {
                            size_t offs_src0_cur = offs_src0 + i02*nb02;
                            size_t offs_src1_cur = offs_src1 + i02*nb12;
                            size_t offs_dst_cur  = offs_dst  + i02*nb2;

                            MPSMatrix * mat_src0 = [[MPSMatrix alloc] initWithBuffer:id_src0 offset:offs_src0_cur descriptor:desc0];
                            MPSMatrix * mat_src1 = [[MPSMatrix alloc] initWithBuffer:id_src1 offset:offs_src1_cur descriptor:desc1];
                            MPSMatrix * mat_dst  = [[MPSMatrix alloc] initWithBuffer:id_dst  offset:offs_dst_cur  descriptor:desc ];

                            [mul encodeToCommandBuffer:command_buffer leftMatrix:mat_src1 rightMatrix:mat_src0 resultMatrix:mat_dst];
                        }
                    } else {
                        if (encoder == nil) {
                            encoder = [command_buffer computeCommandEncoder];
                        }

                        int nth0 = 32;
                        int nth1 = 1;

                        // use custom matrix x vector kernel
                        switch (src0t) {
                            case GGML_TYPE_F16:
                                {
                                    GGML_ASSERT(ne02 == ne12);

                                    nth0 = 64;
                                    nth1 = 1;
                                    [encoder setComputePipelineState:ctx->pipeline_mul_mat_f16_f32];
                                } break;
                            case GGML_TYPE_Q4_0:
                                {
                                    GGML_ASSERT(ne02 == 1);
                                    GGML_ASSERT(ne12 == 1);

                                    nth0 = 8;
                                    nth1 = 8;
                                    [encoder setComputePipelineState:ctx->pipeline_mul_mat_q4_0_f32];
                                } break;
                            case GGML_TYPE_Q4_1:
                                {
                                    GGML_ASSERT(ne02 == 1);
                                    GGML_ASSERT(ne12 == 1);

                                    nth0 = 8;
                                    nth1 = 8;
                                    [encoder setComputePipelineState:ctx->pipeline_mul_mat_q4_1_f32];
                                } break;
                            case GGML_TYPE_Q2_K:
                                {
                                    GGML_ASSERT(ne02 == 1);
                                    GGML_ASSERT(ne12 == 1);

                                    nth0 = 4;
                                    nth1 = 16;
                                    [encoder setComputePipelineState:ctx->pipeline_mul_mat_q2_k_f32];
                                } break;
                            case GGML_TYPE_Q3_K:
                                {
                                    GGML_ASSERT(ne02 == 1);
                                    GGML_ASSERT(ne12 == 1);

                                    nth0 = 4;
                                    nth1 = 16;
                                    [encoder setComputePipelineState:ctx->pipeline_mul_mat_q3_k_f32];
                                } break;
                            case GGML_TYPE_Q4_K:
                                {
                                    GGML_ASSERT(ne02 == 1);
                                    GGML_ASSERT(ne12 == 1);

                                    nth0 = 4;
                                    nth1 = 16;
                                    [encoder setComputePipelineState:ctx->pipeline_mul_mat_q4_k_f32];
                                } break;
                            case GGML_TYPE_Q5_K:
                                {
                                    GGML_ASSERT(ne02 == 1);
                                    GGML_ASSERT(ne12 == 1);

                                    nth0 = 4;
                                    nth1 = 16;
                                    [encoder setComputePipelineState:ctx->pipeline_mul_mat_q5_k_f32];
                                } break;
                            case GGML_TYPE_Q6_K:
                                {
                                    GGML_ASSERT(ne02 == 1);
                                    GGML_ASSERT(ne12 == 1);

                                    nth0 = 4;
                                    nth1 = 16;
                                    [encoder setComputePipelineState:ctx->pipeline_mul_mat_q6_k_f32];
                                } break;
                            default:
                                {
                                    fprintf(stderr, "Asserting on type %d\n",(int)src0t);
                                    GGML_ASSERT(false && "not implemented");
                                }
                        };


                        ENCODE_BUFFER(src0, Read);
                        ENCODE_BUFFER(src1, Read);
                        ENCODE_BUFFER(dst, Write);
                        [encoder setBytes:&ne00 length:sizeof(ne00) atIndex:next_bind_point++];
                        [encoder setBytes:&ne01 length:sizeof(ne01) atIndex:next_bind_point++];
                        [encoder setBytes:&nb00 length:sizeof(nb00) atIndex:next_bind_point++];
                        [encoder setBytes:&nb01 length:sizeof(nb01) atIndex:next_bind_point++];
                        [encoder setBytes:&nb02 length:sizeof(nb02) atIndex:next_bind_point++];
                        [encoder setBytes:&ne10 length:sizeof(ne10) atIndex:next_bind_point++];
                        [encoder setBytes:&ne11 length:sizeof(ne11) atIndex:next_bind_point++];
                        [encoder setBytes:&nb10 length:sizeof(nb10) atIndex:next_bind_point++];
                        [encoder setBytes:&nb11 length:sizeof(nb11) atIndex:next_bind_point++];
                        [encoder setBytes:&nb12 length:sizeof(nb12) atIndex:next_bind_point++];
                        [encoder setBytes:&ne0  length:sizeof(ne0)  atIndex:next_bind_point++];
                        [encoder setBytes:&ne1  length:sizeof(ne1)  atIndex:next_bind_point++];

                        if (src0t == GGML_TYPE_Q4_0 || src0t == GGML_TYPE_Q4_1) {
                            [encoder setThreadgroupMemoryLength:nth0*nth1*sizeof(float) atIndex:0];
                            [encoder dispatchThreadgroups:MTLSizeMake(ne01, ne11, 1) threadsPerThreadgroup:MTLSizeMake(nth0, nth1, 1)];
                        }
                        else if (src0t == GGML_TYPE_Q2_K ||
                                 src0t == GGML_TYPE_Q3_K ||
                                 src0t == GGML_TYPE_Q4_K ||
                                 src0t == GGML_TYPE_Q5_K ||
                                 src0t == GGML_TYPE_Q6_K) {
                            [encoder setThreadgroupMemoryLength:nth0*nth1*sizeof(float) atIndex:0];
                            [encoder dispatchThreadgroups:MTLSizeMake(ne01, 1, 1) threadsPerThreadgroup:MTLSizeMake(nth0, nth1, 1)];
                        } else {
                            [encoder setThreadgroupMemoryLength:nth0*sizeof(float) atIndex:0];
                            [encoder dispatchThreadgroups:MTLSizeMake(ne01, ne11, ne12) threadsPerThreadgroup:MTLSizeMake(nth0, nth1, 1)];
                        }
                    }
                } break;
            case GGML_OP_GET_ROWS:
                {
                    if (encoder == nil) {
                        encoder = [command_buffer computeCommandEncoder];
                    }

                    switch (src0->type) {
                        case GGML_TYPE_F16:  [encoder setComputePipelineState:ctx->pipeline_get_rows_f16]; break;
                        case GGML_TYPE_Q4_0: [encoder setComputePipelineState:ctx->pipeline_get_rows_q4_0]; break;
                        case GGML_TYPE_Q4_1: [encoder setComputePipelineState:ctx->pipeline_get_rows_q4_1]; break;
                        case GGML_TYPE_Q2_K: [encoder setComputePipelineState:ctx->pipeline_get_rows_q2_k]; break;
                        case GGML_TYPE_Q3_K: [encoder setComputePipelineState:ctx->pipeline_get_rows_q3_k]; break;
                        case GGML_TYPE_Q4_K: [encoder setComputePipelineState:ctx->pipeline_get_rows_q4_k]; break;
                        case GGML_TYPE_Q5_K: [encoder setComputePipelineState:ctx->pipeline_get_rows_q5_k]; break;
                        case GGML_TYPE_Q6_K: [encoder setComputePipelineState:ctx->pipeline_get_rows_q6_k]; break;
                        default: GGML_ASSERT(false && "not implemented");
                    }

                    ENCODE_BUFFER(src0, Read);
                    ENCODE_BUFFER(src1, Read);
                    ENCODE_BUFFER(dst, Write);
                    [encoder setBytes:&(src0->ne[0]) length:sizeof( int64_t) atIndex:next_bind_point++];
                    [encoder setBytes:&(src0->nb[1]) length:sizeof(uint64_t) atIndex:next_bind_point++];
                    [encoder setBytes:&(dst->nb[1])  length:sizeof(uint64_t) atIndex:next_bind_point++];

                    const int64_t n = ggml_nelements(src1);

                    [encoder dispatchThreadgroups:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
                } break;
            case GGML_OP_RMS_NORM:
                {
                    if (encoder == nil) {
                        encoder = [command_buffer computeCommandEncoder];
                    }

                    const float eps = 1e-6f;

                    const int nth = 256;

                    [encoder setComputePipelineState:ctx->pipeline_rms_norm];
                    ENCODE_BUFFER(src0, Read);
                    ENCODE_BUFFER(dst, Write);
                    [encoder setBytes:&ne00 length:sizeof( int64_t) atIndex:next_bind_point++];
                    [encoder setBytes:&nb01 length:sizeof(uint64_t) atIndex:next_bind_point++];
                    [encoder setBytes:&eps  length:sizeof(   float) atIndex:next_bind_point++];
                    [encoder setThreadgroupMemoryLength:nth*sizeof(float) atIndex:0];

                    const int64_t nrows = ggml_nrows(src0);

                    [encoder dispatchThreadgroups:MTLSizeMake(nrows, 1, 1) threadsPerThreadgroup:MTLSizeMake(nth, 1, 1)];
                } break;
            case GGML_OP_ROPE:
                {
                    if (encoder == nil) {
                        encoder = [command_buffer computeCommandEncoder];
                    }

                    const int n_dims = ((int32_t *) src1->data)[1];
                    const int mode   = ((int32_t *) src1->data)[2];

                    const int n_past = ((int32_t *)(src1->data))[0];

                    [encoder setComputePipelineState:ctx->pipeline_rope];
                    ENCODE_BUFFER(src0, Read);
                    ENCODE_BUFFER(dst, Write);
                    [encoder setBytes:&ne00   length:sizeof( int64_t) atIndex:next_bind_point++];
                    [encoder setBytes:&ne01   length:sizeof( int64_t) atIndex:next_bind_point++];
                    [encoder setBytes:&ne02   length:sizeof( int64_t) atIndex:next_bind_point++];
                    [encoder setBytes:&ne03   length:sizeof( int64_t) atIndex:next_bind_point++];
                    [encoder setBytes:&nb00   length:sizeof(uint64_t) atIndex:next_bind_point++];
                    [encoder setBytes:&nb01   length:sizeof(uint64_t) atIndex:next_bind_point++];
                    [encoder setBytes:&nb02   length:sizeof(uint64_t) atIndex:next_bind_point++];
                    [encoder setBytes:&nb03   length:sizeof(uint64_t) atIndex:next_bind_point++];
                    [encoder setBytes:&ne0    length:sizeof( int64_t) atIndex:next_bind_point++];
                    [encoder setBytes:&ne1    length:sizeof( int64_t) atIndex:next_bind_point++];
                    [encoder setBytes:&ne2    length:sizeof( int64_t) atIndex:next_bind_point++];
                    [encoder setBytes:&ne3    length:sizeof( int64_t) atIndex:next_bind_point++];
                    [encoder setBytes:&nb0    length:sizeof(uint64_t) atIndex:next_bind_point++];
                    [encoder setBytes:&nb1    length:sizeof(uint64_t) atIndex:next_bind_point++];
                    [encoder setBytes:&nb2    length:sizeof(uint64_t) atIndex:next_bind_point++];
                    [encoder setBytes:&nb3    length:sizeof(uint64_t) atIndex:next_bind_point++];
                    [encoder setBytes:&n_past length:sizeof(     int) atIndex:next_bind_point++];
                    [encoder setBytes:&n_dims length:sizeof(     int) atIndex:next_bind_point++];
                    [encoder setBytes:&mode   length:sizeof(     int) atIndex:next_bind_point++];

                    [encoder dispatchThreadgroups:MTLSizeMake(ne01, ne02, ne03) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
                } break;
            case GGML_OP_CPY:
                {
                    if (encoder == nil) {
                        encoder = [command_buffer computeCommandEncoder];
                    }

                    const int nth = 32;

                    switch (src0t) {
                        case GGML_TYPE_F32:
                            {
                                switch (dstt) {
                                    case GGML_TYPE_F16: [encoder setComputePipelineState:ctx->pipeline_cpy_f32_f16]; break;
                                    case GGML_TYPE_F32: [encoder setComputePipelineState:ctx->pipeline_cpy_f32_f32]; break;
                                    default: GGML_ASSERT(false && "not implemented");
                                };
                            } break;
                        default: GGML_ASSERT(false && "not implemented");
                    }

                    ENCODE_BUFFER(src0, Read);
                    ENCODE_BUFFER(dst, Write);
                    [encoder setBytes:&ne00 length:sizeof( int64_t) atIndex:next_bind_point++];
                    [encoder setBytes:&ne01 length:sizeof( int64_t) atIndex:next_bind_point++];
                    [encoder setBytes:&ne02 length:sizeof( int64_t) atIndex:next_bind_point++];
                    [encoder setBytes:&ne03 length:sizeof( int64_t) atIndex:next_bind_point++];
                    [encoder setBytes:&nb00 length:sizeof(uint64_t) atIndex:next_bind_point++];
                    [encoder setBytes:&nb01 length:sizeof(uint64_t) atIndex:next_bind_point++];
                    [encoder setBytes:&nb02 length:sizeof(uint64_t) atIndex:next_bind_point++];
                    [encoder setBytes:&nb03 length:sizeof(uint64_t) atIndex:next_bind_point++];
                    [encoder setBytes:&ne0  length:sizeof( int64_t) atIndex:next_bind_point++];
                    [encoder setBytes:&ne1  length:sizeof( int64_t) atIndex:next_bind_point++];
                    [encoder setBytes:&ne2  length:sizeof( int64_t) atIndex:next_bind_point++];
                    [encoder setBytes:&ne3  length:sizeof( int64_t) atIndex:next_bind_point++];
                    [encoder setBytes:&nb0  length:sizeof(uint64_t) atIndex:next_bind_point++];
                    [encoder setBytes:&nb1  length:sizeof(uint64_t) atIndex:next_bind_point++];
                    [encoder setBytes:&nb2  length:sizeof(uint64_t) atIndex:next_bind_point++];
                    [encoder setBytes:&nb3  length:sizeof(uint64_t) atIndex:next_bind_point++];

                    [encoder dispatchThreadgroups:MTLSizeMake(ne01, ne02, ne03) threadsPerThreadgroup:MTLSizeMake(nth, 1, 1)];
                } break;
            default:
                fprintf(stderr, "%s: node %3d, op = %8s not implemented\n", __func__, i, ggml_op_name(dst->op));
                GGML_ASSERT(false);
        }
    }

    if (encoder != nil) {
        [encoder endEncoding];
        encoder = nil;
    }

    [command_buffer commit];
    [command_buffer waitUntilCompleted];

    {
        const double time_elapsed = [command_buffer GPUEndTime] - [command_buffer GPUStartTime];
        UNUSED(time_elapsed);

        metal_printf("%s: time elapsed = %f ms\n", __func__, time_elapsed * 1000.0);
    }
}
