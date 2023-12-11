/*
 * keccak.cu  Implementation of Keccak/SHA3 digest
 *
 * Date: 12 June 2019
 * Revision: 1
 *
 * This file is released into the Public Domain.
 */
 
// Edited by krlnokrl
#include <cuda.h>
#include <cuda_runtime.h>
#include <curand_kernel.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <unistd.h>
#include <cstdlib>
#include <ctime>
 
typedef unsigned char BYTE;
typedef unsigned int  WORD;
typedef unsigned long long LONG; 
 

#define KECCAK_ROUND 24
#define KECCAK_STATE_SIZE 25
#define KECCAK_Q_SIZE 192

#define N 2147483640

__constant__ LONG CUDA_KECCAK_CONSTS[24] = { 0x0000000000000001, 0x0000000000008082,
                                          0x800000000000808a, 0x8000000080008000, 0x000000000000808b, 0x0000000080000001, 0x8000000080008081,
                                          0x8000000000008009, 0x000000000000008a, 0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
                                          0x000000008000808b, 0x800000000000008b, 0x8000000000008089, 0x8000000000008003, 0x8000000000008002,
                                          0x8000000000000080, 0x000000000000800a, 0x800000008000000a, 0x8000000080008081, 0x8000000000008080,
                                          0x0000000080000001, 0x8000000080008008 };

typedef struct {

    BYTE sha3_flag;
    WORD digestbitlen;
    LONG rate_bits;
    LONG rate_BYTEs;
    LONG absorb_round;

    int64_t state[KECCAK_STATE_SIZE];
    BYTE q[KECCAK_Q_SIZE];

    LONG bits_in_queue;

} cuda_keccak_ctx_t;
typedef cuda_keccak_ctx_t CUDA_KECCAK_CTX;


__device__ __forceinline__ LONG cuda_keccak_leuint64(void* const in)
{
    LONG a;
    memcpy(&a, in, 8);
    return a;
}


//#define cuda_keccak_MIN(a,b) ((a) < (b) ? (a) : (b))
//#define cuda_keccak_UMIN(a,b) ((a) < (b) ? (a) : (b))


__device__ __forceinline__ int64_t cuda_keccak_MIN(const int64_t a, const int64_t b)
{
    if (a > b) return b;
    return a;
}

__device__ __forceinline__ LONG cuda_keccak_UMIN(const LONG a, const LONG b)
{
    if (a > b) return b;
    return a;
}

__device__ __forceinline__ unsigned long long xor5(const unsigned long long a, const unsigned long long b, const unsigned long long c, const unsigned long long d, const unsigned long long e)
{
	unsigned long long result;
	asm("xor.b64 %0, %1, %2;" : "=l"(result) : "l"(d) ,"l"(e));
	asm("xor.b64 %0, %0, %1;" : "+l"(result) : "l"(c));
	asm("xor.b64 %0, %0, %1;" : "+l"(result) : "l"(b));
	asm("xor.b64 %0, %0, %1;" : "+l"(result) : "l"(a));
	return result;
}


__device__ void cuda_keccak_extract(cuda_keccak_ctx_t *ctx)
{
    LONG len = ctx->rate_bits >> 6;
    int64_t a;
    int s = sizeof(LONG);
	
	#pragma unroll 2
    for (int i = 0;i < len;i++) {
        a = cuda_keccak_leuint64((int64_t*)&ctx->state[i]);
        memcpy(ctx->q + (i * s), &a, s);
    }
}


__device__ __forceinline__ unsigned long long cuda_keccak_ROTL64(const unsigned long long x, const int offset) {
	unsigned long long res;
	asm("{ // ROTL64 \n\t"
		".reg .u32 tl,th,vl,vh;\n\t"
		".reg .pred p;\n\t"
		"mov.b64 {tl,th}, %1;\n\t"
		"shf.l.wrap.b32 vl, tl, th, %2;\n\t"
		"shf.l.wrap.b32 vh, th, tl, %2;\n\t"
		"setp.lt.u32 p, %2, 32;\n\t"
		"@!p mov.b64 %0, {vl,vh};\n\t"
		"@p  mov.b64 %0, {vh,vl};\n\t"
	"}\n" : "=l"(res) : "l"(x) , "r"(offset)
	);
	return res;
}
/*__device__ __forceinline__ LONG cuda_keccak_ROTL64(LONG a, LONG  b)
{
    return (a << b) | (a >> (64 - b));
}
*/



__device__ __forceinline__ static void cuda_keccak_permutations(cuda_keccak_ctx_t * ctx)
{

    int64_t* A = ctx->state;;

    int64_t *a00 = A, *a01 = A + 1, *a02 = A + 2, *a03 = A + 3, *a04 = A + 4;
    int64_t *a05 = A + 5, *a06 = A + 6, *a07 = A + 7, *a08 = A + 8, *a09 = A + 9;
    int64_t *a10 = A + 10, *a11 = A + 11, *a12 = A + 12, *a13 = A + 13, *a14 = A + 14;
    int64_t *a15 = A + 15, *a16 = A + 16, *a17 = A + 17, *a18 = A + 18, *a19 = A + 19;
    int64_t *a20 = A + 20, *a21 = A + 21, *a22 = A + 22, *a23 = A + 23, *a24 = A + 24;
	
	int64_t c0;
	int64_t c1;
	int64_t c2;
	int64_t c3;
	int64_t c4;
	
	int64_t d0;
	int64_t d1;
	int64_t d2;
	int64_t d3;
	int64_t d4;
	
	#pragma unroll 2
    for (int i = 0; i < KECCAK_ROUND; i++) {

        /* Theta */
        /*
		c0 = *a00 ^ *a05 ^ *a10 ^ *a15 ^ *a20;
        c1 = *a01 ^ *a06 ^ *a11 ^ *a16 ^ *a21;
        c2 = *a02 ^ *a07 ^ *a12 ^ *a17 ^ *a22;
        c3 = *a03 ^ *a08 ^ *a13 ^ *a18 ^ *a23;
        c4 = *a04 ^ *a09 ^ *a14 ^ *a19 ^ *a24;
		*/
		c0 = xor5(*a00, *a05, *a10, *a15, *a20);
		c1 = xor5(*a01, *a06, *a11, *a16, *a21);
		c2 = xor5(*a02, *a07, *a12, *a17, *a22);
		c3 = xor5(*a03, *a08, *a13, *a18, *a23);
		c4 = xor5(*a04, *a09, *a14, *a19, *a24);
		
        d1 = cuda_keccak_ROTL64(c1, 1) ^ c4;
        d2 = cuda_keccak_ROTL64(c2, 1) ^ c0;
        d3 = cuda_keccak_ROTL64(c3, 1) ^ c1;
        d4 = cuda_keccak_ROTL64(c4, 1) ^ c2;
        d0 = cuda_keccak_ROTL64(c0, 1) ^ c3;

        *a00 ^= d1;
        *a05 ^= d1;
        *a10 ^= d1;
        *a15 ^= d1;
        *a20 ^= d1;
        *a01 ^= d2;
        *a06 ^= d2;
        *a11 ^= d2;
        *a16 ^= d2;
        *a21 ^= d2;
        *a02 ^= d3;
        *a07 ^= d3;
        *a12 ^= d3;
        *a17 ^= d3;
        *a22 ^= d3;
        *a03 ^= d4;
        *a08 ^= d4;
        *a13 ^= d4;
        *a18 ^= d4;
        *a23 ^= d4;
        *a04 ^= d0;
        *a09 ^= d0;
        *a14 ^= d0;
        *a19 ^= d0;
        *a24 ^= d0;

        /* Rho pi */
        c1 = cuda_keccak_ROTL64(*a01, 1);
        *a01 = cuda_keccak_ROTL64(*a06, 44);
        *a06 = cuda_keccak_ROTL64(*a09, 20);
        *a09 = cuda_keccak_ROTL64(*a22, 61);
        *a22 = cuda_keccak_ROTL64(*a14, 39);
        *a14 = cuda_keccak_ROTL64(*a20, 18);
        *a20 = cuda_keccak_ROTL64(*a02, 62);
        *a02 = cuda_keccak_ROTL64(*a12, 43);
        *a12 = cuda_keccak_ROTL64(*a13, 25);
        *a13 = cuda_keccak_ROTL64(*a19, 8);
        *a19 = cuda_keccak_ROTL64(*a23, 56);
        *a23 = cuda_keccak_ROTL64(*a15, 41);
        *a15 = cuda_keccak_ROTL64(*a04, 27);
        *a04 = cuda_keccak_ROTL64(*a24, 14);
        *a24 = cuda_keccak_ROTL64(*a21, 2);
        *a21 = cuda_keccak_ROTL64(*a08, 55);
        *a08 = cuda_keccak_ROTL64(*a16, 45);
        *a16 = cuda_keccak_ROTL64(*a05, 36);
        *a05 = cuda_keccak_ROTL64(*a03, 28);
        *a03 = cuda_keccak_ROTL64(*a18, 21);
        *a18 = cuda_keccak_ROTL64(*a17, 15);
        *a17 = cuda_keccak_ROTL64(*a11, 10);
        *a11 = cuda_keccak_ROTL64(*a07, 6);
        *a07 = cuda_keccak_ROTL64(*a10, 3);
        *a10 = c1;

        /* Chi */
        c0 = *a00 ^ (~*a01 & *a02);
        c1 = *a01 ^ (~*a02 & *a03);
        *a02 ^= ~*a03 & *a04;
        *a03 ^= ~*a04 & *a00;
        *a04 ^= ~*a00 & *a01;
        *a00 = c0;
        *a01 = c1;

        c0 = *a05 ^ (~*a06 & *a07);
        c1 = *a06 ^ (~*a07 & *a08);
        *a07 ^= ~*a08 & *a09;
        *a08 ^= ~*a09 & *a05;
        *a09 ^= ~*a05 & *a06;
        *a05 = c0;
        *a06 = c1;

        c0 = *a10 ^ (~*a11 & *a12);
        c1 = *a11 ^ (~*a12 & *a13);
        *a12 ^= ~*a13 & *a14;
        *a13 ^= ~*a14 & *a10;
        *a14 ^= ~*a10 & *a11;
        *a10 = c0;
        *a11 = c1;

        c0 = *a15 ^ (~*a16 & *a17);
        c1 = *a16 ^ (~*a17 & *a18);
        *a17 ^= ~*a18 & *a19;
        *a18 ^= ~*a19 & *a15;
        *a19 ^= ~*a15 & *a16;
        *a15 = c0;
        *a16 = c1;

        c0 = *a20 ^ (~*a21 & *a22);
        c1 = *a21 ^ (~*a22 & *a23);
        *a22 ^= ~*a23 & *a24;
        *a23 ^= ~*a24 & *a20;
        *a24 ^= ~*a20 & *a21;
        *a20 = c0;
        *a21 = c1;

        /* Iota */
        *a00 ^= CUDA_KECCAK_CONSTS[i];
    }
}


__device__ __forceinline__ void cuda_keccak_absorb(cuda_keccak_ctx_t *ctx, BYTE* const in)
{

    LONG offset = 0;
	
	#pragma unroll 2
    for (LONG i = 0; i < ctx->absorb_round; ++i) {
        ctx->state[i] ^= cuda_keccak_leuint64(in + offset);
        offset += 8;
    }

    cuda_keccak_permutations(ctx);
}

__device__ __forceinline__ void cuda_keccak_pad(cuda_keccak_ctx_t *ctx)
{
    ctx->q[ctx->bits_in_queue >> 3] |= (1L << (ctx->bits_in_queue & 7));

    if (++(ctx->bits_in_queue) == ctx->rate_bits) {
        cuda_keccak_absorb(ctx, ctx->q);
        ctx->bits_in_queue = 0;
    }

    LONG full = ctx->bits_in_queue >> 6;
    LONG partial = ctx->bits_in_queue & 63;

    LONG offset = 0;
    for (int i = 0; i < full; ++i) {
        ctx->state[i] ^= cuda_keccak_leuint64(ctx->q + offset);
        offset += 8;
    }

    if (partial > 0) {
        LONG mask = (1L << partial) - 1;
        ctx->state[full] ^= cuda_keccak_leuint64(ctx->q + offset) & mask;
    }

    ctx->state[(ctx->rate_bits - 1) >> 6] ^= 9223372036854775808ULL;/* 1 << 63 */

    cuda_keccak_permutations(ctx);
    cuda_keccak_extract(ctx);

    ctx->bits_in_queue = ctx->rate_bits;
}

/*
 * Digestbitlen must be 128 224 256 288 384 512
 */
__device__ void cuda_keccak_init(cuda_keccak_ctx_t *ctx, const WORD digestbitlen)
{
    memset(ctx, 0, sizeof(cuda_keccak_ctx_t));
    ctx->sha3_flag = 0;
    ctx->digestbitlen = digestbitlen;
    ctx->rate_bits = 1600 - ((ctx->digestbitlen) << 1);
    ctx->rate_BYTEs = ctx->rate_bits >> 3;
    ctx->absorb_round = ctx->rate_bits >> 6;
    ctx->bits_in_queue = 0;
}

/*
 * Digestbitlen must be 224 256 384 512
 */
__device__ void cuda_keccak_sha3_init(cuda_keccak_ctx_t *ctx, const WORD digestbitlen)
{
    cuda_keccak_init(ctx, digestbitlen);
    ctx->sha3_flag = 1;
}

__device__ void cuda_keccak_update(cuda_keccak_ctx_t *ctx, BYTE* const in, const LONG inlen)
{
    int64_t BYTEs = ctx->bits_in_queue >> 3;
    int64_t count = 0;
	int64_t partial = 0;
    while (count < inlen) {
        if (BYTEs == 0 && count <= ((int64_t)(inlen - ctx->rate_BYTEs))) {
            do {
                cuda_keccak_absorb(ctx, in + count);
                count += ctx->rate_BYTEs;
            } while (count <= ((int64_t)(inlen - ctx->rate_BYTEs)));
        } else {
            partial = cuda_keccak_MIN(ctx->rate_BYTEs - BYTEs, inlen - count);
            memcpy(ctx->q + BYTEs, in + count, partial);

            BYTEs += partial;
            count += partial;

            if (BYTEs == ctx->rate_BYTEs) {
                cuda_keccak_absorb(ctx, ctx->q);
                BYTEs = 0;
            }
        }
    }
    ctx->bits_in_queue = BYTEs << 3;
}

__device__ void cuda_keccak_final(cuda_keccak_ctx_t *ctx, BYTE *out)
{
    if (ctx->sha3_flag) {
        int mask = (1 << 2) - 1;
        ctx->q[ctx->bits_in_queue >> 3] = (BYTE)(0x02 & mask);
        ctx->bits_in_queue += 2;
    }

    cuda_keccak_pad(ctx);
    LONG i = 0;

    while (i < ctx->digestbitlen) {
        if (ctx->bits_in_queue == 0) {
            cuda_keccak_permutations(ctx);
            cuda_keccak_extract(ctx);
            ctx->bits_in_queue = ctx->rate_bits;
        }

        LONG partial_block = cuda_keccak_UMIN(ctx->bits_in_queue, ctx->digestbitlen - i);
        memcpy(out + (i >> 3), ctx->q + (ctx->rate_BYTEs - (ctx->bits_in_queue >> 3)), partial_block >> 3);
        ctx->bits_in_queue -= partial_block;
        i += partial_block;
    }
}

__global__ void calculate(int timestamp) {
    int tid = threadIdx.x + blockIdx.x * blockDim.x;

    BYTE data[32] = {0};
    memcpy(data, &tid, 4);

    curandState state;
    curand_init((unsigned long long)clock() + tid, 0, 0, &state);

    for (int i = 4; i < 64; i += 4) {
        int block = (int)(curand_uniform_double(&state) * 1000000);
        memcpy(data+(i)/2, &block, 4);
    }

    memcpy(data+20, &timestamp, 4);

    BYTE challenge[32] = {0};
    challenge[0] = 0x72;
    challenge[1] = 0x45;
    challenge[2] = 0x54;
    challenge[3] = 0x48;

    BYTE hash[32] = {0};
        

    for (int i=0; i <N; i++) {
        memcpy(data+22, &i, 4);
        CUDA_KECCAK_CTX ctx;

        cuda_keccak_init(&ctx, 256);
        cuda_keccak_update(&ctx, data, 32);
        cuda_keccak_update(&ctx, challenge, 32);
        cuda_keccak_final(&ctx, hash);

      if (hash[0] == 0x00 && hash[1] == 0x77 && hash[2] == 0x77 && hash[3] == 0x77 && hash[4] == 0x77 && hash[5] == 0x77) {
          printf("0x");
          for (int j = 0; j < 32; j ++) {
            printf("%02x", data[j]);
          }
          printf("\n");
      }
    }

}

int main(int argc, char **argv) {
    int gpuid = 0;
    if (argc == 2) {
        gpuid = std::atoi(argv[1]);
    }
    cudaSetDevice(gpuid);
    while (true) {
            time_t currentUnixTime = std::time(nullptr);
            calculate<<<24, 256>>>(static_cast<int>(currentUnixTime));
    }
    cudaDeviceSynchronize();  // not important
}

